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
# Per-run scratch dir (mktemp, NOT a fixed path).  A fixed path persists across
# runs, so anything that reads it without rebuilding tests whatever the
# PREVIOUS run left behind: a stale pre-bounce binary was once reused here and
# the suite reported an old crash ceiling as a current measurement.  qbe-mk
# rebuilds its outputs on every call, but the checks that read an artifact
# WITHOUT rebuilding it first -- root-stores' fib.s, vfield-lowers' oos.ssa,
# the structural mutual-tail binary -- would otherwise answer from the last
# run's tree after a failed build.  rt.o, the one artifact meant to survive,
# lives in tools/qbe/ under qbe-mk's own freshness guard.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/qbe-check.XXXXXX")" || {
  echo "qbe-check: mktemp failed" >&2
  exit 2
}
trap 'rm -rf "$TMP"' EXIT
FAIL=0

# Fail loud before ~50 cryptic per-fixture mismatches: the VM reference runner
# is a zig build product this script does not build itself.
[ -x "$ROOT/zig-out/bin/elmvm" ] || {
  echo "qbe-check: zig-out/bin/elmvm missing (run: zig build elmvm)" >&2
  exit 2
}
echo "qbe-check: artifacts in $TMP" >&2

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

# like run(), but with AOTRUN_ARGV=1 on BOTH runners: the trailing args are the
# APP's *argv* pseudo-global (string list), NOT int call args — the selfhost
# CLI-driver contract (elmvm/aot-run).  Guards the argvPrimThunk arity bug.
run_argv() {
  local name="$1" entry="$2" fixture="$3"; shift 3
  local args=("$@")
  local bin
  bin="$("$ROOT/tools/qbe/qbe-mk.sh" "$fixture" "$entry" "$TMP/$name" "${args[@]}" 2>/dev/null)" || {
    echo "FAIL $name: qbe-mk"; FAIL=1; return
  }
  (cd "$ROOT/elm-compiler" &&
    MIDTIER=0 node run.js "$ROOT/$fixture" "$TMP/$name/ref.csexp") >/dev/null 2>&1
  local vm_out nat_out
  vm_out="$(AOTRUN_ARGV=1 "$ROOT/zig-out/bin/elmvm" "$TMP/$name/ref.csexp" "$entry" "${args[@]}" 2>&1)"
  nat_out="$(timeout 60 env AOTRUN_ARGV=1 "$bin" "$entry" "${args[@]}" 2>&1)"
  if [ "$vm_out" != "$nat_out" ]; then
    echo "FAIL $name: vm='$vm_out' native='$nat_out'"
    FAIL=1
    return
  fi
  echo "PASS $name: identical (${nat_out:0:80})"
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

# ---- stage 5: the argv pseudo-global (found by the selfhost behavioural
#      run — no fixture used argv, so the suite was blind to it) ----
# argvPrimThunk was a 0-param Lam read as arity 0 but applied with 1 arg; the
# fix gives it a real 1-arg binder.  run_argv sets AOTRUN_ARGV=1 on BOTH
# runners (string list, not int args).
run_argv argvrepro-empty ArgvRepro.main tools/qbe/fixtures/argvrepro.elm
run_argv argvrepro-count ArgvRepro.count tools/qbe/fixtures/argvrepro.elm a b c d

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
# The compile's own status decides, not the old artifact's absence: with no
# build this run there is no oos.ssa, and "no err prefix in a missing file"
# must not read as a pass.
if (cd "$ROOT/elm-compiler" &&
      QBE=1 QBE_ENTRY=Oos.main node run.js "$TMP/oos.elm" "$TMP/oos.ssa") >/dev/null 2>&1 \
   && [ -f "$TMP/oos.ssa" ] \
   && ! head -c 4 "$TMP/oos.ssa" | grep -q '^err '; then
  echo "PASS vfield-lowers: record field pattern ({ x } = {x=1}) now lowers (no loud failure)"
else
  echo "FAIL vfield-lowers: record field pattern still fails loudly: $(head -c 200 "$TMP/oos.ssa" 2>/dev/null)"
  FAIL=1
fi

# ---- stage 6: FLATTEN (defun-local, escape-safe aggregate flattening) ----
# flatten.elm: every aggregate is built AND consumed in ONE defun, so the pass
# must delete the record representation entirely (assoc/snd/@p, plus the cons/
# emptylist chain they sit on).  noflatten.elm: structurally similar aggregates
# that all ESCAPE (returned, captured, passed, stored in a tuple that escapes,
# aliased, or a list pattern whose bind lands on the tail) — the pass must
# change NOTHING there.  Same source shapes, opposite outcomes.
run flatten   Flatten.main   tools/qbe/fixtures/flatten.elm
run noflatten NoFlatten.main tools/qbe/fixtures/noflatten.elm

# ---- structural: an A/B on the SAME source.  QBE_NOFLATTEN=1 disables the
#      pass, so the two builds differ ONLY by it — which is the asymmetry
#      proof ("fails before, passes after"), and strictly sharper than an
#      absolute count, which a fixture change could quietly satisfy.
#
# prim_count <ssa> <prim-name>: the number of `rt_prim` SITES whose prim
# symbol is <name>.  The prim travels as a static data address (`l $d7`), so
# the name is resolved from its `data $d7 = align 8 { b "assoc", b 0 }`
# definition — counted, not assumed.
prim_count() {
  awk -v want="$2" '
    FNR==NR {
      l=$0; gsub(/[(),]/," ",l); n=split(l,f," ")
      nm=""
      for(i=1;i<=n;i++) if(f[i]=="b" && f[i+1] ~ /^"/) { nm=f[i+1]; gsub(/"/,"",nm) }
      if (nm != "") for(j=1;j<=n;j++) if(f[j] ~ /^\$d[0-9]+$/) { map[f[j]]=nm; break }
      next
    }
    {
      l=$0; gsub(/[(),]/," ",l); n=split(l,f," ")
      for(i=1;i<=n;i++) if(f[i] ~ /\$rt_prim/ && f[i+2] ~ /^\$d[0-9]+$/) { if (map[f[i+2]]==want) c++ }
    }
    END { print c+0 }
  ' "$1" "$1"
}

