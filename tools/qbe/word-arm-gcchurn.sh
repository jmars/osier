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
# instead of crashing), the EXIT CODES match, and STDOUT is BYTE-IDENTICAL.  The
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
  if [ "$arm" = word ]; then
    (cd "$CDIR" && QBE_VALREP=word QBE_ENTRY=M.main node run.js "$src" "$ssa") >/dev/null 2>&1
  else
    (cd "$CDIR" && QBE_ENTRY=M.main node run.js "$src" "$ssa") >/dev/null 2>&1
  fi
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

# row <fixture> <heap> <timeout-s> — one (fixture, heap) pair, both arms.
row() {
  local fx="$1" heap="$2" secs="$3"
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
  esac
  env "${envs[@]}" timeout "$secs" "$BUILD/$fx.$heap.val" M.main > "$BUILD/$fx.$heap.val.out" 2> "$BUILD/$fx.$heap.val.err"
  local vrc=$?
  env "${envs[@]}" timeout "$secs" "$BUILD/$fx.$heap.word" M.main > "$BUILD/$fx.$heap.word.out" 2> "$BUILD/$fx.$heap.word.err"
  local wrc=$?
  if [ "$vrc" = 124 ] || [ "$wrc" = 124 ]; then
    fail "$label: TIMED OUT (val $vrc, word $wrc) — a wrong stride can loop instead of crashing; word stderr: $(head -1 "$BUILD/$fx.$heap.word.err")"
  elif [ "$vrc" != "$wrc" ]; then
    fail "$label: exit codes differ (val $vrc, word $wrc) — word stderr: $(head -1 "$BUILD/$fx.$heap.word.err")"
  elif ! cmp -s "$BUILD/$fx.$heap.val.out" "$BUILD/$fx.$heap.word.out"; then
    fail "$label: stdout differs — val [$(cat "$BUILD/$fx.$heap.val.out")] word [$(cat "$BUILD/$fx.$heap.word.out")].  THE VAL ARM IS THE ORACLE: this is a wrong number, not a missing feature."
  else
    pass "$label: both arms exit $vrc and print the same STDOUT bytes ($(wc -c < "$BUILD/$fx.$heap.val.out") B: $(cat "$BUILD/$fx.$heap.val.out" | cut -c1-24))"
  fi
}

# ---- the two ROOTING sites, at a heap small enough to collect constantly ----
row hold     h1      120
row partial  h1      120
# ---- the interleaved-siblings shape (two creations, one expression) ----
row churn    h1      120
# ---- the OVER-applied arm (rem < nargs), which no fixture exercised ----
row over     h1      120
# ---- and the same two sites at DEFAULT KNOBS: the defect is not a small-heap
#      artefact, and these are the rows that reproduce the review's headline
#      numbers (250,000 closures cross the default 16 MiB trigger) ----
row holdbig  default 300
row partbig  default 300
# ---- RUNTIME-BUILT STRING BYTES (perf word-arm-rawroot item 1): a separate
#      defect class in the same file, and it fires at DEFAULT knobs too ----
row str      h1      180
row str      default 180
# ---- RUNTIME-BUILT RECORD NAMES ARRAYS (perf word-arm-records R4): the update
#      family's ONE new allocation window, and the row that FOUND TWO DEFECTS in
#      the twins that wrote it (the R3/R4 review's blockers 1 and 2).  Both heaps,
#      because the tagged names word is only re-derived on a promotion.
#      MEASURED BEFORE the fixes: val 6000/6000/0 at both heaps; word h1
#      SEGFAULT (rc 139), word default `mknum overflow`.  AFTER: 6000/6000/0 on
#      both arms at both heaps - and this row is why the family could not be
#      called complete before it was here.
row rec      h1      240
row rec      h2      240
row rec      h4      240
row rec      default 240
# ---- THE HIT PATH (perf word-arm-records H1 FIX): `{ r | y <- i }` on an
#      EXISTING field never reaches recAppend, so it is the UPDATE family's own
#      window — `Rt.recUpd` allocates through `Rt.allocRecord` and holds `rec`
#      across it.  The diagnosis measured this path SEGFAULTING at 60000
#      iterations while green at 6000 (it allocates less per iteration, so the
#      young trigger is crossed later), which is why the rung set is the full
#      ladder and the iteration count is higher than the insertion fixture's.
row recupd   h1      300
row recupd   h2      300
row recupd   h4      300
row recupd   default 300

if [ "$fails" != 0 ]; then
  echo "word-arm-gcchurn: $fails failure(s) — a closure is being read after a collection it did not survive"
  exit 1
fi
exit 0
