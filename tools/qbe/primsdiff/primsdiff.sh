#!/usr/bin/env bash
# primsdiff.sh — THE GENERALIZED PRIM DIFFERENTIAL (handoff osier-midprims,
# step 5): consdiff.sh's shape over every ported prim family.  ONE generator
# (gen.js, fixed seed) produces the SAME vectors as (a) a spec the ZIG arm
# parses — every op dispatched through prims.execPrimitive, the reference
# entry — and (b) a surface fixture whose spellings compile to PrimApps that
# QBE_MIDCONS=1 routes to the Mid implementations.  IDENTICAL stdout is the
# claim, per batch, plain AND under QBE_HEAP_MB=16 (the churn arm: the moving
# collector churns every allocation either side makes).
#
# COVERAGE (36 ported prims through their surface spellings): the arithmetic
# and comparison operators (int and float), `=` over numbers, mixed
# numeric-promote pairs, strings, booleans and nested lists; the full Bitwise
# family (i32 operands, masked and unmasked shift counts, JS ToInt32 edges);
# the four tag predicates; the string family (cn over strings AND over
# numbers via fromInt's trusted-lie path, c-strlen, repeat, substring's
# clamps incl. negative start/len, char-code's bounds, str->bytes,
# bytes->string); absvector/address->/<-address (write then read —
# uninitialized elements are read by NEITHER arm); @p (tuples); assoc+snd
# (record get); cons; emptylist.
#
# STATED GAPS (the cons-spike discipline — a stated gap is a result):
#   * x/0 and x/0.0-as-SIGFPE: both arms die; untestable same-process.
#     The `=` prim's symbol/prim arms and `str`'s composite printer are not
#     reachable from surface Elm (no symbol literals; `str` stays host-side
#     over floatText), so they are covered indirectly (record fields give the
#     assoc/symbol path) or not at all (str — HOST-ONLY by classification).
#   * The Bitwise float arms (ToInt32 of a float) cannot type at the surface;
#     `asF`/`toI32` machinery is covered by the arithmetic/float batches.
#   * hd/tl/fst/reverse/append/absvector? have NO surface spelling
#     (unreachable from the front end) — nothing can drive them; they were
#     left unported rather than differentially-untested.
#   * Halt arms (emptylist non-0, assoc/bytes->string non-list): both arms
#     process-die; excluded by construction (generator never emits them).
#
# Usage: tools/qbe/primsdiff/primsdiff.sh [--n=200] [--seed=20261011] [--ops=LIST]
# Exit: 0 = every comparison identical; 1 = a divergence; 2 = tooling.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/primsdiff.XXXXXX")" || exit 2
# keep $WORK on failure for inspection; remove on success only
trap '[ "$FAIL" -eq 0 ] && rm -rf "$WORK"' EXIT

N=200
SEED=20261011
OPS="add-int add-float sub-int mul-int div-int fdiv-float lt-int le-int gt-int ge-float eq-int eq-mixed eq-string eq-bool eq-list and-int or-int xor-int not-int shl-int shr-int shrzf-int isnum isstr iscons isnil cn-str cn-num strlen repeat-str substring-str charcode-str strbytes bytestr vec atp assoc-int assoc-str cons-int nil"
for a in "$@"; do
  case "$a" in
    --n=*)     N="${a#--n=}" ;;
    --seed=*)  SEED="${a#--seed=}" ;;
    --ops=*)   OPS="${a#--ops=}" ;;
    *) echo "primsdiff: unknown argument '$a'" >&2; exit 2 ;;
  esac
done

command -v node >/dev/null 2>&1 || { echo "primsdiff: node not found" >&2; exit 2; }
command -v zig  >/dev/null 2>&1 || { echo "primsdiff: zig not found" >&2; exit 2; }
command -v cc   >/dev/null 2>&1 || { echo "primsdiff: cc not found" >&2; exit 2; }
[ -x "$ROOT/vendor/qbe/qbe" ] || { echo "primsdiff: vendored qbe missing" >&2; exit 2; }
[ -f "$ROOT/elm-compiler/compiler.js" ] || { echo "primsdiff: compiler.js missing (run build.sh)" >&2; exit 2; }

echo "primsdiff: building the Zig reference arm"
zig build-obj -O ReleaseFast -lc -femit-bin="$WORK/primref.o" \
  --dep gc --dep rt -Mroot="$ROOT/tools/qbe/primsdiff/primsdiff-zig.zig" \
  -Mgc="$ROOT/vendor/osier-rt/src/gc.zig" \
  --dep gc -Mrt="$ROOT/vendor/osier-rt/src/rt.zig" || {
  echo "primsdiff: zig build-obj FAILED" >&2; exit 2; }
cc "$WORK/primref.o" -lc -o "$WORK/primref" || { echo "primsdiff: cc link FAILED" >&2; exit 2; }

FAIL=0
TOTAL=0
for op in $OPS; do
  B="$WORK/$op"
  echo "primsdiff: batch op=$op n=$N seed=$SEED"
  node tools/qbe/primsdiff/gen.js "$B" --op="$op" --n="$N" --seed="$SEED" || exit 2

  if ! RUN_STACK_KB=131072 QBE_MIDCONS=1 "$ROOT/tools/qbe/qbe-mk.sh" "$B/Fixture.elm" PrimDiff.all "$B/midarm" >/dev/null 2>&1; then
    echo "FAIL op=$op: qbe-mk compile failed"
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
    # BYTE-EXACT: outputs go straight to files (command substitution would
    # silently drop NUL bytes — the byte-list batches print raw bytes, and a
    # divergence IN the nulls must not be invisible).  stderr is kept out of
    # the compared stream but its presence fails the exit-code check.
    env "${ENVV[@]}" timeout 120 "$WORK/primref" "$B/vectors.spec" > "$B/zig.$mode.out" 2> "$B/zig.$mode.err"
    zrc=$?
    env "${ENVV[@]}" timeout 120 "$BIN" PrimDiff.all > "$B/mid.$mode.out" 2> "$B/mid.$mode.err"
    mrc=$?
    if [ "$zrc" -ne 0 ] || [ "$mrc" -ne 0 ]; then
      echo "FAIL $mode op=$op: exit codes zig=$zrc mid=$mrc"
      echo "  zig: $(head -c 200 "$B/zig.$mode.out" 2>/dev/null)"
      echo "  mid: $(head -c 200 "$B/mid.$mode.out" 2>/dev/null)"
      FAIL=1
      continue
    fi
    if ! cmp -s "$B/zig.$mode.out" "$B/mid.$mode.out"; then
      echo "FAIL $mode op=$op: outputs DIVERGE — first difference:"
      cmp "$B/zig.$mode.out" "$B/mid.$mode.out" | head -c 200
      echo
      echo "  (full outputs kept: $B/{zig,mid}.$mode.out)"
      FAIL=1
    else
      echo "PASS $mode op=$op: identical ($(wc -c < "$B/zig.$mode.out") bytes)"
    fi
  done
done

if [ "$FAIL" -eq 0 ]; then
  echo "primsdiff: VERDICT — the Mid implementations agree with the Zig execPrimitive entries on $TOTAL comparisons ($OPS batches x plain + QBE_HEAP_MB=16 churn), n=$N vectors per batch, seed $SEED"
  exit 0
fi
echo "primsdiff: VERDICT — DIVERGENCE (see FAIL lines above)"
exit 1
