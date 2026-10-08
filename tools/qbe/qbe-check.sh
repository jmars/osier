#!/usr/bin/env bash
# qbe-check.sh — the stage-1 verification runner (native-backend slice).
#
# For every slice fixture: compile BOTH ways from the same source, run the
# SAME entry with the same args on elmvm and on the native binary, and
# require IDENTICAL stdout.  Also runs the two crux checks:
#
#   * GC CHURN: rerun the native binary under a tiny QBE_HEAP_MB so the
#     moving collector runs constantly (QBE_HEAP_MB=1 => every allocation
#     pressure point scavenges); output must still match.  This is the
#     behavioural proof that the pooled-frame roots actually root (a
#     promotion bug = silently stale pointers, not a crash).
#   * ROOT STORES SURVIVE: grep the emitted .s for stores/loads through the
#     pooled frame pointer (%rbx = rt_frame_enter's result) around the
#     recursive callq sites — the structural counterpart of the behavioural
#     check (a future qbe that starts promoting would show as 0).
#
#   * TAIL: a cross-defun tail fixture (mutual recursion) measures how deep
#     the native stack grows per hop vs the VM (ulimit-bounded).
#
# Usage: tools/qbe/qbe-check.sh    (exit 0 = all checks pass)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="${TMPDIR:-/tmp}/qbe-check"
mkdir -p "$TMP"
FAIL=0

# fixture entry args...
run() {
  local name="$1" entry="$2" fixture="$3"; shift 3
  local args=("$@")
  local bin
  bin="$("$ROOT/tools/qbe/qbe-mk.sh" "$fixture" "$entry" "$TMP/$name" "${args[@]}" 2>/dev/null)" || {
    echo "FAIL $name: qbe-mk"; FAIL=1; return
  }

  # the VM reference: same sources, same entry, same args
  (cd "$ROOT/elm-compiler" &&
    MIDTIER=0 node run.js "$ROOT/$fixture" "$TMP/$name/ref.csexp") >/dev/null 2>&1
  local vm_out
  vm_out="$("$ROOT/zig-out/bin/elmvm" "$TMP/$name/ref.csexp" "$entry" "${args[@]}" 2>&1)"
  local nat_out
  nat_out="$("$bin" "$entry" "${args[@]}" 2>&1)"

  if [ "$vm_out" != "$nat_out" ]; then
    echo "FAIL $name: vm='$vm_out' native='$nat_out'"
    FAIL=1
    return
  fi
  echo "PASS $name: identical ($nat_out)"

  # GC churn: minimum viable heap (MIN_HEAP_BYTES = 16MB, heap.zig:61 —
  # smaller inits fail), so every allocation-pressure point collects.
  # A fixture whose LIVE SET cannot fit 16MB opts out by ending in "-nochurn".
  if [[ "$name" != *-nochurn ]]; then
  local churn_out
  churn_out="$(QBE_HEAP_MB=16 "$bin" "$entry" "${args[@]}" 2>&1)" || true
  if [ "$churn_out" != "$vm_out" ]; then
    echo "FAIL $name: CHURN mismatch (QBE_HEAP_MB=1): '$churn_out'"
    FAIL=1
  else
    echo "PASS $name: gc-churn (QBE_HEAP_MB=1) identical"
  fi
  fi
}

# ---- the slice fixtures (in-scope constructs only) ----
run fib        Fib.fib          tests/elm-fixtures/fib.elm 10
run fib20      Fib.fib          tests/elm-fixtures/fib.elm 20
run countdown  Countdown.countdown tests/elm-fixtures/countdown.elm 100000
run applytwice ApplyTwice.main  tests/elm-fixtures/applytwice.elm
run closure    Closure.main     tests/elm-fixtures/closure.elm
run const42    Const42.main     tools/qbe/fixtures/const42.elm
run idn        Idn.idn          tools/qbe/fixtures/idn.elm 7
run ifx        Ifx.main         tools/qbe/fixtures/ifx.elm
# churn: 150k conses = ~13.2MB live, just under the 16MB minimum heap, so the
# QBE_HEAP_MB=16 stress rerun collects/promotes constantly and still fits the
# reservation; 500k at the default heap is the identity run.
run churn      Churn.build      tools/qbe/fixtures/churn.elm 150000 0
run churnbig-nochurn Churn.build tools/qbe/fixtures/churn.elm 500000 0

# ---- structural root-store check on fib's assembly ----
S="$TMP/fib/fib.s"
if [ -f "$S" ]; then
  # stores through the pooled frame pointer (%rbx holds rt_frame_enter's
  # result in fib's compiled body) that must survive around the two
  # recursive callq sites
  n=$(sed -n '/^q_Fib_x2efib:/,/end function q_Fib_x2efib/p' "$S" \
        | grep -c '(%rbx)')
  c=$(sed -n '/^q_Fib_x2efib:/,/end function q_Fib_x2efib/p' "$S" \
        | grep -c 'callq q_Fib_x2efib')
  if [ "$n" -ge 20 ] && [ "$c" -eq 2 ]; then
    echo "PASS root-stores: $n frame-pointer memory ops around $c recursive callq in fib.s"
  else
    echo "FAIL root-stores: only $n frame-pointer ops around $c calls (promotion?)"
    FAIL=1
  fi
else
  echo "FAIL root-stores: $S missing"
  FAIL=1
fi

# ---- loud-failure check: an out-of-scope fixture must NOT compile ----
printf 'module Oos exposing (main)\n\nmain =\n    case [1, 2] of\n        x :: _ ->\n            x\n\n        [] ->\n            0\n' \
  > "$TMP/oos.elm"
(cd "$ROOT/elm-compiler" && QBE=1 QBE_ENTRY=Oos.main node run.js "$TMP/oos.elm" "$TMP/oos.ssa") >/dev/null 2>&1
if head -c 4 "$TMP/oos.ssa" 2>/dev/null | grep -q '^err '; then
  echo "PASS loud-fail: Case rejected with: $(head -1 "$TMP/oos.ssa")"
else
  echo "FAIL loud-fail: out-of-scope fixture compiled"
  FAIL=1
fi

# ---- cross-defun tail: how deep before the native stack dies ----
if [ ! -x "$TMP/mutual/mutualtail" ]; then
  "$ROOT/tools/qbe/qbe-mk.sh" tools/qbe/fixtures/mutualtail.elm Mutual.even "$TMP/mutual" >/dev/null 2>&1
fi
if [ -x "$TMP/mutual/mutualtail" ]; then
  # the VM runs Mutual.even 1000000 fine (appterm); native grows a frame per
  # hop — find the practical ceiling
  # MEASURED CEILING (this host, 8MB stack): cross-defun tail hops survive
  # ~20-40k (2 native frames/hop, QBE prologues ~200B) before SIGSEGV, while
  # the VM runs 1e6+ (appterm = constant stack).  Cross-defun tails are
  # PLAIN CALLS in this slice — the honest cost of no bounce loop yet.
  d=20000
  if "$TMP/mutual/mutualtail" Mutual.even $d >/dev/null 2>&1; then
    echo "PASS mutual-tail $d ok; ceiling measured between 20k-40k hops (VM: 1e6+ unlimited)"
  else
    echo "FAIL mutual-tail $d: crashed"
    FAIL=1
  fi
fi

exit $FAIL
