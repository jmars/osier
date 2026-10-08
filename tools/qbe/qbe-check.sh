#!/usr/bin/env bash
# qbe-check.sh — the stage-1 verification runner (native-backend slice).
#
# For every slice fixture: compile BOTH ways from the same source, run the
# SAME entry with the same args on elmvm and on the native binary, and
# require IDENTICAL stdout.  Also runs the two crux checks:
#
#   * GC CHURN: rerun the native binary under a tiny QBE_HEAP_MB so the
#     moving collector runs constantly (the minimum viable heap, so every
#     allocation pressure point scavenges); output must still match.  This
#     is the behavioural proof that the pooled-frame roots actually root (a
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

# GC-churn heap, in MB: the minimum viable heap (MIN_HEAP_BYTES = 16MB,
# vendor/zinc-vm/src/gc/heap.zig:61 — a literal 1 fails gc init), so every
# allocation-pressure point collects.  One definition: the rerun below and
# every message derive from this, so they cannot drift apart again.
CHURN_MB=16

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
  # `timeout` guards the native run: bug-2 (clostail) is an infinite loop
  # when the closure self-tail miscompiles, and a regression must fail loudly
  # here rather than wedge the whole check script.
  nat_out="$(timeout 60 "$bin" "$entry" "${args[@]}" 2>&1)"

  if [ "$vm_out" != "$nat_out" ]; then
    echo "FAIL $name: vm='$vm_out' native='$nat_out'"
    FAIL=1
    return
  fi
  # truncate: a fixture whose RESULT prints large (bigprint) would flood the
  # log; the comparison above is still on the full outputs.
  echo "PASS $name: identical (${nat_out:0:80})"

  # GC churn: CHURN_MB above (the minimum viable heap), so every
  # allocation-pressure point collects.
  # A fixture whose LIVE SET cannot fit it opts out by ending in "-nochurn".
  if [[ "$name" != *-nochurn ]]; then
  local churn_out
  churn_out="$(QBE_HEAP_MB=$CHURN_MB "$bin" "$entry" "${args[@]}" 2>&1)" || true
  if [ "$churn_out" != "$vm_out" ]; then
    echo "FAIL $name: CHURN mismatch (QBE_HEAP_MB=$CHURN_MB): '$churn_out'"
    FAIL=1
  else
    echo "PASS $name: gc-churn (QBE_HEAP_MB=$CHURN_MB) identical"
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
# churn: 150k conses = ~13.2MB live, just under the CHURN_MB minimum heap, so
# the gc-churn stress rerun collects/promotes constantly and still fits the
# reservation; 500k at the default heap is the identity run.
run churn      Churn.build      tools/qbe/fixtures/churn.elm 150000 0
run churnbig-nochurn Churn.build tools/qbe/fixtures/churn.elm 500000 0

# nice-to-have 9: a result whose printed form EXCEEDS the old 16384-byte print
# buffer (~24KB here).  Both runners stream now, so native and VM must agree
# at this size; before the fix native died with "print failed" and the VM with
# "error: WriteFailed".  Same shape as churn (the slice supports `::`).
run bigprint   BigPrint.build   tools/qbe/fixtures/bigprint.elm 2000 0

# ---- the four regression fixtures (the 22/22 suite was structurally blind
#      to these shapes; one per stage-1 review must-fix) ----
# bug 1: arity-2 self-tail whose accumulator is OBSERVABLE (the committed
# churn has this shape but returns 0, hiding the (n-1)::acc miscompile).
run selftail2  SelfTail2.build  tools/qbe/fixtures/selftail2.elm 3 0
# bug 4: a non-tail If (every fixture If was in tail position).
run nontailif  IfElse.main      tools/qbe/fixtures/nontailif.elm
# bug 2: a closure tail-calling its ENCLOSING defun (VM terminates; the
# miscompile was an in-frame loop of the closure = hang, hence `timeout`).
run clostail   ClosTail.main    tools/qbe/fixtures/clostail.elm 5
# bug 3: i64-boundary equality (32-bit ceqw was wrong on the full payload).
run eq64       Eq.eq            tools/qbe/fixtures/eq64.elm 4294967296 0

# ---- stage 2: pattern matching (Case / Con / match steps / LetDestruct) ----
# match: constructor patterns with sub-patterns, NESTED ctor patterns, a
# destructuring let (tuple pattern), ordered alts where order changes the
# result (Some 0 before Some _), int literal patterns + catch-all, and a Case
# inside a closure body — all summed into one observable number.
run match      Match.main       tools/qbe/fixtures/match.elm
# matchlit: literal patterns beyond Int — Bool, String, Char (a 1-char string),
# and a string literal inside a constructor sub-pattern (order matters).
run matchlit   MatchLit.main    tools/qbe/fixtures/matchlit.elm

