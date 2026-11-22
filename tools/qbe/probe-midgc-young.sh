#!/usr/bin/env bash
# probe-midgc-young.sh — GC NURSERY: THE MOVEMENT ORACLE + the young arms.
#
# THE MOVEMENT ORACLE IS valchurn (the plan's own): its three arms read
#   win * 10000 + stale * 100 + rooted
# and the ROOTED arm is the discriminator — the referent is held BOTH in a
# rooted `val` binder AND as a raw copy in a stack Box:
#   * NON-MOVING collector  -> 10011 (the raw copy still reads: 11)
#   * MOVING collector      -> 10001 (the root slot was updated to the new
#                              address, the raw copy was not: 1)
# THE PROOF IS THE PAIR, one binary, env-toggled:
#   QBE_MIDGC_YOUNG=0       -> 10011  (the mark-sweep golden, the run-time escape)
#   QBE_MIDGC_YOUNG=1/unset -> 10001  (== the mark-sweep route's moving number)
# FAIL-BEFORE (MEASURED, stage A): the young arm died
#   'scavenge read a POISONED (forwarded young) body' in the DRAIN — the
#   FORWARDED test's word `&` lowered w-class and never fired, so every
#   forwarded body was re-copied and the drain scanned a re-copy whose
#   word -1 (an address) it read as the count.  Fixed with a compare
#   spelling; TestMain's register-class landmine row pins the class of it.
#
# Plus the graded Wyoung arms (survival, two roots, the stale raw copy, the
# rooted arm) and the stats witness (scavenges happened, bytes copied are a
# small fraction of the young volume).
#
# Usage: tools/qbe/probe-midgc-young.sh
# Exit: 0 = every arm holds, 1 = an arm FAILED, 2 = tooling.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
export TMPDIR="${TMPDIR:-/tmp}"

YOUNG_MB=1
HEAP_MB=16
N=200000
WORK="$(mktemp -d "${TMPDIR:-/tmp}/probe-midgc-young.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

need() { command -v "$1" >/dev/null 2>&1 || { echo "probe-midgc-young: $1 not found" >&2; exit 2; }; }
need node; need cc

rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

ELM_BIN="${ELM_BIN:-$(command -v elm || echo "$HOME/.npm-global/lib/node_modules/elm/bin/elm")}"
(cd "$ROOT/osier-compiler" && ELM_HOME="$PWD/.elm-cache" "$ELM_BIN" make src/Main.elm --output=compiler.js >/dev/null) \
  || { echo "probe-midgc-young: elm make compiler.js failed" >&2; exit 1; }

# QBE_VALREP=val is PINNED (the a148922 class): the fixtures' .mid surfaces spell
# inline heap cells the word arm's emitter cannot lower (VR3b2), so an unpinned
# run dies at the fixture BUILD on the default (word) arm before any nursery
# invariant executes.  The nursery this probe drives is arm-shared; the val arm
# builds the fixtures and runs the churn.
BIN="$(QBE_MIDGC=1 QBE_MIDGC_YOUNG=1 QBE_VALREP=val "$ROOT/tools/qbe/qbe-mk.sh" tools/qbe/fixtures/valchurn.elm Valchurn.main "$WORK" 2>"$WORK/mk.log")" \
  || { echo "probe-midgc-young: qbe-mk failed" >&2; cat "$WORK/mk.log" >&2; exit 1; }
YBIN="$(QBE_MIDGC=1 QBE_MIDGC_YOUNG=1 QBE_VALREP=val "$ROOT/tools/qbe/qbe-mk.sh" tools/qbe/fixtures/young.elm Young.main "$WORK" 2>"$WORK/mky.log")" \
  || { echo "probe-midgc-young: qbe-mk (young) failed" >&2; cat "$WORK/mky.log" >&2; exit 1; }

run() { timeout 120 "$@"; }

# ---- arm 1: MOVEMENT — the young arm prints the MOVING golden -------------
out="$(run env QBE_MIDGC_YOUNG=1 QBE_MIDGC_YOUNG_MB=$YOUNG_MB QBE_MIDGC_STATS=1 QBE_HEAP_MB=$HEAP_MB "$BIN" Valchurn.main 2>"$WORK/vc.on")"
if [ "$out" = "10001" ]; then
  echo "PASS (1): valchurn YOUNG prints $out — the MOVING golden (the DEFAULT build: the nursery scavenge promotes and poisons the young original)"
else
  fail "valchurn YOUNG printed '$out', want 10001 (moving)"
fi

# ---- arm 2: THE HATCH — the same binary, env unset, is the OLD golden -----
out="$(run env QBE_MIDGC_YOUNG=0 QBE_MIDGC_STATS=1 QBE_HEAP_MB=$HEAP_MB "$BIN" Valchurn.main 2>"$WORK/vc.off")"
if [ "$out" = "10011" ]; then
  echo "PASS (2): the SAME binary with QBE_MIDGC_YOUNG=0 prints $out — the non-moving mark-sweep golden (the run-time escape hatch)"
else
  fail "valchurn young-OFF printed '$out', want 10011 (non-moving)"
