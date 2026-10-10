#!/usr/bin/env bash
# perf-emit.sh — time ONE QBE emit (stage 1) for a fixture, and report the
# artifact's sha256/size.  The emit-only slice of qbe-mk.sh: no qbe, no cc, no
# run.  Used to measure the Peephole.elm Set.union quadratic before/after.
#
#   tools/qbe/perf-emit.sh <fixture.elm> <Entry.key> <out.ssa>
#
# Prints one machine-readable line:
#   perf-emit: <secs> s  <sha256>  <bytes>  <out>
# The number is `date +%s%N` around the node invocation (wall clock, includes
# process start + the fixed corpus parse the driver always pays).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURE="$1"; ENTRY="$2"; OUT="$3"
[ -f "$FIXTURE" ] || { echo "perf-emit: no fixture: $FIXTURE" >&2; exit 2; }
mkdir -p "$(dirname "$OUT")"

# run.js resolves the corpus against ELMC_ROOT/elm-compiler relative to the CWD.
t0=$(date +%s%N)
( cd "$ROOT" && QBE=1 QBE_ENTRY="$ENTRY" \
    node "$ROOT/elm-compiler/run.js" "$FIXTURE" "$OUT" )
t1=$(date +%s%N)

case "$(head -c 4 "$OUT")" in
  "err "*) echo "perf-emit: compile FAILED: $(head -c 300 "$OUT")" >&2; exit 1;;
esac
secs=$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.2f", (b - a) / 1000000000 }')
printf 'perf-emit: %s s  %s  %s bytes  %s\n' \
  "$secs" "$(sha256sum "$OUT" | cut -d' ' -f1)" "$(stat -c %s "$OUT")" "$OUT"
