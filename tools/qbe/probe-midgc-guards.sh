#!/usr/bin/env bash
# probe-midgc-guards.sh — the two LOUD FAILURES the collector gained (GC ARC F1),
# each with its fail-before arm.
#
# WHY THESE GUARDS.  A collector is where a quiet bug is unrecoverable, and both
# of these were recorded as SHOULD-FIXES on the stage-4 review rather than as
# defects, because neither could be reached from a valid program:
#
#   (1) COLLECT-BEFORE-INIT.  `Rt.collect` used to bind `*Region region =
#       wload(glob, 0)` and dereference it (`region->magic`) with no test for
#       zero.  The loud die the code advertises was unreachable in the NULL case
#       — the SEGV happened first.  Now the region WORD is tested before any
#       dereference and both null shapes die with a message.
#
#   (2) THE MARK-STACK BOUND.  plan.md §2.2 recorded it as a 0.05% MARGIN
#       ("262,144 entries vs 262,007 max blocks at 16 MB") — an assertion.  It
#       is a GEOMETRY THEOREM (see Rt.gcInit's comment): capacity = markEnd - 64,
#       the largest possible block count = (capEnd - heapStart)/64 because the
#       smallest physical block is class 1 = 8 words, and the walk pushes at
#       most one entry per body.  gcInit DERIVES both numbers and dies at init
#       if the stack is smaller than the heap can hold.  GC ARC unit 4 moved
#       both sides to the CEILING (the reserve the heap can grow into), so the
#       margin is a constant 64 entries at every heap: the STRESSOR below is the
#       same halving, and it now halves a stack sized for 8x the heap.
#
# THE ASYMMETRY (both arms mutate runtime.mid, which the compiler reads at RUN
# time, so the arm costs one qbe-mk and no elm rebuild; every mutation is
# restored by the probe's own trap):
#
#   (1) the STRESSOR is `call Rt.collect(mknum(0));` injected at the top of
#       Rt.allocVector — i.e. reach the collector before Rt.gcInit has mapped
#       anything.  PRE-FIX BODY: SEGV (139).  POST-FIX BODY: the loud message,
#       exit 1.  Same stressor, two bodies: the body is the only variable.
#   (2) the STRESSOR is a HALVED mark stack (`capWords / 16` instead of
#       `capWords / 8`).  PRE-FIX BODY (no derived check): the program runs to
#       completion and prints the golden — a SILENT mis-geometry that would only
#       bite a heap whose live set is larger.  POST-FIX BODY: dies AT INIT.
#
# Usage:
#   tools/qbe/probe-midgc-guards.sh          # PASS-AFTER (this tree)
#   tools/qbe/probe-midgc-guards.sh --before # FAIL-BEFORE (both arms)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

MID="osier-compiler/runtime.mid"
FIXTURE="tools/qbe/fixtures/midgc-live.elm"
ENTRY="MidgcLive.main"
GOLDEN=1275
CHURN_MB=16
MSG_PREINIT="qbe-rt: midgc: collect before init (no region mapped)"
MSG_BOUND="qbe-rt: midgc: mark stack smaller than the heap can hold"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/probe-midgc-guards.XXXXXX")" || exit 2
cp "$MID" "$WORK/runtime.mid.orig"
trap 'cp "$WORK/runtime.mid.orig" "$MID"; rm -rf "$WORK"' EXIT

need() { command -v "$1" >/dev/null 2>&1 || { echo "probe-midgc-guards: $1 not found" >&2; exit 2; }; }
need node; need cc

# build + run the fixture under QBE_MIDGC=1 at the minimum heap; print
# "STDOUT||STDERR||EXIT" so an arm can assert on a die or a SEGV.
run_probe() {
  local out
  out="$(mktemp -d "$WORK/run.XXXXXX")"
  QBE_MIDGC=1 "$ROOT/tools/qbe/qbe-mk.sh" "$FIXTURE" "$ENTRY" "$out" >/dev/null 2>&1 \
    || { echo "probe-midgc-guards: qbe-mk failed" >&2; return 1; }
  local so se rc
  so="$(QBE_HEAP_MB=$CHURN_MB "$out/midgc-live" "$ENTRY" 2>"$out/err")"; rc=$?
  se="$(cat "$out/err")"
  printf '%s||%s||%s' "$so" "$se" "$rc"
}

