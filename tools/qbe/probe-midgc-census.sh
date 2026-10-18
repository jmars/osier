#!/usr/bin/env bash
# probe-midgc-census.sh — the HATCH-GATE CENSUS, DERIVED BY EMITTING (GC ARC F1).
#
# WHAT IT PINS.  plan.md §2.2's "still allocates in Zig under QBE_MIDGC=1" table
# is the precondition for ever flipping the hatch, and the plan itself records
# that the table has been WRONG THREE TIMES, always too short, and must be
# "verified by EMITTING, never by intent".  This probe IS that verification: it
# emits EVERY corpus group (the language gate's own registry, the same one
# tools/osier-corpus-ssa.sh walks) with QBE_MIDGC=1 and reads the resulting
# .ssa for the host shim's allocating surface.
#
# THE CLAIMS IT CHECKS (each one is a claim the table makes):
#
#   1. NO Zig-GC CONSTRUCTOR IS REACHED.  `rt_string`, `rt_con`,
#      `rt_make_closure`, `rt_vec_alloc`, `rt_raw_alloc` and the `rt_prim_*`
#      direct prim entries — the allocators whose results live in the ZIG
#      collector's heap — must appear ZERO times across every ACCEPTED program.
#      A reappearance is the cross-heap edge the corrected criterion forbids:
#      a Mid object referencing something the Zig collector can reclaim (or
#      MOVE — the same defect, see plan.md §2.2's stage-5 finding).
#   2. THE ONE REMAINING ZIG-GC ALLOCATOR IS NAMED, and it is the argv
#      registry: `rt_argv_install` -> buildArgvList -> values.valString/valCons.
#      It must appear in EVERY accepted program (Rt.main calls it
#      unconditionally), so a future change that SILENTLY routes another shape
#      through it without touching the table shows up as a count, not as prose.
#      Its reachability argument (why no Mid object can hold it) is in
#      plan.md §2.2's row; its ROOTING is probe-midgc-argv.sh's job.
#   3. THE REFUSAL SET IS EXACTLY THE 21 GROUPS THE CENSUS REFUSES — 7 host-seam
#      (Platform.program/Platform.worker -> Runtime.program/Runtime.worker) and
#      14 `value`-prim.  A refusal that silently WIDENS hides work behind a
#      compile error; one that silently NARROWS is the cross-heap hole.  The
#      other 34 non-emitting groups are PRE-EXISTING compile_error rows (type
#      errors), which are neither accepted nor refused-by-census.
#
# WHAT IT CANNOT SEE (stated, not hidden): the emit is per group ENTRY-REACHABLE,
# so a shape reachable only from an unregistered program is invisible here — the
# same limitation the corpus baseline states.  And it reads BYTES: a seat that
# allocates in Zig without a distinctive symbol (there is none today) is out of
# its reach.
#
# Usage:
#   tools/qbe/probe-midgc-census.sh    # exit 0 = the table's claims hold
#
# Exit: 0 = census clean, 1 = a claim FAILED (the offending groups are printed),
#       2 = tooling.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

GATE="$ROOT/tests/elm-fixtures/run-elm-gate.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/probe-midgc-census.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

need() { command -v "$1" >/dev/null 2>&1 || { echo "probe-midgc-census: $1 not found" >&2; exit 2; }; }
need node
need jq

# ---- the corpus plan, from the GATE's own registry (never a hand list) ----
MANIFEST="$(ELM_GATE_MANIFEST_ONLY=1 "$GATE" 2>/dev/null)" || {
  echo "probe-midgc-census: the gate refused to build its manifest" >&2; exit 2; }
[ -f "$MANIFEST" ] || { echo "probe-midgc-census: no manifest from the gate" >&2; exit 2; }

jq -r '.groups[] | [(.output | split("/")[-1] | sub("\\.(csexp|ssa)$"; "")),
                   (.sources | join(" ")), .entry] | join("|")' "$MANIFEST" > "$WORK/plan.tsv"
[ -s "$WORK/plan.tsv" ] || { echo "probe-midgc-census: empty plan" >&2; exit 2; }

mkdir -p "$WORK/ssa"
cat > "$WORK/one.sh" <<'EOJ'
#!/usr/bin/env bash
IFS='|' read -r name srcs entry <<< "$1"
( cd "$OSIER_ROOT/elm-compiler" && QBE=1 QBE_ENTRY="$entry" QBE_MIDGC=1 node run.js $srcs "$2/$name.ssa" ) \
  > "$2/$name.log" 2>&1
[ -s "$2/$name.ssa" ] || echo "probe-midgc-census: $name produced no output" >&2
EOJ
chmod +x "$WORK/one.sh"
while IFS= read -r line; do [ -n "$line" ] && printf '%s\0' "$line"; done < "$WORK/plan.tsv" \
  | OSIER_ROOT="$ROOT" xargs -0 -r -P "${OSIER_CORPUS_J:-8}" -I{} "$WORK/one.sh" "{}" "$WORK/ssa"
