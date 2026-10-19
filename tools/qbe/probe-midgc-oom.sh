#!/usr/bin/env bash
# probe-midgc-oom.sh — the SCRIPTED fail-before / pass-after probe for the
# perf-gc1 follow-up CLASS-TABLE BOUND (the review's should-fix: an
# out-of-range class index in the Mid collector's free-list table).
#
# THE DEFECT.  Rt.gcAlloc computes cls = classOf(total) for ANY requested size,
# and Rt.gcAllocGo (elm-compiler/runtime.mid) indexed the per-class free-list
# table with it and no bounds check.  The table has
# numClasses = 1 + classOf(heapWords) entries, so a single request LARGER than
# the heap (the fixture's 2097502-word vector on a 16 MB heap) yields
# cls >= numClasses and the load/store lands PAST the table — a live block's
# header/body: silent corruption in the general case, a crash when that word is
# a small block header.  Not a clean die.
#
# THE ASYMMETRY.  tools/qbe/fixtures/midgc-oom.elm makes exactly that request
# (its header carries the arithmetic: total 2097502 words > the 16 MB heap's
# 2097152-word capacity; classOf(total) = 1024 = numClasses).
#
#   * PASS-AFTER (this tree): Rt.gcAllocGo returns 0 for cls >= numClasses, so
#     the request funnels into Rt.gcAlloc's bump path, which cannot satisfy it —
#     and the run dies LOUDLY at the CEILING (GC ARC unit 4 added heap growth,
#     so the arm that pins this die pins the ceiling TOO: QBE_MIDGC_MAXMB=16
#     makes the ceiling the initial heap, reproducing the pre-growth geometry
#     class 1024 == numClasses 1024 exactly).  The output is the ceiling line
#     plus the same `qbe-rt: midgc: out of memory` token, exit 1.  The CONTROL
#     arm reruns the same binary at QBE_HEAP_MB=32/QBE_MIDGC_MAXMB=32, where the
#     same request fits (class 1024 < numClasses 1537) and prints 200: the die
#     is caused by the request EXCEEDING the ceiling, not by its size as such,
#     and the guard does not refuse a request that fits.
#   * THE GROWTH ARM (unit 4): at QBE_HEAP_MB=16 with the DEFAULT ceiling the
#     SAME request grows the heap (16 -> 32 MB, reported on the stats line) and
#     prints 200 — the same block the pre-growth tree refused outright.
#   * FAIL-BEFORE: without the guard (the 4c71924 body) the same run SIGSEGVs
#     (exit 139) — table[numClasses] is the heap's first block FLAGS word, a
#     small nonzero, which the pop arm dereferences as a pointer.  The control
#     arm still prints 200, so the misbehaviour is attributable to the OOB
#     index and not to a broken revert.
#
# Usage:
#   tools/qbe/probe-midgc-oom.sh          # PASS-AFTER (current tree)
#   tools/qbe/probe-midgc-oom.sh --before # FAIL-BEFORE: drop the guard, run,
#                                         # RESTORE (trapped)
#
# The --before arm restores runtime.mid under a trap, so even a failed run
# never leaves the tree edited.  NO REBUILD is needed on either arm: run.js
# reads elm-compiler/runtime.mid at compile time (elm-compiler/run.js:55) and
# compiles it into the .ssa inside qbe-mk, so the file swap alone decides the
# arm — compiler.js and rt.o are untouched (runtime.mid is Mid source, not a
# Zig module).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

RUNTIME="elm-compiler/runtime.mid"
FIXTURE="tools/qbe/fixtures/midgc-oom.elm"
ENTRY="MidgcOom.main"
GOLDEN=200
OOM="qbe-rt: midgc: out of memory"
# 16 MB is the minimum heap the other MidGC probes run at; the fixture's class
# arithmetic is derived for it (numClasses 1024 at a 16 MB ceiling) and
# rechecked by the control arm at 32 MB.  The ceiling is pinned to the initial
# heap on both arms so the geometry is the pre-growth one (unit 4's default
# ceiling would GROW this heap instead of dying — that is the growth arm below).
CHURN_MB=16
CEIL_MB=16
CONTROL_MB=32

