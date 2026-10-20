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
#   QBE_MIDGC_YOUNG unset   -> 10011  (the pre-nursery Mid golden, unchanged)
#   QBE_MIDGC_YOUNG=1       -> 10001  (== the DEFAULT Zig-route build's number)
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

ELM_BIN="${ELM_BIN:-$HOME/.npm-global/lib/node_modules/elm/bin/elm}"
(cd "$ROOT/elm-compiler" && ELM_HOME="$PWD/.elm-cache" "$ELM_BIN" make src/Main.elm --output=compiler.js >/dev/null) \
  || { echo "probe-midgc-young: elm make compiler.js failed" >&2; exit 1; }

BIN="$(QBE_MIDGC=1 QBE_MIDGC_YOUNG=1 "$ROOT/tools/qbe/qbe-mk.sh" tools/qbe/fixtures/valchurn.elm Valchurn.main "$WORK" 2>"$WORK/mk.log")" \
  || { echo "probe-midgc-young: qbe-mk failed" >&2; cat "$WORK/mk.log" >&2; exit 1; }
YBIN="$(QBE_MIDGC=1 QBE_MIDGC_YOUNG=1 "$ROOT/tools/qbe/qbe-mk.sh" tools/qbe/fixtures/young.elm Young.main "$WORK" 2>"$WORK/mky.log")" \
  || { echo "probe-midgc-young: qbe-mk (young) failed" >&2; cat "$WORK/mky.log" >&2; exit 1; }

run() { timeout 120 "$@"; }

# ---- arm 1: MOVEMENT — the young arm prints the MOVING golden -------------
out="$(run env QBE_MIDGC_YOUNG=1 QBE_MIDGC_YOUNG_MB=$YOUNG_MB QBE_MIDGC_STATS=1 QBE_HEAP_MB=$HEAP_MB "$BIN" Valchurn.main 2>"$WORK/vc.on")"
if [ "$out" = "10001" ]; then
  echo "PASS (1): valchurn YOUNG prints $out — the MOVING golden (the default Zig route's own number)"
else
  fail "valchurn YOUNG printed '$out', want 10001 (moving)"
fi

# ---- arm 2: THE HATCH — the same binary, env unset, is the OLD golden -----
out="$(run env QBE_MIDGC_STATS=1 QBE_HEAP_MB=$HEAP_MB "$BIN" Valchurn.main 2>"$WORK/vc.off")"
if [ "$out" = "10011" ]; then
  echo "PASS (2): the SAME binary with QBE_MIDGC_YOUNG unset prints $out — the non-moving pre-nursery golden"
else
  fail "valchurn young-OFF printed '$out', want 10011 (non-moving)"
fi

# ---- arm 3: the DEFAULT build agrees (the moving reference) ---------------
DBIN="$("$ROOT/tools/qbe/qbe-mk.sh" tools/qbe/fixtures/valchurn.elm Valchurn.main "$WORK/def" 2>>"$WORK/mk.log")" \
  || { echo "probe-midgc-young: qbe-mk (default) failed" >&2; exit 1; }
out="$(run env QBE_HEAP_MB=$HEAP_MB "$DBIN" Valchurn.main 2>/dev/null)"
if [ "$out" = "10001" ]; then
  echo "PASS (3): the DEFAULT (Zig, moving) build prints $out — the number the young arm must match"
else
  fail "the default build printed '$out', want 10001"
fi

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

# ---- arm 5: the STATS witness — scavenges ran and copied a small fraction --
s="$(grep -c '^midgc: scavenge s=' "$WORK/vc.on")"
c="$(grep '^midgc: scavenge s=' "$WORK/vc.on" | tail -1 | sed 's/.* copied=\([0-9]*\) .*/\1/')"
if [ "$s" -ge 8 ] && [ "$c" -le 65536 ]; then
  echo "PASS (5): $s scavenges; last copied ${c}B — survivors are a small fraction of the ${YOUNG_MB}MB young volume"
else
  fail "stats witness: $s scavenges, last copied ${c}B (want >= 8 scavenges, copied <= 65536)"
fi

exit $rc
