#!/usr/bin/env bash
# word-arm-diff.sh — THE ONLY ORACLE THAT SEES BOTH ARMS AT ONCE (perf
# word-arm-area3rt).
#
# WHY THIS ROW EXISTS.  Every other word-arm instrument reads ONE arm: the text
# pins assert the shape the author wrote, the corpus pins the val arm's bytes,
# and word-arm-probe runs word-arm code against hand-written seats — none of them
# compares the two REPRESENTATIONS.  They are SUPPOSED to differ (that is the
# whole point of the arm), so a .ssa comparison is meaningless; the only shared
# observable is the PROGRAM'S OUTPUT.
#
# WHAT IT CANNOT SEE, MEASURED (review BLOCKER 1).  A whole PROGRAM is the wrong
# instrument for the emitter's ELEMENT paths as long as the surface lane refused
# every aggregate: under the word arm an arg-taking entry needs a `Lam`, which
# the surface lane refuses, so no fixture could CONSTRUCT a heap object at all.
# MEASURED: flipping `wordVecBody`'s heap arm to a 16-byte-wrong base left this
# row GREEN.  That gap is `word-arm-probe`'s `vec` probe (a hand-built code-10
# block driven through `vecbody`), and the mutation that this row cannot see
# turns THAT red.  The two rows are complements, not duplicates: this one proves
# the arms agree on a program's OUTPUT, the probe proves the element machinery
# is right.
#
# THAT GAP HAS NARROWED (perf word-arm-surface): `cons.elm` builds a cons chain,
# so this row now EXECUTES the heap-cell path, the element stores and the
# printer's tag-4 walk — a wrong element base or stride in `Rt.cons`'s arm shows
# up here as differing output or a SIGSEGV.  `case.elm` goes further: its `f p`
# and `g xs` are ARG-TAKING top-level defuns CALLED from `main`, so the word
# arm's argument path (a word in a register, stored by the callee's prologue)
# and the tail call into it are exercised too — an earlier revision of this
# paragraph said the row could not reach an arg-taking entry, which was true
# when only `cons.elm`/`tup.elm` existed and false from the commit that added
# `case.elm`.
#
# ARITHMETIC IS COVERED TOO (perf word-arm-arith): `arith.elm` runs `+ - *`,
# `//` (including its TRUNCATE-TOWARD-ZERO corners and the named `// 0` halt),
# the four comparisons, `==`, `/=` and `negate` on both arms, and `receq.elm`
# runs `==` on RECORDS — the fixture that was UNWRITABLE until the `=` prim was
# ported, because `Rt.recEqGo` was correct-but-unexecuted without it.
#
# CLOSURES ARE COVERED TOO (perf word-arm-closures): `clo.elm` holds functions as
# VALUES — a global reached through `Rt.globalClosure` and called twice (so the
# descriptor CACHE hit is exercised, not just the miss), a capturing lambda
# created twice with different captures, a higher-order call whose head is a
# `Var` (the whole generic apply chain), and an UNDER-applied closure
# (`Rt.applyPartGo`'s three-range interleave).  That fixture is why this row is
# the closure unit's behavioural oracle: the closure machinery was textually
# twinned by earlier units and never EXECUTED, and running it found two real
# defects (`Rt.globalClosure`'s twin answered a fixnum-shaped closure and wrote
# its header eight bytes off) that every pin in the tree was green over.
#
# WHAT IS STILL OUT OF REACH, and therefore still the probes' job: a VECTOR
# built by the surface (no prim constructs one from a program), a FLOAT
# (area 5), and CHAR/STRING ORDERING (`"a" < "b"`), which the word arm refuses
# BY NAME rather than answering through the numeric-only `Rt.<`.  So the `vec`,
# `veclen` and `call` probes are complements to this row, not duplicates.
#
# WHAT IT DOES.  For each fixture: compile the same source TWICE — once on the
# val arm (`QBE_ENTRY=M.main node run.js`) and once with `QBE_VALREP=word` —
# assemble each through the SAME vendored qbe, link each with cc, RUN each with
# the entry name, and gate on
#   (a) both binaries building (a qbe or cc failure is a FAIL, not a skip),
#   (b) IDENTICAL exit codes,
#   (c) BYTE-IDENTICAL STDOUT (stderr is not compared — the exit code is),
#   (d) the word-arm .ssa not being an `err ` payload (a refusal is not a run),
#   (e) neither arm TIMING OUT: a wrong count or stride can loop instead of
#       crashing, and a gate that hangs reports nothing.
# The exit code is part of the assertion because a wrong offset does not print
# FAIL — it dies as SIGSEGV (139) or SIGABRT (134).
#
# Usage (from the repo root):  tools/qbe/word-arm-diff.sh
# Exit: 0 = every fixture's two arms agreed; 1 = a mismatch or a build failure;
#       2 = tooling missing.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CDIR="$ROOT/osier-compiler"
HERE="$ROOT/tools/qbe/word-arm-diff"
QBE="$ROOT/vendor/qbe/qbe"

