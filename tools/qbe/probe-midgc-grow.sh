#!/usr/bin/env bash
# probe-midgc-grow.sh — THE HEAP GROWS (GC ARC unit 4), and the ceiling is
# LOUD.  The asymmetry this probe scripts, in one place:
#
#   * FAIL-BEFORE (MEASURED on 4c48214, the commit before this unit): the Mid
#     heap was a HARD one-shot mmap of `heapBytes + heapBytes/8`, so the two
#     100%-live fixtures died at the minimum heap —
#         QBE_MIDGC_YOUNG=0 QBE_MIDGC=1 QBE_HEAP_MB=16 churn Churn.build 150000 0
#           -> midgc: c=4 ... ; qbe-rt: midgc: out of memory        (exit 1)
#         QBE_MIDGC_YOUNG=0 QBE_MIDGC=1 QBE_HEAP_MB=16 vfield VField.rootedField
#           -> qbe-rt: midgc: out of memory                         (exit 1)
#     while the SAME knob on the Zig arm survived by doubling its heap
#     (live_pages 14337 -> 28673, plan §3.2).  The difference was BUDGET
#     SEMANTICS, not churn pressure: churn's live set is 19.2 MB and
#     vfield-rooted's is 25.2 MB, both 100 % live.
#   * PASS-AFTER (this tree): QBE_HEAP_MB is the INITIAL heap; Rt.gcAlloc
#     DOUBLES the limit on exhaustion, up to a ceiling of min(8 x initial,
#     initial + 4 GB) — the Zig arm's own effective ceiling — overridable with
#     QBE_MIDGC_MAXMB.  Both fixtures print their goldens at 16 MB, with the
#     growth reported on the stats line:
#         midgc: grow 32 MB (was 16 MB, ceiling 128 MB)
#   * THE CEILING IS A REAL BOUND, not a hint: `QBE_MIDGC_MAXMB=16` on the SAME
#     binary reproduces the pre-unit behaviour LOUDLY, with the numbers that
#     make the case actionable (never a silent OOM at the initial size, and
#     never a silent grow past the ceiling).
#   * THE RECLAMATION ORACLE STAYS SHARP: midgc-reclaim's row exists to prove
#     the collector REUSES dead cells (~192 MB allocated through a 16 MB heap).
#     Growth could quietly buy that row out, so the arm below reruns it with the
#     ceiling pinned to the heap (growth OFF) and requires the same golden: the
#     reclamation is real, not a bigger heap.
#
# Every arm is a `qbe-mk` (no elm rebuild: run.js reads osier-compiler/runtime.mid
# at emit time) plus a run; the whole probe is a few seconds.
#
# Usage: tools/qbe/probe-midgc-grow.sh
# Exit: 0 = every arm holds, 1 = an arm FAILED, 2 = tooling.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

HEAP_MB=16
CEIL_MB=128           # 8 x 16 MB, the stated rule, quoted in gcInit's comment
OOM_TOKEN="qbe-rt: midgc: out of memory"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/probe-midgc-grow.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

need() { command -v "$1" >/dev/null 2>&1 || { echo "probe-midgc-grow: $1 not found" >&2; exit 2; }; }
need node; need cc

rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

# build <fixture> <entry> <outdir> -> echoes the binary path
build() {
  QBE_MIDGC=1 "$ROOT/tools/qbe/qbe-mk.sh" "$1" "$2" "$3" 2>/dev/null
}

# ---- arm 1: churn (19.2 MB live) at a 16 MB INITIAL heap -------------------
BIN_CHURN="$(build tools/qbe/fixtures/churn.elm Churn.build "$WORK/churn")" \
  || { echo "probe-midgc-grow: qbe-mk churn failed" >&2; exit 1; }
out="$(QBE_MIDGC_YOUNG=0 QBE_MIDGC=1 QBE_HEAP_MB="$HEAP_MB" QBE_MIDGC_STATS=1 timeout 120 "$BIN_CHURN" Churn.build 150000 0 2>"$WORK/churn.err")"
status=$?
grows="$(grep -c '^midgc: grow ' "$WORK/churn.err")"
if [ "$status" -ne 0 ] || [ "$out" != "0" ]; then
  fail "churn at QBE_HEAP_MB=$HEAP_MB printed '$out' (exit $status), want '0' — the heap did not grow (stderr: $(tr '\n' '|' < "$WORK/churn.err"))"
elif [ "$grows" -ne 1 ]; then
  fail "churn at QBE_HEAP_MB=$HEAP_MB reported $grows growth events, want exactly 1 (19.2 MB of live bodies fits one doubling) — stderr: $(tr '\n' '|' < "$WORK/churn.err")"
