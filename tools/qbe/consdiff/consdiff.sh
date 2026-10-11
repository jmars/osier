#!/usr/bin/env bash
# consdiff.sh — THE CONS DIFFERENTIAL (handoff osier-consspike, TRACK 2 step 4):
# the load-bearing oracle for "the runtime can be written at the Mid level".
#
# ONE generator (gen.js, fixed seed) produces the SAME argument vectors as
#   (a) a spec file the ZIG arm parses, and
#   (b) a surface fixture whose every `::` compiles to a call through the
#       Mid-implemented Rt.cons (QBE_MIDCONS=1).
# The Zig arm drives prims.execPrimitive — the reference implementation the
# rt_prim generic route and pass-A direct entries call — and prints its
# results with values.printValue; the native driver prints the fixture's
# entry with the SAME printer.  IDENTICAL stdout is the claim: the Mid cons
# agrees with the Zig cons on generated vectors, not hand-picked ones.
#
# BATCHES: one per element type β (int/float/bool/string, plain and nested —
# surface `::` is typed, so a batch's fixture is homogeneous in β; see
# gen.js's header).  Each batch runs BOTH arms twice: plain, and under
# QBE_HEAP_MB=16 (the minimum viable heap, qbe-check's CHURN_MB discipline)
# so the moving collector churns every cons either side makes — a rooting bug
# in the Rt.cons lowering is a stale interior pointer HERE, not a latent
# corruption.
#
# WHAT THIS DOES NOT COVER (stated plainly): improper pairs (a non-list cdr)
# are the @p prim on the surface — identical Zig body (values.zig valCons
# serves both; its Mid port is step 5).  String/float/number CONSTRUCTION is
# not under test — only cons is; the literals arrive through each arm's own
# constructors and are compared as VALUES.
#
# Usage: tools/qbe/consdiff/consdiff.sh [--n=200] [--seed=20261010] [--batches=LIST]
# Exit: 0 = every comparison identical; 1 = a divergence (the most important
# possible finding of the whole spike — do not weaken the comparison to make
# it pass); 2 = tooling.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/consdiff.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

N=200
SEED=20261010
BATCHES="int:0 float:0 bool:0 string:0 int:1 string:1 bool:2"
for a in "$@"; do
  case "$a" in
    --n=*)        N="${a#--n=}" ;;
    --seed=*)     SEED="${a#--seed=}" ;;
    --batches=*)  BATCHES="${a#--batches=}" ;;
    *) echo "consdiff: unknown argument '$a'" >&2; exit 2 ;;
  esac
done

command -v node >/dev/null 2>&1 || { echo "consdiff: node not found" >&2; exit 2; }
command -v zig  >/dev/null 2>&1 || { echo "consdiff: zig not found"  >&2; exit 2; }
command -v cc   >/dev/null 2>&1 || { echo "consdiff: cc not found"   >&2; exit 2; }
[ -x "$ROOT/vendor/qbe/qbe" ] || { echo "consdiff: vendored qbe missing" >&2; exit 2; }
[ -f "$ROOT/elm-compiler/compiler.js" ] || { echo "consdiff: compiler.js missing (run build.sh)" >&2; exit 2; }

# ---- the ZIG arm: build-obj + cc, the exact link shape qbe-mk uses for rt.o
echo "consdiff: building the Zig reference arm"
zig build-obj -O ReleaseFast -lc -femit-bin="$WORK/consref.o" \
  --dep gc --dep rt -Mroot="$ROOT/tools/qbe/consdiff/consdiff-zig.zig" \
  -Mgc="$ROOT/vendor/osier-rt/src/gc.zig" \
  --dep gc -Mrt="$ROOT/vendor/osier-rt/src/rt.zig" || {
  echo "consdiff: zig build-obj FAILED" >&2; exit 2; }
cc "$WORK/consref.o" -lc -o "$WORK/consref" || { echo "consdiff: cc link FAILED" >&2; exit 2; }

FAIL=0
TOTAL=0
for batch in $BATCHES; do
  KIND="${batch%%:*}"; NEST="${batch##*:}"
  B="$WORK/$KIND-$NEST"
  echo "consdiff: batch kind=$KIND nest=$NEST n=$N seed=$SEED"
  node tools/qbe/consdiff/gen.js "$B" --kind="$KIND" --nest="$NEST" --n="$N" --seed="$SEED" || exit 2

  # RUN_STACK_KB: a nest-2 fixture's bindings are single giant nested-literal
  # expressions, and the compiler's recursive lowering over them exceeds
  # node's default V8 stack — run.js's own re-exec knob (its header documents
  # exactly this class), so the deeper batches compile with a raised budget.
  if ! RUN_STACK_KB=131072 QBE_MIDCONS=1 "$ROOT/tools/qbe/qbe-mk.sh" "$B/Fixture.elm" ConsDiff.all "$B/midarm" >/dev/null 2>&1; then
    echo "FAIL kind=$KIND nest=$NEST: qbe-mk compile failed"
    FAIL=1
    continue
  fi
  BIN="$B/midarm/Fixture"

  for mode in default churn-16; do
    TOTAL=$((TOTAL + 1))
    if [ "$mode" = churn-16 ]; then
      ENVV=(LC_ALL=C QBE_HEAP_MB=16)
    else
      ENVV=(LC_ALL=C)
    fi
    zig_out="$(env "${ENVV[@]}" timeout 120 "$WORK/consref" "$B/vectors.spec" 2>&1)"
    zrc=$?
    mid_out="$(env "${ENVV[@]}" timeout 120 "$BIN" ConsDiff.all 2>&1)"
    mrc=$?
    if [ "$zrc" -ne 0 ] || [ "$mrc" -ne 0 ]; then
      echo "FAIL $mode kind=$KIND nest=$NEST: exit codes zig=$zrc mid=$mrc"
      echo "  zig: $(printf '%s' "$zig_out" | head -c 200)"
      echo "  mid: $(printf '%s' "$mid_out" | head -c 200)"
      FAIL=1
      continue
    fi
    if [ "$zig_out" != "$mid_out" ]; then
      echo "FAIL $mode kind=$KIND nest=$NEST: outputs DIVERGE — first difference:"
      diff <(printf '%s\n' "$zig_out") <(printf '%s\n' "$mid_out") | head -c 1200
      echo
      printf '%s' "$zig_out" > "$B/zig.$mode.out"
      printf '%s' "$mid_out" > "$B/mid.$mode.out"
      echo "  (full outputs kept: $B/{zig,mid}.$mode.out)"
      FAIL=1
    else
      echo "PASS $mode kind=$KIND nest=$NEST: identical ($(printf '%s' "$zig_out" | wc -c) bytes, $(printf '%s' "$zig_out" | grep -o '\[cons ' | wc -l) cons cells printed)"
    fi
  done
done

if [ "$FAIL" -eq 0 ]; then
  echo "consdiff: VERDICT — Mid Rt.cons agrees with the Zig execPrimitive entry on $TOTAL comparisons ($BATCHES batches x plain + QBE_HEAP_MB=16 churn)"
fi
exit $FAIL
