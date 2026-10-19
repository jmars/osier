#!/usr/bin/env bash
# probe-midgc-verify.sh — GC ARC unit 2: the VERIFIER's negative controls.
#
# A probe whose every arm passes proves nothing about an assert.  Each arm here
# DELIBERATELY corrupts one thing the collector relies on, and the assertion is
# that the corruption is NAMED (which invariant, at which heap offset, in which
# collect) instead of arriving later as a wrong number or a SIGSEGV.  The pair
# that carries the argument is mode 3: the SAME binary is silent with
# QBE_MIDGC_VERIFY off and dies V2 by name with it on — the asymmetry is the
# proof that the post-collect walk measures something.
#
# Instruments under test (elm-compiler/runtime.mid):
#   * the BLOCK MAP, region slot 25 — one byte per 64-byte minimum block,
#     0 = not a block start, 1 = live, 2 = freed (swept, on a free list);
#   * Rt.gcMarkPtr's PER-POINTER invariants, live in EVERY build:
#       "mark of a NON-BLOCK-START pointer at heap offset N (collect K)"
#       "mark of a pointer to a FREED block at heap offset N (collect K)"
#   * QBE_MIDGC_VERIFY=1's post-collect walk (Rt.gcVerify/Rt.gcVerifyLists):
#       V1 block-map agreement / V2 lands exactly on the cursor / V3 no mark
#       bit survives / V4 marked+freed == blocks / V5-V6 the free lists.
#
# Usage: tools/qbe/probe-midgc-verify.sh
# Exit: 0 = every arm behaved as its invariant predicts, 1 = an arm FAILED, 2 = tooling.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

HEAP_MB=16
N=6000
CHURN=12000         # ~7 MB of class-9 churn: crosses the 16 MB heap's 4 MB trigger
GOLDEN=252306000    # mode 0 = Wmidwalk.nat at N/CHURN above (the walk probe's golden)
WORK="$(mktemp -d "${TMPDIR:-/tmp}/probe-midgc-verify.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

need() { command -v "$1" >/dev/null 2>&1 || { echo "probe-midgc-verify: $1 not found" >&2; exit 2; }; }
need node; need cc

rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

BIN="$(QBE_MIDGC=1 "$ROOT/tools/qbe/qbe-mk.sh" tools/qbe/fixtures/midgc-verify.elm tools/qbe/fixtures/midgc-walk.elm MidgcVerify.main "$WORK" 2>"$WORK/mk.log")" \
  || { echo "probe-midgc-verify: qbe-mk failed" >&2; cat "$WORK/mk.log" >&2; exit 1; }

# run <mode> [extra env...] — stdout to $WORK/out, stderr to $WORK/err, status
# in STATUS.  Called DIRECTLY (never in a command substitution): a substitution
# runs this in a subshell and the exit status — the thing every arm below
# reads — would be lost.
STATUS=0
run() {
  local mode="$1"
  shift
  env "$@" QBE_MIDGC=1 QBE_HEAP_MB="$HEAP_MB" QBE_MIDGC_MAXMB="$HEAP_MB" \
    timeout 120 "$BIN" MidgcVerify.main "$mode" "$N" "$CHURN" >"$WORK/out" 2>"$WORK/err"
  STATUS=$?
}

# ---- arm 1: the CORRECT program is green with and without VERIFY ----------
# The no-false-positive control: an instrument that fires on a correct program
# is worthless, and this one runs at EVERY collect of a graph with 12 000 live
# words.
run 0
plain_out="$(cat "$WORK/out")"
plain_rc="$STATUS"
run 0 QBE_MIDGC_VERIFY=1
verify_out="$(cat "$WORK/out")"
if [ "$plain_rc" -eq 0 ] && [ "$STATUS" -eq 0 ] && [ "$verify_out" = "$plain_out" ] && [ "$verify_out" = "$GOLDEN" ]; then
  echo "PASS (1): the correct program prints the golden $verify_out with AND without QBE_MIDGC_VERIFY=1 — the verifier has no false positive"
elif [ "$STATUS" -ne 0 ]; then
  fail "QBE_MIDGC_VERIFY=1 DIED on a correct program (exit $STATUS): $(grep -m1 'qbe-rt' "$WORK/err")"
else
  fail "VERIFY changed a correct program's output ('$plain_out' -> '$verify_out')"
fi

# ---- arm 2: an INTERIOR pointer is named by the marker -------------------
run 1
if [ "$STATUS" -eq 0 ]; then
  fail "an INTERIOR pointer payload was MARKED silently (printed $(cat "$WORK/out")) — the block-start invariant did not fire"
elif grep -q 'NON-BLOCK-START pointer at heap offset' "$WORK/err"; then
  echo "PASS (2): an interior pointer payload is NAMED:"
  echo "          $(grep -m1 'NON-BLOCK-START' "$WORK/err")"
else
  fail "mode 1 died for the wrong reason: $(tail -2 "$WORK/err" | tr '\n' ' ')"
fi

