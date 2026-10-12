#!/usr/bin/env bash
# primsdiff.sh — THE GENERALIZED PRIM DIFFERENTIAL (handoff osier-midprims,
# step 5): consdiff.sh's shape over every ported prim family.  ONE generator
# (gen.js, fixed seed) produces the SAME vectors as (a) a spec the ZIG arm
# parses — every op dispatched through prims.execPrimitive, the reference
# entry — and (b) a surface fixture whose spellings compile to PrimApps that
# QBE_MIDCONS=1 routes to the Mid implementations.  IDENTICAL stdout is the
# claim, per batch, plain AND at QBE_HEAP_MB=16.
#
# ======================= WHAT EACH BATCH ACTUALLY RUNS =======================
# THE STEP-5 REVIEW (handoff osier-midrt-review) found this script's coverage
# claim FALSE and the claim is now CHECKED, not asserted.  Two defects, both
# MEASURED by reading the Mid arm's own .ssa:
#
#  1. THE assoc/snd BATCHES WERE TAUTOLOGIES.  The spelling was
#     `let r = {f=a,g=b} in r.f`, which the pipeline CONSTANT-FOLDS (the
#     record's shape is known at the access), so each v-defun stored the field
#     value directly and the Mid arm never ran Rt.assoc/Rt.snd/Rt.assocGo —
#     the batch compared the folder against the Zig chain.  Fixed: the record
#     is built by a top-level function and read through another function's
#     PARAMETER (both survive the optimizer).  The `.g` vectors force assoc's
#     recursive arm (Rt.assocGo + its symbol deepEq); a head-only read
#     returns before it.
#
#  2. THE OPERATOR/EQ BATCHES WERE THE SAME DEFECT.  Lower's inline fast path
#     is gated by a deny-by-default VALUE proof (isIntKnown/isFloatKnown:
#     literals, Int/Float-typed parameters, + - * over those), so `(3) + (4)`
#     is emitted as a raw i64 add and `(a) == (b)` on proven numbers as a
#     payload compare: MEASURED, add-int/sub-int/mul-int/add-float/
#     fdiv-float/lt-int/le-int/gt-int/ge-float and eq-int/eq-mixed/eq-bool
#     produced NO `call $q_Rt_<op>` from any vector defun.  Those batches now
#     ALTERNATE the proven spelling with an OPAQUE one (each operand wrapped
#     in a top-level identity, which the proof denies), so ONE batch compares
#     BOTH paths against the reference.
#
# THE MECHANICAL CHECK: every batch declares, in gen.js, the Rt symbols its
# Mid arm must CALL (`require` -> $B/require.txt), and this script counts call
# sites in the Mid arm's .ssa ATTRIBUTED TO ITS OWN (non-q_Rt_) DEFUNS.  A
# batch that stops exercising a prim FAILS here instead of passing quietly —
# "this batch runs the Mid implementation" is an exit code, not a comment.
#
# COVERAGE (the routed Mid prims, per batch, all CHECKED): the arithmetic and
# comparison operators (int and float), `=` over numbers, mixed
# numeric-promote pairs, strings (incl. the equal-string TRUE path),
# booleans, nested lists and EQUAL-LENGTH VECTORS (elementwise walk);
# the full Bitwise family (i32 operands, masked and unmasked shift counts, JS
# ToInt32 edges); the four tag predicates; the string family (cn over strings
# AND over numbers via fromInt's trusted-lie path, c-strlen, repeat,
# substring's clamps incl. negative start/len, char-code's bounds,
# str->bytes, bytes->string); absvector/address->/<-address (write then read —
# uninitialized elements are read by NEITHER arm); @p (tuples); assoc+snd
# (record get AND record-field patterns, both the let-destructure and the
# case-alt VField seats); cons; emptylist.
#
# CHURN (should-fix 3): the churn batches (churn-str / churn-cons /
# churn-vec) allocate tens of KB PER VECTOR, which is the only lever that
# works — the nursery is a FIXED 8MB (vendor/osier-rt/src/gc/heap.zig:53) and
# QBE_HEAP_MB scales the TOTAL heap only, so the other batches' QBE_HEAP_MB=16
# run is a small-heap RERUN and NOT a collection (their PASS line says
# `heap16-rerun`, and it is not a churn claim).  For the churn batches this
# script PARSES BOTH ARMS' [GC STATS] line and fails unless the collector
# actually ran.  MEASURED (n=200): churn-str 334 scavenges, churn-cons 8
# scavenges, churn-vec 0 scavenges but 11 full collects — a multi-KB array is
# old-gen-allocated, so the vector family churns the OLD GENERATION.
#
# STATED GAPS (the cons-spike discipline — a stated gap is a result):
#   * x/0 and x/0.0-as-SIGFPE: both arms die; untestable same-process.
#   * The `=` prim's SYMBOL arms: sym/sym IS reachable and is now covered
#     BEHAVIOURALLY by the gate fixture tests/elm-fixtures/symeq.elm (stage-3
#     zigretire: case dispatch on nullary constructors lowers to Rt.= on two
#     bare symbol Values, and Record.remove's trusted body does `k == intern
#     "x"` = static sym: vs runtime-interned — the same-name-different-pointer
#     byte-walk fallback).  Its failure mode IS the pointer-identity fast path
#     being wrong (proved by asymmetry: always-True and pointer-only mutations
#     both flip it).  sym/prim and prim/sym are UNREACHABLE from compiled Elm
#     (no surface spelling builds a prim Value), so they have no behavioural
#     coverage — their soundness rests on the same word-0-name-pointer layout
#     argument.  `str`'s composite printer is NOT reachable (no symbol
#     literals; `str` stays host-side over floatText).
#   * The Bitwise float arms (ToInt32 of a float) cannot type at the surface;
#     `asF`/`toI32` machinery is covered by the arithmetic/float batches.
#   * hd/tl/fst/reverse/append/absvector? have NO surface spelling
#     (unreachable from the front end) — nothing can drive them; they were
#     left unported rather than differentially-untested.  THEY HAVE NO
#     COMPARISON and no batch here can give them one.
#   * Halt arms (emptylist non-0, assoc/bytes->string non-list): both arms
#     process-die; excluded by construction (generator never emits them).
#   * deepEqual's depth-1000 CYCLE GUARD: values.zig:346 answers FALSE for a
#     cyclic structure; the Mid deepEq has no counter, so a self-referential
#     vector makes Rt.= overflow the native stack (loud die) where the
#     reference returns false.  Unreachable from the typed surface spellings
#     this differential compiles, so no batch can drive it — recorded as a
#     POST-FLIP DIVERGENCE, not papered over.
#
# REFERENCE GOLDENS (capture item 3): the prim behaviours no surface spelling
# can reach (the `=` symbol arms) are captured in
# tools/qbe/primsdiff/golden/ — see its README.  `--golden` re-runs the
# reference arm on every committed spec there and diffs against the committed
# bytes; `--golden=freeze` re-captures.  Both exist only while the Zig
# reference arm does (pre-flip).
#
# ============ POST-FLIP BEHAVIOUR CHANGES (not differential gaps) ============
# These are NOT coverage gaps — no generated vector can see them — and they are
# recorded HERE because the flip deletes the reference arm that could still
# contradict them.  Each is MEASURED, not inferred.
#
#  1. CYCLE GUARD (capture item 4).  values.zig:346's deepEqual carries a
#     depth-1000 counter and answers FALSE past it, so a CYCLIC structure
#     terminates.  The Mid deepEq has no counter: a self-referential vector
#     (constructible from the surface through the vectorSet alias) makes Rt.=
#     recurse until the native stack dies — "qbe-rt: native stack depth
#     exceeded ... 64.0 MiB limit", exit 1 — where the reference prints false.
#     PINNED by qbe-check's cycleeq-dies-loudly row (post-flip: the DEFAULT
#     route dies; the pre-flip `false` golden is frozen evidence of the
#     deleted Zig behaviour).  It is a
#     LOUD divergence (never a silently wrong answer); the fix is a depth
#     parameter threaded through Mid deepEq/vecEq/assocGo, which re-shapes
#     Rt.='s helper ABI and belongs to the flip.
#
#  2. NUL TERMINATION (capture item 5).  Mid-built strings are NOT
#     NUL-terminated: bytesToStr allocates count+1 (Mid/RtPrims.elm) and
#     fillGo writes only count bytes, while EVERY Zig constructor terminates
#     (values.zig valString/valStringFrom, prims.zig primCn/primRepeat/
#     primBytesToStr).  INVISIBLE TODAY, and verified so by reading every
#     reader: all of them go through values.strSlice (length-based), and the
#     one NUL-needing consumer (execplan.zig dupeZ) copies via strSlice first.
#     DECISION: deferred to the flip, with the exact fix named (a final
#     RawByteStore of 0 at buf[count]) — implementing it now moves the emitted
#     .ssa of every string-constructing group AND leaves the committed
#     bootstrap seed stale relative to Mid/RtPrims.elm, which the task's
#     oracle forbids re-freezing unless the runtime INTERFACE moved (it did
#     not: the ABI marker is unchanged).  Do it in the same change that
#     re-freezes the seed.
#
#  3. RECURSION CLIFF (capture item 6).  Every Mid string helper recurses PER
#     BYTE (bytesOf / subGo / repGo / fillGo / bytesEqGo / nameBytes /
#     bytesBuild / symEq / countL / revGo).  100KB strings (Str.repeat 50000
#     "ab") pass on both arms; 1MB (500000 "ab") KILLS the Mid arm loudly
#     ("native stack depth exceeded", 64 MiB raised stack) where the reference
#     prints 1000000.  Post-flip this is a behaviour change for large-string
#     programs, at a cliff between 100KB and 1MB.  A documented limit, not a
#     guard: the death is loud and the fix (iterative or tail-shaped helpers)
#     is flip work, like the cycle counter.
#
#  4. rt_vec_alloc(0) AND WRAPPED SIZES (capture item 7).  rt_vec_alloc(0)
#     returns a LIVE zero-length array (tools/qbe/rt.zig) where the reference's
#     valVector(0) leaves data=null: an OOB index on an empty vector is memory
#     corruption on the Mid side vs a null-deref crash on the reference.  And
#     n in [2^31, 2^32) — reachable through wrapped surface arithmetic — makes
#     the reference build a len<0 null-data value while the Mid @intCast
#     panics.  Both arms garbage-land; parity note only, and post-flip the
#     reference branch ceases to exist.
#
# Usage: tools/qbe/primsdiff/primsdiff.sh [--n=200] [--seed=20261011] [--ops=LIST]
#        tools/qbe/primsdiff/primsdiff.sh --golden[=freeze]
#        tools/qbe/primsdiff/primsdiff.sh --freeze-batch-ref   (PRE-FLIP ONLY)
# Exit: 0 = every comparison identical (and every instrumentation contract
#       satisfied); 1 = a divergence or a batch that does not exercise its
#       prims; 2 = tooling.
#
# ---- THE FLIP (osier-flip, step 6) --------------------------------------
# The flip DELETES the Zig handlers these batches drove, so the reference arm
# becomes the evidence captured BEFORE the deletion:
#   --freeze-batch-ref  runs the full pipeline WITH the live Zig arm and
#                       copies every batch's reference stdout (both modes)
#                       plus the reference GC STATS lines into
#                       golden/batches/ — the frozen reference.  It exists
#                       ONLY while prims.zig still has the handlers.
# After the flip the DEFAULT mode compares the Mid arm's output against those
# frozen bytes (see the POST-FLIP REFERENCE section in the loop below): the
# differential still falsifies any FUTURE change to the Mid implementations
# (they must keep printing what the pre-flip Zig reference printed), and it
# can NO LONGER falsify a live Zig-vs-Mid divergence — there is no live Zig
# arm, and the reference side of the churn assertion is frozen evidence, not
# a measurement.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/primsdiff.XXXXXX")" || exit 2
# keep $WORK on failure for inspection; remove on success only
FAIL=0
trap '[ "${FAIL:-1}" -eq 0 ] && rm -rf "$WORK"' EXIT

