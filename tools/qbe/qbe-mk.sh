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
#            cc <out>.s                   -> <out>     (linked, -lc; no runtime object since Z6)
#
# ZIGHOST Z6 DELETED the runtime object (tools/qbe/rt.o, built by rt-o.sh from
# tools/qbe/hostshim.zig + the vendored osier-rt package).  The runtime is Mid
# and is emitted into the .ssa, so this pipeline no longer invokes zig at all.
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

# ---- NO RUNTIME OBJECT (ZIGHOST Z6) ----
# There is no rt.o any more: the runtime is Mid (runtime.mid), emitted INTO the
# .ssa, so the artifact links against libc and nothing else.  The measured
# proof that this is a deletion and not a wish: scraping the emitted symbol set
# of all 159 corpus groups yields $rt_call0..16, $rt_call2r, $rt_glob and
# $rt_glob_addr — all of which the .ssa itself defines — and ZERO references to
# any symbol the old object exported.  A remaining client would be a LINK
# ERROR here, loudly, which is the guard this comment replaces.

# ---- elm -> .ssa ----
(cd "$ROOT/elm-compiler" &&
  QBE=1 QBE_ENTRY="$ENTRY" node run.js "${SRCS[@]}" "$BASE.ssa") >&2

case "$(head -c 4 "$BASE.ssa")" in
  "err "*) echo "qbe-mk: compile failed: $(cat "$BASE.ssa")" >&2; exit 1;;
esac

# ---- .ssa -> .s -> binary ----
"$ROOT/vendor/qbe/qbe" "$BASE.ssa" > "$BASE.s"

# DEV-ONLY PROFILER (opt-in; the DEFAULT link is untouched).  QBE_PROF=1
# adds tools/qbe/prof.c, a ~120-line sampling shim: setitimer(ITIMER_PROF) at
# QBE_PROF_HZ (default 1000) writes the interrupted RIP into a ring from the
# SIGPROF handler and dumps `pc count` lines at atexit.  Resolve them with
# tools/qbe/prof-report.sh.  This box has no perf/gprof/valgrind, so this is
# the only way to ask where a QBE artifact's CPU time goes.  Nothing in the
# tree links it by accident: without QBE_PROF=1 this script's cc line is
# byte-for-byte the one it always was.
PROF_O=()
if [ "${QBE_PROF:-0}" = 1 ]; then
  PROF_O=("$OUTDIR/.prof.o")
  cc -O2 -c "$ROOT/tools/qbe/prof.c" -o "${PROF_O[0]}" || {
    echo "qbe-mk: QBE_PROF=1 but profiling shim failed to build" >&2; exit 1; }
fi

cc "$BASE.s" "${PROF_O[@]}" -o "$BASE" -lc
echo "$BASE"
