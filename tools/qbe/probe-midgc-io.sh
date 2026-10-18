#!/usr/bin/env bash
# probe-midgc-io.sh — the scripted statement of stage 7 O2's act on a HOST-IO
# program: `QBE_MIDGC=1` (with NO other flag) COMPILES it and it prints the
# golden.
#
# THE SHAPE.  tools/qbe/fixtures/midgc-io.elm reads a 150-byte file into a Mid
# cons (`keeper s = [s]`), churns a 4-arg MUTUAL tail recursion, then
# content-compares the kept string AND prints its length.
#
#   * PASS-AFTER (this tree, stage 7 O2): `QBE_MIDGC=1` alone — no QBE_MIDHOST —
#     compiles under the DEFAULT Mid host and prints "100|150".  Before O2 that
#     exact command was a COMPILE REFUSAL (Lower.elm's effect-loop arm, naming
#     Runtime.program) and O2 deleted that arm with the census.
#   * The default path (no MIDGC at all) is unchanged: same binary shape, same
#     golden.
#
# THE FAIL-BEFORE ARM IS GONE, AND THE MEASUREMENT IS WHY (do not re-add it
# without re-measuring).  It used to be: disable run.js's QBE_MIDHOST guard,
# build QBE_MIDGC=1 QBE_MIDHOST=0 (the ZIG host on a Mid heap) and read the
# cross-heap signature "0|150" out of it.  ON THIS TREE THAT NO LONGER
# REPRODUCES: MEASURED 2026-10-18, the Zig-host-on-a-Mid-heap build prints
# "100|150" at QBE_HEAP_MB=16 (with and without QBE_NOSTRINGINTERN), i.e. the
# kept string's data bytes are NOT reclaimed.  WHY (INTERPRETATION, not isolated
# by me): the hole needed a ZIG-nursery scavenge, and the tail array the fixture
# uses as its trigger (rt_tail_known's nargs>3 g.allocArray) is allocated on the
# MID heap once QBE_MIDGC=1 is on — that is what the stage-5 tail-array work
# MEASURED (midgc-tail: "tail_gcarray = 3,000,000").  So the trigger, not the
# hole's definition, went away.
#
# SO WHAT STANDS BEHIND THE DELETED REFUSALS is structural, not a live
# reproducer: the default route has ONE heap (the Mid host allocates through the
# Mid seats), so no Mid object can reference Zig-nursery memory on it; the
# pairing that could is the `QBE_MIDHOST=0` opt-out, and run.js's
# MIDGC_DEPENDS_ON refuses it loudly (exit 2).  That guard is DEFENSIVE on this
# tree — it has no reproducer either — and it is kept because the invariant is
# real (the Zig host builds values.valString/valCons results, and `value`/argv
# still hands out a Zig-heap valCons), so any future Zig-side allocation on the
# host path would reopen the hole without a compile-time symptom.
#
# Usage:
#   tools/qbe/probe-midgc-io.sh          # PASS-AFTER (current tree)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

FIXTURE="tools/qbe/fixtures/midgc-io.elm"
INPUT="tools/qbe/fixtures/input/midgc-io.txt"
ENTRY="MidgcIo.main"
GOLDEN='"100|150"'
CHURN_MB=16

need() { command -v "$1" >/dev/null 2>&1 || { echo "probe-midgc-io: $1 not found" >&2; exit 2; }; }

build_and_run() { # $1 = out dir; rest = env assignments for the BUILD
  local out="$1"; shift
  env "$@" "$ROOT/tools/qbe/qbe-mk.sh" "$FIXTURE" "$ENTRY" "$out" >/dev/null 2>&1 || {
    echo "BUILD_FAILED"
    return 0
  }
  env MIDGC_IO_IN="$ROOT/$INPUT" QBE_HEAP_MB=$CHURN_MB timeout 120 \
    "$out/midgc-io" "$ENTRY" 2>&1
}

case "${1:-}" in
  "")
    need node; need cc
    out="$(mktemp -d "${TMPDIR:-/tmp}/probe-midgc-io.XXXXXX")"
    trap 'rm -rf "$out"' EXIT
    got="$(build_and_run "$out" QBE_MIDGC=1)"
    rm -rf "$out"
    if [ "$got" = "BUILD_FAILED" ]; then
      echo "FAIL-AFTER: QBE_MIDGC=1 still REFUSES the host-IO program — the effect-loop refusal arm is back (O2 deleted it)" >&2
      exit 1
    fi
    if [ "$got" != "$GOLDEN" ]; then
      echo "FAIL-AFTER: QBE_MIDGC=1 printed '$got', want $GOLDEN — the Mid host on a Mid heap is not sound, so O2's flip is premature" >&2
      exit 1
    fi
    out2="$(mktemp -d "${TMPDIR:-/tmp}/probe-midgc-io.XXXXXX")"
    ctrl="$(build_and_run "$out2")"
    rm -rf "$out2"
    if [ "$ctrl" != "$GOLDEN" ]; then
      echo "FAIL-AFTER: the default path printed '$ctrl', want $GOLDEN — the flip moved the default route's answer" >&2
      exit 1
    fi
    echo "PASS-AFTER: QBE_MIDGC=1 compiles the host-IO program under the DEFAULT Mid host and prints $GOLDEN (the stage-5 compile refusal is gone), and the default path still prints $GOLDEN"
    ;;
  *)
    echo "usage: tools/qbe/probe-midgc-io.sh" >&2
    exit 2
    ;;
esac
