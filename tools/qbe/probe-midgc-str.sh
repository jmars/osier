#!/usr/bin/env bash
# probe-midgc-str.sh — the SCRIPTED fail-before / pass-after probe for the
# zigretire stage-5 PART 5 CENSUS-ARM pin (the PART-5 review's should-fix 1
# and 2): the `str` entry of `nurseryHostPrims` protects pure programs, and
# until this probe existed its DELETION left every gate green.
#
# THE ASYMMETRY.  tools/qbe/fixtures/midgc-str.elm keeps `String.fromFloat
# (0.0/0.0)` (NaN — the one shape whose `str` result is the raw Zig-nursery
# string, NOT rebuilt through Mid `cn`) in a Mid cons, then churns a 4-arg
# MUTUAL tail recursion to force the Zig scavenge, then content-compares.
#
#   * PASS-AFTER (this tree): QBE_MIDGC=1 REFUSES the program at compile time,
#     naming `str` (the CENSUS arm — the program is pure, no Platform seam).
#     The DEFAULT path still prints "100" (the nursery string is evacuated,
#     not reclaimed).
#   * FAIL-BEFORE: reverting ONE line in elm-compiler/src/Mid/Qbe/Lower.elm
#     (deleting the `str` entry from nurseryHostPrims) lets the program compile
#     under QBE_MIDGC=1; it then prints "0" — the kept "NaN" data bytes were
#     reclaimed by the Zig scavenge while the Value (and its length field)
#     survived.  The exact cross-heap signature, PINNED: corrupt == "0", never
#     "not-equal-to-golden".
#
# Usage:
#   tools/qbe/probe-midgc-str.sh          # PASS-AFTER (current tree)
#   tools/qbe/probe-midgc-str.sh --before # FAIL-BEFORE: revert, rebuild, run,
#                                         # RESTORE
#
# The --before arm restores Lower.elm under a trap, so even a failed run never
# leaves the tree edited.  It rebuilds compiler.js itself (ELM_BIN defaults to
# the npm-global elm, the same path osier-numbers.sh documents).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

LOWER="elm-compiler/src/Mid/Qbe/Lower.elm"
FIXTURE="tools/qbe/fixtures/midgc-str.elm"
ENTRY="MidgcStr.main"
GOLDEN='"100"'
FAIL_BEFORE='"0"'
CHURN_MB=16
ELM_BIN="${ELM_BIN:-$HOME/.npm-global/lib/node_modules/elm/bin/elm}"

# The one reverted line: the `str` entry of nurseryHostPrims (the LAST list
# element).  Anchored on the unique `"value"` + `"str"` + closing-bracket
# sequence so the reversion/restore cannot hit any other list in Lower.elm.
BEFORE_BLOCK=$'                        , "value"\n                        , "str"\n                        ]'
AFTER_BLOCK=$'                        , "value"\n                        ]'

need() { command -v "$1" >/dev/null 2>&1 || { echo "probe-midgc-str: $1 not found" >&2; exit 2; }; }

rebuild() {
  (cd "$ROOT/elm-compiler" && ELM_HOME="$PWD/.elm-cache" "$ELM_BIN" make src/Main.elm --output=compiler.js >/dev/null) \
    || { echo "probe-midgc-str: elm make compiler.js failed" >&2; exit 1; }
}

