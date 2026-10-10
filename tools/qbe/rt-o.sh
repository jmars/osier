#!/usr/bin/env bash
# rt-o.sh — build (or refresh) tools/qbe/rt.o, the runtime object every QBE
# artifact is linked against, behind a FAIL-SAFE freshness probe.
#
#   usage: tools/qbe/rt-o.sh          # prints the rt.o path on stdout
#
# ONE COPY OF THE GRAPH.  tools/qbe/qbe-mk.sh (fixtures) and
# tools/qbe-bootstrap.sh (the committed seed) both need this object, and this
# repo has already paid for a mis-copied version of it once (the
# fresh-clone blocker fixed in a7755b8).  Callers must not re-type it.
# tools/qbe/qbe-selfhost.sh still carries its own copy, byte-identical in the
# probe and the build command, with a different failure exit code (2 — its
# "tooling failure" class); it is the load-bearing whole-corpus oracle and is
# left untouched deliberately.  Keep the two in step.
#
# The probe must FAIL SAFE: if `find` itself errors (missing dir,
# permissions), "no newer input found" would silently reuse an rt.o built from
# different inputs — treat "cannot tell" as stale and rebuild.  And if the
# rebuild fails, REFUSE LOUDLY: a stale rt.o is worse than none (it is exactly
# how a suite reports an old binary's behaviour as a measurement).
#
# Which inputs: tools/qbe/rt.zig (the exported ABI surface), the vendored
# osier-rt package it imports, and src/effectloop.zig (the package it links).
#
# Env:
#   RT_O_DIE_EXIT  exit status when the rebuild fails (default 1).
# Exit: 0 the object is present and fresh-or-rebuilt; non-zero otherwise.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RT="$ROOT/tools/qbe/rt.o"
DIE_EXIT="${RT_O_DIE_EXIT:-1}"

say()  { printf 'rt-o: %s\n' "$*" >&2; }
fail() { say "$*"; exit "$DIE_EXIT"; }

command -v zig >/dev/null 2>&1 || fail "zig not found (it builds $RT)"

rt_newer="$(find "$ROOT/tools/qbe/rt.zig" "$ROOT/vendor/osier-rt/src" "$ROOT/src/effectloop.zig" \
              -newer "$RT" -print -quit 2>/dev/null)" || rt_newer="PROBE_FAILED"
if [ "$rt_newer" = "PROBE_FAILED" ]; then
  say "rt.o freshness probe FAILED -- rebuilding rather than trusting it"
fi
if [ ! -f "$RT" ] || [ -n "$rt_newer" ]; then
  say "building $RT"
  zig build-obj -O ReleaseFast -lc -femit-bin="$RT" \
    --dep gc --dep rt --dep effectloop -Mroot="$ROOT/tools/qbe/rt.zig" \
    -Mgc="$ROOT/vendor/osier-rt/src/gc.zig" \
    --dep gc -Mrt="$ROOT/vendor/osier-rt/src/rt.zig" \
    --dep gc --dep rt -Meffectloop="$ROOT/src/effectloop.zig" \
    || fail "rt.o rebuild FAILED -- refusing to answer from a stale $RT"
fi

printf '%s\n' "$RT"