# ---- arm 3: a STALE pointer to a FREED block is named --------------------
# NOREUSE=1 is what makes it deterministic: with the free list never popped the
# block cannot be handed out again, so its state is FREE at the marking collect.
run 2 QBE_MIDGC_NOREUSE=1
if [ "$STATUS" -eq 0 ]; then
  fail "a pointer to a FREED block was MARKED silently (printed $(cat "$WORK/out")) — the stale-pointer invariant did not fire"
elif grep -q 'pointer to a FREED block at heap offset' "$WORK/err"; then
  echo "PASS (3): a stale pointer to a freed block is NAMED under NOREUSE:"
  echo "          $(grep -m1 'FREED block' "$WORK/err")"
  echo "          (stated: with reuse ON the same program is SILENT — the freed block has been re-issued, so the"
  echo "           stale handle aliases a LIVE object and the confusion is invisible to any collector)"
else
  fail "mode 2 died for the wrong reason: $(tail -2 "$WORK/err" | tr '\n' ' ')"
fi

# ---- arm 4: THE ASYMMETRY — a corrupted class is SILENT without VERIFY ---
run 3
bad_plain_rc="$STATUS"
bad_plain_out="$(cat "$WORK/out")"
if [ "$bad_plain_rc" -eq 0 ]; then
  echo "PASS (4a): FAIL-BEFORE — with QBE_MIDGC_VERIFY off, a corrupted block class is SILENT (exit 0, printed '$bad_plain_out'): the sweep jumps past the frontier and everything after it is neither marked nor freed"
else
  echo "NOTE (4a): without VERIFY the corrupted class died anyway (exit $bad_plain_rc): $(grep -m1 'qbe-rt' "$WORK/err")"
fi
run 3 QBE_MIDGC_VERIFY=1
if [ "$STATUS" -eq 0 ]; then
  fail "with QBE_MIDGC_VERIFY=1 a corrupted block class was STILL silent (printed $(cat "$WORK/out")) — the post-collect walk is not reading the block map"
elif grep -q 'VERIFY V2:' "$WORK/err"; then
  echo "PASS (4b): FAIL-AFTER — the same binary with QBE_MIDGC_VERIFY=1 names it:"
  echo "          $(grep -m1 'VERIFY V2' "$WORK/err")"
else
  fail "mode 3 under VERIFY died for the wrong reason: $(tail -2 "$WORK/err" | tr '\n' ' ')"
fi

# ---- arm 5: the verifier is CHEAP ENOUGH to run in the gates --------------
# Measured, not asserted: the same run's sweep+sweepUs line with and without
# VERIFY.  Reported so a later reader sees the cost rather than a claim.
run 0 QBE_MIDGC_STATS=1
plain_us="$(awk '/sweepUs=/ { sub(/.*sweepUs=/, ""); s += $1 } END { print s + 0 }' "$WORK/err")"
run 0 QBE_MIDGC_VERIFY=1 QBE_MIDGC_STATS=1
verify_us="$(awk '/sweepUs=/ { sub(/.*sweepUs=/, ""); s += $1 } END { print s + 0 }' "$WORK/err")"
collects="$(grep -c '^midgc: c=' "$WORK/err")"
if [ "${collects:-0}" -ge 1 ] && [ "${plain_us:-0}" -gt 0 ]; then
  echo "PASS (5): the verifier's cost is MEASURED, not asserted: $collects collect(s), sweep phase ${plain_us}us without VERIFY vs ${verify_us}us with it (the post-collect walk is a second pass over the frontier, so ~2x the sweep is the design point)"
else
  echo "NOTE (5): no collect happened in the stats arm — the cost arm is vacuous at this heap, not a failure"
fi

# ---- arm 6: the verifier's own STACK, at a ceiling with ~131 000 classes ---
# The walkers must be SELF-recursive (the lowerer turns `return call self(..)`
# into `jmp @body`); the first version split the class loop and the list walk
# into two MUTUALLY recursive defuns, and at a 4 GB ceiling (numClass ~131 000)
# that chain ran the C stack out — a SIGSEGV inside the FORENSIC instrument, the
# one failure mode that must never happen.  This arm is the regression guard:
# it is a plain run with VERIFY on, and the assertion is that it does not die.
run 0 QBE_MIDGC_VERIFY=1 QBE_MIDGC_MAXMB=4096
scale_rc="$STATUS"
scale_out="$(cat "$WORK/out")"
if [ "$scale_rc" -eq 0 ] && [ "$scale_out" = "$GOLDEN" ]; then
  echo "PASS (6): the verifier survives a 4 GB CEILING (~131 000 size classes, so the class loop is 131 000 iterations on ONE frame) and still prints the golden"
elif [ "$scale_rc" -eq 139 ]; then
  fail "the verifier SEGFAULTED at QBE_MIDGC_MAXMB=4096 — the walkers have gone mutually recursive again (they must be self-recursive: only that form lowers to a jump)"
else
  fail "mode 0 under VERIFY at a 4 GB ceiling printed '$scale_out' (exit $scale_rc), want the golden $GOLDEN"
fi

if [ "$rc" -eq 0 ]; then
  echo "PASS: every invariant NAMED its failure, and the one that needs the post-collect walk (V2)"
  echo "      is SILENT without QBE_MIDGC_VERIFY=1 — the instruments are live, not decorative."
fi
exit "$rc"