# Compile the fixture under QBE_MIDGC=1.  With $1 = expect_refusal (default 1),
# asserts the compile FAILS with the refusal naming `str`; with 0, asserts the
# compile SUCCEEDS (the --before arm, where the `str` entry is deleted).
midgc_compile() {
  local expect_refusal="${1:-1}"
  local out
  out="$(mktemp -d "${TMPDIR:-/tmp}/probe-midgc-str.XXXXXX")"
  if QBE_MIDGC=1 "$ROOT/tools/qbe/qbe-mk.sh" "$FIXTURE" "$ENTRY" "$out" >/dev/null 2>&1; then
    if [ "$expect_refusal" = "1" ]; then
      echo "probe-midgc-str: QBE_MIDGC=1 did NOT refuse the pure str program (it compiled) — the census-arm \`str\` entry is missing" >&2
      exit 1
    fi
  else
    if [ "$expect_refusal" = "0" ]; then
      echo "probe-midgc-str: QBE_MIDGC=1 still refuses the program under --before (the reversion did not delete the \`str\` entry)" >&2
      exit 1
    fi
    if ! head -c 4 "$out/midgc-str.ssa" | grep -q '^err '; then
      echo "probe-midgc-str: QBE_MIDGC=1 failed but the .ssa is not an 'err' — unexpected compile failure" >&2
      exit 1
    fi
    if ! grep -q '`str`' "$out/midgc-str.ssa"; then
      echo "probe-midgc-str: the refusal does not NAME the str prim (backtick-quoted)" >&2
      exit 1
    fi
  fi
  echo "$out"
}

# Default-path control: the fixture must print the golden with the Zig
# collector (the kept string is rooted -> evacuated, not reclaimed).
default_control() {
  local out
  out="$(mktemp -d "${TMPDIR:-/tmp}/probe-midgc-str.XXXXXX")"
  trap 'rm -rf "$out"' RETURN
  "$ROOT/tools/qbe/qbe-mk.sh" "$FIXTURE" "$ENTRY" "$out" >/dev/null 2>&1 \
    || { echo "probe-midgc-str: default qbe-mk failed" >&2; exit 1; }
  QBE_HEAP_MB=$CHURN_MB timeout 120 "$out/midgc-str" "$ENTRY" 2>&1
}

case "${1:-}" in
  "")
    need node; need cc
    rebuild
    out="$(midgc_compile 1)"
    rm -rf "$out"
    ctrl="$(default_control)"
    if [ "$ctrl" = "$GOLDEN" ]; then
      echo "PASS-AFTER: QBE_MIDGC=1 refuses the pure str program (names the \`str\` prim — the CENSUS arm); the default path prints $GOLDEN"
      exit 0
    else
      echo "FAIL-AFTER: the default path printed '$ctrl', want '$GOLDEN'" >&2
      exit 1
    fi
    ;;
  --before)
    need node; need cc
    # Delete the ONE line (the `str` entry), then always restore it.
    python3 - "$LOWER" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
before = '                        , "value"\n                        , "str"\n                        ]'
after = '                        , "value"\n                        ]'
assert s.count(before) == 1, f"expected exactly one reversion site, found {s.count(before)}"
open(p, "w").write(s.replace(before, after))
PY
    restore() {
      python3 - "$LOWER" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
after = '                        , "value"\n                        ]'
before = '                        , "value"\n                        , "str"\n                        ]'
assert s.count(after) == 1, f"expected exactly one reverted site, found {s.count(after)}"
open(p, "w").write(s.replace(after, before))
PY
      (cd "$ROOT/elm-compiler" && ELM_HOME="$PWD/.elm-cache" "$ELM_BIN" make src/Main.elm --output=compiler.js >/dev/null) || true
    }
    trap restore EXIT
    rebuild
    out="$(midgc_compile 0)"
    corrupt="$(QBE_HEAP_MB=$CHURN_MB timeout 120 "$out/midgc-str" "$ENTRY" 2>&1)"
    rm -rf "$out"
    if [ "$corrupt" = "$FAIL_BEFORE" ]; then
      echo "FAIL-BEFORE REPRODUCED: with the \`str\` entry deleted, the pure str program printed '$corrupt' (== $FAIL_BEFORE) — the kept NaN data bytes were reclaimed by the Zig scavenge while the Value survived"
      exit 0
    else
      echo "FAIL-BEFORE NOT REPRODUCED: printed '$corrupt', want the exact cross-heap signature '$FAIL_BEFORE' — the probe does not pin the mechanism" >&2
      exit 1
    fi
    ;;
  *)
    echo "usage: tools/qbe/probe-midgc-str.sh [--before]" >&2
    exit 2
    ;;
esac