fi

# ---- arm 3: RETIRED at ZIGHOST Z0 -----------------------------------------
# It built valchurn with QBE_MIDGC=0 — the ZIG collector's route — and asserted
# it printed 10001, the moving number the young arm must match.  That route is
# deleted and run.js now REFUSES QBE_MIDGC=0 (exit 2), so there is no second
# collector to compare against: arm 1 above is already the moving number, and a
# re-pointed arm 3 would rebuild BIN and measure the same binary twice.
# The claim arm 3 carried ("the young arm's number is the moving one") is what
# arm 1 + arm 2's PAIR asserts — 10001 with the nursery, 10011 without it.

# ---- arm 4: the graded Wyoung arms ----------------------------------------
for spec in "0 424242" "1 11000022" "2 0" "3 1" "4 1" "5 1"; do
  set -- $spec
  out="$(run env QBE_MIDGC_YOUNG=1 QBE_MIDGC_YOUNG_MB=$YOUNG_MB QBE_HEAP_MB=$HEAP_MB "$YBIN" Young.main "$1" $N 2>"$WORK/y.$1")"
  if [ "$out" = "$2" ]; then
    echo "PASS (4/$1): Wyoung mode $1 -> $2"
  else
    fail "Wyoung mode $1 printed '$out', want $2"
  fi
done

# ---- arm 4f: THE WRITE BARRIER — fill an OLD vector one young store at a time
# FAIL-BEFORE (MEASURED, pre-barrier): the same run printed 673069544 — a
# silent wrong number: the vector (1.2MB > the 1MB young) is allocated
# OLD-DIRECT, every store is old->young, and with no remembered set the
# scavenge reclaims the stored elements out from under the vector.
# PASS-AFTER: the golden, with the stats line witnessing the set
# (rs=1, copied=1048576 bodies=16384 — the remembered walk promoted them).
out="$(run env QBE_MIDGC_YOUNG=1 QBE_MIDGC_YOUNG_MB=1 QBE_MIDGC_STATS=1 QBE_HEAP_MB=$HEAP_MB "$YBIN" Young.main 6 30000 2>"$WORK/fill")"
if [ "$out" = "449985000" ]; then
  echo "PASS (4f): fill — an old vector filled one young store at a time — sums the golden (barrier: $(grep -o 'rs=[0-9]*' "$WORK/fill" | tail -1) recorded)"
else
  fail "fill printed '$out', want 449985000 (the write barrier's arm)"
fi

# ---- arm 4u: THE DOCUMENTED UNCOVERED EDGE — a young pointer stored into an
# old RAW block by wstore goes stale under the nursery (true) and stays valid
# with the run-time hatch off (false): word stores are host bookkeeping by
# Mid.Ir's node contract, NO barrier covers them, and this arm PINS the hole's
# existence.
a="$(run env QBE_MIDGC_YOUNG=1 QBE_MIDGC_YOUNG_MB=1 QBE_HEAP_MB=$HEAP_MB "$YBIN" Young.main 7 $N 2>/dev/null)"
b="$(run env QBE_MIDGC_YOUNG=0 QBE_MIDGC_STATS=1 QBE_HEAP_MB=$HEAP_MB "$YBIN" Young.main 7 $N 2>/dev/null)"
if [ "$a" = "true" ] && [ "$b" = "false" ]; then
  echo "PASS (4u): the KNOWN-UNCOVERED arm — a wstore'd young pointer goes stale under the nursery (true) and stays valid with it off (false)"
else
  fail "uncovered arm printed '$a'/'$b', want true/false"
fi

# ---- arm 4p: THE LAZY-REGION PIN — a vecstore before any Mid allocation
# (the hostapply flip blocker's cheap stand-in): pre-fix the barrier read
# rt_glob word 0 = the .bss zero and SIGSEGV'd; post-fix the store is plain.
out="$(run env QBE_MIDGC_YOUNG=1 QBE_MIDGC_YOUNG_MB=1 QBE_HEAP_MB=$HEAP_MB "$YBIN" Young.main 8 1 2>/dev/null)"
if [ "$out" = "42" ]; then
  echo "PASS (4p): prealloc — a vecstore before the lazy region is mapped is a plain store (the barrier's NULL-region guard)"
else
  fail "prealloc printed '$out', want 42 (the barrier's lazy-region guard)"
fi

# ---- arm 5: the STATS witness — scavenges ran and copied a small fraction --
s="$(grep -c '^midgc: scavenge s=' "$WORK/vc.on")"
c="$(grep '^midgc: scavenge s=' "$WORK/vc.on" | tail -1 | sed 's/.* copied=\([0-9]*\) .*/\1/')"
if [ "$s" -ge 8 ] && [ "$c" -le 65536 ]; then
  echo "PASS (5): $s scavenges; last copied ${c}B — survivors are a small fraction of the ${YOUNG_MB}MB young volume"
else
  fail "stats witness: $s scavenges, last copied ${c}B (want >= 8 scavenges, copied <= 65536)"
fi

exit $rc
