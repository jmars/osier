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
# THE SECOND ARM USED TO BE THE CENSUS ROW'S OWN EVIDENCE, and it was not a
# run: under QBE_MIDGC=1 the argv repr was COMPILE-REFUSED (`Runtime.argv ()`
# lowers to the `value` prim, `value` was on nurseryHostPrims, and the refusal
# is what made the argv list UNREACHABLE from a Mid object).  STAGE 7 O2 DELETED
# that arm with the rest of the census (the Mid host is the default now), so the
# arm is a MEASUREMENT instead of a refusal: the same program must COMPILE under
# QBE_MIDGC=1 and still answer NARGS — MEASURED on the O2 tree at QBE_HEAP_MB=16
# with 60000 args.  That is a weaker statement than the old one and it is
# recorded as such: nothing on the default route scavenges the Zig nursery after
# boot (the argv list is still a Zig-heap valCons, and `value` is the one prim
# that hands it out), so "it answers correctly" is evidence, not a proof of
# soundness.  The census's replacement — refuse a MID GC heap driven by the ZIG
# host — is in run.js's MIDGC_DEPENDS_ON and is scripted by probe-midgc-io.sh.
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

run_arm() { # $1 = midgc (0: the default route; the 1 arm is midgc_arm below)
  local midgc="$1" out r
  out="$(mktemp -d "$WORK/b$midgc.XXXXXX")"
  build "$out" "$midgc" || { echo "RESULT=build-failed" >&2; return 1; }
  r="$(count_with "$out/argvrepro" QBE_MIDGC="$midgc")"
  echo "RESULT=$r"
}

# the MIDGC arm: the emit must COMPILE (O2 deleted the refusal) and the binary
# must still answer the argv count — the `value` prim on a Mid heap, measured.
midgc_arm() {
  local out r
  out="$(mktemp -d "$WORK/midgc.XXXXXX")"
  build "$out" 1 || { echo "BUILD_FAILED"; return 0; }
  r="$(count_with "$out/argvrepro" QBE_MIDGC=1)"
  echo "RESULT=$r"
}

rc=0
case "${1:-}" in
  "")
    r="$(run_arm 0)"
    echo "QBE_MIDGC=0: $r (want RESULT=$NARGS)"
    [ "$r" = "RESULT=$NARGS" ] || { echo "FAIL-AFTER: the default route lost argv entries" >&2; rc=1; }
    mg="$(midgc_arm)"
    if [ "$mg" = "BUILD_FAILED" ]; then
      echo "FAIL-AFTER: QBE_MIDGC=1 still REFUSES the argv-reading program — the census arm is back (O2 deleted it)" >&2; rc=1
    elif [ "$mg" = "RESULT=$NARGS" ]; then
      echo "QBE_MIDGC=1: COMPILES under the default Mid host and answers $NARGS — the census arm's \`value\` entry is gone, and the argv list survives the Mid churn (MEASURED; see the header for what this does and does not prove)"
    else
      echo "FAIL-AFTER: QBE_MIDGC=1 answered '$mg', want RESULT=$NARGS (the argv list did not survive the Mid churn)" >&2; rc=1
    fi
    [ "$rc" -eq 0 ] && echo "PASS-AFTER: *argv* survives a scavenge inside the build ($NARGS entries), and the MIDGC arm now runs instead of being refused"
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
