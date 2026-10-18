#!/usr/bin/env bash
# probe-midgc-argv.sh — the *argv* REGISTRY's ROOTING hole (GC ARC F1), the row
# of plan.md §2.2's hatch-gate census that names `rt_argv`/`buildArgvList`.
#
# THE HOLE.  buildArgvList walks the C argv back-to-front building a cons list,
# and the retired body rooted only from INSIDE valCons — so the accumulator was
# UNROOTED at the moment `values.valString` allocated the next car.  The Zig
# collector's nursery is a fixed 1 MB with a PREEMPTIVE trigger, so a long
# enough command line fires a scavenge in that window, and a scavenge reclaims
# the whole nursery: the tail built so far is freed, `acc` points at freed
# memory, and *argv* comes back as garbage.
#
# IS IT ROUTE-SPECIFIC?  NO — the hole is in the ZIG heap on both routes (the
# hatch only changes who owns the Mid heap; the argv registry is Zig-heap
# either way, and the list is built before the Mid region even exists).  The
# fix therefore lives in the DEFAULT route's code path too, which is why this
# probe drives it there.
#
# THE SECOND ARM IS THE CENSUS ROW'S OWN EVIDENCE, and it is not a run: under
# QBE_MIDGC=1 the argv repr is COMPILE-REFUSED.  `Runtime.argv ()` lowers to the
# `value` prim, `value` is on the census's nurseryHostPrims list, and the
# refusal is what makes the argv list UNREACHABLE from a Mid object — the
# corrected criterion (plan.md §2.2) is "no Mid object may reference anything
# the Zig collector can reclaim", and a program that cannot be built cannot hold
# one.  So the arm asserts the refusal, in the refusal's own words.
#
# THE ASYMMETRY.  tools/qbe/fixtures/argvrepro.elm's `count` returns the LENGTH
# of Runtime.argv (), so a corrupt tail changes the answer, not just the data.
#
#   * PASS-AFTER (this tree): the accumulator SLOT is rooted across the whole
#     build (`g.rootValue(&acc)`), so a scavenge rewrites acc in place and the
#     count is exact.
#   * FAIL-BEFORE: two lines deleted (the root push and its defer) restore the
#     retired body.  MEASURED signature: `[GC NURSERY #1 …]` then the runtime's
#     `non-exhaustive case` abort — the list contains a value that is not a cons
#     or nil, i.e. reclaimed memory.  (It is 20000 args that first fires the
#     scavenge; 60000 is used for margin.)
#
# Usage:
#   tools/qbe/probe-midgc-argv.sh            # PASS-AFTER, both routes
#   tools/qbe/probe-midgc-argv.sh --before    # FAIL-BEFORE, both routes
#
# The --before arm edits tools/qbe/hostshim.zig (so rt.o is rebuilt — rt-o.sh's
# freshness probe sees the change) and restores it under a trap.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

HOSTSHIM="tools/qbe/hostshim.zig"
FIXTURE="tools/qbe/fixtures/argvrepro.elm"
ENTRY="ArgvRepro.count"
NARGS=60000
FAIL_BEFORE="non-exhaustive case"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/probe-midgc-argv.XXXXXX")" || exit 2
cp "$HOSTSHIM" "$WORK/hostshim.zig.orig"
trap 'cp "$WORK/hostshim.zig.orig" "$HOSTSHIM"; rm -rf "$WORK"' EXIT

need() { command -v "$1" >/dev/null 2>&1 || { echo "probe-midgc-argv: $1 not found" >&2; exit 2; }; }
need node; need cc; need python3

# 60000 args of ~23 bytes: ~1.4 MB of command line, i.e. more than the 1 MB
# nursery, which is what forces the scavenge inside the build.
python3 -c "print(' '.join('a' * 20 + str(i) for i in range($NARGS)))" > "$WORK/args.txt"

build() { # $1 = out dir
  QBE_MIDGC="$2" "$ROOT/tools/qbe/qbe-mk.sh" "$FIXTURE" "$ENTRY" "$1" >/dev/null 2>&1
}

# echo the program's stdout (the argv COUNT); the golden is NARGS
count_with() { # $1 = binary, rest = env prefix
  local bin="$1"; shift
  env AOTRUN_ARGV=1 QBE_HEAP_MB=16 "$@" "$bin" "$ENTRY" $(cat "$WORK/args.txt") 2>&1
}

mutate_before() {
  python3 - "$HOSTSHIM" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = """    var rt = g.rootValue(&acc); // the SLOT is rooted: a move rewrites acc in place
    defer rt.end();
"""
assert s.count(old) == 1, "the rooted accumulator lines are not where the probe expects"
open(p, "w").write(s.replace(old, ""))
PY
}

run_arm() { # $1 = midgc (0 only: the 1 arm is a compile refusal, see below)
  local midgc="$1" out r
  out="$(mktemp -d "$WORK/b$midgc.XXXXXX")"
  build "$out" "$midgc" || { echo "RESULT=build-failed" >&2; return 1; }
  r="$(count_with "$out/argvrepro" QBE_MIDGC="$midgc")"
  echo "RESULT=$r"
}

# the MIDGC arm: the emit must be REFUSED, by name, and produce no binary.
refusal_arm() {
  local out
  out="$(mktemp -d "$WORK/refuse.XXXXXX")"
  ( cd "$ROOT/elm-compiler" && QBE=1 QBE_ENTRY="$ENTRY" QBE_MIDGC=1 \
      node run.js "$ROOT/$FIXTURE" "$out/argvrepro.ssa" ) >/dev/null 2>&1
  head -c 400 "$out/argvrepro.ssa" 2>/dev/null
}

rc=0
case "${1:-}" in
  "")
    r="$(run_arm 0)"
    echo "QBE_MIDGC=0: $r (want RESULT=$NARGS)"
    [ "$r" = "RESULT=$NARGS" ] || { echo "FAIL-AFTER: the default route lost argv entries" >&2; rc=1; }
    ref="$(refusal_arm)"
    case "$ref" in
      *"refuses this program"*"\`value\`"*) echo "QBE_MIDGC=1: REFUSED by the census (the \`value\` prim) — no Mid object can hold the argv list" ;;
      *) echo "FAIL-AFTER: the MIDGC emit of an argv-reading program was NOT refused: '$ref'" >&2; rc=1 ;;
    esac
    [ "$rc" -eq 0 ] && echo "PASS-AFTER: *argv* survives a scavenge inside the build ($NARGS entries), and under the hatch it is unreadable by construction"
    ;;
  --before)
    mutate_before || exit 1
    r="$(run_arm 0)"
    echo "QBE_MIDGC=0: $r (want the '$FAIL_BEFORE' signature)"
    case "$r" in
      *"$FAIL_BEFORE"*) echo "FAIL-BEFORE REPRODUCED: without the root the reclaimed tail makes *argv* unreadable" ;;
      *) echo "FAIL-BEFORE NOT REPRODUCED: got '$r'" >&2; rc=1 ;;
    esac
    ;;
  *)
    echo "usage: tools/qbe/probe-midgc-argv.sh [--before]" >&2
    exit 2
    ;;
esac
exit "$rc"
