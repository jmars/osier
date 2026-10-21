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
# IS IT ROUTE-SPECIFIC?  NO — the hole is in the ZIG heap (the argv registry is
# Zig-heap; the list is built before the Mid region even exists).  There is one
# route since ZIGHOST Z0 (the collector hatch is retired: run.js refuses
# QBE_MIDGC=0), so the two arms this probe used to run — the flag off and on —
# are the SAME build now and have been collapsed into one.
#
# THE SECOND ARM IS GONE, and the record of what it was is kept because the
# MEASUREMENT it carried is still the honest bound on this probe: under the
# collector hatch the argv repr was COMPILE-REFUSED (`Runtime.argv ()` lowers to
# the `value` prim, `value` was on nurseryHostPrims, so the argv list was
# UNREACHABLE from a Mid object).  STAGE 7 O2 deleted that refusal, turning the
# arm into a measurement — the same program COMPILES and still answers NARGS,
# MEASURED on the O2 tree at QBE_HEAP_MB=16 with 60000 args — and ZIGHOST Z0
# removed the flag, so both arms became the SAME build and were collapsed.  The
# statement this probe makes is therefore the weaker one, and it is recorded as
# such: nothing on this route scavenges the Zig nursery after boot (the argv
# list is still a Zig-heap valCons, and `value` is the one prim that hands it
# out), so "it answers correctly" is evidence, not a proof of soundness.  The
# census's replacement — refuse a MID GC heap driven by the ZIG host — is in
# run.js's MIDGC_DEPENDS_ON and is scripted by probe-midgc-io.sh.
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
#   tools/qbe/probe-midgc-argv.sh            # PASS-AFTER (the only route)
#   tools/qbe/probe-midgc-argv.sh --before    # FAIL-BEFORE (the only route)
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
  "$ROOT/tools/qbe/qbe-mk.sh" "$FIXTURE" "$ENTRY" "$1" >/dev/null 2>&1
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

run_arm() {
  local out r
  out="$(mktemp -d "$WORK/b.XXXXXX")"
  build "$out" || { echo "RESULT=build-failed" >&2; return 1; }
  r="$(count_with "$out/argvrepro")"
  echo "RESULT=$r"
}

rc=0
case "${1:-}" in
  "")
    r="$(run_arm)"
    echo "the Mid route: $r (want RESULT=$NARGS)"
    [ "$r" = "RESULT=$NARGS" ] || { echo "FAIL-AFTER: the route lost argv entries" >&2; rc=1; }
    [ "$rc" -eq 0 ] && echo "PASS-AFTER: *argv* survives a scavenge inside the build ($NARGS entries) on the only collector there is"
    ;;
  --before)
    mutate_before || exit 1
    r="$(run_arm)"
    echo "the Mid route: $r (want the '$FAIL_BEFORE' signature)"
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
