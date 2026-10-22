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
#   rt:exports  every `export fn` signature in tools/qbe/hostshim.zig — the symbols
#               the .ssa calls (sorted).
#   rt:callN    every `extern fn rt_callN` signature — the arity dispatch
#               table the .ssa must DEFINE (sorted).
#   rt:types    the `max_arity` / `Desc` / `Meta` / `Ret` declarations in
#               tools/qbe/hostshim.zig (braces-literal typed / returned across the
#               ABI or written by generated `data` blocks).
#   gc:layout   the LAYOUT CENSUS (handoff-osier-zigretire-plan STAGE 2): the
#               digest of the ONE definition, `Mid/RtLayout.elm`, as parsed by
#               tools/qbe/layout-census.sh.  It is deliberately NOT a
#               sed-extraction of the Zig declarations any more — the layout
#               lives in exactly one place, and deriving the marker from the
#               census is what makes a change to ANY of those numbers move it
#               (the census's own Zig leg and the comptime rows in types.zig /
#               rt.zig are what then say WHICH seat is wrong).
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
RT="$ROOT/tools/qbe/hostshim.zig"
TYPES="$ROOT/vendor/osier-rt/src/gc/types.zig"
MANIFEST="$ROOT/osier-compiler/selfhost/manifest.json"

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
# ZIGHOST Z6 DELETED tools/qbe/hostshim.zig, so these three components now hash
# an EMPTY declaration set — deliberately, not accidentally: the marker keeps
# SAYING "the Zig runtime interface is empty", which is the post-Z6 truth, and a
# re-appearing hostshim.zig would move them (the `-f` guard reads the file when
# it exists).  WHAT THAT COSTS, stated: the marker can no longer SEE a new Zig
# runtime file under some other name — `git grep -c zig` over the tracked tree
# (0 outside historical prose) and qbe-check's primdirect-symbols tombstone are
# the guards for that, not this digest.
rt_exports() { { [ -f "$RT" ] && grep -E '^export fn ' "$RT" || true; } | norm | sort | sha; }
rt_calln()   { { [ -f "$RT" ] && grep -E '^extern fn rt_call' "$RT" || true; } | norm | sort | sha; }
rt_types()   { { [ -f "$RT" ] && { blocks "$RT" '^const max_arity'; blocks "$RT" '^pub const (Desc|Meta|Ret)'; } || true; } | norm | sha; }
# THE LAYOUT, FROM THE CENSUS — not from the Zig declaration text.  The
# census parses Mid/RtLayout.elm (the single definition) and is what the
# generated `gc/layout_gen.zig` is built from; see tools/qbe/layout-census.sh.
gc_layout()  { "$ROOT/tools/qbe/layout-census.sh" --marker; }

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
      osier-compiler/run.js \
      osier-compiler/src/Prelude.elm \
      osier-compiler/src/Runtime.elm
    (cd "$ROOT/osier-compiler/core-libs" && ls *.elm | sed 's|^|osier-compiler/core-libs/|')
  } | sort -u | while read -r f; do
        printf '%s  %s\n' "$(sha256sum "$ROOT/$f" | cut -c1-64)" "$f"
      done | sha
}

marker_of() { # $1 rt:exports digest, $2 rt:callN, $3 rt:types, $4 gc:layout
  printf 'rt:exports %s\nrt:callN %s\nrt:types %s\ngc:layout %s\n' "$1" "$2" "$3" "$4" | sha
}

# ---- gather ----------------------------------------------------------------
# (ZIGHOST Z6) $RT (hostshim.zig) and $TYPES (gc/types.zig) are GONE with the
# Zig runtime: the three rt:* components hash an empty set, and the LIVE
# component is `gc:layout` — the census of Mid/RtLayout.elm, the single
# definition of every cross-ABI number that the emitted IL is derived from.
# NOTHING here reads a Zig file any more, which is why the marker survives as a
# meaningful check rather than a formality: it pins the layout the .ssa and the
# seed agree on, and the seed's own bytes.
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
      printf '# edit in a declaration does NOT move the marker.\n'
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
    echo "  and a runtime object from different revisions link cleanly and then read" >&2
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