elif ! grep -qx "midgc: grow 32 MB (was $HEAP_MB MB, ceiling $CEIL_MB MB)" "$WORK/churn.err"; then
  fail "churn's growth line is not the DOUBLING 16 -> 32 MB under a $CEIL_MB MB ceiling: $(grep '^midgc: grow ' "$WORK/churn.err")"
else
  echo "PASS (1): churn (19.2 MB of 100% live bodies) at QBE_HEAP_MB=$HEAP_MB prints '0' after ONE doubling:"
  grep '^midgc: grow ' "$WORK/churn.err" | sed 's/^/    /'
fi

# ---- arm 2: vfield-rooted (25.2 MB live) at the same heap ------------------
BIN_VF="$(build tools/qbe/fixtures/vfield.elm VField.rootedField "$WORK/vf")" \
  || { echo "probe-midgc-grow: qbe-mk vfield failed" >&2; exit 1; }
out="$(QBE_MIDGC_YOUNG=0 QBE_MIDGC=1 QBE_HEAP_MB="$HEAP_MB" QBE_MIDGC_STATS=1 timeout 120 "$BIN_VF" VField.rootedField 2>"$WORK/vf.err")"
status=$?
if [ "$status" -eq 0 ] && [ "$out" = "20000100007" ] && grep -q '^midgc: grow ' "$WORK/vf.err"; then
  echo "PASS (2): vfield-rooted (25.2 MB live, the {x} field IS rooted) at QBE_HEAP_MB=$HEAP_MB prints $out after: $(grep '^midgc: grow ' "$WORK/vf.err")"
else
  fail "vfield-rooted at QBE_HEAP_MB=$HEAP_MB printed '$out' (exit $status), want '20000100007' with a growth line — stderr: $(tr '\n' '|' < "$WORK/vf.err")"
fi

# ---- arm 3: THE CEILING IS LOUD (growth refused == the pre-unit behaviour) --
out="$(QBE_MIDGC_YOUNG=0 QBE_MIDGC=1 QBE_HEAP_MB="$HEAP_MB" QBE_MIDGC_MAXMB="$HEAP_MB" timeout 120 "$BIN_CHURN" Churn.build 150000 0 2>&1)"
status=$?
if [ "$status" -eq 1 ] \
  && grep -qx "qbe-rt: midgc: out of memory: heap at its ceiling of $HEAP_MB MB (initial $HEAP_MB MB)" <<<"$out" \
  && grep -qx "$OOM_TOKEN" <<<"$out"; then
  echo "PASS (3): QBE_MIDGC_MAXMB=$HEAP_MB refuses the growth and dies LOUDLY, naming the ceiling and the initial heap:"
  tail -2 <<<"$out" | sed 's/^/    /'
else
  fail "with QBE_MIDGC_MAXMB=$HEAP_MB churn exited $status with '$(tr '\n' '|' <<<"$out")', want the loud ceiling die (exit 1, both lines)"
fi

# ---- arm 4: the doubling is STEP BY STEP, and stops at the rule's ceiling ---
# 900 000 conses = ~115 MB of live bodies: 16 -> 32 -> 64 -> 128 (8x = the rule's
# ceiling), then the request fits and the program prints its golden.
out="$(QBE_MIDGC_YOUNG=0 QBE_MIDGC=1 QBE_HEAP_MB="$HEAP_MB" QBE_MIDGC_STATS=1 timeout 300 "$BIN_CHURN" Churn.build 900000 0 2>"$WORK/churn-big.err")"
status=$?
seq="$(grep '^midgc: grow ' "$WORK/churn-big.err" | sed 's/^midgc: grow //; s/ MB (was.*//' | tr '\n' ' ')"
if [ "$status" -eq 0 ] && [ "$out" = "0" ] && [ "$seq" = "32 64 128 " ]; then
  echo "PASS (4): ~115 MB of live bodies walks the doubling ladder 16 -> ${seq% } MB and still prints '0'"
else
  fail "churn 900000 at QBE_HEAP_MB=$HEAP_MB printed '$out' (exit $status) after grows '$seq', want '0' after '32 64 128 '"
fi

# ---- arm 5: a ceiling ABOVE the request still completes; the rule is 8x -----
# 1 500 000 conses = ~192 MB > the 128 MB rule ceiling: a LOUD die, never a
# silent truncation, and the message names the ceiling (not the initial heap).
out="$(QBE_MIDGC_YOUNG=0 QBE_MIDGC=1 QBE_HEAP_MB="$HEAP_MB" QBE_MIDGC_STATS=1 timeout 300 "$BIN_CHURN" Churn.build 1500000 0 2>&1)"
status=$?
if [ "$status" -eq 1 ] \
  && grep -qx "qbe-rt: midgc: out of memory: heap at its ceiling of $CEIL_MB MB (initial $HEAP_MB MB)" <<<"$out"; then
  echo "PASS (5): ~192 MB of live bodies exceeds the rule ceiling ($CEIL_MB MB) and dies naming it, not the initial heap"
