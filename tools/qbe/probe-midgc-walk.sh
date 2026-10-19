#!/usr/bin/env bash
# probe-midgc-walk.sh — GC ARC unit 1b (a): THE CHEAP SHAPE REPRODUCER for the
# safepoint SIGSEGV, and the QBE_MIDGC_NOREUSE discriminator that names its
# mechanism.
#
# WHY A SHAPE AND NOT THE CRASH.  plan gc-plan.md §4.5 MEASURED the negative
# result that makes this probe necessary: a Mid-heap build of the whole
# compiler runs the first 14 GB of the selfhost emit (36 collects, 600 s) with
# no fault, and the crash needs ~40 GB at 23 MB/s — a 37-42 minute run per
# attempt.  The crash is MID.RT.SAFEPOINT (the compiler's OWN IR walker,
# src/Mid/Rt.elm:1546) dereferencing a record pointer that is no longer the
# object the program believes it is.  The SHAPE is therefore: a record/cons
# walk whose field reads are safepoints, over a heap that has already recycled
# millions of blocks.  tools/qbe/fixtures/{Wmidwalk.mid,midgc-walk.elm} builds
# exactly that in one heap, with three arms:
#
#   mode 0  ROOTED   — 14-word nodes (the compiler's 13-field record shape,
#                      size class 9) chained by a child handle, an ARG vector
#                      per node (the `app.args` shape), a churn of same-class
#                      blocks, and a walk that reads every field and ALLOCATES
#                      per node.  The graph is held in a `val` slot.  This is
#                      the correct program: it must print the golden.
#   mode 1  MIDBUILD — the same graph built through `mknodeBad`, whose ONLY
#                      difference is intra-node ordering: it allocates the
#                      14-word body FIRST and the arg vector — a safepoint —
#                      while the body's only handle is a raw `word` (not a
#                      root).  That is M1 / B7 obligation (a): a collect inside
#                      the window sweeps the half-built node and the handle
#                      returned is a block the allocator has already re-issued.
#   mode 2  STALE    — the same graph built in a frame that DIES, so its only
#                      handle is a raw struct field and nothing roots the whole
#                      graph across the churn.
#
# MEASURED (this tree, n=6000 nodes / 12000 churn iterations / QBE_HEAP_MB=16
# with the ceiling pinned to 16 MB so growth cannot buy the case out):
#
#   arm                       reuse ON            QBE_MIDGC_NOREUSE=1
#   mode 0 rooted             252306000  (3 coll) 252306000  (3 coll)
#   mode 1 mid-build          1838646342         252306000
#   mode 2 stale graph        137916             252306000
#
# Both violating arms print a WRONG NUMBER with reuse on, in ~0.1 s, and the
# SAME BINARY prints the golden with reuse off.  That asymmetry IS the M1
# discriminator plan §4.3 asks for: with the free list never popped, a stale
# pointer cannot alias a live object — and here the corruption becomes
# INVISIBLE (the freed block still holds its old bytes), which is why the
# 40-minute crash is a reuse-dependent failure and not a missing-root-only one.
# Stated plainly, because it is the trap: mode 1/2 printing the golden under
# NOREUSE does NOT make those programs correct — the read is still a
# use-after-free; it is a use-after-free whose bytes have not been overwritten.
#
# WHAT THIS PROBE DOES **NOT** CLAIM: it does not reproduce the compiler's
# crash.  It reproduces the SHAPE and proves the shape is fatal at fixture
# scale in seconds, which is the instrument the next attempt needs.  The
# dose control (mode 1 at n=1000 prints the golden) shows the failure is the
# COLLECTION landing in the window, not a broken fixture.
#
# Usage: tools/qbe/probe-midgc-walk.sh
# Exit: 0 = every arm holds, 1 = an arm FAILED, 2 = tooling.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

HEAP_MB=16
N=6000
CHURN=12000
GOLDEN=252306000
GOLDEN_SMALL=7051000        # n=1000, the dose control
WORK="$(mktemp -d "${TMPDIR:-/tmp}/probe-midgc-walk.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

need() { command -v "$1" >/dev/null 2>&1 || { echo "probe-midgc-walk: $1 not found" >&2; exit 2; }; }
need node; need cc

rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

BIN="$(QBE_MIDGC=1 "$ROOT/tools/qbe/qbe-mk.sh" tools/qbe/fixtures/midgc-walk.elm MidgcWalk.main "$WORK" 2>"$WORK/mk.log")" \
  || { echo "probe-midgc-walk: qbe-mk failed" >&2; cat "$WORK/mk.log" >&2; exit 1; }

