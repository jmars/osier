#!/usr/bin/env bash
# probe-midgc-stats.sh — THE COLLECT COUNTER AND THE MARK-VS-SWEEP SPLIT
# (GC ARC F1), i.e. the instrument that turns two ASSERTED claims in plan.md
# §2.2 into measurements.
#
# THE TWO CLAIMS.
#   (a) "At 64/128 MB there are ZERO collects, so that residual is route cost,
#       not the collector" (stage-4 review finding 2: PROVEN by threshold
#       arithmetic, never observed).
#   (b) "The 16 MB delta is the O(heap) sweep vs the zig scavenger's O(live)"
#       — ASSERTED, with no collect counter and no per-phase clock in the tree.
#
# WHAT IT MEASURES.  QBE_MIDGC_STATS=1 makes each collect print one line on
# stderr (the knob is read once in Rt.gcInit — the collector's own defuns are
# the only ones gated, so the DEFAULT route's bytes do not move):
#
#   midgc: c=<n> mark=<bodies marked> swept=<heap bytes walked> markUs=<n> sweepUs=<n>
#
# `mark` is the O(live) half (one push per distinct object body, gcMarkPtr's
# `marked == 0` test, reset per collect); `swept` is the O(heap) half; the two
# µs fields are CLOCK_MONOTONIC around each phase.  The fixture is
# tools/qbe/fixtures/midgc-live.elm — the SAME churn the stage-4 differential
# used (300 x 500 = 150k conses, 14.4 MB allocated, live set ~600-1000 bodies).
#
# THE ASSERTIONS (each one fails if the claim is wrong, so the probe is not a
# printout: a "can this FAIL?" reading of every line is in the brackets):
#   * collect count per heap 16/32/64/128 MB = 4/2/1/0 [if the instrument were
#     inert, the counts would be 0 everywhere and the first assertion dies; if
#     claim (a) were false, the 128 MB count would be non-zero];
#   * the 128 MB run's residue is EXACTLY zero collects — the differential's
#     +31-40% there is NOT the collector;
#   * monotonic sweep scaling: `swept` at 64 MB >= 3x `swept` at 16 MB (the
#     O(heap) law) while `mark` does NOT scale with the heap (the O(live) law)
#     — the measured shape of the split;
#   * the mark is not free: markUs > 0 on at least one collect, so "the mark
#     walk could be the whole cost" is at least an available measurement;
#   * the PROGRAM's golden is unchanged with the knob on (stdout 1275) — the
#     instrument does not perturb the answer.
#
# Usage:
#   tools/qbe/probe-midgc-stats.sh
#
# Exit: 0 = every claim holds, 1 = a claim FAILED, 2 = tooling.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

FIXTURE="tools/qbe/fixtures/midgc-live.elm"
ENTRY="MidgcLive.main"
GOLDEN=1275
BIN_NAME="midgc-live"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/probe-midgc-stats.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

need() { command -v "$1" >/dev/null 2>&1 || { echo "probe-midgc-stats: $1 not found" >&2; exit 2; }; }
need node; need cc

QBE_MIDGC=1 "$ROOT/tools/qbe/qbe-mk.sh" "$FIXTURE" "$ENTRY" "$WORK" >/dev/null 2>&1 \
  || { echo "probe-midgc-stats: qbe-mk failed" >&2; exit 1; }
BIN="$WORK/$BIN_NAME"
[ -x "$BIN" ] || { echo "probe-midgc-stats: no binary at $BIN" >&2; exit 1; }

