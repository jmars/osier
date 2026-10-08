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
# rt.o is built once (rebuilt when tools/qbe/rt.zig or the vendored VM is
# newer) with `zig build-obj` against the SAME gc/vm modules the repo's
# build.zig uses — no QBE or VM source is modified.
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

# ---- runtime object (cached) ----
RT="$ROOT/tools/qbe/rt.o"
if [ ! -f "$RT" ] || [ "$ROOT/tools/qbe/rt.zig" -nt "$RT" ] \
   || find "$ROOT/vendor/zinc-vm/src" -name '*.zig' -newer "$RT" 2>/dev/null | head -1 | grep -q .; then
  echo "qbe-mk: building $RT" >&2
  zig build-obj -O ReleaseFast -lc -femit-bin="$RT" \
    --dep gc --dep vm -Mroot="$ROOT/tools/qbe/rt.zig" \
    -Mgc="$ROOT/vendor/zinc-vm/src/gc.zig" \
    --dep gc -Mvm="$ROOT/vendor/zinc-vm/src/vm.zig"
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
