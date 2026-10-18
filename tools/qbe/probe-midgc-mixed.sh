#!/usr/bin/env bash
# probe-midgc-mixed.sh — the SCRIPTED fail-before / pass-after probe for the
# perf-gc1 SIZE-CLASS free list (plan.md §2.2, stage-4 review finding 3).
#
# THE ASYMMETRY.  tools/qbe/fixtures/midgc-mixed.elm allocates a MIX of sizes
# (S2/S3/S4 Con vectors interleaved in `keep`, plus 13-field churn records and
# 14-field live records), churns the 13-field records so their blocks must be
# recycled, and asserts a sum.  The churn's 67-word records and the live list's
# 72-word records are DIFFERENT exact sizes that round to the SAME size class
# (class 9, 72 words).
#
#   * PASS-AFTER (this tree): Rt.gcAllocGo pops the per-class free list, so the
#     live 14-field list recycles the churn's freed class-9 blocks -> 220555350.
#   * FAIL-BEFORE: the stage-4 exact-match free list (`2 + (fcount +
#     4*fcount*fkind) == total`) cannot recycle a 67-word block for a 72-word
#     request, so the live list bumps past the free list and dies
#     `qbe-rt: midgc: out of memory` with ~12 MB of freed blocks available.
#
# The --before arm reverts the whole perf-gc1 unit (the allocator, the region
# layout, the seat list, the seeds and the TestMain pins — the four files the
# unit changes; the header/layout and the allocator move together, so a
# one-file revert would not link) to the fix's PARENT commit 08e994d, rebuilds,
# runs, and RESTORES under a trap.  The parent SHA is named explicitly so the
# revert reproduces the pre-fix allocator no matter what later commits sit on
# top of this one.
#
# Usage:
#   tools/qbe/probe-midgc-mixed.sh          # PASS-AFTER (current tree)
#   tools/qbe/probe-midgc-mixed.sh --before # FAIL-BEFORE: revert to 08e994d,
#                                           # rebuild, run, RESTORE (trapped)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

FIXTURE="tools/qbe/fixtures/midgc-mixed.elm"
ENTRY="MidgcMixed.main"
GOLDEN=220555350
FAIL_BEFORE="qbe-rt: midgc: out of memory"
CHURN_MB=16
ELM_BIN="${ELM_BIN:-$HOME/.npm-global/lib/node_modules/elm/bin/elm}"
# The commit this unit is built on: its runtime.mid/RtGc.elm/Rt.elm/TestMain.elm
# are the pre-fix allocator the --before arm reverts to.
BASE_SHA=08e994d

FILES="elm-compiler/runtime.mid elm-compiler/src/Mid/RtGc.elm elm-compiler/src/Mid/Rt.elm elm-compiler/src/TestMain.elm"

need() { command -v "$1" >/dev/null 2>&1 || { echo "probe-midgc-mixed: $1 not found" >&2; exit 2; }; }

rebuild() {
  (cd "$ROOT/elm-compiler" && ELM_HOME="$PWD/.elm-cache" "$ELM_BIN" make src/Main.elm --output=compiler.js >/dev/null) \
    || { echo "probe-midgc-mixed: elm make compiler.js failed" >&2; exit 1; }
}

# build + run the fixture under QBE_MIDGC=1 at the minimum heap; print stdout+stderr.
run_probe() {
  local out
  out="$(mktemp -d "${TMPDIR:-/tmp}/probe-midgc-mixed.XXXXXX")"
  trap 'rm -rf "$out"' RETURN
  QBE_MIDGC=1 "$ROOT/tools/qbe/qbe-mk.sh" "$FIXTURE" "$ENTRY" "$out" >/dev/null 2>&1 \
    || { echo "probe-midgc-mixed: qbe-mk failed" >&2; exit 1; }
  QBE_HEAP_MB=$CHURN_MB timeout 120 "$out/midgc-mixed" "$ENTRY" 2>&1
}

case "${1:-}" in
  "")
    need node; need cc
    rebuild
    out="$(run_probe || true)"
    if [ "$out" = "$GOLDEN" ]; then
      echo "PASS-AFTER: midgc-mixed under QBE_MIDGC=1 QBE_HEAP_MB=$CHURN_MB prints $out (== $GOLDEN)"
      exit 0
    else
      echo "FAIL-AFTER: midgc-mixed printed '$out', want '$GOLDEN' — the size-class free list is not recycling" >&2
      exit 1
    fi
    ;;
  --before)
    need node; need cc
    git cat-file -e "$BASE_SHA^{commit}" 2>/dev/null \
      || { echo "probe-midgc-mixed: base commit $BASE_SHA not present" >&2; exit 2; }
    # Back up the unit's four files, then swap in the pre-fix versions.
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/probe-midgc-mixed-before.XXXXXX")"
    for f in $FILES; do
      mkdir -p "$tmp/$(dirname "$f")"
      cp "$f" "$tmp/$f"
      git show "$BASE_SHA:$f" > "$f"
    done
    restore() {
      for f in $FILES; do
        cp "$tmp/$f" "$f"
      done
      rm -rf "$tmp"
      (cd "$ROOT/elm-compiler" && ELM_HOME="$PWD/.elm-cache" "$ELM_BIN" make src/Main.elm --output=compiler.js >/dev/null) || true
    }
    trap restore EXIT
    rebuild
    out="$(run_probe || true)"
    if [ "$out" = "$FAIL_BEFORE" ]; then
      echo "FAIL-BEFORE REPRODUCED: midgc-mixed printed '$out' (== '$FAIL_BEFORE') with the exact-match free list (67-word blocks unusable for the 72-word live list)"
      exit 0
    else
      echo "FAIL-BEFORE NOT REPRODUCED: printed '$out', want the exact signature '$FAIL_BEFORE' — the probe does not pin the mechanism" >&2
      exit 1
    fi
    ;;
  *)
    echo "usage: tools/qbe/probe-midgc-mixed.sh [--before]" >&2
    exit 2
    ;;
esac
