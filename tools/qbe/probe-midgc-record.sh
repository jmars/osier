#!/usr/bin/env bash
# probe-midgc-record.sh — the SCRIPTED fail-before / pass-after probe for the
# zigretire stage-5 RECORD-construction seat (Zig `rt_vec_alloc` + barrier
# `rt_vec_store` -> Mid `Rt.allocVector` + `rt_vec_store_plain`).
#
# THE ASYMMETRY.  tools/qbe/fixtures/midgc-record.elm builds a Mid-allocated
# cons list whose elements are positional records `{ n, m }`, and also
# exercises an OPEN-row insertion (`addTag`, the dynamic names array) and a
# `Record.remove`.  Its sum is 60209 — the value any correct collector prints.
#
#   * PASS-AFTER (this tree): QBE_MIDGC=1 routes every record DATA array
#     through the Mid seat `Rt.allocVector`, so list and record data share the
#     MID heap -> 60209.
#   * FAIL-BEFORE: reverting ONE line in elm-compiler/src/Mid/Qbe/Lower.elm
#     (lowerRecordLitPos's `if s.midGc then` -> `if False then`) restores the
#     stage-4 state where a record literal still Zig-allocated its data array
#     via `rt_vec_alloc`.  The list is Mid-allocated, its records' data arrays
#     Zig-allocated: the cross-heap edge, and the run reads freed record data
#     -> a WRONG SUM, never 60209.
#
# Usage:
#   tools/qbe/probe-midgc-record.sh          # PASS-AFTER (current tree)
#   tools/qbe/probe-midgc-record.sh --before # FAIL-BEFORE: apply the
#                                            # reversion, rebuild, run, RESTORE
#
# The --before arm restores Lower.elm under a trap, so even a failed run never
# leaves the tree edited.  It rebuilds compiler.js itself (ELM_BIN defaults to
# the npm-global elm, the same path osier-numbers.sh documents).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

LOWER="elm-compiler/src/Mid/Qbe/Lower.elm"
FIXTURE="tools/qbe/fixtures/midgc-record.elm"
ENTRY="MidgcRecord.main"
GOLDEN=60209
FAIL_BEFORE=115409
CHURN_MB=16
ELM_BIN="${ELM_BIN:-$HOME/.npm-global/lib/node_modules/elm/bin/elm}"

# The one reverted line, anchored on its unique 3-line context (the `dataArg`
# name is unique to lowerRecordLitPos; lowerRecordUpdateClosed uses `ndArg`),
# so the replacement cannot hit any other `if s.midGc then` site in Lower.elm.
BEFORE_BLOCK=$'                                ( dataArg, s2 ) =\n                                    if s.midGc then\n                                        midGcAllocSeat "Rt.allocVector" (Il.Con n) s1'
AFTER_BLOCK=$'                                ( dataArg, s2 ) =\n                                    if False then\n                                        midGcAllocSeat "Rt.allocVector" (Il.Con n) s1'

need() { command -v "$1" >/dev/null 2>&1 || { echo "probe-midgc-record: $1 not found" >&2; exit 2; }; }

rebuild() {
  (cd "$ROOT/elm-compiler" && ELM_HOME="$PWD/.elm-cache" "$ELM_BIN" make src/Main.elm --output=compiler.js >/dev/null) \
    || { echo "probe-midgc-record: elm make compiler.js failed" >&2; exit 1; }
}

# build + run the fixture under QBE_MIDGC=1 at the minimum heap; print stdout.
run_probe() {
  local out
  out="$(mktemp -d "${TMPDIR:-/tmp}/probe-midgc-record.XXXXXX")"
  trap 'rm -rf "$out"' RETURN
  QBE_MIDGC=1 "$ROOT/tools/qbe/qbe-mk.sh" "$FIXTURE" "$ENTRY" "$out" >/dev/null 2>&1 \
    || { echo "probe-midgc-record: qbe-mk failed" >&2; exit 1; }
  QBE_HEAP_MB=$CHURN_MB timeout 120 "$out/midgc-record" "$ENTRY" 2>&1
}

case "${1:-}" in
  "")
    need node; need cc
    rebuild
    out="$(run_probe)"
    if [ "$out" = "$GOLDEN" ]; then
      echo "PASS-AFTER: midgc-record under QBE_MIDGC=1 QBE_HEAP_MB=$CHURN_MB prints $out (== $GOLDEN)"
      exit 0
    else
      echo "FAIL-AFTER: midgc-record printed '$out', want '$GOLDEN' — the stage-5 record route is not sound" >&2
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
before = "                                ( dataArg, s2 ) =\n                                    if s.midGc then\n                                        midGcAllocSeat \"Rt.allocVector\" (Il.Con n) s1"
after = "                                ( dataArg, s2 ) =\n                                    if False then\n                                        midGcAllocSeat \"Rt.allocVector\" (Il.Con n) s1"
assert s.count(before) == 1, f"expected exactly one reversion site, found {s.count(before)}"
open(p, "w").write(s.replace(before, after))
PY
    restore() {
      python3 - "$LOWER" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
after = "                                ( dataArg, s2 ) =\n                                    if False then\n                                        midGcAllocSeat \"Rt.allocVector\" (Il.Con n) s1"
before = "                                ( dataArg, s2 ) =\n                                    if s.midGc then\n                                        midGcAllocSeat \"Rt.allocVector\" (Il.Con n) s1"
assert s.count(after) == 1, f"expected exactly one reverted site, found {s.count(after)}"
open(p, "w").write(s.replace(after, before))
PY
      (cd "$ROOT/elm-compiler" && ELM_HOME="$PWD/.elm-cache" "$ELM_BIN" make src/Main.elm --output=compiler.js >/dev/null) || true
    }
    trap restore EXIT
    rebuild
    out="$(run_probe)"
    if [ "$out" = "$FAIL_BEFORE" ]; then
      echo "FAIL-BEFORE REPRODUCED: midgc-record printed '$out' (== $FAIL_BEFORE) with record data arrays on the Zig rt_vec_alloc route (cross-heap edge, freed record data)"
      exit 0
    else
      echo "FAIL-BEFORE NOT REPRODUCED: printed '$out', want the exact signature '$FAIL_BEFORE' — the probe does not pin the mechanism" >&2
      exit 1
    fi
    ;;
  *)
    echo "usage: tools/qbe/probe-midgc-record.sh [--before]" >&2
    exit 2
    ;;
esac