[ "$(ls "$WORK"/ssa/*.ssa 2>/dev/null | wc -l)" -gt 0 ] \
  || { echo "probe-midgc-census: nothing emitted" >&2; exit 1; }

# ---- classify: FORBIDDEN (a Zig-GC allocator), REFUSED (by the census), ----
# ---- PRE-EXISTING (a compile_error row), ACCEPTED (the sound domain)     ----
FORBIDDEN='rt_string|rt_con|rt_make_closure|rt_vec_alloc|rt_raw_alloc|rt_prim_'
: > "$WORK/forbidden.txt"; : > "$WORK/hostseam.txt"; : > "$WORK/valueprim.txt"
: > "$WORK/preexisting.txt"; : > "$WORK/accepted.txt"; : > "$WORK/argv.txt"
for f in "$WORK"/ssa/*.ssa; do
  n="$(basename "$f" .ssa)"
  if head -c 3 "$f" | grep -q '^err'; then
    if grep -q 'host effect loop' "$f"; then printf '%s ' "$n" >> "$WORK/hostseam.txt"
    elif grep -q '`value`' "$f";      then printf '%s ' "$n" >> "$WORK/valueprim.txt"
    else printf '%s ' "$n" >> "$WORK/preexisting.txt"; fi
    continue
  fi
  printf '%s ' "$n" >> "$WORK/accepted.txt"
  grep -oE "call \\\$($FORBIDDEN)[A-Za-z0-9_]*" "$f" | sort -u | sed "s|^|$n: |" >> "$WORK/forbidden.txt"
  grep -q 'call \$rt_argv_install' "$f" && printf '%s ' "$n" >> "$WORK/argv.txt"
done

n_acc=0; for x in $(cat "$WORK/accepted.txt"); do n_acc=$((n_acc+1)); done
n_forb=0; [ -s "$WORK/forbidden.txt" ] && n_forb="$(wc -l < "$WORK/forbidden.txt" | tr -d ' ')"
n_host=0; for x in $(cat "$WORK/hostseam.txt"); do n_host=$((n_host+1)); done
n_val=0;  for x in $(cat "$WORK/valueprim.txt");  do n_val=$((n_val+1)); done
n_pre=0;  for x in $(cat "$WORK/preexisting.txt"); do n_pre=$((n_pre+1)); done
n_argv=0; for x in $(cat "$WORK/argv.txt");       do n_argv=$((n_argv+1)); done

echo "census (QBE_MIDGC=1, $(ls "$WORK"/ssa/*.ssa | wc -l | tr -d ' ') groups emitted):"
echo "  accepted (the sound domain)      $n_acc"
echo "  refused by the census            $((n_host + n_val))  ($n_host host-seam: $(cat "$WORK/hostseam.txt"); $n_val value-prim)"
echo "  pre-existing compile_error rows  $n_pre"
echo "  rt_argv_install reached          $n_argv / $n_acc accepted programs"
echo "  FORBIDDEN Zig-GC allocator calls $n_forb"

rc=0
if [ "$n_forb" -ne 0 ]; then
  echo "FAIL: a Zig-GC allocator is reachable under QBE_MIDGC=1 — the census table is short by these:" >&2
  sed 's/^/    /' "$WORK/forbidden.txt" >&2
  rc=1
fi
if [ "$n_acc" -eq 0 ]; then
  echo "FAIL: no program was accepted — the census is vacuous, not clean" >&2
  rc=1
fi
if [ "$n_argv" -ne "$n_acc" ]; then
  echo "FAIL: rt_argv_install is not reached by every accepted program ($n_argv of $n_acc) — Rt.main calls it unconditionally, so either the route moved or this probe is measuring the wrong symbol; the argv row of plan.md §2.2 is now unbacked" >&2
  rc=1
fi
if [ "$n_host" -ne 7 ] || [ "$n_val" -ne 14 ]; then
  echo "FAIL: the refusal set moved (host-seam $n_host, want 7; value-prim $n_val, want 14)." >&2
  echo "  A WIDER refusal hides work behind a compile error; a NARROWER one is the cross-heap hole." >&2
  echo "  host-seam: $(cat "$WORK/hostseam.txt")" >&2
  echo "  value-prim: $(cat "$WORK/valueprim.txt")" >&2
  rc=1
fi

if [ "$rc" -eq 0 ]; then
  echo "PASS: under QBE_MIDGC=1, no accepted program reaches a Zig-GC allocator; the single"
  echo "      remaining Zig-heap allocation is the argv registry (plan.md §2.2's row), and the"
  echo "      refusal set is exactly the 21 groups the census names."
fi
exit "$rc"
