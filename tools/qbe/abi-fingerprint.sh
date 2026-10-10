#!/usr/bin/env bash
# abi-fingerprint.sh — the .ssa <-> rt.o ABI marker, DERIVED from the tree.
#
# WHY THIS EXISTS.  `tools/bootstrap/compiler.ssa` is emitted QBE IL: it CALLS
# the runtime's exported symbols, DECLARES its own view of the runtime's
# aggregates (`type :val` / `:ret` / `:desc`) and DEFINES the arity table
# (`export function :ret $rt_call0..$rt_callN`) that `rt.o` dispatches into.
# Nothing in that pairing is checked by QBE or by cc: a `.ssa` and an `rt.o`
# built from different revisions of the runtime link CLEANLY and then read
# each other's structs at the wrong offsets — a silent wrong answer, this
# repo's stale-artifact class.  The seed therefore carries a marker, and
# `tools/qbe-bootstrap.sh` recomputes it from the CURRENT tree and refuses on
# a mismatch.
#
# WHAT THE MARKER COVERS (each an interface, not an implementation, so a
# comment or a private-function change inside rt.zig does NOT move it):
#   rt:exports  every `export fn` signature in tools/qbe/rt.zig — the symbols
#               the .ssa calls (sorted).
#   rt:callN    every `extern fn rt_callN` signature — the arity dispatch
#               table the .ssa must DEFINE (sorted).
#   rt:types    the `max_arity` / `Desc` / `Meta` / `Ret` declarations in
#               tools/qbe/rt.zig (braces-literal typed / returned across the
#               ABI or written by generated `data` blocks).
#   gc:layout   the `ValTag` enum and the `Value` struct in
#               vendor/osier-rt/src/gc/types.zig (the layout the collector
#               scans and the .ssa reads at fixed offsets).
#
# Comments are stripped and whitespace squeezed BEFORE hashing, so the marker
# tracks declarations, not formatting.
#
# Usage:
#   tools/qbe/abi-fingerprint.sh                 # print every component + marker
#   tools/qbe/abi-fingerprint.sh --write  <abi>  # (re)freeze a seed's .abi file
#   tools/qbe/abi-fingerprint.sh --check  <abi>  # assert an .abi against the tree
#   tools/qbe/abi-fingerprint.sh --status <abi>  # REPORT ONLY: fresh/drifted/stale
#
# Exit: 0 ok / fresh; 3 the marker does NOT match the tree (--check); 2 tooling
#       failure.  --status NEVER exits non-zero on staleness (it is the
#       report-only path: a stale seed is expected and still bootstraps).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RT="$ROOT/tools/qbe/rt.zig"
TYPES="$ROOT/vendor/osier-rt/src/gc/types.zig"
MANIFEST="$ROOT/elm-compiler/selfhost/manifest.json"

sha() { sha256sum | cut -c1-64; }

# ---- normalisation + block extraction ---------------------------------------
# `norm` strips a trailing `//` comment and squeezes whitespace; `blocks`
# prints a whole declaration, brace-balanced, starting at an ERE-matching line.
norm() { sed -e 's|//.*||' -e 's/[[:space:]]\+/ /g' -e 's/^ //' -e 's/ $//' | grep -v '^$' || true; }

blocks() { # $1 file, $2 start-line ERE
  awk -v start="$2" '
    function depth(s,   i,c,n) {
      n = 0
      for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); if (c == "{") n++; else if (c == "}") n-- }
      return n
    }
    { if (!on) { if ($0 ~ start) { on = 1; d = 0 } else next } }
    { print; s = $0; sub(/\/\/.*/, "", s); d += depth(s); if (d == 0) on = 0 }
  ' "$1"
}

# ---- components -------------------------------------------------------------
rt_exports() { grep -E '^export fn ' "$RT" | norm | sort | sha; }
rt_calln()   { grep -E '^extern fn rt_call' "$RT" | norm | sort | sha; }
rt_types()   { { blocks "$RT" '^const max_arity'; blocks "$RT" '^pub const (Desc|Meta|Ret)'; } | norm | sha; }
# ValTag's block is cut at its first inner `pub fn` (char(): the legacy
# tag->char table is not LAYOUT, so a change to it must not move the marker).
gc_layout()  { { blocks "$TYPES" '^pub const ValTag =' | sed '/^[[:space:]]*pub fn /,$d'
                 blocks "$TYPES" '^pub const Value ='; } | norm | sha; }

# ---- emit inputs (REPORT-ONLY freshness, never a gate) ----------------------
# Everything ONE emission of the whole-compiler .ssa reads: the manifest's 64
# sources, the fixed corpus run.js always appends, and run.js itself.  The
# digest is a PROXY for "would the emit still produce the seed's bytes" — it
# is deliberately not an emit, which costs minutes.
emit_inputs() {
  local n=0
  {
    jq -r '.groups[0].sources[]' "$MANIFEST"
    printf '%s\n' \
      elm-compiler/run.js \
      elm-compiler/src/Prelude.elm \
      elm-compiler/src/Runtime.elm
    (cd "$ROOT/elm-compiler/core-libs" && ls *.elm | sed 's|^|elm-compiler/core-libs/|')
  } | sort -u | while read -r f; do
        printf '%s  %s\n' "$(sha256sum "$ROOT/$f" | cut -c1-64)" "$f"
      done | sha
}

