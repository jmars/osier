#!/usr/bin/env bash
# midtier-runtime.sh — the middle tier's RUNTIME measurement.
#
# WHY THIS EXISTS.  The per-pass acceptance criterion used through the pass
# series was EMITTED-INSTRUCTION COUNT (`tools/midtier-emit-stats.py`).  That
# metric is WRONG for this work, and it demonstrably corrupted the pass chain:
# Inline was kept despite +10.75% instructions (its real effect is removing the
# per-call frame/env allocation, the VM's dominant cost), while Arity's two
# representation repairs — the over-application split and the partial
# eta-expansion — were dropped for adding ~3 instructions each, gutting the
# plan's designated representation pass.  A representation transform can ADD
# instructions while REMOVING an allocation or a call, so instruction count is
# NOT a proxy for runtime here (see docs/vm-perf-plan.md: per-call frame
# allocation at old-gen sizes defeats the generational collector; a nested
# vmExecEnv peel allocates a fresh ~3 MB frame stack; buildPartialClosure
# copies the whole closure body's instruction array).  This script measures the
# thing the passes actually target: WALL-CLOCK on the VM.
#
# WHAT IT DOES.  For each benchmark fixture in tools/bench/ it compiles the
# bundle under several MIDTIER flag combinations and reports, side by side:
#   * the emitted instruction count (informative, NOT the verdict), and
#   * wall-clock of the fixture's `main` (a heavy loop) on `zig-out/bin/elmvm`,
#     with ELMC_HEAP_MB set so the measurement is not heap-bound,
#   * and, when vmbench is built, ns-per-instruction + GC counts of the
#     fixture's `once` entry (one unit of the target operation, looped).
#
# The flag set isolates each pass: `MIDTIER=1` vs `MIDTIER=1 MIDTIER_NOINLINE=1`
# is Inline's runtime effect; `… MIDTIER_NOARITY=1` is Arity's.  A "runtime
# win" here is a wall-clock / ns-per-instruction IMPROVEMENT, reported even
# when the instruction count moves the other way.
#
# Usage: tools/midtier-runtime.sh [bench-name ...]   (default: all of tools/bench)
# Env:   MIDTIER_RT_RUNS=n   elmvm wall-clock runs per bundle (default 3)

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ELMVM="$ROOT/zig-out/bin/elmvm"
VMBENCH="$ROOT/zig-out/bin/vmbench"
CDIR="$ROOT/elm-compiler"
STATS="$ROOT/tools/midtier-emit-stats.py"
BENCHDIR="$ROOT/tools/bench"
RUNS="${MIDTIER_RT_RUNS:-3}"

for tool in node python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "FAIL: $tool not on PATH" >&2; exit 2; }
done
[ -x "$ELMVM" ] || { echo "FAIL: $ELMVM missing (run: zig build elmvm)" >&2; exit 2; }
[ -f "$CDIR/compiler.js" ] || { echo "FAIL: $CDIR/compiler.js missing" >&2; exit 2; }

benches=("$@")
if [ "${#benches[@]}" -eq 0 ]; then
    benches=()
    for f in "$BENCHDIR"/*.elm; do
        [ -f "$f" ] || continue
        benches+=("$(basename "$f" .elm)")
    done
fi

# Each row:  flag label | MIDTIER env… | suffix
# The suffix names the compiled bundle and the report column.
declare -a MODES=(
    "MIDTIER=0|MIDTIER=0|m0"
    "MIDTIER=1|MIDTIER=1|m1"
    "MIDTIER=1, no Inline|MIDTIER=1 MIDTIER_NOINLINE=1|noinline"
    "MIDTIER=1, no Arity|MIDTIER=1 MIDTIER_NOARITY=1|noarity"
    "MIDTIER=1, no Shrink|MIDTIER=1 MIDTIER_NOSHRINK=1|noshrink"
    "MIDTIER=1, no ConstFold|MIDTIER=1 MIDTIER_NOCONSTFOLD=1|noconstfold"
    "MIDTIER=1, no DeadGlobals|MIDTIER=1 MIDTIER_NODEADGLOBALS=1|nodeadglobals"
)

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# wall-clock of one elmvm run, in fractional seconds.
rt_time() { # <bundle> <entry>
    local t0 t1
    t0="$(date +%s%N)"
    ELMC_HEAP_MB=256 "$ELMVM" "$1" "$2" >/dev/null 2>&1
    t1="$(date +%s%N)"
    echo "$(( (t1 - t0) )) " | awk '{ printf "%.3f", $1 / 1000000000 }'
}

# best (min) wall-clock over $RUNS runs.
rt_best() { # <bundle> <entry>
    local best=999999 i t
    for ((i=0;i<RUNS;i++)); do
        t="$(rt_time "$1" "$2")"
        best="$(awk -v t="$t" -v b="$best" 'BEGIN { if (t < b) print t; else print b }')"
    done
    echo "$best"
}

for b in "${benches[@]}"; do
    src="$BENCHDIR/$b.elm"
    [ -f "$src" ] || { echo "no such benchmark: $src" >&2; exit 2; }
    mod="$(awk '/^module /{print $2; exit}' "$src")"
    entry="$mod.main"

    echo "=================================================================="
    echo "benchmark: $b  (entry $entry)"
    printf '%-26s %12s %12s\n' "mode" "instrs" "wall(ms)"
    row=0
    for m in "${MODES[@]}"; do
        label="${m%%|*}"; rest="${m#*|}"; envs="${rest%%|*}"; suf="${rest##*|}"
        out="$TMP/$b.$suf.csexp"
        # shellcheck disable=SC2086
        env $envs node "$CDIR/run.js" "$src" "$out" >/dev/null 2>&1
        rc=$?
        if [ "$rc" -ne 0 ]; then
            printf '%-26s %12s %12s\n' "$label" "COMPILE-FAIL" "-"
            continue
        fi
        ninstr="$(python3 "$STATS" "$out" 2>/dev/null | sed -n 's/.*instrs= *\([0-9]*\).*/\1/p' | head -1)"
        wt="$(rt_best "$out" "$entry")"
        wtms="$(awk -v w="$wt" 'BEGIN { printf "%.1f", w * 1000 }')"
        printf '%-26s %12s %12s\n' "$label" "$ninstr" "$wtms"
    done

    if [ -x "$VMBENCH" ]; then
        echo "--- vmbench ($b.once, one unit of the target op, looped) ---"
        for m in "${MODES[@]}"; do
            label="${m%%|*}"; rest="${m#*|}"; suf="${rest##*|}"
            out="$TMP/$b.$suf.csexp"
            [ -s "$out" ] || continue
            vmout="$(ELMC_HEAP_MB=256 "$VMBENCH" "$out" "$mod.once" --secs=2 7 2>&1)"
            nsi="$(printf '%s\n' "$vmout" | awk '/ns_per_instr/{print $2; exit}')"
            gc="$(printf '%s\n' "$vmout" | awk '/gc:/{print; exit}')"
            printf '  %-24s ns/instr=%-10s %s\n' "$label" "$nsi" "$gc"
        done
    fi
done

echo
echo "READING THE TABLE: instruction count is INFORMATIVE ONLY.  A representation"
echo "transform that ADDS instructions while LOWERING wall-clock / ns-per-instr"
echo "is a WIN — the instruction count must not veto it (see the header)."