# ---- REFERENCE GOLDENS (pre-flip): verify or re-capture ------------------
# RETIRED AT THE FLIP: this mode re-ran the live Zig reference arm against the
# committed specs, and the flip DELETED the handlers those specs drive ("=",
# the symbol arms).  golden/*.spec + *.out remain the frozen evidence of the
# behaviours no surface spelling can reach; nothing on this tree can
# re-derive them.  The batch reference (the 46 differential batches) is the
# frozen golden/batches/ the default mode compares against.
if [ "${1:-}" = "--golden" ] || [ "${1:-}" = "--golden=freeze" ]; then
  echo "primsdiff: --golden is RETIRED at the flip — the Zig reference arm no longer exists;" >&2
  echo "primsdiff: golden/{*.spec,*.out} are frozen pre-flip evidence (git 8f581b8), verified by nothing on this tree;" >&2
  echo "primsdiff: the batch reference the default mode uses is golden/batches/ (also frozen pre-flip)." >&2
  exit 2
fi


N=200
SEED=20261011
OPS="add-int add-float sub-int mul-int div-int fdiv-float lt-int le-int gt-int ge-float eq-int eq-mixed eq-string eq-string-same eq-bool eq-list eq-vec and-int or-int xor-int not-int shl-int shr-int shrzf-int isnum isstr iscons isnil cn-str cn-num strlen repeat-str substring-str charcode-str strbytes bytestr vec atp assoc-int assoc-str assoc-pat cons-int nil churn-str churn-cons churn-vec"
FREEZE_REF=0
for a in "$@"; do
  case "$a" in
    --n=*)     N="${a#--n=}" ;;
    --seed=*)  SEED="${a#--seed=}" ;;
    --ops=*)   OPS="${a#--ops=}" ;;
    --freeze-batch-ref) FREEZE_REF=1 ;;
    *) echo "primsdiff: unknown argument '$a'" >&2; exit 2 ;;
  esac
