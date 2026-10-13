#!/usr/bin/env bash
# probe-midgc-string.sh — the SCRIPTED fail-before / pass-after probe for the
# zigretire stage-5 PART 4 STRING-LITERAL seat (Zig `rt_string` interning +
# nursery fallback -> Mid STATIC data under QBE_MIDGC=1).
#
# THE ASYMMETRY.  tools/qbe/fixtures/midgc-string.elm keeps a Mid cons list of
# 100 DISTINCT string literals alive across a churn of ~400k literal
# evaluations, then compares the kept strings BY CONTENT against a fresh copy.
#
#   * PASS-AFTER (this tree): under QBE_MIDGC=1 a string literal is emitted as
#     STATIC data (the immutable, null-terminated data symbol itself), so
#     rt_string is never called, no Zig-nursery allocation is made, and the
#     content equality holds -> 31200200.
#   * FAIL-BEFORE: reverting ONE line in elm-compiler/src/Mid/Qbe/Lower.elm
#     (lowerLit's LString case `if s.midGc then` -> `if False then`) restores
#     the Zig rt_string route; under QBE_NOSTRINGINTERN=1 its fallback
#     allocates each literal in the Zig nursery, the churn forces a scavenge
#     (collect.zig:713-720 re-claims the whole nursery), and the kept data is
#     overwritten WHILE LIVE -> the equality fails -> 31200100 (never 31200200).
#
# The script ALSO asserts the structural pin: the emitted MIDGC .ssa contains
# ZERO `rt_string` calls (a re-added Zig string route under the hatch goes red
# on emission, not only on behaviour — this is what closes the runtime
# intern_live >= 2048 fallback, which no flag list could enumerate).
#
# Usage:
#   tools/qbe/probe-midgc-string.sh          # PASS-AFTER (current tree)
#   tools/qbe/probe-midgc-string.sh --before # FAIL-BEFORE: apply the
#                                            # reversion, rebuild, run, RESTORE
#
# The --before arm restores Lower.elm under a trap, so even a failed run never
# leaves the tree edited.  It rebuilds compiler.js itself (ELM_BIN defaults to
# the npm-global elm, the same path osier-numbers.sh documents).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

LOWER="elm-compiler/src/Mid/Qbe/Lower.elm"
FIXTURE="tools/qbe/fixtures/midgc-string.elm"
ENTRY="MidgcString.main"
GOLDEN=31200200
FAIL_BEFORE=31200100
CHURN_MB=16
ELM_BIN="${ELM_BIN:-$HOME/.npm-global/lib/node_modules/elm/bin/elm}"

# The one reverted line, anchored on its unique comment (the words "the string
# data IS the static" occur only in lowerLit's LString midGc branch), so the
# replacement cannot hit any other `if s.midGc then` site in Lower.elm.
BEFORE_BLOCK=$'            if s.midGc then\n                -- Mid: the string data IS the static data symbol'
AFTER_BLOCK=$'            if False then\n                -- Mid: the string data IS the static data symbol'

need() { command -v "$1" >/dev/null 2>&1 || { echo "probe-midgc-string: $1 not found" >&2; exit 2; }; }

rebuild() {
  (cd "$ROOT/elm-compiler" && ELM_HOME="$PWD/.elm-cache" "$ELM_BIN" make src/Main.elm --output=compiler.js >/dev/null) \
    || { echo "probe-midgc-string: elm make compiler.js failed" >&2; exit 1; }
}

