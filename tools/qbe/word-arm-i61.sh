# word-arm-i61.sh — THE WORD ARM'S FIXNUM BOUNDARY, EXECUTED ON BOTH ARMS
# (perf word-arm-arith; REWRITTEN by perf word-arm-area4).
#
# WHAT CHANGED, AND WHY THE REWRITE IS THE UNIT'S PROOF RATHER THAN ITS CHORE.
# This script used to assert that the two arms DIVERGE at the i61 boundary: the
# val arm printed the exact i64 product and the word arm exited 1 with the named
# `mknum overflow` refusal, because the i61 OVERFLOW/BOXING path did not exist.
# It exists now, so the word arm BOXES the value and prints the same bytes — and
# the divergence this file was built to state is gone.  THE FAIL-BEFORE IS THE
# OLD FILE: same program, same invocation, exit 1 + a message, and now exit 0 +
# the exact value.  A row written at the same time as the fix could not
# distinguish "the box works" from "the row was written to match it".
#
# THE ROWS, and every one of them compares the TWO ARMS on the SAME program:
#   1. 2^61 (the OUTSIDE edge)  — both arms exit 0 printing 2305843009213693952.
#      The word arm reaches it through a code-13 boxed cell; the val arm carries
#      it in a 40-byte Value.  Same number, two representations.
#   2. 2^59 (the INSIDE edge)   — both arms exit 0 printing 576460752303423488,
#      with NO box.  This is what stops row 1 passing by boxing everything.
#   3. A NEGATIVE outside value  — `0 - (2^61)` on both arms.  A box is signed
#      like any i64, so a boxing path that only handled magnitudes would fail
#      here and pass row 1.
#   4. A ROUND TRIP              — `(2^61) // (2^61)` is 1.  The boxed operand
#      has to be READ BACK out of the cell by `Rt./`, so this is the row that
#      proves the cell's payload is the i64 and not something box-shaped.
#   5. WRAP THROUGH THE BOX      — `(2^60) * 16` wraps to 0 on both arms, i.e.
#      boxing does not widen the value space (L3's i64 wrap is unchanged).
#
# BOTH VALUES ARE COMPUTED, never spelled: 2^61 is `536870912 * 4294967296`
# (2^29 * 2^32) and 2^59 is `536870912 * 1073741824`.  A big literal DOES work
# on both arms now (that is AREA 4's literal half, pinned by the `intbig` gate
# rows), but a computed value is what proves the ARITHMETIC path.
#
# Usage (from the repo root):  tools/qbe/word-arm-i61.sh
# Exit: 0 = every row passed; 1 = a row failed; 2 = tooling missing.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CDIR="$ROOT/osier-compiler"
HERE="$ROOT/tools/qbe/word-arm-i61"
QBE="$ROOT/vendor/qbe/qbe"

[ -f "$CDIR/compiler.js" ] || { echo "word-arm-i61: $CDIR/compiler.js missing (run: osier-compiler/build.sh)" >&2; exit 2; }
[ -x "$QBE" ] || { echo "word-arm-i61: $QBE missing (run: tools/qbe-build.sh)" >&2; exit 2; }
command -v cc >/dev/null 2>&1 || { echo "word-arm-i61: cc missing" >&2; exit 2; }

BUILD="$(mktemp -d "${TMPDIR:-/tmp}/word-arm-i61.XXXXXX")" || exit 2
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

OVER="$HERE/over.elm"
[ -f "$OVER" ] || { echo "FAIL word-arm-i61: $OVER missing — the fixture that EXECUTES the i61 boundary was deleted" >&2; exit 1; }

# ---- the two-arm comparison, in ONE place ----------------------------------
# run <fixture> <arm> <tag> -> sets RC / OUT (and fails the row on a build error)
RC=0
OUT=""
run() {
  local src="$1" arm="$2" tag="$3"
  build "$src" "$arm" "$tag" || return 1
  timeout 20 "$BUILD/$tag" M.main > "$BUILD/$tag.out" 2> "$BUILD/$tag.err"
  RC=$?
  OUT="$(cat "$BUILD/$tag.out")"
  return 0
}

