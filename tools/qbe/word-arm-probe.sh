#!/usr/bin/env bash
# word-arm-probe.sh — THE WORD ARM'S BEHAVIOUR GATE (perf VR3b3).
#
# WHAT IT PROVES.  Under QBE_VALREP=word no program compiled through run.js can
# run: the runtime is always injected, so the emitted set always reaches
# Rt.main and the runtime's FIRST CALL stops the arm at AREA 6.  That leaves the
# emitter's heap side — the tag writes (A), the payload reads (B), the tag tests
# (C) and the string cell (D) — with no executable oracle on the arm it
# targets, and a text pin cannot be one: on this arm a text pin asserts the
# SHAPE THE AUTHOR WROTE, so it cannot see a wrong shape one instruction away.
# MEASURED: five such bugs shipped past every pin in VR3b3's first commit and a
# sixth (a boolean tagis fold) past the second.  This script is the instrument
# that catches them, so it runs in the gate.
#
# HOW.  For each probe in Mid.Qbe.WordArmProbe:
#   1. `QBE_VALREP=word QBE_WORDARM_PROBE=<name> node run.js out.ssa` emits the
#      module — the SAME defun TestMain pins, through the SAME lowering path
#      run.js uses (so what runs is the emitter's own output, not a
#      hand-written module);
#   2. vendor/qbe/qbe assembles it;
#   3. the probe's entry is globalized (QBE emits it module-local) and linked
#      with harness.c, which stubs the four seats to the CONTRACT runtime.mid
#      states — in particular `Rt.allocRaw` returns `mknum(body)` with the
#      2-word header 16 bytes BEFORE it, which is the convention gcAlloc
#      implements on every path and the val arm consumes;
#   4. the binary RUNS and its assertions are checked.
#
# THE EXIT CODE IS PART OF THE ASSERTION.  A wrong offset does not print FAIL —
# it dies as SIGSEGV (139) or SIGABRT (134) — so each probe's exit status is
# gated, and the probe's own PASS/FAIL lines are checked on top.  A gate that
# read only stdout would pass a crash.
#
# Usage (from the repo root):
#   tools/qbe/word-arm-probe.sh            # build + run every probe, gate on it
#   tools/qbe/word-arm-probe.sh --keep     # leave the build dir for inspection
#
# Exit: 0 = every probe PASSED (with the expected number of checks);
#       1 = a probe FAILED, crashed, or emitted nothing;
#       2 = tooling/prerequisite missing.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CDIR="$ROOT/osier-compiler"
HERE="$ROOT/tools/qbe/word-arm-probe"
QBE="$ROOT/vendor/qbe/qbe"

# probe name | entry symbol | -D flag | expected check count
PROBES=(
  "str|q_St_x2ef|PROBE_STR|5"
  "payload|q_Pl_x2ef|PROBE_PAY|4"
  "len|q_Ln_x2ef|PROBE_LEN|2"
  "tagheap|q_Tg_x2ef|PROBE_TAGHEAP|5"
  "tagnil|q_Nt_x2ef|PROBE_TAGNIL|3"
  "tagbool|q_Bt_x2ef|PROBE_TAGBOOL|4"
)

[ -f "$CDIR/compiler.js" ] || { echo "word-arm-probe: $CDIR/compiler.js missing (run: osier-compiler/build.sh)" >&2; exit 2; }
[ -x "$QBE" ] || { echo "word-arm-probe: $QBE missing (run: tools/qbe-build.sh)" >&2; exit 2; }
command -v cc >/dev/null 2>&1 || { echo "word-arm-probe: cc missing" >&2; exit 2; }
command -v objcopy >/dev/null 2>&1 || { echo "word-arm-probe: objcopy missing" >&2; exit 2; }

KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/word-arm-probe.XXXXXX")" || exit 2
cleanup() { [ "$KEEP" = 1 ] && { echo "word-arm-probe: build dir $BUILD"; return; }; rm -rf "$BUILD"; }
trap cleanup EXIT

fails=0
for spec in "${PROBES[@]}"; do
  IFS='|' read -r name sym flag want <<<"$spec"
  ssa="$BUILD/$name.ssa"
  ( cd "$CDIR" && QBE_VALREP=word QBE_WORDARM_PROBE="$name" node run.js "$ssa" >/dev/null 2>"$BUILD/$name.emit.err" )
  if [ ! -s "$ssa" ]; then
    echo "FAIL $name: emitted nothing"; fails=$((fails + 1)); continue
  fi
  if head -c 4 "$ssa" | grep -q '^err'; then
    echo "FAIL $name: $(head -c 200 "$ssa")"; fails=$((fails + 1)); continue
  fi
  if ! "$QBE" -o "$BUILD/$name.s" "$ssa" 2>"$BUILD/$name.qbe.err"; then
    echo "FAIL $name: qbe rejected the module: $(head -3 "$BUILD/$name.qbe.err" | tr '\n' ' ')"
    fails=$((fails + 1)); continue
  fi
  if ! cc -c -w -o "$BUILD/$name.o" "$BUILD/$name.s" 2>"$BUILD/$name.cc.err"; then
    echo "FAIL $name: cc rejected the assembly: $(head -3 "$BUILD/$name.cc.err" | tr '\n' ' ')"
    fails=$((fails + 1)); continue
  fi
  objcopy --globalize-symbol="$sym" "$BUILD/$name.o"
  if ! cc -O1 -w -D"$flag" -o "$BUILD/p_$name" "$HERE/harness.c" "$BUILD/$name.o" 2>"$BUILD/$name.link.err"; then
    echo "FAIL $name: link failed: $(head -3 "$BUILD/$name.link.err" | tr '\n' ' ')"
    fails=$((fails + 1)); continue
  fi
  out="$("$BUILD/p_$name" 2>&1)"
  rc=$?
  got="$(printf '%s\n' "$out" | grep -c '^PASS')"
  bad="$(printf '%s\n' "$out" | grep -c '^FAIL')"
  # THE EXIT CODE IS PART OF THE ASSERTION: a crash (139/134/132) prints no FAIL.
  if [ "$rc" -ne 0 ] || [ "$bad" -ne 0 ] || [ "$got" -ne "$want" ]; then
    echo "FAIL $name: rc=$rc pass=$got want=$want fail=$bad"
    printf '%s\n' "$out" | sed 's/^/    /'
    fails=$((fails + 1))
  else
    echo "PASS $name ($got checks)"
  fi
done

if [ "$fails" -ne 0 ]; then
  echo "=============================="
  echo "word-arm-probe: $fails probe(s) FAILED"
  exit 1
fi
echo "=============================="
echo "word-arm-probe: all ${#PROBES[@]} probes PASS"
