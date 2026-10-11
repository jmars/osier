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
#        tools/qbe/consdiff/consdiff.sh --freeze-ref   (PRE-FLIP ONLY)
# Exit: 0 = every comparison identical; 1 = a divergence (the most important
# possible finding of the whole spike — do not weaken the comparison to make
# it pass); 2 = tooling.
#
# THE FLIP (osier-flip, step 6): the Zig cons handler is DELETED, so the
# reference arm becomes the evidence captured BEFORE the deletion.
# --freeze-ref runs the pipeline WITH the live Zig arm and copies every
# batch's reference stdout (both modes) into golden/ — it exists ONLY while
# prims.zig still has primCons.  After the flip the script compares the Mid
# arm against those frozen bytes: it still falsifies any FUTURE change to
# Rt.cons, and can NO LONGER falsify a live Zig-vs-Mid divergence (there is
# no live Zig arm).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/consdiff.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

N=200
SEED=20261010
BATCHES="int:0 float:0 bool:0 string:0 int:1 string:1 bool:2"
FREEZE_REF=0
for a in "$@"; do
  case "$a" in
    --n=*)        N="${a#--n=}" ;;
    --seed=*)     SEED="${a#--seed=}" ;;
    --batches=*)  BATCHES="${a#--batches=}" ;;
    --freeze-ref) FREEZE_REF=1 ;;
    *) echo "consdiff: unknown argument '$a'" >&2; exit 2 ;;
  esac
done

GREF="$ROOT/tools/qbe/consdiff/golden"
if [ "$FREEZE_REF" = 1 ]; then
  mkdir -p "$GREF"
  {
    echo "frozen $(date -u +%Y-%m-%dT%H:%M:%SZ) from git $(git -C "$ROOT" rev-parse HEAD) (prims.zig still carries primCons)"
    echo "n=$N seed=$SEED batches=$BATCHES"
  } > "$GREF/MANIFEST.txt"
fi

command -v node >/dev/null 2>&1 || { echo "consdiff: node not found" >&2; exit 2; }
command -v zig  >/dev/null 2>&1 || { echo "consdiff: zig not found"  >&2; exit 2; }
command -v cc   >/dev/null 2>&1 || { echo "consdiff: cc not found"   >&2; exit 2; }
[ -x "$ROOT/vendor/qbe/qbe" ] || { echo "consdiff: vendored qbe missing" >&2; exit 2; }
[ -f "$ROOT/elm-compiler/compiler.js" ] || { echo "consdiff: compiler.js missing (run build.sh)" >&2; exit 2; }

# ---- THE REFERENCE, POST-FLIP ----------------------------------------------
# The flip DELETED the Zig cons handler, so the reference is the FROZEN bytes
# the Zig arm printed BEFORE the deletion (golden/, captured at git 8f581b8
# with primCons present; same generator, same n/seed).  --freeze-ref is the
# PRE-FLIP capture mode: it builds the live Zig arm, compares live and copies
# the reference out (post-flip its runs die loudly, "unknown primitive" — it
# self-retires).
if [ "$FREEZE_REF" = 1 ]; then
  echo "consdiff: building the Zig reference arm (pre-flip freeze mode)"
  zig build-obj -O ReleaseFast -lc -femit-bin="$WORK/consref.o" \
    --dep gc --dep rt -Mroot="$ROOT/tools/qbe/consdiff/consdiff-zig.zig" \
    -Mgc="$ROOT/vendor/osier-rt/src/gc.zig" \
    --dep gc -Mrt="$ROOT/vendor/osier-rt/src/rt.zig" || {
    echo "consdiff: zig build-obj FAILED" >&2; exit 2; }
  cc "$WORK/consref.o" -lc -o "$WORK/consref" || { echo "consdiff: cc link FAILED" >&2; exit 2; }
else
  [ -s "$GREF/MANIFEST.txt" ] || {
    echo "consdiff: no frozen reference at $GREF (the flip deleted the Zig arm; re-capturing needs the pre-flip tree + --freeze-ref)" >&2; exit 2; }
  echo "consdiff: reference = the FROZEN pre-flip Zig arm ($GREF, $(head -1 "$GREF/MANIFEST.txt")); no live Zig arm is built"
fi

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
    if [ "$FREEZE_REF" = 1 ]; then
      zig_out="$(env "${ENVV[@]}" timeout 120 "$WORK/consref" "$B/vectors.spec" 2>&1)"
      zrc=$?
      REF_OUT="$zig_out"; REF_NAME="live zig arm"
    else
      REF_FILE="$GREF/$KIND-$NEST.$mode.out"
      if [ ! -s "$REF_FILE" ]; then
        echo "FAIL $mode kind=$KIND nest=$NEST: no frozen reference at $REF_FILE"
        FAIL=1
        continue
      fi
      REF_OUT="$(cat "$REF_FILE")"; zrc=0; REF_NAME="frozen pre-flip reference"
    fi
    mid_out="$(env "${ENVV[@]}" timeout 120 "$BIN" ConsDiff.all 2>&1)"
    mrc=$?
    if [ "$FREEZE_REF" = 1 ] && [ "$zrc" -eq 0 ]; then
      printf '%s' "$zig_out" > "$GREF/$KIND-$NEST.$mode.out"
    fi
    if [ "$zrc" -ne 0 ] || [ "$mrc" -ne 0 ]; then
      echo "FAIL $mode kind=$KIND nest=$NEST: exit codes ref=$zrc mid=$mrc"
      echo "  ref: $(printf '%s' "$REF_OUT" | head -c 200)"
      echo "  mid: $(printf '%s' "$mid_out" | head -c 200)"
      FAIL=1
      continue
    fi
    if [ "$REF_OUT" != "$mid_out" ]; then
      echo "FAIL $mode kind=$KIND nest=$NEST: the Mid arm DIVERGES from the $REF_NAME — first difference:"
      diff <(printf '%s\n' "$REF_OUT") <(printf '%s\n' "$mid_out") | head -c 1200
      echo
      printf '%s' "$mid_out" > "$B/mid.$mode.out"
      echo "  (mid output kept: $B/mid.$mode.out)"
      FAIL=1
    else
      echo "PASS $mode kind=$KIND nest=$NEST: identical with the $REF_NAME ($(printf '%s' "$mid_out" | wc -c) bytes, $(printf '%s' "$mid_out" | grep -o '\[cons ' | wc -l) cons cells printed)"
    fi
  done
done

if [ "$FAIL" -eq 0 ]; then
  echo "consdiff: VERDICT — Mid Rt.cons still prints what the FROZEN pre-flip Zig reference printed, on $TOTAL comparisons ($BATCHES batches x plain + QBE_HEAP_MB=16; reference golden/, captured at git 8f581b8 before the flip deleted the Zig handler).  NO LIVE ZIG ARM EXISTS: a live Zig-vs-Mid divergence is no longer falsifiable here"
fi
exit $FAIL
