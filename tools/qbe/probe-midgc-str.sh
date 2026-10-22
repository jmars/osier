#!/usr/bin/env bash
# probe-midgc-str.sh — the SCRIPTED fail-before / pass-after probe for the
# zigretire stage 3 GROUP 2 `str` census-arm CLOSURE (the former stage-5
# PART 5 census-arm pin, whose MEANING FLIPPED): `str` now has a Mid body
# (Rt.str) that renders String.fromFloat's float into a GC string, so the
# kept NaN text survives the Zig scavenge — the last census-arm entry of the
# host-IO soundness hole is CLOSED, and the `str` entry LEFT Lower.elm's
# nurseryHostPrims.
#
# THE ASYMMETRY.  tools/qbe/fixtures/midgc-str.elm keeps `String.fromFloat
# (0.0/0.0)` (NaN — the one shape whose pre-GROUP-2 `str` result was the raw
# Zig-nursery string) in a Mid cons, churns a 4-arg MUTUAL tail recursion to
# force the Zig scavenge, then content-compares.
#
#   * PASS-AFTER (this tree): QBE_MIDGC=1 COMPILES the program (no refusal) and
#     prints "100" — the kept "NaN" is Mid-allocated (Rt.str -> rt_float_text
#     -> a GC string), so the Zig scavenge cannot reclaim it.
#   * FAIL-BEFORE (NO LONGER RUNNABLE, stage 7 O2): re-adding ONE line in
#     osier-compiler/src/Mid/Qbe/Lower.elm (the `str` entry of nurseryHostPrims)
#     made QBE_MIDGC=1 REFUSE the program at compile time, naming `str`.  O2
#     DELETED that list and both refusal arms (the Mid host is the default, so
#     the hole closes by construction), so the reversion target no longer
#     exists and the --before arm is GONE rather than silently broken.  The
#     asymmetry it documented is history; what still pins the claim is this
#     script's PASS-AFTER arm plus qbe-check's `run_midgc midgc-str` row, which
#     goes red if QBE_MIDGC=1 starts refusing again or if Rt.str stops
#     rendering into a GC string ("0" instead of "100").
#
# Usage:
#   tools/qbe/probe-midgc-str.sh          # PASS-AFTER (current tree)
#
# It rebuilds compiler.js itself (ELM_BIN defaults to the npm-global elm, the
# same path osier-numbers.sh documents).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

FIXTURE="tools/qbe/fixtures/midgc-str.elm"
ENTRY="MidgcStr.main"
GOLDEN='"100"'
CHURN_MB=16
ELM_BIN="${ELM_BIN:-$HOME/.npm-global/lib/node_modules/elm/bin/elm}"

# The one reverted line: the `str` entry of nurseryHostPrims (the LAST list
# element, present ONLY in the --before tree).  Anchored on the unique
# `"value"` + optional-`"str"` + closing-bracket sequence so the
# reversion/restore cannot hit any other list in Lower.elm.
WITHOUT_STR=$'                        , "value"\n                        ]'
WITH_STR=$'                        , "value"\n                        , "str"\n                        ]'

need() { command -v "$1" >/dev/null 2>&1 || { echo "probe-midgc-str: $1 not found" >&2; exit 2; }; }

rebuild() {
  (cd "$ROOT/osier-compiler" && ELM_HOME="$PWD/.elm-cache" "$ELM_BIN" make src/Main.elm --output=compiler.js >/dev/null) \
    || { echo "probe-midgc-str: elm make compiler.js failed" >&2; exit 1; }
}

# Compile the fixture under QBE_MIDGC=1.  With $1 = expect_refusal (default 0),
# asserts the compile SUCCEEDS and echoes the binary path; with 1, asserts the
# compile FAILS naming `str` (the --before arm, where the `str` entry is
# re-added).
midgc_build() {
  local expect_refusal="${1:-0}"
  local out
  out="$(mktemp -d "${TMPDIR:-/tmp}/probe-midgc-str.XXXXXX")"
  if QBE_MIDGC=1 "$ROOT/tools/qbe/qbe-mk.sh" "$FIXTURE" "$ENTRY" "$out" >/dev/null 2>&1; then
    if [ "$expect_refusal" = "1" ]; then
      echo "probe-midgc-str: QBE_MIDGC=1 compiled the program under --before (the reversion did not re-add the \`str\` entry)" >&2
      exit 1
    fi
  else
    if [ "$expect_refusal" = "0" ]; then
      echo "probe-midgc-str: QBE_MIDGC=1 refuses the program under PASS-AFTER (the \`str\` entry is still present — Rt.str did not leave the refusal list)" >&2
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
  echo "$out/midgc-str"
}

# Run the compiled MIDGC binary at the minimum heap; expect the golden.
midgc_run() {
  local bin="$1"
  local out
  out="$(QBE_HEAP_MB=$CHURN_MB timeout 120 "$bin" "$ENTRY" 2>&1)"
  if [ "$out" = "$GOLDEN" ]; then
    echo "$out"
  else
    echo "probe-midgc-str: QBE_MIDGC=1 printed '$out', want '$GOLDEN' (the kept NaN was reclaimed or mis-rendered)" >&2
    exit 1
  fi
}

# Default-path control: the fixture must print the golden with the Zig
# collector (Rt.str's GC string is rooted -> evacuated, not reclaimed).
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
    bin="$(midgc_build 0)"
    ctrl="$(default_control)"
    if [ "$ctrl" = "$GOLDEN" ] && [ "$(midgc_run "$bin")" = "$GOLDEN" ]; then
      echo "PASS-AFTER: QBE_MIDGC=1 compiles the pure str program (no refusal) and prints $GOLDEN (the kept NaN is Mid-allocated, so the Zig scavenge cannot reclaim it); the default path prints $GOLDEN"
      exit 0
    else
      echo "FAIL-AFTER: midgc/default printed '$ctrl', want '$GOLDEN'" >&2
      exit 1
    fi
    ;;
  *)
    echo "usage: tools/qbe/probe-midgc-str.sh" >&2
    exit 2
    ;;
esac
