#!/usr/bin/env bash
# qbe-mk.sh — one command from an .elm fixture to a NATIVE executable
# (native-backend stage 1; handoff-qbe-lower).
#
#   tools/qbe/qbe-mk.sh <fixture.elm> <Entry.key> <outdir> [entry-args...]
#
# Pipeline:  node run.js (QBE=1 QBE_ENTRY) -> <out>.ssa
#            vendor/qbe/qbe <out>.ssa      -> <out>.s   (exit checked)
#            cc <out>.s tools/qbe/rt.o     -> <out>     (linked, -lc)
#
# rt.o is built once (rebuilt when tools/qbe/rt.zig or the vendored runtime
# is newer) with `zig build-obj` against the osier-rt package's gc/rt modules
# (the SAME modules the repo's build.zig uses).  It links NO interpreter: the
# ZINC VM package is not part of the QBE path at all.
#
# Exit: 0 success.  Prints the built binary's path.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURE="$1"; ENTRY="$2"; OUTDIR="$3"; shift 3 || true
ARGS=("$@")

[ -f "$FIXTURE" ] || { echo "qbe-mk: no fixture: $FIXTURE" >&2; exit 2; }
[ -n "$ENTRY" ] || { echo "qbe-mk: entry key required (e.g. Fib.fib)" >&2; exit 2; }
mkdir -p "$OUTDIR"
BASE="$OUTDIR/$(basename "$FIXTURE" .elm)"

# ---- runtime object (cached, freshness-invalidated) ----
# A cached rt.o answers only while NOTHING it was built from is newer than it.
# The freshness probe must FAIL SAFE: if `find` itself errors (missing dir,
# permissions), "no newer input found" would silently reuse an rt.o built from
# different inputs -- treat "cannot tell" as stale and rebuild.  And if the
# rebuild fails, refuse loudly: a stale rt.o here is worse than none (it is
# exactly how a suite reports an old binary's behaviour as a measurement).
RT="$ROOT/tools/qbe/rt.o"
rt_newer="$(find "$ROOT/tools/qbe/rt.zig" "$ROOT/vendor/osier-rt/src" "$ROOT/src/effectloop.zig" \
              -newer "$RT" -print -quit 2>/dev/null)" || rt_newer="PROBE_FAILED"
if [ "$rt_newer" = "PROBE_FAILED" ]; then
  echo "qbe-mk: rt.o freshness probe FAILED -- rebuilding rather than trusting it" >&2
fi
if [ ! -f "$RT" ] || [ -n "$rt_newer" ]; then
  echo "qbe-mk: building $RT" >&2
  zig build-obj -O ReleaseFast -lc -femit-bin="$RT" \
    --dep gc --dep rt --dep effectloop -Mroot="$ROOT/tools/qbe/rt.zig" \
    -Mgc="$ROOT/vendor/osier-rt/src/gc.zig" \
    --dep gc -Mrt="$ROOT/vendor/osier-rt/src/rt.zig" \
    --dep gc --dep rt -Meffectloop="$ROOT/src/effectloop.zig" \
    || { echo "qbe-mk: rt.o rebuild FAILED -- refusing to answer from a stale $RT" >&2; exit 1; }
fi

# ---- elm -> .ssa ----
(cd "$ROOT/elm-compiler" &&
  QBE=1 QBE_ENTRY="$ENTRY" node run.js "$ROOT/$FIXTURE" "$BASE.ssa") >&2

case "$(head -c 4 "$BASE.ssa")" in
  "err "*) echo "qbe-mk: compile failed: $(cat "$BASE.ssa")" >&2; exit 1;;
esac

# ---- .ssa -> .s -> binary ----
"$ROOT/vendor/qbe/qbe" "$BASE.ssa" > "$BASE.s"
cc "$BASE.s" "$RT" -o "$BASE" -lc
echo "$BASE"