done

command -v node >/dev/null 2>&1 || { echo "primsdiff: node not found" >&2; exit 2; }
command -v zig  >/dev/null 2>&1 || { echo "primsdiff: zig not found" >&2; exit 2; }
command -v cc   >/dev/null 2>&1 || { echo "primsdiff: cc not found" >&2; exit 2; }
[ -x "$ROOT/vendor/qbe/qbe" ] || { echo "primsdiff: vendored qbe missing" >&2; exit 2; }
[ -f "$ROOT/elm-compiler/compiler.js" ] || { echo "primsdiff: compiler.js missing (run build.sh)" >&2; exit 2; }

# ---- THE REFERENCE, POST-FLIP ----------------------------------------------
# The flip DELETED the Zig handlers, so the reference is the FROZEN bytes the
# Zig arm printed BEFORE the deletion (golden/batches/, captured at git
# 8f581b8 with the handlers present; same generator, same n/seed).  The
# default mode runs ONLY the Mid arm and compares against those files.  What
# this still falsifies: any future change to the Mid implementations (they
# must keep printing the pre-flip reference bytes), the exercise contracts,
# and the Mid arm's churn behaviour.  What it can NO LONGER falsify: a LIVE
# Zig-vs-Mid divergence — there is no live Zig arm, and the reference side of
# the churn assertion is frozen evidence (printed, not measured).
# --freeze-batch-ref is the PRE-FLIP capture mode: it builds the live Zig
# arm, runs BOTH, compares live, and copies the reference out.  Post-flip its
# reference runs die loudly ("unknown primitive") — it self-retires.
REFDIR="$ROOT/tools/qbe/primsdiff/golden/batches"
if [ "$FREEZE_REF" = 1 ]; then
  echo "primsdiff: building the Zig reference arm (pre-flip freeze mode)"
  zig build-obj -O ReleaseFast -lc -femit-bin="$WORK/primref.o" \
    --dep gc --dep rt -Mroot="$ROOT/tools/qbe/primsdiff/primsdiff-zig.zig" \
    -Mgc="$ROOT/vendor/osier-rt/src/gc.zig" \
    --dep gc -Mrt="$ROOT/vendor/osier-rt/src/rt.zig" || {
    echo "primsdiff: zig build-obj FAILED" >&2; exit 2; }
  cc "$WORK/primref.o" -lc -o "$WORK/primref" || { echo "primsdiff: cc link FAILED" >&2; exit 2; }
  mkdir -p "$REFDIR"
  {
    echo "frozen $(date -u +%Y-%m-%dT%H:%M:%SZ) from git $(git -C "$ROOT" rev-parse HEAD)"
    echo "n=$N seed=$SEED"
    echo "ops=$OPS"
  } > "$REFDIR/MANIFEST.txt"
