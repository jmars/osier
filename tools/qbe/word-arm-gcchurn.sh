#!/usr/bin/env bash
# word-arm-gcchurn.sh — CLOSURES UNDER COLLECTION, ON BOTH ARMS (perf
# word-arm-closures FIX, review BLOCKER).
#
# WHY THIS ROW EXISTS AT ALL, and why word-arm-diff could not be it.  Every
# word-arm fixture in the tree allocates far below one GC trigger, so NONE of
# them ever collects — and a ROOTING defect is invisible without a collection.
# That is not a gap in coverage, it is a gap in the INSTRUMENT: the closure
# class shipped with a fixture that runs, a source pin, a probe row and 368
# green qbe-check rows, and the word arm still answered 19709031 where the val
# arm answers 18003000 — silently, rc=0, EMPTY STDERR, at DEFAULT settings.
#
# THE DEFECT THIS ROW PINS (both sites, both word-arm twins):
#   * `Rt.closure`      — the capture block (`allocKind(10, cnt)`) is a RAW WORD
#     live across the closure BODY's `allocKind(6, 4)`;
#   * `Rt.applyPartGo`  — `envv` (`allocvec(total)`) is the same shape, and its
#     `rootPop` came BEFORE the body's allocation.
# A scavenge landing on that second allocation frees the first block (nothing
# referenced it), resets `youngCursor`, and hands the memory to the body — so
# the closure's body word 2 names the body itself.  Nothing crashes; the
# capture read answers whatever reused the block.
#
# SO THE ROW HAS TWO AXES, and a row is only here if it fails on the OTHER side
# of one of them:
#   HEAP     — QBE_HEAP_MB=1 forces many collections; the DEFAULT rows exist
#              because the defect is not a small-heap artefact (the 16 MiB
#              default trigger is crossed at 250,000 closures).
#   SURVIVAL — `hold`/`holdbig` keep the closures REACHABLE across later
#              collections (a defect on the way out), `churn` interleaves two
#              creations in ONE expression (a defect between siblings), and
#              `over` runs the OVER-applied arm (rem < nargs), which no
#              committed word-arm fixture exercised before this unit.
#
# WHAT IT ASSERTS, per (fixture, heap) row: both arms BUILD (a qbe or cc failure
# is a FAIL, not a skip), neither arm TIMES OUT (a wrong count/stride can loop
# instead of crashing), the EXIT CODES match, STDOUT is BYTE-IDENTICAL, and — for
# a row declared a COLLECTING rung — that BOTH arms actually collected at least
# once (the scavenge count is read off the arm's `QBE_MIDGC_STATS=1` transcript,
# not asserted in a comment: a rung that collects zero times cannot fail on a
# rooting defect and must not be credited as coverage).  The
# expected value is deliberately NOT spelled here: the val arm IS the oracle —
# it is the representation the program was written against — so a hard-coded
# number would be a second thing to keep in step, and a wrong one would bless a
# wrong answer on both arms at once.
#
# WHICH ROW FAILS ON WHAT, measured rather than asserted, because "every row
# proves the fix" is exactly the overclaim this repo keeps paying for:
#   * `hold`, `partial`, `holdbig`, `partbig` — THE ROOTING PROOF.  With the two
#     fixes reverted (a scratch runtime.mid, compiler.js rebuilt) these four go
#     RED with the numbers the review measured (19709031, 20363304, 31252390090,
#     31278680545); with them in place all four are green.
#   * `churn` — a COVERAGE row, and it PASSES on both sides of the fix
#     (MEASURED): it runs the two-creations-in-one-expression shape, which is a
#     different interleave from hold/partial's one-at-a-time build, and it
#     discriminates a different mutation (untagging body word 2 turns it red).
#     It is here to keep the shape RUNNING, not to prove the rooting.
#   * `over` — the OVER-applied arm (rem < nargs), which no committed word-arm
#     fixture exercised before this unit.  PROVEN FAIL-ABLE against the stride
#     it pins: `sp->args = args + rem * 8` mutated to `rem * 40` in
#     Rt.applyTailGo turns it RED (MEASURED, `[cons 10 . 400040000]` against
#     `[cons 15 . 400140000]`).
#   * `str` — A DIFFERENT CLASS, added by perf word-arm-rawroot item 1: not a
#     raw word held across an allocation but a heap object whose BODY WAS NOT
#     WALKED AT ALL.  A word-arm string's BYTES lived in a second young block
#     reachable only through a body unit the collector never scans, so the bytes
#     were reclaimed while the cell (and its length) survived.  MEASURED before
#     the fix, silently, rc=0: `154/5846` at QBE_HEAP_MB=1 and `5699/301` at
#     DEFAULT knobs — the second number is why the row runs at both, and the
#     CONTENT comparison (`s == build i`, which walks the bytes) is why it can
#     see the defect at all: the length lives in the cell and reads correctly.
# A row that cannot fail is not a row; a row that claims the wrong failure is
# worse.
#
# Usage (from the repo root):  tools/qbe/word-arm-gcchurn.sh
# Exit: 0 = every row passed; 1 = a row failed or a fixture is missing;
#       2 = tooling missing.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CDIR="$ROOT/osier-compiler"
HERE="$ROOT/tools/qbe/word-arm-gcchurn"
QBE="$ROOT/vendor/qbe/qbe"