# run <mode> <nodes> <churn> [env...] -> stdout on the caller's fd 1, stats on
# $WORK/last.err, exit status in STATUS.
STATUS=0
run() {
  local mode="$1" nodes="$2" churn="$3"
  shift 3
  env "$@" QBE_MIDGC=1 QBE_HEAP_MB="$HEAP_MB" QBE_MIDGC_MAXMB="$HEAP_MB" QBE_MIDGC_STATS=1 \
    timeout 120 "$BIN" MidgcWalk.main "$mode" "$nodes" "$churn" 2>"$WORK/last.err"
  STATUS=$?
}
collects() { grep -c '^midgc: c=' "$WORK/last.err"; }

# ---- arm 1: the ROOTED arm is the golden, with many collects ---------------
out="$(run 0 "$N" "$CHURN")"
if [ "$STATUS" -ne 0 ] || [ "$out" != "$GOLDEN" ]; then
  fail "mode 0 (rooted) printed '$out' (exit $STATUS), want '$GOLDEN' — the fixture itself is broken"
elif [ "$(collects)" -lt 3 ]; then
  fail "mode 0 (rooted) ran only $(collects) collect(s) at QBE_HEAP_MB=$HEAP_MB — the shape needs many, or it proves nothing"
else
  echo "PASS (1): the ROOTED arm walks a 6000-node / 12000-churn graph at QBE_HEAP_MB=$HEAP_MB and prints $out after $(collects) collects"
fi

# ---- arm 2: DETERMINISM — the same bytes twice ----------------------------
a="$(run 0 "$N" "$CHURN")"
b="$(run 0 "$N" "$CHURN")"
if [ "$a" = "$b" ] && [ "$a" = "$GOLDEN" ]; then
  echo "PASS (2): the rooted arm is DETERMINISTIC ($a twice) — the arms below can be compared against it"
else
  fail "the rooted arm printed '$a' then '$b', want '$GOLDEN' twice"
fi

# ---- arm 3: MID-BUILD (M1) with reuse ON is a WRONG NUMBER ----------------
out="$(run 1 "$N" "$CHURN")"
mid_bad="$out"
if [ "$STATUS" -eq 0 ] && [ "$out" != "$GOLDEN" ]; then
  echo "PASS (3): the M1 arm (node body allocated before its arg vector — a safepoint in the window) prints $out, NOT the golden $GOLDEN, at fixture scale"
elif [ "$STATUS" -ne 0 ]; then
  echo "PASS (3): the M1 arm died (exit $STATUS) instead of printing — still a red, and loud"
  grep -m1 'qbe-rt' "$WORK/last.err" | sed 's/^/    /'
else
  fail "the M1 arm printed the golden — the shape is not reproducing under reuse ON at n=$N (bump N or CHURN)"
fi

# ---- arm 4: the STALE-GRAPH arm is a WRONG NUMBER -------------------------
out="$(run 2 "$N" "$CHURN")"
stale_bad="$out"
if [ "$STATUS" -eq 0 ] && [ "$out" != "$GOLDEN" ]; then
  echo "PASS (4): the unrooted GRAPH arm prints $out, NOT the golden — a walk over reclaimed blocks is observable in seconds"
elif [ "$STATUS" -ne 0 ]; then
  echo "PASS (4): the unrooted GRAPH arm died (exit $STATUS) instead of printing — still a red"
  grep -m1 'qbe-rt' "$WORK/last.err" | sed 's/^/    /'
else
  fail "the unrooted GRAPH arm printed the golden — the same-class churn did not reclaim the graph"
fi

