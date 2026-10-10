#!/usr/bin/env bash
# elmc.sh — thin CLI wrapper for the aot-built elmc compiler binary (M15).
#
#   elmc <input1.elm> [input2.elm ...] <output.csexp>
#   elmc <manifest>            (line format: sources one per line, each
#                                group terminated by '-> <out.csexp>')
#
# Builds zig-out/bin/elmc from the selfhost group (NativeMain + the compiler
# frontend, via aot-build.sh --group) on first use, then runs it with the
# driver's argv plumbing enabled:
#   AOTRUN_ARGV=1   the binary's arguments reach NativeMain as Runtime.argv ()
#   AOTRUN_QUIET=1  the driver's final model print is suppressed (clean stdout)
#
# Byte-for-byte parity with `node elm-compiler/run.js ...` is the contract
# (same corpus order, same Lower.Module.compileBatch, same output bytes).
#
# Env:
#   ELMC_BIN   use this prebuilt binary instead of (re)building
#   ELMC_HEAP_MB  heap override for the compiler binary (big groups)
#   ELMC_SKIP_BUILD=1  fail loudly instead of building when ELMC_BIN is unset
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${ELMC_BIN:-$ROOT/zig-out/bin/elmc}"

# Global zig cache off the cramped /home onto the pool (see aot-build.sh).
: "${ZIG_GLOBAL_CACHE_DIR:=$ROOT/.zig-cache-global}"
export ZIG_GLOBAL_CACHE_DIR
mkdir -p "$ZIG_GLOBAL_CACHE_DIR"

# Freshness-invalidated cache (the tools/qbe/qbe-mk.sh pattern).  zig-out/bin/
# elmc is NOT content-addressed -- aot-build.sh copies it out of a private zig
# build into a fixed path -- so mere existence proves nothing: without this
# guard the first build answers forever, however much the compiler sources
# change afterwards.  Rebuild whenever anything it was compiled from is newer
# than it: the compiler sources (src/ + the core-libs corpus + run.js and the
# compiled compiler.js they produce), the selfhost group it compiles, the AOT
# runtime/driver, the runtime package it links (vendor/osier-rt: gc + rt, the
# post-split home of the GC/values the QBE and AOT paths share) and the VM it
# still links (vendor/zinc-vm, the interpreter side), and the aotdump that
# produced its gen.zig.  The probe FAILS SAFE: if `find` cannot run, rebuild.  The
# cost of a false positive is one aot-build (~9 min, see below); the cost of
# a false negative is a compiler binary answering for sources it was not
# built from -- the stale-artifact class qbe-mk.sh's rt.o guard exists for.
need_build=0
reason=""
if [ ! -x "$BIN" ]; then
  need_build=1
  reason="missing"
else
  elmc_newer="$(find \
    "$ROOT/elm-compiler/src" "$ROOT/elm-compiler/core-libs" "$ROOT/elm-compiler/selfhost" \
    "$ROOT/elm-compiler/run.js" "$ROOT/elm-compiler/compiler.js" \
    "$ROOT/tools/aot" "$ROOT/vendor/zinc-vm/src" "$ROOT/vendor/osier-rt/src" \
    "$ROOT/src/effectloop.zig" \
    "$ROOT/zig-out/bin/aotdump" \
    -newer "$BIN" -print -quit 2>/dev/null)" || elmc_newer="PROBE_FAILED"
  if [ -n "$elmc_newer" ]; then
    need_build=1
    reason="stale (newer input: $elmc_newer)"
  fi
fi

if [ "$need_build" -eq 1 ]; then
  if [ "${ELMC_SKIP_BUILD:-0}" = "1" ]; then
    echo "elmc: no fresh binary at $BIN ($reason); set ELMC_BIN or drop ELMC_SKIP_BUILD" >&2
    exit 2
  fi
  echo "elmc: building $BIN ($reason; aot-build NativeMain + selfhost group)..." >&2
  # compiler.js is the input a rebuild would bake.  If the compiler sources are
  # newer than it, building now would produce a binary compiled from a STALE
  # compiler -- refuse with the fix instead of proceeding (the same rule as
  # qbe-mk's rt.o: a cached artifact must never answer for inputs it was not
  # built from).  TestMain.elm is excluded: it is the test runner, not part of
  # the compiler (selfhost/manifest.json excludes it for the same reason).
  if [ -f "$ROOT/elm-compiler/compiler.js" ]; then
    cj_newer="$(find "$ROOT/elm-compiler/src" -name '*.elm' ! -name 'TestMain.elm' \
                 -newer "$ROOT/elm-compiler/compiler.js" -print -quit 2>/dev/null)" \
      || cj_newer="PROBE_FAILED"
    if [ -n "$cj_newer" ]; then
      echo "elmc: elm-compiler/compiler.js may be stale (newer source: $cj_newer) --" >&2
      echo "elmc: run (cd elm-compiler && ./build.sh) first, then retry; not building from a stale compiler" >&2
      exit 2
    fi
  fi
  # ELMC_BUILD_MODE: -O for aot-build.  Default ReleaseFast: the compiler is a
  # binary you RUN (often repeatedly), and a Debug build is ~10x slower at
  # runtime (it is the whole point of elmc to be usable); the one-time ~9 min
  # LLVM cost on the full-closure gen.zig is worth it.  Set
  # ELMC_BUILD_MODE=Debug only for a quick syntax/debug build.
  "$ROOT/tools/aot/aot-build.sh" \
    "$ROOT/elm-compiler/selfhost/NativeMain.elm" \
    --group "$ROOT/elm-compiler/selfhost/manifest.json" \
    --entry NativeMain.main \
    -O "${ELMC_BUILD_MODE:-ReleaseFast}" \
    -o "$BIN"
fi

export AOTRUN_ARGV=1
export AOTRUN_QUIET=1

# ELMC_HEAP_MB — the compiler's GC heap.  Measured on the corpus compile
# (2026-10-02): time SCALES WITH HEAP SIZE because a nursery scavenge walks the
# old-gen live set (O(heap)), so a smaller heap is faster.  Curve (one corpus
# compile): 1000MB=25m35s (past the knee — full collects thrash), 1500MB=21m31s
# (fastest), 2000MB=22m05s, 4000MB=25m58s, 8000MB=~35m, 16000MB=62m.  2000 sits
# just above the ~1500MB knee with headroom for large groups — the previous
# hard-coded 8000 was ~40% slower.  Override for a bigger/smaller working set.
export ELMC_HEAP_MB="${ELMC_HEAP_MB:-2000}"

exec "$BIN" "$@"