# ---- stage 3: aggregates and literals (records / tuples / lists / bools) ----
# record: RecordLit read back by 3 fields in a DIFFERENT order + a nested
# record (fields -> 4312); RecordUpdate must be domain-preserving (upd returns
# the full updated assoc-list structure); main returns the record so the
# printed assoc-list ORDER is compared against the VM.
run record      Record.main     tools/qbe/fixtures/record.elm
run record-fields Record.fields tools/qbe/fixtures/record.elm
run record-upd  Record.upd      tools/qbe/fixtures/record.elm
run record-readupd Record.readUpd tools/qbe/fixtures/record.elm
# list: ListLit + MEmpty/MCons (stage 2's MEmpty, now fixture-able because
# `[]` lowers): fold a literal, match an empty literal, head/tail a literal.
run list        ListAgg.main    tools/qbe/fixtures/list.elm
# bool: ShortAnd/ShortOr where the RIGHT side is infinite self-recursion — it
# must NOT be evaluated (the `timeout` guard fails the run if it is) — and
# NotEqual on 5/6 vs 5/5.
run bool        Bool.main       tools/qbe/fixtures/bool.elm
# tup: a right-nested cons chain to and from a destructuring let, a 2-tuple
# (snd is a plain value), and a nested tuple pattern.
run tup         Tup.main        tools/qbe/fixtures/tup.elm
# utf8: non-ASCII string literals — UTF-8 byte length and byte identity
# (eq uses `==`'s byte compare; main returns the string for a print compare).
run utf8        Utf8.main       tools/qbe/fixtures/utf8.elm
run utf8-eq     Utf8.eq         tools/qbe/fixtures/utf8.elm
# aggchurn: a ListLit of 4 large lists (each ~2.6MB) built INLINE, so the
# collector runs DURING the outer list's construction while earlier elements
# are rooted — the partial-aggregate rooting hazard, under CHURN_MB below.
run aggchurn    AggChurn.main   tools/qbe/fixtures/aggchurn.elm

# ---- stage 4: arity > 8 (the old rt_callN table stopped at rt_call8) ----
# arity9: a 9-ary defun called DIRECTLY from the driver (rt_call9).  arity9apply:
# apply9 add9 -> f 1..9 where f is a Var, so the 9-ary call goes through
# rt_apply's saturation buffer (the generic/partial path the direct shape
# does not exercise).
run arity9      Arity9.add9     tools/qbe/fixtures/arity9.elm 1 2 3 4 5 6 7 8 9
run arity9apply Arity9.main9    tools/qbe/fixtures/arity9.elm

# ---- stage 5: record field patterns (VField) ----
# vfield-let: a destructuring let field pattern ({x,y} = p).  vfield-nested: a
# field pattern nested inside a ctor pattern (VField [IdxStep 1]).  vfield-mixed:
# a field-pattern alt alongside literal/wildcard/nullary alts in ONE case.
# vfield-rooted: a field-pattern value used ACROSS a 200000-cell allocation (the
# rooting path — under CHURN_MB below the collector runs while x is live).
run vfield-let    VField.letField   tools/qbe/fixtures/vfield.elm
run vfield-nested VField.nestedField tools/qbe/fixtures/vfield.elm
run vfield-mixed  VField.mixedCase  tools/qbe/fixtures/vfield.elm
run vfield-rooted VField.rootedField tools/qbe/fixtures/vfield.elm
run vfield-main   VField.main       tools/qbe/fixtures/vfield.elm