else
  [ -s "$REFDIR/MANIFEST.txt" ] || {
    echo "primsdiff: no frozen reference at $REFDIR (the flip deleted the Zig arm; re-capturing needs the pre-flip tree + --freeze-batch-ref)" >&2; exit 2; }
  echo "primsdiff: reference = the FROZEN pre-flip Zig arm ($REFDIR, $(head -1 "$REFDIR/MANIFEST.txt"))"
  nfrozen="$(ls "$REFDIR"/*.out 2>/dev/null | wc -l)"
  echo "primsdiff: $nfrozen frozen reference output(s); no live Zig arm is built (deleted at the flip)"
fi

# Call sites in the Mid arm's .ssa, ATTRIBUTED to the calling function:
# "<callee> <count>" for every callee called from a defun that is NOT q_Rt_*.
# A prim called only from inside the Rt program itself (e.g. assocGo, called
# by Rt.assoc) is NOT evidence that the batch exercises it — those call sites
# are emitted as soon as the defun is seeded.
# [GC STATS] parsing for the churn assertion: scavenges+full_collects, and
# scavenges alone (0 when the line is absent).
gc_field() {
  local line
  line="$(grep -h '\[GC STATS\]' "$1" 2>/dev/null | head -1)"
  [ -n "$line" ] || { echo 0; return; }
  printf '%s\n' "$line" | tr ' ' '\n' | awk -F= -v want="$2" \
    '$1=="scavenges"{s=$2} $1=="full_collects"{f=$2} END{ if (want=="scav") print s+0; else print s+f+0 }'
}
gc_total() { gc_field "$1" tot; }
gc_scav() { gc_field "$1" scav; }