# The defun body WITH the fix, and the same body at 4c71924 without it.  The
# `clsW >= n` guard text occurs nowhere else in runtime.mid, so the swap cannot
# hit another site; each direction asserts exactly one occurrence.
# STALE ANCHORS FIXED (GC ARC unit 4, found while pinning the ceiling): both
# bodies were spelled with the PRE-U5 `wload(regionW, 8|9|12)` word offsets, so
# after the struct re-spelling the `--before` arm's `assert s.count(old) == 1`
# could never match — the fail-before arm was silently unrunnable (the default
# invocation never caught it).  They are now the struct-field spelling the file
# actually carries.
AFTER_BODY=$'  word clsW = payload(cls, 0);\n  word n = regionW->numClass;\n  if (mkbool(clsW >= n)) {\n    return mknum(0);\n  } else {\n    word head = wload(table, clsW);\n    if (mkbool(head == 0)) {\n      return mknum(0);\n    } else {\n      word kind = regionW->kind;\n      word count = regionW->count;\n      wstore(table, clsW, wload(head, 0));\n      wstore(head, -2, kind * 2 + clsW * 4);\n      wstore(head, -1, count);\n      return mknum(head);\n    }\n  }'
BEFORE_BODY=$'  word clsW = payload(cls, 0);\n  word head = wload(table, clsW);\n  if (mkbool(head == 0)) {\n    return mknum(0);\n  } else {\n    word kind = regionW->kind;\n    word count = regionW->count;\n    wstore(table, clsW, wload(head, 0));\n    wstore(head, -2, kind * 2 + clsW * 4);\n    wstore(head, -1, count);\n    return mknum(head);\n  }'

need() { command -v "$1" >/dev/null 2>&1 || { echo "probe-midgc-oom: $1 not found" >&2; exit 2; }; }

swap() { # $1 = body to find (exactly one), $2 = body to write
  python3 - "$RUNTIME" "$1" "$2" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
assert s.count(old) == 1, f"expected exactly one occurrence of the body, found {s.count(old)}"
open(path, "w").write(s.replace(old, new))
PY
}

WORKDIR=""
BIN=""
STATUS=0
RUN_OUT=""

build() {
  BIN="$(QBE_MIDGC=1 "$ROOT/tools/qbe/qbe-mk.sh" "$FIXTURE" "$ENTRY" "$WORKDIR" 2>/dev/null)" \
    || { echo "probe-midgc-oom: qbe-mk (QBE_MIDGC=1) failed" >&2; exit 1; }
}

# run at $1 MB of heap with the ceiling pinned to $2 MB (empty = the default
# rule); sets RUN_OUT and STATUS (the run's own exit status, 139 = SIGSEGV).
run_at() {
  STATUS=0
  RUN_OUT="$(QBE_MIDGC=1 QBE_HEAP_MB="$1" QBE_MIDGC_MAXMB="$2" timeout 60 "$BIN" "$ENTRY" 2>&1)" || STATUS=$?
}

# the loud ceiling die: the ceiling line (with its two numbers) AND the
# unchanged `midgc: out of memory` token, as the LAST line.
CEIL_MSG="qbe-rt: midgc: out of memory: heap at its ceiling of $CEIL_MB MB (initial $CHURN_MB MB)
qbe-rt: midgc: out of memory"

