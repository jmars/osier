#!/usr/bin/env bash
# probe-midgc-argvtab.sh — THE VALUES TABLE IS A ROOT (ZIGHOST Z1's found hole).
#
# THE HOLE.  The values table (the host's 256 x 48-byte {name, Value} array,
# base in globals word 3) holds `*argv*` — a MID-heap cons chain built by
# Rt.argvInstall — plus the three standard streams.  It was registered with the
# ZIG collector only (`Vm.init` -> gc.registerValuesTable), and since ZIGHOST
# Z0 retired the Zig heap that registration marks nothing: Rt.gcMarkRoots /
# Rt.gcScavRoots walked the shadow stack and the values table was in NO Mid
# root set at all.  Any full collect between boot and the read reclaimed the
# argv chain.
#
# WHY THE EXISTING argv PROBE PASSES.  probe-midgc-argv.sh reads *argv* ONCE,
# and its 60000-entry list is promoted by the scavenges inside the build and
# read before any full collect fires — it passes by PROMOTION AND TIMING, not
# by being rooted.  That is exactly the class of pass this probe replaces with
# an asymmetry.
#
# THE INSTRUMENT.  tools/qbe/fixtures/argvroot.elm reads *argv* TWICE with
# ~19 MB of cons-cell churn between the reads (scavenges AND full collects at
# QBE_HEAP_MB=16) and prints `a * 1000000 + b`.  The accumulator is a rooted
# frame slot; the only unrooted object in the program is the one under test.
#
#   * PASS-AFTER (this tree): Rt.gcMarkValuesTab / Rt.gcScavValuesTab walk the
#     table (48-byte stride, live = a nonzero name word), so both reads see the
#     same live chain and the answer is GOLDEN.
#   * FAIL-BEFORE: two lines deleted — the two `call Rt.gcMarkValuesTab(0)` /
#     `call Rt.gcScavValuesTab(0)` sites in Rt.collect / Rt.gcScavenge, i.e.
#     exactly the state of the tree before Z1.  MEASURED on this tree: the
#     second read walks a reclaimed (and by then re-used) block and the run
#     dies BARE SIGSEGV — rc 139, no output at all.  The arm accepts any
#     non-golden outcome (a wrong number is the other way the same bug shows:
#     the block is re-issued by the churn, so what the walk reads is whatever
#     the free list handed out).
#
# Both arms run the SAME source, the same args and the same heap: only the two
# walk calls differ, so the asymmetry is the walk and nothing else.
#
# Usage:
#   tools/qbe/probe-midgc-argvtab.sh            # PASS-AFTER
#   tools/qbe/probe-midgc-argvtab.sh --before    # FAIL-BEFORE (edits runtime.mid
#                                               # under a trap; rt.o is untouched)
# Exit: 0 = the arm behaved as stated, 1 = it did not, 2 = tooling.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

RUNTIME="elm-compiler/runtime.mid"
FIXTURE="tools/qbe/fixtures/argvroot.elm"
ENTRY="ArgvRoot.probe"
NARGS=200
HEAP_MB=16
WORK="$(mktemp -d "${TMPDIR:-/tmp}/probe-midgc-argvtab.XXXXXX")" || exit 2
cp "$RUNTIME" "$WORK/runtime.mid.orig"
trap 'cp "$WORK/runtime.mid.orig" "$RUNTIME"; rm -rf "$WORK"' EXIT

need() { command -v "$1" >/dev/null 2>&1 || { echo "probe-midgc-argvtab: $1 not found" >&2; exit 2; }; }
need node; need cc; need python3

python3 -c "print(' '.join('a' * 12 + str(i) for i in range($NARGS)))" > "$WORK/args.txt"

# The golden is DERIVED, not measured from a run: `a * 1000000 + b` with both
# reads counting the same N-element list.
GOLDEN=$(( NARGS * 1000000 + NARGS ))

mutate_before() {
  python3 - "$RUNTIME" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
for old in ("      call Rt.gcMarkValuesTab(mknum(0));\n",
            "  call Rt.gcScavValuesTab(mknum(0));\n"):
    assert s.count(old) == 1, "the walk call is not where the probe expects: %r" % old
    s = s.replace(old, "")
open(p, "w").write(s)
PY
}

run_arm() {
  local out r rc
  out="$(mktemp -d "$WORK/b.XXXXXX")"
  "$ROOT/tools/qbe/qbe-mk.sh" "$FIXTURE" "$ENTRY" "$out" >/dev/null 2>&1 \
    || { echo "RESULT=build-failed"; return 0; }
  # AOTRUN_ARGV=1 is what makes *argv* the plain cons list of ALL args (without
  # it Rt.main treats the tail as ENTRY args and refuses more than 16).
  r="$(env AOTRUN_ARGV=1 QBE_HEAP_MB=$HEAP_MB "$out/argvroot" "$ENTRY" $(cat "$WORK/args.txt") 2>&1)"
  rc=$?
  echo "RESULT=$r RC=$rc"
}

rc=0
case "${1:-}" in
  "")
    r="$(run_arm)"
    echo "the Mid route: $r (want RESULT=$GOLDEN RC=0)"
    if [ "$r" = "RESULT=$GOLDEN RC=0" ]; then
      echo "PASS-AFTER: *argv* survives a churn of full collects AND scavenges between the two reads ($NARGS entries, twice)"
    else
      echo "FAIL-AFTER: the values table's root walk lost argv entries" >&2
      rc=1
    fi
    ;;
  --before)
    mutate_before || exit 1
    r="$(run_arm)"
    echo "the Mid route without the two walk calls: $r (want anything but RESULT=$GOLDEN RC=0)"
    if [ "$r" = "RESULT=$GOLDEN RC=0" ]; then
      echo "FAIL-BEFORE NOT REPRODUCED: the answer is the golden with NO values-table walk — the fixture does not prove the walk is load-bearing" >&2
      rc=1
    else
      echo "FAIL-BEFORE REPRODUCED: without the values-table walk the second read of *argv* sees reclaimed memory"
    fi
    ;;
  *)
    echo "usage: tools/qbe/probe-midgc-argvtab.sh [--before]" >&2
    exit 2
    ;;
esac
exit "$rc"