[ -f "$CDIR/compiler.js" ] || { echo "word-arm-gcchurn: $CDIR/compiler.js missing (run: osier-compiler/build.sh)" >&2; exit 2; }
[ -x "$QBE" ] || { echo "word-arm-gcchurn: $QBE missing (run: tools/qbe-build.sh)" >&2; exit 2; }
command -v cc >/dev/null 2>&1 || { echo "word-arm-gcchurn: cc missing" >&2; exit 2; }

BUILD="$(mktemp -d "${TMPDIR:-/tmp}/word-arm-gcchurn.XXXXXX")" || exit 2
trap 'rm -rf "$BUILD"' EXIT

fails=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

# build <src> <arm> <tag> -> $BUILD/<tag> (or a FAIL and a non-zero return)
build() {
  local src="$1" arm="$2" tag="$3" ssa="$BUILD/$3.ssa"
  local -a arms
  # BOTH ARMS EXPLICIT (flip-prep): the val arm used to be "QBE_VALREP unset",
  # i.e. the DEFAULT arm — the flip makes that the WORD arm, and every row
  # below would then compare word against word while still printing its
  # counter assertions green.
  case "$arm" in
    val)  arms=(QBE_VALREP=val) ;;
    word) arms=(QBE_VALREP=word) ;;
    *) fail "$tag: unknown arm '$arm'"; return 1 ;;
  esac
  (cd "$CDIR" && env "${arms[@]}" QBE_ENTRY=M.main node run.js "$src" "$ssa") >/dev/null 2>&1
  if [ ! -s "$ssa" ]; then fail "$tag: no .ssa emitted"; return 1; fi
  case "$(head -c 4 "$ssa")" in
    "err "*) fail "$tag: the compile REFUSED — $(head -c 200 "$ssa")"; return 1 ;;
  esac
  if ! "$QBE" "$ssa" > "$BUILD/$tag.s" 2> "$BUILD/$tag.qerr"; then
    fail "$tag: qbe rejected the .ssa — $(head -1 "$BUILD/$tag.qerr")"; return 1
  fi
  if ! cc "$BUILD/$tag.s" -o "$BUILD/$tag" -lc 2> "$BUILD/$tag.cerr"; then
    fail "$tag: cc failed — $(grep -m1 'undefined reference\|error' "$BUILD/$tag.cerr")"; return 1
  fi
  return 0
}