case "${1:-}" in
  "")
    need node; need cc; need python3
    WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/probe-midgc-oom.XXXXXX")"
    trap 'rm -rf "$WORKDIR"' EXIT
    build

    run_at "$CHURN_MB" "$CEIL_MB"
    if [ "$STATUS" = 1 ] && [ "$RUN_OUT" = "$CEIL_MSG" ]; then
      echo "PASS-AFTER: an over-ceiling single request (419840 vector slots > a 16 MB ceiling) dies loudly (exit 1):"
      printf '%s\n' "$RUN_OUT" | sed 's/^/    /'
    else
      echo "FAIL-AFTER: the over-ceiling request exited $STATUS with '$RUN_OUT', want the loud ceiling die (exit 1, '$CEIL_MSG') — the class-table/ceiling bound is missing" >&2
      exit 1
    fi

    run_at "$CHURN_MB" ""
    if [ "$STATUS" = 0 ] && [ "$RUN_OUT" = "$GOLDEN" ]; then
      echo "PASS-AFTER (growth): the SAME request at QBE_HEAP_MB=$CHURN_MB with the DEFAULT ceiling grows the heap and prints $RUN_OUT (== $GOLDEN) — the block the pre-growth tree refused"
    else
      echo "FAIL-AFTER (growth): the default-ceiling arm at QBE_HEAP_MB=$CHURN_MB exited $STATUS with '$RUN_OUT', want '$GOLDEN' — the growth step did not satisfy a request the ceiling allows" >&2
      exit 1
    fi

    run_at "$CONTROL_MB" "$CONTROL_MB"
    if [ "$STATUS" = 0 ] && [ "$RUN_OUT" = "$GOLDEN" ]; then
      echo "PASS-AFTER: the SAME request at QBE_HEAP_MB=$CONTROL_MB/QBE_MIDGC_MAXMB=$CONTROL_MB (where it fits) prints $RUN_OUT (== $GOLDEN) — the die is heap pressure, not request size"
      exit 0
    else
      echo "FAIL-AFTER: the control at QBE_HEAP_MB=$CONTROL_MB exited $STATUS with '$RUN_OUT', want '$GOLDEN' — the guard refuses a request that fits, or the fixture is broken" >&2
      exit 1
    fi
    ;;
  --before)
    need node; need cc; need python3
    WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/probe-midgc-oom.XXXXXX")"
    swap "$AFTER_BODY" "$BEFORE_BODY"
    trap 'rm -rf "$WORKDIR"; swap "$BEFORE_BODY" "$AFTER_BODY"' EXIT
    build

    run_at "$CHURN_MB" "$CEIL_MB"
    if [ "$STATUS" = 1 ] && [ "$RUN_OUT" = "$CEIL_MSG" ]; then
      echo "FAIL-BEFORE NOT REPRODUCED: without the guard the over-heap request still dies at the ceiling (exit 1) — the probe does not pin the out-of-range class index (re-derive the fixture's class arithmetic for this ceiling)" >&2
      exit 1
    fi
    if [ "$STATUS" -ge 128 ]; then
      echo "FAIL-BEFORE REPRODUCED: without the guard the over-heap request dies by signal $((STATUS - 128)) (exit $STATUS, '$RUN_OUT') instead of the loud OOM die — the class index walks past the free-list table"
    else
      echo "FAIL-BEFORE NOT REPRODUCED: the run exited $STATUS with '$RUN_OUT', want a signal death (exit >= 128) — the probe does not pin the mechanism" >&2
      exit 1
    fi

    run_at "$CONTROL_MB" "$CONTROL_MB"
    if [ "$STATUS" = 0 ] && [ "$RUN_OUT" = "$GOLDEN" ]; then
      echo "FAIL-BEFORE ATTRIBUTABLE: the reverted tree still prints $RUN_OUT (== $GOLDEN) at QBE_HEAP_MB=$CONTROL_MB, so the signal death is the OOB index, not a broken revert"
      exit 0
    else
      echo "FAIL-BEFORE UNATTRIBUTABLE: the reverted tree's control at QBE_HEAP_MB=$CONTROL_MB exited $STATUS with '$RUN_OUT', want '$GOLDEN'" >&2
      exit 1
    fi
    ;;
  *)
    echo "usage: tools/qbe/probe-midgc-oom.sh [--before]" >&2
    exit 2
    ;;
esac