# compile one fixture entry to .ssa with the pass ON or OFF, via a SCRATCH
# output path (run.js writes to the path it is given; nothing here can clobber
# a tracked artifact).
qbe_ssa() { # <fixture> <entry> <out.ssa> <on|off>
  if [ "$4" = "off" ]; then
    (cd "$ROOT/elm-compiler" && QBE=1 QBE_NOFLATTEN=1 QBE_ENTRY="$2" node run.js "$ROOT/$1" "$3") >/dev/null 2>&1
  else
    (cd "$ROOT/elm-compiler" && QBE=1 QBE_ENTRY="$2" node run.js "$ROOT/$1" "$3") >/dev/null 2>&1
  fi
}

# aggregate prims: any of these is a heap aggregate the pass exists to remove
AGGPRIMS="assoc snd @p emptylist cons"

qbe_ssa tools/qbe/fixtures/flatten.elm   Flatten.main   "$TMP/flat-on.ssa"  on
qbe_ssa tools/qbe/fixtures/flatten.elm   Flatten.main   "$TMP/flat-off.ssa" off
qbe_ssa tools/qbe/fixtures/noflatten.elm NoFlatten.main "$TMP/noflat-on.ssa"  on
qbe_ssa tools/qbe/fixtures/noflatten.elm NoFlatten.main "$TMP/noflat-off.ssa" off