marker_of() { # $1 rt:exports digest, $2 rt:callN, $3 rt:types, $4 gc:layout
  printf 'rt:exports %s\nrt:callN %s\nrt:types %s\ngc:layout %s\n' "$1" "$2" "$3" "$4" | sha
}

# ---- gather ----------------------------------------------------------------
[ -f "$RT" ]      || { echo "abi-fingerprint: missing $RT" >&2; exit 2; }
[ -f "$TYPES" ]   || { echo "abi-fingerprint: missing $TYPES" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "abi-fingerprint: jq not found" >&2; exit 2; }

RT_EXPORTS="$(rt_exports)"
RT_CALLN="$(rt_calln)"
RT_TYPES="$(rt_types)"
GC_LAYOUT="$(gc_layout)"
MARKER="$(marker_of "$RT_EXPORTS" "$RT_CALLN" "$RT_TYPES" "$GC_LAYOUT")"

# The .abi reader: `key=value`, `#` comments.  Values never contain `=`.
abi_get() { grep -E "^$2=" "$1" | head -1 | cut -d= -f2-; }

case "${1:-}" in
  ""|--print)
    printf 'abi-marker=%s\n'      "$MARKER"
    printf 'abi-rt-exports=%s\n'  "$RT_EXPORTS"
    printf 'abi-rt-callN=%s\n'    "$RT_CALLN"
    printf 'abi-rt-types=%s\n'    "$RT_TYPES"
    printf 'abi-gc-layout=%s\n'   "$GC_LAYOUT"
    ;;
  --write)
    ABI="${2:?abi-fingerprint: --write needs the .abi path}"
    SEED="${3:?abi-fingerprint: --write needs the seed path}"
    [ -s "$SEED" ] || { echo "abi-fingerprint: no seed at $SEED" >&2; exit 2; }
    {
      printf '# %s — the ABI marker + provenance for %s.\n' "$(basename "$ABI")" "$(basename "$SEED")"
      printf '# Regenerate the two together:  tools/qbe-bootstrap.sh --freeze\n'
      printf '# Written by tools/qbe/abi-fingerprint.sh --write; the components are\n'
      printf '# digests of DECLARATIONS (comments/whitespace stripped), so a comment\n'
      printf '# edit in rt.zig does NOT move the marker.\n'
      printf 'seed-bytes=%s\n'    "$(stat -c %s "$SEED")"
      printf 'seed-sha256=%s\n'   "$(sha256sum "$SEED" | cut -c1-64)"
      printf 'abi-marker=%s\n'    "$MARKER"
      printf 'abi-rt-exports=%s\n' "$RT_EXPORTS"
      printf 'abi-rt-callN=%s\n'  "$RT_CALLN"
      printf 'abi-rt-types=%s\n'  "$RT_TYPES"
      printf 'abi-gc-layout=%s\n' "$GC_LAYOUT"
      printf 'emit-inputs=%s\n'   "$(emit_inputs)"
    } > "$ABI"
    echo "abi-fingerprint: wrote $ABI (marker $MARKER)"
    ;;
  --check)
    ABI="${2:?abi-fingerprint: --check needs the .abi path}"
    [ -f "$ABI" ] || { echo "abi-fingerprint: no marker file at $ABI" >&2; exit 2; }
    got="$(abi_get "$ABI" abi-marker)"
    if [ "$got" = "$MARKER" ]; then
      echo "abi-fingerprint: OK — the seed's ABI marker matches this tree ($MARKER)"
      exit 0
    fi
    echo "abi-fingerprint: ABI MISMATCH" >&2
    echo "  seed $ABI records abi-marker=$got" >&2
    echo "  this tree  computes   abi-marker=$MARKER" >&2
    echo "  the runtime interface MOVED since the seed was emitted; a .ssa" >&2
    echo "  and an rt.o from different revisions link cleanly and then read" >&2
    echo "  each other's structs at the wrong offsets.  Components that differ:" >&2
    for c in rt-exports:RT_EXPORTS rt-callN:RT_CALLN rt-types:RT_TYPES gc-layout:GC_LAYOUT; do
      key="${c%%:*}"; var="${c##*:}"
      a="$(abi_get "$ABI" "abi-$key")"
      b="${!var}"
      [ "$a" = "$b" ] || printf '    %-10s seed %s  tree %s\n' "$key" "$a" "$b" >&2
    done
    echo "  Remedy: re-emit the seed and re-freeze the marker TOGETHER —" >&2
    echo "      tools/qbe-bootstrap.sh --freeze   (see tools/bootstrap/PROVENANCE.md)" >&2
    exit 3
    ;;
  --status)
    ABI="${2:?abi-fingerprint: --status needs the .abi path}"
    [ -f "$ABI" ] || { echo "absent"; exit 0; }
    got="$(abi_get "$ABI" abi-marker)"
    want="$(abi_get "$ABI" emit-inputs)"
    have="$(emit_inputs)"
    if [ "$got" != "$MARKER" ]; then
      printf 'ABI-STALE — the runtime interface moved; tools/qbe-bootstrap.sh will refuse (%s)\n' "$got"
    elif [ "$want" = "$have" ]; then
      printf 'FRESH — the emit inputs are unchanged since the seed was frozen\n'
    else
      printf 'DRIFTED — the emit inputs moved since the seed was frozen (expected; still bootstraps)\n'
    fi
    exit 0
    ;;
  *)
    echo "abi-fingerprint: usage: abi-fingerprint.sh [--write <abi> <seed> | --check <abi> | --status <abi>]" >&2
    exit 2
    ;;
esac
