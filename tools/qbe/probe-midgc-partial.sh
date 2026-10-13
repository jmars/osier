#!/usr/bin/env bash
# probe-midgc-partial.sh — the SCRIPTED fail-before / pass-after probe for the
# zigretire stage-5 PART 2 PARTIAL-APPLICATION seat (applyGo's `rem > nargs`
# arm: Zig `g.allocArray` -> the Mid Rt.allocVector seat via the weak-extern
# bridge in tools/qbe/rt.zig).
#
# THE ASYMMETRY.  tools/qbe/fixtures/midgc-partial.elm builds a Mid-allocated
# cons list whose elements are PARTIALS (`add n` = the 1-of-2 application of
# `add`), then churns MORE partials (dropped) so a collection fires while the
# list is the only live data.  Its sum is 200 * (n + 10) = 22100 — the value
# any correct collector must print.
#
#   * PASS-AFTER (this tree): QBE_MIDGC=1 routes the partial's env array
#     through the Mid seat, so list and env arrays share the MID heap -> 22100.
#   * FAIL-BEFORE: reverting ONE line in tools/qbe/rt.zig (applyGo's
#     `if (midgc_active) midgcVecAlloc(total) else` -> plain `g.allocArray`)
#     restores the stage-4 state where the partial's env array was Zig-
#     allocated.  The list is Mid-allocated, its partials' env arrays
#     Zig-allocated: the cross-heap edge the stage-5 review found BY EMISSION,
#     and the Zig scavenger frees the env arrays it cannot see through the Mid
#     list -> a WRONG SUM (MEASURED 49900) or a crash, never 22100.
#
# Usage:
#   tools/qbe/probe-midgc-partial.sh          # PASS-AFTER (current tree)
#   tools/qbe/probe-midgc-partial.sh --before # FAIL-BEFORE: apply the
#                                             # reversion, rebuild rt.o, run,
#                                             # RESTORE (trapped)
#
# The --before arm restores rt.zig under a trap, so even a failed run never
# leaves the tree edited.  It rebuilds rt.o via tools/qbe/rt-o.sh (the shared
# freshness-probed graph) and compiler.js is NOT touched.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

RT="tools/qbe/rt.zig"
FIXTURE="tools/qbe/fixtures/midgc-partial.elm"
ENTRY="MidgcPartial.main"
GOLDEN=22100
CHURN_MB=16

# The one reverted line, anchored on its unique full text.
BEFORE_LINE="        var envv: ?[*]Value = if (midgc_active) midgcVecAlloc(total) else g.allocArray(Value, total);"
AFTER_LINE="        var envv: ?[*]Value = g.allocArray(Value, total);"

need() { command -v "$1" >/dev/null 2>&1 || { echo "probe-midgc-partial: $1 not found" >&2; exit 2; }; }

rebuild_rt() {
  "$ROOT/tools/qbe/rt-o.sh" >/dev/null \
    || { echo "probe-midgc-partial: rt-o.sh failed" >&2; exit 1; }
}

run_probe() {
  local out
  out="$(mktemp -d "${TMPDIR:-/tmp}/probe-midgc-partial.XXXXXX")"
  trap 'rm -rf "$out"' RETURN
  QBE_MIDGC=1 "$ROOT/tools/qbe/qbe-mk.sh" "$FIXTURE" "$ENTRY" "$out" >/dev/null 2>&1 \
    || { echo "probe-midgc-partial: qbe-mk failed" >&2; exit 1; }
  QBE_HEAP_MB=$CHURN_MB timeout 180 "$out/midgc-partial" "$ENTRY" 2>&1
}

case "${1:-}" in
  "")
    need node; need cc; need zig
    rebuild_rt
    out="$(run_probe)"
    if [ "$out" = "$GOLDEN" ]; then
      echo "PASS-AFTER: midgc-partial under QBE_MIDGC=1 QBE_HEAP_MB=$CHURN_MB prints $out (== $GOLDEN)"
      exit 0
    else
      echo "FAIL-AFTER: midgc-partial printed '$out', want '$GOLDEN' — the stage-5 partial route is not sound" >&2
      exit 1
    fi
    ;;
  --before)
    need node; need cc; need zig
    python3 - "$RT" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
before = "        var envv: ?[*]Value = if (midgc_active) midgcVecAlloc(total) else g.allocArray(Value, total);"
after = "        var envv: ?[*]Value = g.allocArray(Value, total);"
assert s.count(before) == 1, f"expected exactly one reversion site, found {s.count(before)}"
open(p, "w").write(s.replace(before, after))
PY
    restore() {
      python3 - "$RT" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
after = "        var envv: ?[*]Value = g.allocArray(Value, total);"
before = "        var envv: ?[*]Value = if (midgc_active) midgcVecAlloc(total) else g.allocArray(Value, total);"
assert s.count(after) == 1, f"expected exactly one reverted site, found {s.count(after)}"
open(p, "w").write(s.replace(after, before))
PY
      "$ROOT/tools/qbe/rt-o.sh" >/dev/null || true
    }
    trap restore EXIT
    rebuild_rt
    out="$(run_probe)"
    if [ "$out" = "$GOLDEN" ]; then
      echo "FAIL-BEFORE NOT REPRODUCED: midgc-partial still prints $GOLDEN with the Zig g.allocArray route restored — the probe does not catch the cross-heap edge" >&2
      exit 1
    else
      echo "FAIL-BEFORE REPRODUCED: midgc-partial printed '$out' (!= $GOLDEN) with the partial env array on the Zig g.allocArray route (cross-heap edge, freed env arrays)"
      exit 0
    fi
    ;;
  *)
    echo "usage: tools/qbe/probe-midgc-partial.sh [--before]" >&2
    exit 2
    ;;
esac
