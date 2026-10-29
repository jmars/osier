#!/usr/bin/env bash
# word-arm-i61.sh — THE WORD ARM'S FIXNUM BOUNDARY, EXECUTED (perf
# word-arm-arith, review finding 1).
#
# WHY THIS IS NOT A word-arm-diff ROW.  That row asserts the two arms AGREE, and
# it is the right instrument for everything else in the arithmetic class.  The
# i61 boundary is the ONE place the arms must NOT agree: a word-arm fixnum is an
# i61, so a result at or beyond 2^60 in magnitude has no fixnum encoding, while
# the val arm carries the exact i64 value.  Comparing the arms here would either
# forbid the correct refusal or bless the wrong number — so this script states
# the divergence instead, one arm per line, and gates on BOTH.
#
# WHAT WAS UNTESTED BEFORE THIS SCRIPT, and it is the unit's headline semantics:
# the `mknum` round-trip refusal ("a result outside i61 is a LOUD named
# refusal") existed only at EMISSION level — a TestMain row asserting the `.ssa`
# contains the `Rt.die` call and the message.  THAT IS A STATEMENT ABOUT TEXT.
# A refusal nobody has ever seen fire is not a tested refusal, and the failure
# it guards against (silently dropping a fixnum's top three bits) is exactly the
# silent-wrong class the arm exists to prevent.
#
# THE THREE ROWS:
#   1. word arm, 2^61: exit 1 AND the named message on stderr.  Exit 1 alone is
#      not enough — a SIGSEGV is 139 and a SIGFPE 136, but a wrong `return 0`
#      would exit 0, so the pair (status, message) is the assertion.
#   2. val arm, 2^61: exit 0 and the EXACT i64 product on stdout.  This is what
#      makes row 1 a decision rather than a limitation: the same program HAS a
#      value, and the word arm says so instead of printing a truncated one.
#   3. word arm, 2^59 (the INSIDE edge): exit 0 and the exact value — so row 1
#      cannot pass by refusing everything large.  (The inside edge is also
#      compared on both arms by `word-arm-diff/arith.elm`; it is repeated here
#      so this script is readable on its own.)
#
# BOTH VALUES ARE COMPUTED, never spelled: a literal above 2^53 parses as
# `LNumberBig` and `lowerLitWord` refuses it under the arm, so a near-boundary
# literal cannot exist.  `536870912 * 4294967296` = 2^29 * 2^32 = 2^61 and
# `536870912 * 1073741824` = 2^59 — both operands legal, the product not.
#
# WHAT IS NOT HERE, and why it cannot be: `INT64_MIN // -1` — `Rt./`'s second
# named halt — is UNREACHABLE on this arm, because a word-arm fixnum's magnitude
# is at most 2^60 and so no operand pair can carry INT64_MIN.  The check is the
# val arm's; it is inert here, not dead.
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
[ -f "$OVER" ] || { echo "FAIL word-arm-i61: $OVER missing — the ONLY fixture that executes the i61 refusal was deleted" >&2; exit 1; }

# ---- row 1: the word arm REFUSES 2^61, by name ----
if build "$OVER" word over-word; then
  timeout 20 "$BUILD/over-word" M.main > "$BUILD/over-word.out" 2> "$BUILD/over-word.err"
  rc=$?
  out="$(cat "$BUILD/over-word.out")"
  err="$(head -1 "$BUILD/over-word.err")"
  if [ "$rc" != 1 ]; then
    fail "over-word: expected exit 1 (the named refusal) and got $rc — stdout [$out] stderr [$err].  A SIGSEGV (139) / SIGFPE (136) is a crash, not a refusal, and 0 means the value was silently WRONG."
  elif [ -n "$out" ]; then
    fail "over-word: refused but still printed [$out] — a refusal that also emits a value is the mixed answer this arm exists to prevent"
  elif ! printf '%s' "$err" | grep -q "mknum overflow"; then
    fail "over-word: exit 1 but the message does not NAME the refusal — stderr [$err]"
  elif ! printf '%s' "$err" | grep -q "i61"; then
    fail "over-word: the message does not name the i61 bound — stderr [$err]"
  else
    pass "over-word: 2^61 halts with exit 1 and the NAMED refusal (the mknum round-trip check FIRES; it was never executed before this row) — stderr: $(printf '%s' "$err" | cut -c1-96)..."
  fi
fi

# ---- row 2: the VAL arm carries the same program to its exact i64 value ----
if build "$OVER" val over-val; then
  timeout 20 "$BUILD/over-val" M.main > "$BUILD/over-val.out" 2> "$BUILD/over-val.err"
  rc=$?
  out="$(cat "$BUILD/over-val.out")"
  if [ "$rc" != 0 ]; then
    fail "over-val: expected exit 0 and got $rc — stderr [$(head -1 "$BUILD/over-val.err")]"
  elif [ "$out" != "2305843009213693952" ]; then
    fail "over-val: expected 2305843009213693952 (2^61) and got [$out]"
  else
    pass "over-val: the SAME program exits 0 printing 2305843009213693952 (2^61) — so the word arm's halt is a decision about its fixnum, not a limitation of the program"
  fi
fi

# ---- row 3: the INSIDE edge is not refused (the row-1 control) ----
cat > "$BUILD/in.elm" <<'ELM'
module M exposing (main)

main =
    536870912 * 1073741824
ELM
if build "$BUILD/in.elm" word in-word; then
  timeout 20 "$BUILD/in-word" M.main > "$BUILD/in-word.out" 2> "$BUILD/in-word.err"
  rc=$?
  out="$(cat "$BUILD/in-word.out")"
  if [ "$rc" != 0 ]; then
    fail "in-word: 2^59 must NOT be refused — got exit $rc, stderr [$(head -1 "$BUILD/in-word.err")].  Without this row row 1 could pass by refusing everything large."
  elif [ "$out" != "576460752303423488" ]; then
    fail "in-word: expected 576460752303423488 (2^59) and got [$out]"
  else
    pass "in-word: 2^59 (the inside edge) exits 0 printing 576460752303423488 — the refusal is the BOUND, not a blanket refusal of large values"
  fi
fi

if [ "$fails" != 0 ]; then
  echo "word-arm-i61: $fails failure(s)"
  exit 1
fi
exit 0
