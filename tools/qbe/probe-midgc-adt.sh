#!/usr/bin/env bash
# probe-midgc-adt.sh — the SCRIPTED fail-before / pass-after probe for the
# zigretire stage-5 ADT-construction seat (Con: Zig `rt_con` -> Mid `Rt.con`).
#
# THE ASYMMETRY.  tools/qbe/fixtures/midgc-adt.elm builds a Mid-allocated
# cons list whose elements are ADT constructors, then churns BOTH shapes so a
# collection fires while the list is the only live data.  Its sum is
# 400 * (n + (n+1)) = 160800 — the value any correct collector must print.
#
#   * PASS-AFTER (this tree): QBE_MIDGC=1 routes every Con through the Mid
#     defun `Rt.con`, so list and elements share the MID heap -> 160800.
#   * FAIL-BEFORE: reverting ONE line in elm-compiler/src/Mid/Qbe/Lower.elm
#     (lowerCon's `if s.midGc then` -> `if False then`) restores the stage-4
#     state where Con still went through the Zig `rt_con`.  The list is
#     Mid-allocated, its elements Zig-allocated: the cross-heap edge the
#     stage-4 review named, and the run reads freed Con data -> a WRONG SUM
#     (MEASURED 229600) or a crash, never 160800.
#
# Usage:
#   tools/qbe/probe-midgc-adt.sh          # PASS-AFTER (current tree)
#   tools/qbe/probe-midgc-adt.sh --before # FAIL-BEFORE: apply the reversion,
#                                         # rebuild, run, RESTORE (trapped)
#
# The --before arm restores Lower.elm under a trap, so even a failed run never
# leaves the tree edited.  It rebuilds compiler.js itself (ELM_BIN defaults to
# the npm-global elm, the same path osier-numbers.sh documents).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

LOWER="elm-compiler/src/Mid/Qbe/Lower.elm"
FIXTURE="tools/qbe/fixtures/midgc-adt.elm"
ENTRY="MidgcAdt.main"
GOLDEN=160800
CHURN_MB=16
ELM_BIN="${ELM_BIN:-$HOME/.npm-global/lib/node_modules/elm/bin/elm}"

# The one reverted line, anchored on its unique 3-line context so the
# replacement cannot hit the other `if s.midGc then` sites in Lower.elm.
BEFORE_BLOCK=$'                            in\n                            if s.midGc then\n                                -- QBE_MIDGC=1: route Con through the Mid defun'
AFTER_BLOCK=$'                            in\n                            if False then\n                                -- QBE_MIDGC=1: route Con through the Mid defun'

need() { command -v "$1" >/dev/null 2>&1 || { echo "probe-midgc-adt: $1 not found" >&2; exit 2; }; }

rebuild() {
  (cd "$ROOT/elm-compiler" && ELM_HOME="$PWD/.elm-cache" "$ELM_BIN" make src/Main.elm --output=compiler.js >/dev/null) \
    || { echo "probe-midgc-adt: elm make compiler.js failed" >&2; exit 1; }
}

# build + run the fixture under QBE_MIDGC=1 at the minimum heap; print stdout.
run_probe() {
  local out
  out="$(mktemp -d "${TMPDIR:-/tmp}/probe-midgc-adt.XXXXXX")"
  trap 'rm -rf "$out"' RETURN
  QBE_MIDGC=1 "$ROOT/tools/qbe/qbe-mk.sh" "$FIXTURE" "$ENTRY" "$out" >/dev/null 2>&1 \
    || { echo "probe-midgc-adt: qbe-mk failed" >&2; exit 1; }
  QBE_HEAP_MB=$CHURN_MB timeout 120 "$out/midgc-adt" "$ENTRY" 2>&1
}

case "${1:-}" in
  "")
    need node; need cc
    rebuild
    out="$(run_probe)"
    if [ "$out" = "$GOLDEN" ]; then
      echo "PASS-AFTER: midgc-adt under QBE_MIDGC=1 QBE_HEAP_MB=$CHURN_MB prints $out (== $GOLDEN)"
      exit 0
    else
      echo "FAIL-AFTER: midgc-adt printed '$out', want '$GOLDEN' — the stage-5 Con route is not sound" >&2
      exit 1
    fi
    ;;
  --before)
    need node; need cc
    # Revert the ONE line, then always restore it (even on a failed run).
    python3 - "$LOWER" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
before = "                            in\n                            if s.midGc then\n                                -- QBE_MIDGC=1: route Con through the Mid defun"
after = "                            in\n                            if False then\n                                -- QBE_MIDGC=1: route Con through the Mid defun"
assert s.count(before) == 1, f"expected exactly one reversion site, found {s.count(before)}"
open(p, "w").write(s.replace(before, after))
PY
    restore() {
      python3 - "$LOWER" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
after = "                            in\n                            if False then\n                                -- QBE_MIDGC=1: route Con through the Mid defun"
before = "                            in\n                            if s.midGc then\n                                -- QBE_MIDGC=1: route Con through the Mid defun"
assert s.count(after) == 1, f"expected exactly one reverted site, found {s.count(after)}"
open(p, "w").write(s.replace(after, before))
PY
      (cd "$ROOT/elm-compiler" && ELM_HOME="$PWD/.elm-cache" "$ELM_BIN" make src/Main.elm --output=compiler.js >/dev/null) || true
    }
    trap restore EXIT
    rebuild
    out="$(run_probe)"
    if [ "$out" = "$GOLDEN" ]; then
      echo "FAIL-BEFORE NOT REPRODUCED: midgc-adt still prints $GOLDEN with the Zig rt_con route restored — the probe does not catch the cross-heap edge" >&2
      exit 1
    else
      echo "FAIL-BEFORE REPRODUCED: midgc-adt printed '$out' (!= $GOLDEN) with Con on the Zig rt_con route (cross-heap edge, freed Con data)"
      exit 0
    fi
    ;;
  *)
    echo "usage: tools/qbe/probe-midgc-adt.sh [--before]" >&2
    exit 2
    ;;
esac
