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
#   2. NO ZIG-GC ALLOCATOR REMAINS AT ALL, and the argv registry is the seat
#      that closed it (O5 seat 4b): `rt_argv_install` -> buildArgvList ->
#      values.valString/valCons WAS the last one, and it is now Mid's
#      (Rt.argvInstall/Rt.argvGo, rooted on a C-heap accumulator slot).  So the
#      row is measured the other way round: `rt_argv_install`/`rt_parse_arg`
#      must appear ZERO times (a reappearance is a retired seat coming back),
#      and the MID installer `q_Rt_x2eargvInstall` must appear in EVERY
#      accepted program — Rt.main calls it unconditionally, so a future change
#      that silently drops or reroutes it shows up as a count, not as prose.
#      Its ROOTING is probe-midgc-argv.sh's job.
#   3. THE REFUSAL SET IS NOW EMPTY — 0 host-seam, 0 `value`-prim — and that is
#      the point, not a regression.  Until stage 7 O2 this probe pinned 21
#      refused groups (7 host-seam: Platform.program/Platform.worker ->
#      Runtime.program/Runtime.worker; 14 `value`-prim), because Lower.elm
#      refused QBE_MIDGC=1 for any program whose host was the ZIG one.  O2 made
#      the MID host the default and DELETED both refusal arms: the hole they
#      refused closes by construction (one heap, the Mid collector, for every
#      allocation on the route), so the sound domain is now every group that
#      COMPILES.  The refusals' replacement is not a census but a CHOICE: the
#      still-unsound pairing is "Mid heap + Zig host", which run.js refuses at
#      BUILD time (MIDGC_DEPENDS_ON's QBE_MIDHOST entry) and which a MIDGC-built
#      binary refuses again at RUN time (Rt.main's QBE_MIDGC region, stage 7 O3
#      — see probe-midgc-midhost0.sh).  So the numbers to keep honest here are:
#      refusals 0/0 (a refusal REAPPEARING means an arm came back), accepted ==
#      every non-error group, and claim 1's forbidden count still 0 across that
#      WIDER domain — which is what makes the widened domain safe to claim.
#      The 34 non-emitting groups are PRE-EXISTING compile_error rows (type
#      errors), which are neither accepted nor refused-by-census.
#
# (The flag is still passed EXPLICITLY: since stage 7 O3 QBE_MIDGC=1 IS the
# default, so this reads the same emit either way — but the probe measures the
# MIDGC route BY NAME, which is what makes it a pin rather than a coincidence.)
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
: > "$WORK/retired.txt"
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
  grep -q 'call \$q_Rt_x2eargvInstall' "$f" && printf '%s ' "$n" >> "$WORK/argv.txt"
  grep -oE 'call \$(rt_argv_install|rt_parse_arg)' "$f" | sort -u | sed "s|^|$n: |" >> "$WORK/retired.txt"
done

n_acc=0; for x in $(cat "$WORK/accepted.txt"); do n_acc=$((n_acc+1)); done
n_forb=0; [ -s "$WORK/forbidden.txt" ] && n_forb="$(wc -l < "$WORK/forbidden.txt" | tr -d ' ')"
n_host=0; for x in $(cat "$WORK/hostseam.txt"); do n_host=$((n_host+1)); done
n_val=0;  for x in $(cat "$WORK/valueprim.txt");  do n_val=$((n_val+1)); done
n_pre=0;  for x in $(cat "$WORK/preexisting.txt"); do n_pre=$((n_pre+1)); done
n_argv=0; for x in $(cat "$WORK/argv.txt");       do n_argv=$((n_argv+1)); done
n_ret=0; [ -s "$WORK/retired.txt" ] && n_ret="$(wc -l < "$WORK/retired.txt" | tr -d ' ')"

echo "census (QBE_MIDGC=1, $(ls "$WORK"/ssa/*.ssa | wc -l | tr -d ' ') groups emitted):"
echo "  accepted (the sound domain)      $n_acc"
echo "  refused by the census            $((n_host + n_val))  ($n_host host-seam: $(cat "$WORK/hostseam.txt"); $n_val value-prim)"
echo "  pre-existing compile_error rows  $n_pre"
echo "  q_Rt_x2eargvInstall reached      $n_argv / $n_acc accepted programs"
echo "  retired Zig driver seats reached $n_ret  (rt_argv_install/rt_parse_arg — want 0)"
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
  echo "FAIL: the MID *argv* installer (q_Rt_x2eargvInstall) is not reached by every accepted program ($n_argv of $n_acc) — Rt.main calls it unconditionally, so either the route moved or this probe is measuring the wrong symbol; the argv row of plan.md §2.2 is now unbacked" >&2
  rc=1
fi
if [ "$n_ret" -ne 0 ]; then
  echo "FAIL: a RETIRED Zig driver seat is still called under QBE_MIDGC=1 (rt_argv_install/rt_parse_arg were deleted at O5 seat 4b) — a route came back:" >&2
  sed 's/^/    /' "$WORK/retired.txt" >&2
  rc=1
fi
# STAGE 7 O2 DELETED THE TWO REFUSAL ARMS, so the set is pinned at ZERO in BOTH
# arms (the census no longer refuses anything; the hole moved to a host CHOICE —
# run.js MIDGC_DEPENDS_ON and, since O3, Rt.main's run-time refusal).  A
# non-zero count here means an arm came back without the argument that deleted
# it, which is why the assertion is `-eq 0` and not a comment.
if [ "$n_host" -ne 0 ] || [ "$n_val" -ne 0 ]; then
  echo "FAIL: the census refuses programs again (host-seam $n_host, value-prim $n_val; want 0/0 since stage 7 O2 deleted the two arms).  A refusal that comes back hides work behind a compile error; if it is intentional, say WHERE the hole reopened and why the host-choice guard cannot cover it." >&2
  echo "  host-seam: $(cat "$WORK/hostseam.txt")" >&2
  echo "  value-prim: $(cat "$WORK/valueprim.txt")" >&2
  rc=1
fi

if [ "$rc" -eq 0 ]; then
  echo "PASS: under QBE_MIDGC=1, no accepted program reaches a Zig-GC allocator, and the"
  echo "      last one on the route — the argv registry — is Mid's now (O5 seat 4b:"
  echo "      Rt.argvInstall/Rt.argvGo over a rooted C-heap slot), reached by every accepted"
  echo "      program.  The refusal set is EMPTY (0/0 — O2's two arms are deleted; the"
  echo "      unsound pairing is a host CHOICE now, refused at build time by run.js and at"
  echo "      run time by Rt.main)."
fi
exit "$rc"