# row <fixture> <heap> <timeout-s> <min-scavenges> — one (fixture, heap) pair,
# both arms.  `min-scavenges` is 1 for a COLLECTING rung and 0 for a REGRESSION
# row, and it is ASSERTED on both arms: the counts used to be comments, so a rung
# that stopped collecting stayed green while proving nothing (the same failure
# the record ladder's `default` row was relabelled for).
row() {
  local fx="$1" heap="$2" secs="$3" min="${4:-0}"
  local src="$HERE/$fx.elm"
  local label="$fx/$heap"
  if [ ! -f "$src" ]; then
    fail "$label: $src is MISSING — the closure class's only collecting oracle lost a fixture"
    return
  fi
  build "$src" val "$fx.$heap.val" || return
  build "$src" word "$fx.$heap.word" || return
  local envs=()
  case "$heap" in
    h1) envs=(QBE_HEAP_MB=1) ;;
    h2) envs=(QBE_HEAP_MB=2) ;;
    h4) envs=(QBE_HEAP_MB=4) ;;
    h8) envs=(QBE_HEAP_MB=8) ;;
    # THE MARK-WALK RUNG (closchurn): with the young generation off there is no
    # scavenge, so the defect's SECOND fingerprint is what fires — the full
    # collector's mark walk reading the same raw count.  A row that only ever
    # ran the scavenger would have missed half the class.
    h2-young0) envs=(QBE_HEAP_MB=2 QBE_MIDGC_YOUNG=0) ;;
  esac
  # QBE_MIDGC_STATS=1 is how a rung proves it COLLECTED: the runtime prints one
  # `midgc: scavenge s=N ...` line per scavenge to stderr (fd 2), so the count is
  # read off the arm's own transcript and not off a comment.  The knob only
  # writes that transcript — stdout, exit code and the values are untouched, so
  # the parity comparison below is still between the two representations.
  env "${envs[@]}" QBE_MIDGC_STATS=1 timeout "$secs" "$BUILD/$fx.$heap.val" M.main > "$BUILD/$fx.$heap.val.out" 2> "$BUILD/$fx.$heap.val.err"
  local vrc=$?
  env "${envs[@]}" QBE_MIDGC_STATS=1 timeout "$secs" "$BUILD/$fx.$heap.word" M.main > "$BUILD/$fx.$heap.word.out" 2> "$BUILD/$fx.$heap.word.err"
  local wrc=$?
  local vsc wsc
  # A COLLECTION IS EITHER KIND: a young-only scavenge (`midgc: scavenge s=`) or a
  # full mark-sweep (`midgc: c=`).  Counting scavenges alone was MEASURED wrong on
  # the first run of this assertion — `str/default` reports zero scavenges on both
  # arms and is nevertheless a row the pre-fix defect showed up in, because what
  # it crossed at the default knob was the FULL-collect trigger.  The metric has
  # to be "did this rung collect at all", not "did it scavenge".
  vsc="$(grep -cE '^midgc: (scavenge|c=)' "$BUILD/$fx.$heap.val.err" 2>/dev/null)"
  wsc="$(grep -cE '^midgc: (scavenge|c=)' "$BUILD/$fx.$heap.word.err" 2>/dev/null)"
  vsc="${vsc:-0}"; wsc="${wsc:-0}"
  if [ "$vrc" = 124 ] || [ "$wrc" = 124 ]; then
    fail "$label: TIMED OUT (val $vrc, word $wrc) — a wrong stride can loop instead of crashing; word stderr: $(head -1 "$BUILD/$fx.$heap.word.err")"
  elif [ "$vrc" != "$wrc" ]; then
    fail "$label: exit codes differ (val $vrc, word $wrc) — word stderr: $(head -1 "$BUILD/$fx.$heap.word.err")"
  elif ! cmp -s "$BUILD/$fx.$heap.val.out" "$BUILD/$fx.$heap.word.out"; then
    fail "$label: stdout differs — val [$(cat "$BUILD/$fx.$heap.val.out")] word [$(cat "$BUILD/$fx.$heap.word.out")].  THE VAL ARM IS THE ORACLE: this is a wrong number, not a missing feature."
  elif [ "$min" != 0 ] && { [ "$vsc" -lt "$min" ] || [ "$wsc" -lt "$min" ]; }; then
    fail "$label: collected only $vsc (val) / $wsc (word) times, and this rung is declared a COLLECTING rung (min $min) — a rung that collects nothing cannot fail on a rooting defect, so it must not be counted as coverage"
  else
    pass "$label: both arms exit $vrc and print the same STDOUT bytes ($(wc -c < "$BUILD/$fx.$heap.val.out") B: $(cat "$BUILD/$fx.$heap.val.out" | cut -c1-24)); collections val $vsc / word $wsc"
  fi
}