[ -f "$CDIR/compiler.js" ] || { echo "word-arm-diff: $CDIR/compiler.js missing (run: osier-compiler/build.sh)" >&2; exit 2; }
[ -x "$QBE" ] || { echo "word-arm-diff: $QBE missing (run: tools/qbe-build.sh)" >&2; exit 2; }
command -v cc >/dev/null 2>&1 || { echo "word-arm-diff: cc missing" >&2; exit 2; }

BUILD="$(mktemp -d "${TMPDIR:-/tmp}/word-arm-diff.XXXXXX")" || exit 2
trap 'rm -rf "$BUILD"' EXIT

fails=0
for src in "$HERE"/*.elm; do
  name="$(basename "$src" .elm)"
  # the entry is the module's `main`, keyed by the module name in the source
  mod="$(sed -n 's/^module \([A-Za-z0-9_]*\) .*/\1/p' "$src" | head -1)"
  entry="$mod.main"

  (cd "$CDIR" && QBE=1 QBE_ENTRY="$entry" node run.js "$src" "$BUILD/$name.val.ssa") >/dev/null 2>&1
  (cd "$CDIR" && QBE_VALREP=word QBE_ENTRY="$entry" node run.js "$src" "$BUILD/$name.word.ssa") >/dev/null 2>&1

  for arm in val word; do
    ssa="$BUILD/$name.$arm.ssa"
    if [ ! -s "$ssa" ]; then
      echo "FAIL $name/$arm: no .ssa emitted"
      fails=$((fails + 1))
      continue
    fi
    case "$(head -c 4 "$ssa")" in
      "err "*)
        echo "FAIL $name/$arm: the compile REFUSED — $(head -c 200 "$ssa")"
        fails=$((fails + 1))
        continue
        ;;
    esac
    if ! "$QBE" "$ssa" > "$BUILD/$name.$arm.s" 2> "$BUILD/$name.$arm.qerr"; then
      echo "FAIL $name/$arm: qbe rejected the .ssa — $(head -1 "$BUILD/$name.$arm.qerr")"
      fails=$((fails + 1))
      continue
    fi
    if ! cc "$BUILD/$name.$arm.s" -o "$BUILD/$name.$arm" -lc 2> "$BUILD/$name.$arm.cerr"; then
      echo "FAIL $name/$arm: cc failed — $(grep -m1 'undefined reference\|error' "$BUILD/$name.$arm.cerr")"
      fails=$((fails + 1))
      continue
    fi
  done

  [ -x "$BUILD/$name.val" ] && [ -x "$BUILD/$name.word" ] || continue

  # A TIMEOUT, AND IT FAILS (review SHOULD-FIX 1).  A wrong COUNT is exactly the
  # class a wrong representation produces — and it does not crash, it LOOPS.  A
  # gate that hangs is worse than one that reds: it burns the run and reports
  # nothing.  `timeout` exits 124, which is != the other arm's code, so the
  # comparison below turns it into a FAIL with the reason visible.
  timeout 20 "$BUILD/$name.val" "$entry" > "$BUILD/$name.val.out" 2> "$BUILD/$name.val.err"
  vrc=$?
  timeout 20 "$BUILD/$name.word" "$entry" > "$BUILD/$name.word.out" 2> "$BUILD/$name.word.err"
  wrc=$?

  if [ "$vrc" = 124 ] || [ "$wrc" = 124 ]; then
    echo "FAIL $name: TIMED OUT (val $vrc, word $wrc) — a wrong count/stride can loop instead of crashing; word stderr: $(head -1 "$BUILD/$name.word.err")"
    fails=$((fails + 1))
  elif [ "$vrc" != "$wrc" ]; then
    echo "FAIL $name: exit codes differ (val $vrc, word $wrc) — word stderr: $(head -1 "$BUILD/$name.word.err")"
    fails=$((fails + 1))
  elif ! cmp -s "$BUILD/$name.val.out" "$BUILD/$name.word.out"; then
    echo "FAIL $name: stdout differs — val [$(cat "$BUILD/$name.val.out")] word [$(cat "$BUILD/$name.word.out")]"
    fails=$((fails + 1))
  else
    echo "PASS $name: both arms exit $vrc and print the same STDOUT bytes ($(wc -c < "$BUILD/$name.val.out") B; stderr is not compared, the exit code is)"
  fi
done

if [ "$fails" != 0 ]; then
  echo "word-arm-diff: $fails failure(s) — the two representations DISAGREE on a program's output"
  exit 1
fi
exit 0