if [ -s "$TMP/flat-on.ssa" ] && [ -s "$TMP/flat-off.ssa" ]; then
  f_bad=0
  # (a) the POSITIVE direction: assoc/snd/@p are gone, and were present
  #     WITHOUT the pass.  emptylist/cons must not grow either.
  for p in assoc snd '@p'; do
    on=$(prim_count "$TMP/flat-on.ssa" "$p")
    off=$(prim_count "$TMP/flat-off.ssa" "$p")
    if [ "$on" -ne 0 ]; then
      echo "FAIL flatten-structural: '$p' still emitted $on time(s) with the pass ON"
      f_bad=1
    elif [ "$off" -lt 1 ]; then
      echo "FAIL flatten-structural: '$p' was ALREADY absent without the pass — fixture does not exercise it"
      f_bad=1
    fi
  done
  for p in emptylist cons; do
    on=$(prim_count "$TMP/flat-on.ssa" "$p")
    off=$(prim_count "$TMP/flat-off.ssa" "$p")
    if [ "$on" -gt "$off" ]; then
      echo "FAIL flatten-structural: '$p' grew with the pass ON ($on > $off)"
      f_bad=1
    fi
  done
  if [ "$f_bad" -eq 0 ]; then
    echo "PASS flatten-structural: assoc/snd/@p 11->0 with the pass; cons/emptylist 16/7 -> $(prim_count "$TMP/flat-on.ssa" cons)/$(prim_count "$TMP/flat-on.ssa" emptylist)"
  else
    FAIL=1
  fi
else
  echo "FAIL flatten-structural: flatten .ssa missing (compile failed?)"
  FAIL=1
fi

if [ -s "$TMP/noflat-on.ssa" ] && [ -s "$TMP/noflat-off.ssa" ]; then
  # (b) the NEGATIVE direction: EVERY aggregate here escapes, so the pass must
  #     be a NO-OP — counted per prim, ON vs OFF, exactly.
  n_bad=0
  for p in $AGGPRIMS; do
    on=$(prim_count "$TMP/noflat-on.ssa" "$p")
    off=$(prim_count "$TMP/noflat-off.ssa" "$p")
    if [ "$on" -ne "$off" ]; then
      echo "FAIL noflatten-structural: '$p' changed under the pass ($off -> $on): an escaping aggregate was flattened"
      n_bad=1
    elif [ "$on" -lt 1 ]; then
      echo "FAIL noflatten-structural: '$p' is absent from the fixture — it does not exercise that escape route"
      n_bad=1
    fi
  done
  if [ "$n_bad" -eq 0 ]; then
    echo "PASS noflatten-structural: pass is a NO-OP on every escaping aggregate (assoc 9, snd 9, @p 10, emptylist 7, cons 17 — identical ON/OFF)"
  else
    FAIL=1
  fi
else
  echo "FAIL noflatten-structural: noflatten .ssa missing (compile failed?)"
  FAIL=1
fi

# ---- cross-defun tail: UNBOUNDED after the bounce loop ----
# (qbe-mk rebuilds this binary from the current tree on every call and $TMP is
# per-run, so a pre-bounce binary left by an earlier commit cannot answer here
# -- that reuse via a fixed-path existence-guard was this check's stale-artifact
# bug.)
if "$ROOT/tools/qbe/qbe-mk.sh" tools/qbe/fixtures/mutualtail.elm Mutual.even "$TMP/mutual" >/dev/null 2>&1; then
  # Mutual.even n -> odd (n-1) -> even (n-2) is MUTUAL tail recursion.  Before
  # the bounce loop these cross-defun tails were PLAIN CALLS and died between
  # 20k-40k hops on an 8MB stack (2 native frames/hop).  After it, a tail call
  # returns a .tail chased by rt_bounce at constant native stack, so 1e6 hops —
  # the same depth the VM's appterm handles — must COMPLETE with the VM's answer.
  d=1000000
  (cd "$ROOT/elm-compiler" &&
    MIDTIER=0 node run.js "$ROOT/tools/qbe/fixtures/mutualtail.elm" "$TMP/mutual/ref.csexp") >/dev/null 2>&1
  vm_out="$("$ROOT/zig-out/bin/elmvm" "$TMP/mutual/ref.csexp" Mutual.even "$d" 2>&1)"
  nat_out="$(timeout 120 "$TMP/mutual/mutualtail" Mutual.even "$d" 2>&1)"
  if [ "$nat_out" = "$vm_out" ] && [ "$vm_out" = "1" ]; then
    echo "PASS mutual-tail $d hops: unbounded (identical to VM; pre-bounce ceiling was 20k-40k)"
  else
    echo "FAIL mutual-tail $d hops: vm='$vm_out' native='$nat_out'"
    FAIL=1
  fi
fi

exit $FAIL