# agree <tag> <src> <expected> <what>
# Runs BOTH arms on the same program and requires exit 0 and the SAME bytes from
# each.  An arm-by-arm message, so a one-sided failure names the arm.
agree() {
  local tag="$1" src="$2" want="$3" what="$4"
  local ok=1
  run "$src" word "$tag-w" || return
  local wrc=$RC wout=$OUT werr
  werr="$(head -1 "$BUILD/$tag-w.err")"
  run "$src" val "$tag-v" || return
  local vrc=$RC vout=$OUT verr
  verr="$(head -1 "$BUILD/$tag-v.err")"
  if [ "$wrc" != 0 ]; then
    fail "$tag: the WORD arm must exit 0 — got $wrc, stderr [$werr].  A SIGSEGV (139)/SIGFPE (136) is a crash and 1 is the pre-AREA-4 refusal; neither is the boxed answer."
    ok=0
  elif [ "$vrc" != 0 ]; then
    fail "$tag: the VAL arm must exit 0 — got $vrc, stderr [$verr]"
    ok=0
  elif [ "$wout" != "$want" ]; then
    fail "$tag: the WORD arm must print [$want] and printed [$wout] — $what"
    ok=0
  elif [ "$vout" != "$want" ]; then
    fail "$tag: the VAL arm must print [$want] and printed [$vout] — the val arm is the oracle here and it MOVED, which is a different defect"
    ok=0
  elif [ "$wout" != "$vout" ]; then
    fail "$tag: the arms disagree — word [$wout] val [$vout]"
    ok=0
  fi
  if [ "$ok" = 1 ]; then
    pass "$tag: BOTH arms exit 0 printing [$want] — $what"
  fi
}

# ---- row 1: the OUTSIDE edge, boxed on the word arm, exact on both ---------
agree over "$OVER" "2305843009213693952" "2^61 does not fit the i61 fixnum, so the word arm BOXES it (a code-13 cell holding the raw i64) and answers the val arm's number exactly.  PRE-AREA-4 this row was exit 1 + the named 'mknum overflow' refusal; that asymmetry is the proof."

# ---- row 2: the INSIDE edge is NOT boxed (row 1's control) ----------------
cat > "$BUILD/in.elm" <<'ELM'
module M exposing (main)

main =
    536870912 * 1073741824
ELM
agree inside "$BUILD/in.elm" "576460752303423488" "2^59 FITS the fixnum and stays inline on the word arm.  Without this row row 1 could pass by boxing everything."

# ---- row 3: a NEGATIVE outside value --------------------------------------
cat > "$BUILD/neg.elm" <<'ELM'
module M exposing (main)

main =
    0 - (536870912 * 4294967296)
ELM
agree negative "$BUILD/neg.elm" "-2305843009213693952" "a boxed cell is SIGNED like any i64, so a boxing path that only handled magnitudes would pass row 1 and fail here."

# ---- row 4: the boxed operand is READ BACK out of the cell ----------------
# `Rt./` reads its operands with `payload`, and on the word arm that reader
# dispatches on the SHAPE — a code-13 cell answers body unit 0.  If the cell's
# payload were anything but the i64, this is where it shows.
cat > "$BUILD/rt.elm" <<'ELM'
module M exposing (main)

main =
    (536870912 * 4294967296) // (536870912 * 4294967296)
ELM
agree roundtrip "$BUILD/rt.elm" "1" "the BOXED operand is read back out of its cell by Rt./ and divided by itself, so this proves the cell's body word IS the i64."

# ---- row 5: WRAP still wraps, THROUGH the box ----------------------------
# 2^60 is boxed (it does not fit), then `* 16` takes the wrapped product 2^64 to
# 0, which fits and is a fixnum again.  Boxing does NOT widen the value space.
cat > "$BUILD/wrap.elm" <<'ELM'
module M exposing (main)

main =
    (536870912 * 2147483648) * 16
ELM
agree wrap "$BUILD/wrap.elm" "0" "2^60 is boxed, then * 16 WRAPS the i64 product to 0 (L3's wrap is unchanged by the representation) and 0 fits a fixnum again — so the box does not widen the value space."

if [ "$fails" != 0 ]; then
  echo "word-arm-i61: $fails failure(s)"
  exit 1
fi
exit 0