# ---- the two ROOTING sites, at a heap small enough to collect constantly ----
row hold     h1      120  1
row partial  h1      120  1
# ---- the interleaved-siblings shape (two creations, one expression) ----
row churn    h1      120  1
# ---- the OVER-applied arm (rem < nargs), which no fixture exercised ----
row over     h1      120  1
# ---- and the same two sites at DEFAULT KNOBS: the defect is not a small-heap
#      artefact, and these are the rows that reproduce the review's headline
#      numbers (250,000 closures cross the default 16 MiB trigger) ----
row holdbig  default 300  1
row partbig  default 300  1
# ---- RUNTIME-BUILT STRING BYTES (perf word-arm-rawroot item 1): a separate
#      defect class in the same file.  THE DEFAULT ROW IS A REGRESSION ROW NOW,
#      AND THAT IS MEASURED, NOT ASSUMED: the pre-fix defect printed
#      `5699/301` at the default knob, but on THIS tree the fixture crosses
#      NEITHER trigger at that knob: `QBE_MIDGC_STATS=1` reports 0 scavenges AND
#      0 full collects on both arms.  WHY the pre-fix run collected there and
#      this one does not is NOT established here (it is not needed for the row);
#      what IS established is that the default rung proves nothing about rooting,
#      so it is a REGRESSION row and h1 is this class's collecting rung.
row str      h1      180  1
row str      default 180  0   # regression row: MEASURED 0 collections on BOTH arms
# ---- RUNTIME-BUILT RECORD NAMES ARRAYS (perf word-arm-records R4): the update
#      family's ONE new allocation window, and the row that FOUND TWO DEFECTS in
#      the twins that wrote it (the R3/R4 review's blockers 1 and 2).  Both heaps,
#      because the tagged names word is only re-derived on a promotion.
#      MEASURED BEFORE the fixes: val 6000/6000/0 at both heaps; word h1
#      SEGFAULT (rc 139), word default `mknum overflow`.  AFTER: 6000/6000/0 on
#      both arms at both heaps - and this row is why the family could not be
#      called complete before it was here.
#      THE RUNGS ARE NOT EQUAL, AND THE COLLECTION COUNTS SAY SO (perf
#      word-arm-records H1 review FINDING 4, measured with QBE_MIDGC_STATS=1 and
#      re-measured under `row()`'s metric — SCAVENGES **OR** FULL COLLECTS, which
#      is what the assertion counts; the original scavenge-only figures 15/9/4/0
#      and 22/16/10/1 are the same rows, lower because a young-only count misses
#      the full sweeps): rec 30/18/8/**0** word (36/28/18/0 val) and recupd
#      44/32/20/1 word (46/36/26/3 val) at h1/h2/h4/default.
#      h1/h2/h4 are REAL COLLECTING RUNGS at three distinct heap sizes and they
#      are what covers the defect.  `default` collects ZERO times for `rec`
#      (recupd's single one fires at the END, on the whole live set), so it
#      cannot fail on a rooting defect — it was green BEFORE the fix.  It is kept
#      as a REGRESSION row (the default knob must keep producing the right
#      answer) and MUST NOT be counted as collection coverage.
row rec      h1      240  1
row rec      h2      240  1
row rec      h4      240  1
row rec      default 240  0   # regression row: 0 scavenges, see above
# ---- THE HIT PATH (perf word-arm-records H1 FIX): `{ r | y <- i }` on an
#      EXISTING field never reaches recAppend, so it is the UPDATE family's own
#      window — `Rt.recUpd` allocates through `Rt.allocRecord` and holds `rec`
#      across it.  The diagnosis measured this path SEGFAULTING at 60000
#      iterations while green at 6000 (it allocates less per iteration, so the
#      young trigger is crossed later), which is why the rung set is the full
#      ladder and the iteration count is higher than the insertion fixture's.
row recupd   h1      300  1
row recupd   h2      300  1
row recupd   h4      300  1
row recupd   default 300  0   # regression row: 1 scavenge, at the END (see above)
# ---- USER ADTs (perf word-arm-frontier): the `Con`/`MTagEq` pair's collecting
#      row.  A word-arm constructor value is ONE code-10 block whose body word 0
#      is a REAL symbol cell and whose arguments are inline body words, so this
#      row holds three allocation windows across a collection that no other row
#      in the tree reaches: the tag symbol's own cell, the vector block itself
#      between `Rt.con`'s `allocKind` and its `Rt.conFill`, and the argument
#      strings staged in the caller's frame and passed to `Rt.con` as
#      `mknum(cbase)`.  The check is a PATTERN MATCH (the tag test plus the
#      element binds) AND a whole-value `==`, so a reclaimed tag cell answers the
#      wrong alternative instead of crashing, and a wrong element stride prints a
#      wrong number.
#      THE RUNGS ARE MEASURED, NOT ASSUMED (QBE_MIDGC_STATS=1, counting SCAVENGES
#      AND FULL COLLECTS — `row()`'s metric): 36/26/12 collections at h1/h2/h4 on
#      the word arm (32/22/14 on the val arm), and ZERO at `default` on BOTH arms
#      — so `default` is a REGRESSION row and must not be counted as collection
#      coverage (the same labelling `rec` needed).  The scavenge-only figures this
#      comment used to quote (18/13/6, 16 at h1 on the val arm) were the same
#      rows under the narrower metric.
row con      h1      240  1
row con      h2      240  1
row con      h4      240  1
row con      default 240  0   # regression row: 0 scavenges, see above
# ---- `let` DESTRUCTURING (perf word-arm-letdestr): the class allocates nothing
#      itself, but `lowerBind` puts every pattern variable in a ROOTED slot and
#      the pattern's tag test is a CALL on this arm (`Rt.=`), so the binds are
#      live across the body's allocations.  MEASURED (QBE_MIDGC_STATS=1, counting
#      scavenges AND full collects) on both arms: 82/174 at h1, 74/164 at h2,
#      64/82 at h4 and 6/7 at DEFAULT — so here even the default rung COLLECTS,
#      and all four are collecting rungs (min 1) rather than the regression rows
#      `rec`/`con` needed at the default knob.
row letd     h1      240  1
row letd     h2      240  1
row letd     h4      240  1
row letd     default 240  1
# ---- FLOAT CELLS (perf word-arm-floats): the class's allocation window is NEW
#      — on the val arm a float literal allocates NOTHING (`storew tagFloat` +
#      `stored slot+8`), while on the word arm it is a code-12 block the EMITTER
#      allocates (`storeWordFloatCell` -> `q_Rt_x2eallocFloat`).  So every defun
#      that mentions a float gained a safepoint, and the runtime's own frame
#      decision had to learn it (`Mid.Rt.unsafeSafepoint`'s `RawMkValue` arm).
#      The fixture holds a RUNTIME-BUILT string and a RUNTIME-BUILT float cell
#      across an allocation window and re-reads both, comparing the float
#      against `i / 2.0` — a value computed through `Rt.f/`, i.e. `fload` +
#      `mkflt` on the OTHER side of the window — so a reclaimed or mis-strided
#      cell disagrees instead of matching itself.  THE RUNGS ARE MEASURED, NOT
#      ASSUMED (QBE_MIDGC_STATS=1, `row()`'s scavenge-OR-full-collect metric):
#      see the comment rows below for the counts.
row flt      h1      240  1
row flt      h2      240  1
row flt      h4      240  1
row flt      default 240  1
# ---- THE HOST EVENT LOOP (perf word-arm-hostpath): the blob's ROOTED SLOT ARRAY,
#      scanned at the layout's stride.  The model is a record that grows a string
#      every step, so the model cell itself MOVES at every collection — which is
#      the only thing that exercises the slot array's scan.  A stride that
#      disagrees with the array's element width rewrites a slot the program does
#      not read and leaves the one it does read pointing at the reused block, so
#      the symptom is a wrong model at rc 0, empty stderr — the class's own shape.
#      MEASURED (QBE_MIDGC_STATS=1, `row()`'s scavenge-OR-full-collect metric),
#      val/word collections: h1 180/188, h2 88/94, h4 44/46, default 3/3.
#      EVERY RUNG IS DECLARED COLLECTING, and the default one was checked rather
#      than assumed: the first draft of this comment called it a REGRESSION row
#      on a 512 MiB measurement, and the row then reported 3 collections on BOTH
#      arms at the real default.  A count taken at the wrong knob is not a
#      measurement of this one.
row host     h1      300  1
row host     h2      300  1
row host     h4      300  1
row host     default 300  1
# ---- THE Task.andThen CONTINUATION (perf andthen-clobber): the SAME slot array
#      as `host`, but the Value that matters lives ONLY in it.  `host` passes
#      with the array unrooted because its model is also reachable through the
#      compiled update's frame; a continuation closure staged by
#      `Rt.hostPushFrame` into `slot[base + 2 + n]` is referenced by NOTHING
#      else, so the first scavenge reclaims it and the churn's next string
#      allocation is handed the same memory.
#      MEASURED BEFORE the fix (pre-fix runtime.mid, same fixture): word arm
#      rc=1 "a heap header carries KIND CODE 0" at h1/h2/h4/64 and rc=0 at
#      QBE_HEAP_MB=512 (no collection); val arm rc=0 everywhere — NOT because it
#      roots better, but because `Rt.hostInit` is frame-free there, so the root
#      it pushed was never truncated: the asymmetry was the FRAME CLASS.
#      AFTER (QBE_MIDGC_STATS=1, `row()`'s scavenge-OR-full-collect metric):
#      val/word collections h1 248/220, h2 122/126, h4 60/62 and DEFAULT 4/4 —
#      all green, "16000/ok" on both arms.  EVERY RUNG IS DECLARED COLLECTING,
#      including the default one: the first draft of this comment called
#      `default` a regression row on a QBE_HEAP_MB=512 measurement (0
#      collections there), and the row then reported 4 on BOTH arms at the real
#      default knob — the same "a count taken at the wrong knob is not a
#      measurement of this one" trap the `host` block above records.
row andthen  h1      240  1
row andthen  h2      240  1
row andthen  h4      240  1
row andthen  default 240  1
# ---- THE SCANNED-BODY COUNTS (the poisoned-body fix, 2026-10-29): a word-arm
#      closure cell is ONE code-6 SCANNED block whose body words 1 and 3 are
#      counts, and the drain walks EVERY body word as a Value — so a RAW count
#      ≡ 7 (mod 8) IS the reserved poison tag, and the collect reports a
#      forwarded body for what is the arithmetic `rem - nargs == 7` / `cnt == 7`.
#      A count ≡ 1 (mod 8) was silently read as a pointer to a low address.
#      THIS ROW IS THE CLASS'S ONLY INSTRUMENT, and it is a LADDER because the
#      class is invisible without a collection that has a ≡ 7-count closure
#      LIVE: `main = \x -> x` never counts 7 and never collects, which is why
#      the whole tree was green while the whole-compiler emit died.
#      MEASURED BEFORE the fix (this tree, the diagnosis binaries): word arm
#      rc 1 `scavenge read a POISONED (forwarded young) body` at h1/h2/h4/h8,
#      rc 1 `unknown value tag in mark walk` at h2 with YOUNG=0, val arm
#      `6000/0|6000/0` rc 0 at h1/h2/h4, and the WORD arm at DEFAULT knobs also
#      `6000/0|6000/0` rc 0 — so the default rung is a REGRESSION row here (it
#      collects ZERO times on both arms; MEASURED with QBE_MIDGC_STATS=1) and
#      must not be credited as collection coverage.
#      MEASURED AFTER (same metric, collections val/word): h1 26/22, h2 20/16,
#      h4 12/8, h8 4/4, h2-young0 5/5 (full collects — the mark-walk arm), and
#      0/0 at default.  All four heaps and the young-off rung are COLLECTING.
#      The fixture compares CONTENT after applying each closure, so a cell whose
#      counts read back at the wrong scale answers a wrong number instead of
#      matching itself — which is what makes this a behaviour row and not a
#      "did it crash" row.
row closchurn h1        120  1
row closchurn h2        120  1
row closchurn h4        120  1
row closchurn h8        120  1
row closchurn h2-young0 120  1
row closchurn default   120  0   # regression row: MEASURED 0 collections on BOTH arms

if [ "$fails" != 0 ]; then
  echo "word-arm-gcchurn: $fails failure(s) — a closure is being read after a collection it did not survive"
  exit 1
fi
exit 0