else
  fail "churn 1500000 at QBE_HEAP_MB=$HEAP_MB exited $status without the '$CEIL_MB MB' ceiling line: $(tail -2 <<<"$out" | tr '\n' '|')"
fi

# ---- arm 6: the ceiling is CLAMPED UP to the initial heap, never below it ---
# QBE_HEAP_MB is the guarantee.  QBE_MIDGC_MAXMB=8 under QBE_HEAP_MB=16 must not
# truncate the heap below the 16 MB that was asked for: the run allocates INTO
# 16 MB (so the ceiling the die names is 16, not 8) and refuses to grow past it.
out="$(QBE_MIDGC_YOUNG=0 QBE_MIDGC=1 QBE_HEAP_MB="$HEAP_MB" QBE_MIDGC_MAXMB=8 timeout 120 "$BIN_CHURN" Churn.build 150000 0 2>&1)"
status=$?
if [ "$status" -eq 1 ] \
  && grep -qx "qbe-rt: midgc: out of memory: heap at its ceiling of $HEAP_MB MB (initial $HEAP_MB MB)" <<<"$out"; then
  echo "PASS (6): QBE_MIDGC_MAXMB=8 under QBE_HEAP_MB=$HEAP_MB is clamped UP to the initial heap — the die names a $HEAP_MB MB ceiling (not 8 MB) and no growth happens"
else
  fail "QBE_MIDGC_MAXMB=8 under QBE_HEAP_MB=$HEAP_MB exited $status with '$(tr '\n' '|' <<<"$out")', want the loud die naming a $HEAP_MB MB ceiling (the clamp keeps the initial heap)"
fi

# ---- arm 7: the transcript is GATED (the default route's bytes/stderr) -----
out="$(QBE_MIDGC_YOUNG=0 QBE_MIDGC=1 QBE_HEAP_MB="$HEAP_MB" timeout 120 "$BIN_CHURN" Churn.build 150000 0 2>"$WORK/churn-quiet.err")"
status=$?
if [ "$status" -eq 0 ] && [ "$out" = "0" ] && [ ! -s "$WORK/churn-quiet.err" ]; then
  echo "PASS (7): without QBE_MIDGC_STATS the growth is SILENT (empty stderr) — the instrument is a knob, not a side effect"
else
  fail "the no-stats arm exited $status with '$out' and stderr '$(tr '\n' '|' < "$WORK/churn-quiet.err")', want '0' and no output"
fi

# ---- arm 8: midgc-reclaim's oracle stays SHARP (growth OFF) ----------------
# ~192 MB allocated through a 16 MB heap, reclaimed batch by batch.  The golden
# must hold with the ceiling pinned to the heap, i.e. with growth impossible:
# otherwise a leak could hide behind the growth this unit added.
BIN_REC="$(build tools/qbe/fixtures/midgc-reclaim.elm MidgcReclaim.main "$WORK/rec")" \
  || { echo "probe-midgc-grow: qbe-mk midgc-reclaim failed" >&2; exit 1; }
out="$(QBE_MIDGC_YOUNG=0 QBE_MIDGC=1 QBE_HEAP_MB="$HEAP_MB" QBE_MIDGC_MAXMB="$HEAP_MB" QBE_MIDGC_STATS=1 timeout 120 "$BIN_REC" MidgcReclaim.main 2>"$WORK/rec.err")"
status=$?
if [ "$status" -eq 0 ] && [ "$out" = "0" ] && ! grep -q '^midgc: grow ' "$WORK/rec.err"; then
  echo "PASS (8): midgc-reclaim still reclaims ~192 MB through a ${HEAP_MB} MB heap with growth DISABLED (no grow line) — its reuse oracle is not bought by the new growth"
else
  fail "midgc-reclaim with QBE_MIDGC_MAXMB=$HEAP_MB printed '$out' (exit $status) with grows '$(grep -c '^midgc: grow ' "$WORK/rec.err")', want '0'/0 grows — the reclaim row now leans on growth"
fi

if [ "$rc" -eq 0 ]; then
  echo "PASS: QBE_HEAP_MB is an INITIAL heap (growth by doubling to min(8x, +4 GB)),"
  echo "      the ceiling is a loud bound that names its numbers, and the reclamation"
  echo "      and instrument discipline the collector already had are unchanged."
fi
exit "$rc"