# build + run the fixture under QBE_MIDGC=1 + QBE_NOSTRINGINTERN=1 at the
# minimum heap; print stdout.  With $1 = check (default 1), also asserts the
# .ssa has zero rt_string calls (the structural pin) — asserted only in the
# PASS-AFTER arm, because the --before arm's reverted route legitimately calls
# rt_string.
run_probe() {
  local check="${1:-1}"
  local out
  out="$(mktemp -d "${TMPDIR:-/tmp}/probe-midgc-string.XXXXXX")"
  trap 'rm -rf "$out"' RETURN
  QBE_MIDGC=1 "$ROOT/tools/qbe/qbe-mk.sh" "$FIXTURE" "$ENTRY" "$out" >/dev/null 2>&1 \
    || { echo "probe-midgc-string: qbe-mk failed" >&2; exit 1; }
  local ssa rt_calls
  ssa="$out/midgc-string.ssa"
  if [ "$check" = "1" ]; then
    rt_calls="$(grep -c 'rt_string' "$ssa" 2>/dev/null || true)"
    if [ "$rt_calls" != "0" ]; then
      echo "probe-midgc-string: the MIDGC .ssa calls rt_string $rt_calls time(s) — the string route is not static (the structural pin failed)" >&2
      exit 1
    fi
    # RUNTIME boundary pin (the intern_live >= 2048 fallback, item 5): drive
    # the runtime counters and assert the intern table is never touched — if
    # rt_string were called at all, intern_live could reach 2048 and fire the
    # nursery fallback no flag could guard.  rt_string=0 => the boundary is
    # unreachable, observed at run time, not just by emission.
    local counts
    counts="$(QBE_HEAP_MB=$CHURN_MB QBE_NOSTRINGINTERN=1 QBE_RT_COUNTS=1 timeout 120 "$out/midgc-string" "$ENTRY" 2>&1 >/dev/null)"
    if ! printf '%s' "$counts" | grep -q 'rt_string=0'; then
      echo "probe-midgc-string: runtime counters show rt_string was called under MIDGC — the intern_live >= 2048 fallback is NOT structurally unreachable" >&2
      exit 1
    fi
  fi
  QBE_HEAP_MB=$CHURN_MB QBE_NOSTRINGINTERN=1 timeout 120 "$out/midgc-string" "$ENTRY" 2>&1
}

case "${1:-}" in
  "")
    need node; need cc
    rebuild
    out="$(run_probe)"
    if [ "$out" = "$GOLDEN" ]; then
      echo "PASS-AFTER: midgc-string under QBE_MIDGC=1 QBE_NOSTRINGINTERN=1 QBE_HEAP_MB=$CHURN_MB prints $out (== $GOLDEN); 0 rt_string calls"
      exit 0
    else
      echo "FAIL-AFTER: midgc-string printed '$out', want '$GOLDEN' — the stage-5 string route is not sound" >&2
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
before = "            if s.midGc then\n                -- Mid: the string data IS the static data symbol"
after = "            if False then\n                -- Mid: the string data IS the static data symbol"
assert s.count(before) == 1, f"expected exactly one reversion site, found {s.count(before)}"
open(p, "w").write(s.replace(before, after))
PY
    restore() {
      python3 - "$LOWER" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
after = "            if False then\n                -- Mid: the string data IS the static data symbol"
before = "            if s.midGc then\n                -- Mid: the string data IS the static data symbol"
assert s.count(after) == 1, f"expected exactly one reverted site, found {s.count(after)}"
open(p, "w").write(s.replace(after, before))
PY
      (cd "$ROOT/elm-compiler" && ELM_HOME="$PWD/.elm-cache" "$ELM_BIN" make src/Main.elm --output=compiler.js >/dev/null) || true
    }
    trap restore EXIT
    rebuild
    out="$(run_probe 0)"
    if [ "$out" = "$FAIL_BEFORE" ]; then
      echo "FAIL-BEFORE REPRODUCED: midgc-string printed '$out' (== $FAIL_BEFORE) with string data on the Zig rt_string route (cross-heap edge, freed string data)"
      exit 0
    else
      echo "FAIL-BEFORE NOT REPRODUCED: printed '$out', want the exact signature '$FAIL_BEFORE' — the probe does not pin the mechanism" >&2
      exit 1
    fi
    ;;
  *)
    echo "usage: tools/qbe/probe-midgc-string.sh [--before]" >&2
    exit 2
    ;;
esac