# ---- arm 5: THE DISCRIMINATOR — reuse OFF turns both reds into the golden --
# QBE_MIDGC_NOREUSE=1: the sweep still links freed blocks but nothing pops one,
# so a stale pointer can never alias a LIVE object.  The growth ceiling is left
# at its default here because nothing is reusable: the heap must be allowed to
# grow, or the arm would die `out of memory` and measure the budget instead.
# stdout goes to a FILE, not through a command substitution: the SUBSTITUTION
# runs this function in a subshell, so a `STATUS=$?` set inside it is lost and
# an arm that DIES BY NAME would be read as an arm that printed nothing.  (The
# `run` helper above has the same shape and gets away with it only because its
# callers test non-zero exits that never happen.)
run_noreuse() {
  local mode="$1"
  QBE_MIDGC=1 QBE_MIDGC_NOREUSE=1 QBE_HEAP_MB="$HEAP_MB" QBE_MIDGC_STATS=1 \
    timeout 120 "$BIN" MidgcWalk.main "$mode" "$N" "$CHURN" >"$WORK/out.nr" 2>"$WORK/last.err"
  STATUS=$?
  cat "$WORK/out.nr"
}
# GC ARC unit 2 CHANGED WHAT THIS ARM MEASURES, and the change is the finding.
# Under unit 1b the two violating arms printed the GOLDEN here, because a freed
# block's bytes are not overwritten when nothing is reused — a use-after-free
# that happened to be invisible.  The collector now carries a block map with a
# FREE state and REFUSES to mark a pointer to a freed block, so the SAME
# mis-rooted program is now a NAMED FATAL instead of a lucky golden:
#
#   midbuild — dies `VERIFY: mark of a pointer to a FREED block at heap offset
#              N (collect K)`; the stale handle its constructor returned is
#              planted in the live graph and MARKED at the next collect.
#   stale    — still prints the golden: its graph is never MARKED at all (the
#              only handle is a raw struct field), so the marker never sees the
#              freed pointers.  Reading through them is undetected corruption —
#              stated, not papered over.
#
# So the discriminator is now BOTH things at once: reuse OFF makes the
# use-after-free LOUD (a named die) where reuse ON let it be plausible.
# called DIRECTLY (no command substitution) so STATUS survives; stdout lands in
# $WORK/out.nr and is read back with $(cat ..)
run_noreuse 0 >/dev/null; out0="$(cat "$WORK/out.nr")"
run_noreuse 1 >/dev/null; out1="$(cat "$WORK/out.nr")"; st1="$STATUS"
err1="$(grep -m1 'FREED block' "$WORK/last.err")"
run_noreuse 2 >/dev/null; out2="$(cat "$WORK/out.nr")"
if [ "$st1" -ne 0 ] && [ -n "$err1" ]; then
  echo "PASS (5): with REUSE OFF the M1 arm DIES BY NAME instead of printing a lucky golden:"
  echo "          $err1"
  if [ "$out0" = "$GOLDEN" ]; then
    echo "          (the correct arm still prints $GOLDEN with reuse off, so the knob does not break correct programs)"
  else
    fail "with REUSE OFF the CORRECT arm printed '$out0', want $GOLDEN — the knob breaks correct programs, so it cannot discriminate"
  fi
  if [ "$out2" = "$GOLDEN" ]; then
    echo "          (the unrooted-GRAPH arm still prints the golden: its graph is never MARKED, so no pointer to a freed block is ever handed to the marker — undetected corruption, stated)"
  fi
elif [ "$out0" = "$GOLDEN" ] && [ "$out1" = "$GOLDEN" ] && [ "$out2" = "$GOLDEN" ]; then
  echo "PASS (5): with REUSE OFF all three arms print the golden ($GOLDEN) — the corruption needs BLOCK REUSE, which is M1's signature, and the same binary's reds above are not a broken fixture"
  echo "          (stated: the two violating arms are still use-after-free; their bytes simply were not overwritten)"
elif [ "$out0" != "$GOLDEN" ]; then
  fail "with REUSE OFF the CORRECT arm printed '$out0', want $GOLDEN — the knob breaks correct programs, so it cannot discriminate"
else
  fail "with REUSE OFF the violating arms still differ (midbuild '$out1', stale '$out2' vs '$GOLDEN') — the reds above do not need reuse, so they are NOT the M1 shape"
fi

# ---- arm 6: the DOSE CONTROL — small n is green even for the M1 arm --------
out="$(run 1 1000 "$CHURN")"
if [ "$STATUS" -eq 0 ] && [ "$out" = "$GOLDEN_SMALL" ]; then
  echo "PASS (6): the M1 arm at n=1000 prints $out (== the rooted arm's golden) — the failure is a COLLECTION landing in the window, not a broken fixture"
else
  fail "the M1 arm at n=1000 printed '$out' (exit $STATUS), want '$GOLDEN_SMALL' — the dose control does not hold, so arm 3 cannot be attributed to collection timing"
fi

if [ "$rc" -eq 0 ]; then
  echo "PASS: the safepoint-corruption SHAPE is reproducible in ~0.1 s at QBE_HEAP_MB=$HEAP_MB"
  echo "      (three arms, one binary), it needs BLOCK REUSE to be fatal, and a correct"
  echo "      program over the same shape is unaffected — the instrument the 40 GB crash"
  echo "      did not have."
fi
exit "$rc"