# find where the collector defun starts so the mutations are anchored, and refuse
# if an anchor is missing (a silent no-op mutation would "pass" forever).
mutate() { python3 - "$MID" "$1" <<'PY'
import sys
path, mode = sys.argv[1], sys.argv[2]
s = open(path).read()

def sub(old, new, why):
    global s
    assert s.count(old) == 1, f"anchor not unique ({s.count(old)}): {why}"
    s = s.replace(old, new)

if mode == "stress-preinit":
    # the STRESSOR only: reach the collector before gcInit
    # (perf U3 moved the region fetch into an inline load, so the anchor is the
    # defun's FIRST statement, not the gcInit call — the stressor still lands
    # ahead of every read of the region word, which is what it is for.)
    sub("defun Rt.allocVector(count : val) -> val {\n  word glob = rawcall rt_glob_addr();",
        "defun Rt.allocVector(count : val) -> val {\n  call Rt.collect(mknum(0));\n  word glob = rawcall rt_glob_addr();",
        "allocVector prologue")
elif mode == "halt-mark-stack":
    # the STRESSOR only: a mark stack the heap can outgrow
    sub("    word markEnd = 64 + capWords / 8 + 64;",
        "    word markEnd = 64 + capWords / 16 + 64;",
        "gcInit markEnd")
elif mode == "revert-preinit":
    # the PRE-FIX BODY: dereference the region without testing it for null
    sub('''  word regionW = wload(glob, 0);
  if (mkbool(regionW == 0)) {
    call Rt.die(rawstr("qbe-rt: midgc: collect before init (no region mapped)"));
    return mknil;
  } else {
    *Region region = regionW;''',
        '''  word regionW = wload(glob, 0);
  if (mkbool(0)) {
    return mknil;
  } else {
    *Region region = regionW;''',
        "collect null guard")
elif mode == "revert-bound":
    # the PRE-FIX BODY: no derived capacity check at init
    sub('''      word maxBlocks = (capEnd - heapStart) / 64;
      if (mkbool(markEnd - 64 < maxBlocks)) {
        call Rt.die(rawstr("qbe-rt: midgc: mark stack smaller than the heap can hold"));
        return mknil;
      } else {
        return mknil;
      }
''',
        '''      word maxBlocks = (capEnd - heapStart) / 64;
''',
        "gcInit mark-stack bound check")
else:
    raise SystemExit(f"unknown mutation {mode}")

open(path, "w").write(s)
PY
}

check_preinit_after() {
  local r; r="$(run_probe)" || return 1
  case "$r" in
    *"||$MSG_PREINIT||1") echo "PASS-AFTER (1): collect before init dies loudly: $MSG_PREINIT"; return 0 ;;
    *) echo "FAIL-AFTER (1): want '$MSG_PREINIT' exit 1, got '$r'" >&2; return 1 ;;
  esac
}
check_preinit_before() {
  local r; r="$(run_probe)" || return 1
  case "$r" in
    *"||139") echo "FAIL-BEFORE REPRODUCED (1): the pre-fix body SEGVs (exit 139) instead of dying loudly"; return 0 ;;
    *) echo "FAIL-BEFORE NOT REPRODUCED (1): want a SEGV (exit 139), got '$r'" >&2; return 1 ;;
  esac
}
check_bound_after() {
  local r; r="$(run_probe)" || return 1
  case "$r" in
    *"||$MSG_BOUND||1") echo "PASS-AFTER (2): a mark stack smaller than the heap can hold dies AT INIT: $MSG_BOUND"; return 0 ;;
    *) echo "FAIL-AFTER (2): want '$MSG_BOUND' exit 1, got '$r'" >&2; return 1 ;;
  esac
}
check_bound_before() {
  local r; r="$(run_probe)" || return 1
  case "$r" in
    "$GOLDEN||"*) echo "FAIL-BEFORE REPRODUCED (2): with no derived check the halved mark stack runs to completion ($GOLDEN) — the mis-geometry is SILENT"; return 0 ;;
    *) echo "FAIL-BEFORE NOT REPRODUCED (2): want a silent '$GOLDEN', got '$r'" >&2; return 1 ;;
  esac
}

case "${1:-}" in
  "")
    mutate stress-preinit || exit 1
    check_preinit_after || { cp "$WORK/runtime.mid.orig" "$MID"; exit 1; }
    cp "$WORK/runtime.mid.orig" "$MID"; mutate halt-mark-stack || exit 1
    check_bound_after || { cp "$WORK/runtime.mid.orig" "$MID"; exit 1; }
    cp "$WORK/runtime.mid.orig" "$MID"
    echo "PASS-AFTER: both guards fire on their stressor; the unmutated tree is restored"
    ;;
  --before)
    mutate stress-preinit || exit 1
    mutate revert-preinit || exit 1
    check_preinit_before || { cp "$WORK/runtime.mid.orig" "$MID"; exit 1; }
    cp "$WORK/runtime.mid.orig" "$MID"
    mutate halt-mark-stack || exit 1
    mutate revert-bound || exit 1
    check_bound_before || { cp "$WORK/runtime.mid.orig" "$MID"; exit 1; }
    cp "$WORK/runtime.mid.orig" "$MID"
    echo "FAIL-BEFORE: both pre-fix bodies are silent (SEGV / wrong-but-quiet geometry); tree restored"
    ;;
  *)
    echo "usage: tools/qbe/probe-midgc-guards.sh [--before]" >&2
    exit 2
    ;;
esac
