#!/usr/bin/env bash
# qbe-mk.sh — one command from an .elm fixture to a NATIVE executable
# (native-backend stage 1; handoff-qbe-lower).
#
#   tools/qbe/qbe-mk.sh <src1.elm> [src2.elm ...] <Entry.key> <outdir> [entry-args...]
#
# One or MORE sources: the last two non-args are <Entry.key> and <outdir>, the
# rest are compiled TOGETHER as one group (the gate's run2 rows need the aux
# module beside the main one).  Callers passing exactly one source keep working.
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
# Args: <src1.elm> [src2.elm ...] <Entry.key> <outdir>.  The last two are the
# entry and the output dir; everything before them is the SOURCE GROUP,
# compiled together as one program (each path made absolute — the node step
# below runs from elm-compiler).  A single source is the common case.
[ "$#" -ge 3 ] || {
  echo "qbe-mk: usage: qbe-mk.sh <src1.elm> [src2.elm ...] <Entry.key> <outdir>" >&2
  exit 2
}
N="$#"
J=$((N - 1))
ENTRY="${!J}"
OUTDIR="${!N}"
SRCS=()
i=1
while [ "$i" -le $((N - 2)) ]; do
  a="${!i}"
  case "$a" in
    /*) SRCS+=("$a") ;;
    *)  SRCS+=("$ROOT/$a") ;;
  esac
  i=$((i + 1))
done
LAST_SRC="${SRCS[${#SRCS[@]} - 1]}"

[ -n "$ENTRY" ] || { echo "qbe-mk: entry key required (e.g. Fib.fib)" >&2; exit 2; }
for s in "${SRCS[@]}"; do
  [ -f "$s" ] || { echo "qbe-mk: no source: $s" >&2; exit 2; }
done
mkdir -p "$OUTDIR"
BASE="$OUTDIR/$(basename "$LAST_SRC" .elm)"

# ---- runtime object (cached, freshness-invalidated) ----
# The graph lives in ONE place (tools/qbe/rt-o.sh): this file, the committed
# seed's bootstrap (tools/qbe-bootstrap.sh) and the whole-corpus oracle all
# link against the same rt.o, and a mis-copied freshness probe here has
# already cost this repo a fresh-clone blocker once.  rt-o.sh keeps the probe
# fail-safe (a failed `find` means "cannot tell" -> rebuild) and REFUSES
# loudly on a failed rebuild -- a stale rt.o is worse than none (it is exactly
# how a suite reports an old binary's behaviour as a measurement).
RT="$("$ROOT/tools/qbe/rt-o.sh")" || exit 1

# ---- elm -> .ssa ----
(cd "$ROOT/elm-compiler" &&
  QBE=1 QBE_ENTRY="$ENTRY" node run.js "${SRCS[@]}" "$BASE.ssa") >&2

case "$(head -c 4 "$BASE.ssa")" in
  "err "*) echo "qbe-mk: compile failed: $(cat "$BASE.ssa")" >&2; exit 1;;
esac

# ---- .ssa -> .s -> binary ----
"$ROOT/vendor/qbe/qbe" "$BASE.ssa" > "$BASE.s"
cc "$BASE.s" "$RT" -o "$BASE" -lc
echo "$BASE"