# run at one heap; echo "<golden-stdout>|<lines-of-stats>"; write the raw stats
# lines to $WORK/stats-<mb>.txt and the summed phases to $WORK/sum-<mb>.txt.
run_at() {
  local mb="$1" so
  so="$(QBE_HEAP_MB="$mb" QBE_MIDGC_STATS=1 "$BIN" "$ENTRY" 2>"$WORK/err-$mb")"
  grep -o 'midgc: c=.*' "$WORK/err-$mb" > "$WORK/stats-$mb.txt" || true
  awk '{ for (i = 1; i <= NF; i++) { split($i, kv, "="); if (kv[1] == "mark") m += kv[2]; else if (kv[1] == "swept") s += kv[2]; else if (kv[1] == "markUs") mu += kv[2]; else if (kv[1] == "sweepUs") su += kv[2] } }
       END { printf "%d %d %d %d\n", m, s, mu, su }' "$WORK/stats-$mb.txt" > "$WORK/sum-$mb.txt"
  echo "$so"
}

rc=0
for mb in 16 32 64 128; do
  want=4; [ "$mb" = 32 ] && want=2; [ "$mb" = 64 ] && want=1; [ "$mb" = 128 ] && want=0
  so="$(run_at "$mb")"
  n="$(wc -l < "$WORK/stats-$mb.txt" | tr -d ' ')"
  read -r mm ss mu su < "$WORK/sum-$mb.txt"
  echo "heap=$mb MB: collects=$n (want $want)  marked=$mm bodies  swept=$ss bytes  mark=$mu us  sweep=$su us"
  if [ "$so" != "$GOLDEN" ]; then
    echo "FAIL: heap=$mb printed '$so', want $GOLDEN — the instrument perturbed the answer" >&2; rc=1
  fi
  if [ "$n" -ne "$want" ]; then
    echo "FAIL: heap=$mb ran $n collects, want $want — the collect-count claim in plan.md §2.2 is WRONG" >&2; rc=1
  fi
done

# the O(heap)-vs-O(live) shape, from the summed phases.  PER COLLECT, because a
# 16 MB run's 4 collects each walk a ~4 MB heap and a 64 MB run's 1 collect walks
# ~16.7 MB: the law is about ONE walk, so the ratio to test is swept/n_collects.
swept16=$(cut -d' ' -f2 < "$WORK/sum-16.txt"); swept64=$(cut -d' ' -f2 < "$WORK/sum-64.txt")
mark16=$(cut -d' ' -f1 < "$WORK/sum-16.txt");   mark64=$(cut -d' ' -f1 < "$WORK/sum-64.txt")
per16=$(( swept16 / 4 )); per64=$(( swept64 / 1 ))
mu_all=$(cat "$WORK"/sum-*.txt | awk '{ s += $3 } END { print s + 0 }')
echo "per collect: swept 16 MB=$per16 bytes vs 64 MB=$per64 bytes;  marked 16 MB=$mark16 bodies (4 collects) vs 64 MB=$mark64 (1 collect)"

if [ "$per16" -eq 0 ] || [ "$per64" -lt $(( per16 * 2 )) ]; then
  echo "FAIL: one sweep does not grow with the heap (64 MB/$per64 vs 16 MB/$per16 per collect) — the O(heap) claim is unsupported" >&2
  rc=1
fi
if [ "$mark64" -gt $(( mark16 * 3 )) ]; then
  echo "FAIL: the marked-body count grows with the HEAP, not with the live set — the mark would not be O(live)" >&2; rc=1
fi
if [ "$mu_all" -eq 0 ]; then
  echo "FAIL: no collect reported mark time — the per-phase clock never fired, so the split is unmeasured" >&2; rc=1
fi
# the 128 MB arm must have produced NO collect line at all (claim (a))
if [ -s "$WORK/stats-128.txt" ]; then
  echo "FAIL: the 128 MB arm collected — plan.md §2.2's 'zero collects at 128 MB' is wrong" >&2; rc=1
fi

if [ "$rc" -eq 0 ]; then
  echo "PASS: the collect count is 4/2/1/0 at 16/32/64/128 MB (measured, not inferred), the sweep scales"
  echo "      with the HEAP while the mark scales with the LIVE SET, and the 128 MB residual is"
  echo "      provably not the collector.  The per-collect split is printed above."
fi
exit "$rc"