# ---- stage 4: the effect loop (StreamRef) + host I/O, native vs elmvm ----
# io-read: read a file (QBE_IO_IN) and write a stdout sentinel through the
# StreamRef (*stoutput*) path.  io-write: write QBE_IO_OUT, read it back, AND
# compare the on-disk CONTENT (the write path itself, not just the round-trip).
# io-fail: a missing readFile (empty-string parity) plus a Task.fail ->
# Task.onError error path — the only failing effect in the host is an explicit
# Task.fail (leaf readFile completes "" on open failure by design).
IO_IN="$ROOT/tools/qbe/fixtures/io-read-input.txt"
IO_OUT="$TMP/io-write-out.txt"
run_io() {
  local name="$1" entry="$2" fixture="$3"
  local bin
  bin="$("$ROOT/tools/qbe/qbe-mk.sh" "$fixture" "$entry" "$TMP/$name" 2>/dev/null)" || {
    echo "FAIL $name: qbe-mk"; FAIL=1; return
  }
  (cd "$ROOT/elm-compiler" &&
    MIDTIER=0 node run.js "$ROOT/$fixture" "$TMP/$name/ref.csexp") >/dev/null 2>&1

  rm -f "$IO_OUT"
  local vm_out vm_file
  vm_out="$(QBE_IO_IN="$IO_IN" QBE_IO_OUT="$IO_OUT" "$ROOT/zig-out/bin/elmvm" "$TMP/$name/ref.csexp" "$entry" 2>&1)"
  vm_file="$(cat "$IO_OUT" 2>/dev/null)"
  rm -f "$IO_OUT"
  local nat_out nat_file
  nat_out="$(timeout 60 env QBE_IO_IN="$IO_IN" QBE_IO_OUT="$IO_OUT" "$bin" "$entry" 2>&1)"
  nat_file="$(cat "$IO_OUT" 2>/dev/null)"

  if [ "$vm_out" != "$nat_out" ]; then
    echo "FAIL $name: vm='$vm_out' native='$nat_out'"
    FAIL=1
    return
  fi
  # the on-disk bytes each run wrote (io-write's real output; a no-op "" for
  # io-read/io-fail, which write no file): native must write the same bytes
  # elmvm did, not merely read them back identically.
  if [ "$vm_file" != "$nat_file" ]; then
    echo "FAIL $name: file content vm='$vm_file' native='$nat_file'"
    FAIL=1
    return
  fi
  echo "PASS $name: identical (${nat_out:0:80})"

  # gc churn: same env, minimum-viable heap
  local churn_out
  churn_out="$(QBE_HEAP_MB=$CHURN_MB QBE_IO_IN="$IO_IN" QBE_IO_OUT="$IO_OUT" "$bin" "$entry" 2>&1)" || true
  if [ "$churn_out" != "$vm_out" ]; then
    echo "FAIL $name: CHURN mismatch (QBE_HEAP_MB=$CHURN_MB): '$churn_out'"
    FAIL=1
  else
    echo "PASS $name: gc-churn (QBE_HEAP_MB=$CHURN_MB) identical"
  fi
}
run_io io-read   IoRead.main  tools/qbe/fixtures/io-read.elm
run_io io-write  IoWrite.main tools/qbe/fixtures/io-write.elm
run_io io-fail   IoFail.main  tools/qbe/fixtures/io-fail.elm
# the write path's on-disk bytes: both runs wrote IO_OUT, and both must equal
# the exact expected content (a round-trip read could hide a wrong write).
EXPECTED_IO="hello native
line2"
rm -f "$IO_OUT"
"$ROOT/tools/qbe/qbe-mk.sh" tools/qbe/fixtures/io-write.elm IoWrite.main "$TMP/io-write" >/dev/null 2>&1
QBE_IO_OUT="$IO_OUT" "$TMP/io-write/io-write" IoWrite.main >/dev/null 2>&1 || true
if [ "$(cat "$IO_OUT" 2>/dev/null)" = "$EXPECTED_IO" ]; then
  echo "PASS io-write-content: on-disk bytes match expected"
else
  echo "FAIL io-write-content: got '$(cat "$IO_OUT" 2>/dev/null)'"
  FAIL=1
fi
rm -f "$IO_OUT"

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

# ---- the last loud-fail is GONE: a record field pattern now LOWERS ----
# VField was the final unsupported construct (rg -c 'Err "qbe:' Lower.elm == 0).
# This is a positive regression guard: `{ x } = { x = 1 }` must compile (no
# `err ` prefix) — if a future regression drops VField, this fails loudly.
printf 'module Oos exposing (main)\n\nmain =\n    let\n        { x } =\n            { x = 1 }\n    in\n    x\n' \
  > "$TMP/oos.elm"
(cd "$ROOT/elm-compiler" && QBE=1 QBE_ENTRY=Oos.main node run.js "$TMP/oos.elm" "$TMP/oos.ssa") >/dev/null 2>&1
if head -c 4 "$TMP/oos.ssa" 2>/dev/null | grep -q '^err '; then
  echo "FAIL vfield-lowers: record field pattern still fails loudly: $(head -1 "$TMP/oos.ssa")"
  FAIL=1
else
  echo "PASS vfield-lowers: record field pattern ({ x } = {x=1}) now lowers (no loud failure)"
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
