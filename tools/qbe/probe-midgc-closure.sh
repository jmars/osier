#!/usr/bin/env bash
# probe-midgc-closure.sh — the SCRIPTED fail-before / pass-after probe for the
# zigretire stage-5 PART 2 CLOSURE seat (rt_make_closure -> Mid `Rt.closure`).
#
# THE ASYMMETRY.  tools/qbe/fixtures/midgc-closure.elm builds a Mid-allocated
# cons list whose elements are CLOSURES WITH A CAPTURE, then churns MORE
# closures (dropped) so a collection fires while the list is the only live
# data.  Its sum is 200 * (n + 10) = 22100 — the value any correct collector
# must print.
#
#   * PASS-AFTER (this tree): QBE_MIDGC=1 routes every closure through the Mid
#     defun `Rt.closure`, so list and env arrays share the MID heap -> 22100.
#   * FAIL-BEFORE: reverting ONE line in elm-compiler/src/Mid/Qbe/Lower.elm
#     (lowerClosure's `if s2.midGc then` -> `if False then`) restores the
#     stage-4 state where closures still went through the Zig `rt_make_closure`.
#     The list is Mid-allocated, its closures' env arrays Zig-allocated: the
#     cross-heap edge the stage-4 review named, and the Zig scavenger frees the
#     env arrays it cannot see through the Mid list -> a WRONG SUM (MEASURED
#     49900) or a crash, never 22100.
#
# Usage:
#   tools/qbe/probe-midgc-closure.sh          # PASS-AFTER (current tree)
#   tools/qbe/probe-midgc-closure.sh --before # FAIL-BEFORE: apply the
#                                             # reversion, rebuild, run,
#                                             # RESTORE (trapped)
#
# The --before arm restores Lower.elm under a trap, so even a failed run never
# leaves the tree edited.  It rebuilds compiler.js itself (ELM_BIN defaults to
# the npm-global elm, the same path osier-numbers.sh documents).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

LOWER="elm-compiler/src/Mid/Qbe/Lower.elm"
FIXTURE="tools/qbe/fixtures/midgc-closure.elm"
ENTRY="MidgcClosure.main"
GOLDEN=22100
CHURN_MB=16
ELM_BIN="${ELM_BIN:-$HOME/.npm-global/lib/node_modules/elm/bin/elm}"

# The one reverted line, anchored on its unique 3-line context.
BEFORE_BLOCK=$'                                            Ok\n                                                (if s2.midGc then\n                                                    -- QBE_MIDGC=1: route the closure through the Mid'
AFTER_BLOCK=$'                                            Ok\n                                                (if False then\n                                                    -- QBE_MIDGC=1: route the closure through the Mid'

need() { command -v "$1" >/dev/null 2>&1 || { echo "probe-midgc-closure: $1 not found" >&2; exit 2; }; }

rebuild() {
  (cd "$ROOT/elm-compiler" && ELM_HOME="$PWD/.elm-cache" "$ELM_BIN" make src/Main.elm --output=compiler.js >/dev/null) \
    || { echo "probe-midgc-closure: elm make compiler.js failed" >&2; exit 1; }
}

run_probe() {
  local out
  out="$(mktemp -d "${TMPDIR:-/tmp}/probe-midgc-closure.XXXXXX")"
  trap 'rm -rf "$out"' RETURN
  QBE_MIDGC=1 "$ROOT/tools/qbe/qbe-mk.sh" "$FIXTURE" "$ENTRY" "$out" >/dev/null 2>&1 \
    || { echo "probe-midgc-closure: qbe-mk failed" >&2; exit 1; }
  QBE_HEAP_MB=$CHURN_MB timeout 180 "$out/midgc-closure" "$ENTRY" 2>&1
}

case "${1:-}" in
  "")
    need node; need cc
    rebuild
    out="$(run_probe)"
    if [ "$out" = "$GOLDEN" ]; then
      echo "PASS-AFTER: midgc-closure under QBE_MIDGC=1 QBE_HEAP_MB=$CHURN_MB prints $out (== $GOLDEN)"
      exit 0
    else
      echo "FAIL-AFTER: midgc-closure printed '$out', want '$GOLDEN' — the stage-5 closure route is not sound" >&2
      exit 1
    fi
    ;;
  --before)
    need node; need cc
    python3 - "$LOWER" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
before = "                                            Ok\n                                                (if s2.midGc then\n                                                    -- QBE_MIDGC=1: route the closure through the Mid"
after = "                                            Ok\n                                                (if False then\n                                                    -- QBE_MIDGC=1: route the closure through the Mid"
assert s.count(before) == 1, f"expected exactly one reversion site, found {s.count(before)}"
open(p, "w").write(s.replace(before, after))
PY
    restore() {
      python3 - "$LOWER" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
after = "                                            Ok\n                                                (if False then\n                                                    -- QBE_MIDGC=1: route the closure through the Mid"
before = "                                            Ok\n                                                (if s2.midGc then\n                                                    -- QBE_MIDGC=1: route the closure through the Mid"
assert s.count(after) == 1, f"expected exactly one reverted site, found {s.count(after)}"
open(p, "w").write(s.replace(after, before))
PY
      (cd "$ROOT/elm-compiler" && ELM_HOME="$PWD/.elm-cache" "$ELM_BIN" make src/Main.elm --output=compiler.js >/dev/null) || true
    }
    trap restore EXIT
    rebuild
    out="$(run_probe)"
    if [ "$out" = "$GOLDEN" ]; then
      echo "FAIL-BEFORE NOT REPRODUCED: midgc-closure still prints $GOLDEN with the Zig rt_make_closure route restored — the probe does not catch the cross-heap edge" >&2
      exit 1
    else
      echo "FAIL-BEFORE REPRODUCED: midgc-closure printed '$out' (!= $GOLDEN) with closures on the Zig rt_make_closure route (cross-heap edge, freed env arrays)"
      exit 0
    fi
    ;;
  *)
    echo "usage: tools/qbe/probe-midgc-closure.sh [--before]" >&2
    exit 2
    ;;
esac