cat > "$WORK/callsites.awk" <<'AWK'
/function/ { c=$0; sub(/.*\$/, "", c); sub(/\(.*/, "", c); cur=c; next }
/call \$/  { k=$0; sub(/.*call \$/, "", k); sub(/\(.*/, "", k); if (cur !~ /^q_Rt_/) n[k]++ }
END { for (k in n) print k, n[k] }
AWK

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
  SSA="$B/midarm/Fixture.ssa"

  # ---- INSTRUMENTATION CONTRACT: the Mid arm CALLS the prims it claims ----
  awk -f "$WORK/callsites.awk" "$SSA" > "$B/callsites.txt"
  REQUIRED="$(tr -d ' ' < "$B/require.txt")"
  if [ -n "$REQUIRED" ]; then
    for sym in $REQUIRED; do
      cnt="$(awk -v s="$sym" '$1 == s { print $2 }' "$B/callsites.txt")"
      if [ -z "$cnt" ]; then
        echo "FAIL op=$op: the Mid arm never CALLS $sym from its own defuns — this batch does not exercise the prim it names (the spelling is folded or inlined away); see the header."
        FAIL=1
      else
        echo "  exercised $sym: $cnt Mid call site(s)"
      fi
    done
  fi

  # ---- churn batches declare that the collector MUST have run ----
  CHURN_MARK="$(tr -d ' \n' < "$B/churn.txt" 2>/dev/null)"
  case "$CHURN_MARK" in 1|2) ;; *) CHURN_MARK="";; esac

  for mode in default heap16-rerun; do
    TOTAL=$((TOTAL + 1))
    if [ "$mode" = heap16-rerun ]; then
      ENVV=(LC_ALL=C QBE_HEAP_MB=16 QBE_GC_STATS=1)
    else
      ENVV=(LC_ALL=C)
    fi
    # BYTE-EXACT: outputs go straight to files (command substitution would
    # silently drop NUL bytes — the byte-list batches print raw bytes, and a
    # divergence IN the nulls must not be invisible).  stderr is kept out of
    # the compared stream but its presence fails the exit-code check — EXCEPT
    # for the churn batches, whose GC STATS line is REQUIRED on stderr.
    if [ "$FREEZE_REF" = 1 ]; then
      env "${ENVV[@]}" timeout 120 "$WORK/primref" "$B/vectors.spec" > "$B/zig.$mode.out" 2> "$B/zig.$mode.err"
      zrc=$?
      REF="$B/zig.$mode.out"
      REFNAME="live zig arm"
    else
      # POST-FLIP: the reference is the FROZEN pre-flip bytes.
      REF="$REFDIR/$op.$mode.out"
      REFNAME="frozen pre-flip reference"
      if [ ! -s "$REF" ]; then
        echo "FAIL $mode op=$op: no frozen reference at $REF"
        FAIL=1
        continue
      fi
      zrc=0
    fi
    env "${ENVV[@]}" timeout 120 "$BIN" PrimDiff.all > "$B/mid.$mode.out" 2> "$B/mid.$mode.err"
    mrc=$?
    if [ "$FREEZE_REF" = 1 ] && [ "$zrc" -eq 0 ]; then
      cp "$B/zig.$mode.out" "$REFDIR/$op.$mode.out"
      grep -h '\[GC STATS\]' "$B/zig.$mode.err" > "$REFDIR/$op.$mode.gcstats" 2>/dev/null || true
    fi
    if [ "$zrc" -ne 0 ] || [ "$mrc" -ne 0 ]; then
      echo "FAIL $mode op=$op: exit codes ref=$zrc mid=$mrc"
      echo "  ref: $(head -c 200 "$REF" 2>/dev/null)"
      echo "  mid: $(head -c 200 "$B/mid.$mode.out" 2>/dev/null)"
      FAIL=1
      continue
    fi
    if ! cmp -s "$REF" "$B/mid.$mode.out"; then
      echo "FAIL $mode op=$op: the Mid arm DIVERGES from the $REFNAME — first difference:"
      cmp "$REF" "$B/mid.$mode.out" | head -c 200
      echo
      echo "  (reference: $REF; mid output kept: $B/mid.$mode.out)"
      FAIL=1
      continue
    fi
    if [ -n "$CHURN_MARK" ] && [ "$mode" = heap16-rerun ]; then
      # POST-FLIP the churn claim is CHECKED ON THE MID ARM ONLY: the
      # reference arm's counters are FROZEN EVIDENCE (printed below as
      # frozen-zig=...), not a live measurement — the flip deleted the Zig
      # handlers.  Level 2 (churn-cons) requires NURSERY SCAVENGES; level 1
      # (churn-str / churn-vec) requires the collector to have run at all (a
      # >504-byte allocation is OLD-GEN by construction, so a batch of large
      # buffers can fill the old generation without ever scavenging).
      mtot=$(gc_total "$B/mid.$mode.err"); msc=$(gc_scav "$B/mid.$mode.err")
      if [ "$CHURN_MARK" = 2 ]; then
        okc=1
        [ "$msc" -gt 0 ] || okc=0
        what="SCAVENGES on the Mid arm (mid=$msc)"
      else
        okc=1
        [ "$mtot" -gt 0 ] || okc=0
        what="a real collection on the Mid arm (mid total=$mtot)"
      fi
      if [ "$okc" -ne 1 ]; then
        echo "FAIL $mode op=$op: CHURN batch shows NO $what — the churn claim is false"
        echo "  mid: $(grep -h '\[GC STATS\]' "$B/mid.$mode.err" 2>/dev/null)"
        FAIL=1
        continue
      fi
      echo "PASS $mode op=$op: identical with the $REFNAME ($(wc -c < "$B/mid.$mode.out") bytes), CHURNED ($what): mid=$(grep -h '\[GC STATS\]' "$B/mid.$mode.err") | frozen-zig=$(cat "$REFDIR/$op.heap16-rerun.gcstats" 2>/dev/null | head -c 120)"
    else
      echo "PASS $mode op=$op: identical with the $REFNAME ($(wc -c < "$B/mid.$mode.out") bytes)"
    fi
  done
done

if [ "$FAIL" -eq 0 ]; then
  echo "primsdiff: VERDICT — the Mid implementations still print what the FROZEN pre-flip Zig reference printed, on $TOTAL comparisons ($OPS batches x plain + QBE_HEAP_MB=16; reference golden/batches/, captured at git 8f581b8 before the flip deleted the Zig handlers), n=$N vectors per batch, seed $SEED; every batch CALLS the prims it names (checked in the Mid arm's .ssa) and the churn batches are proven to have collected on the Mid arm.  NO LIVE ZIG ARM EXISTS: a live Zig-vs-Mid divergence is no longer falsifiable here"
  exit 0
fi
echo "primsdiff: VERDICT — DIVERGENCE or an unexercised batch (see FAIL lines above)"
exit 1
