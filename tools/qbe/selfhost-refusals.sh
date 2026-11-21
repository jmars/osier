#!/usr/bin/env bash
# selfhost-refusals.sh — pin the selfhost driver's four MANIFEST/CORPUS refusals.
#
#   tools/qbe/selfhost-refusals.sh
#
# WHY.  The selfhost driver (osier-compiler/selfhost/NativeMain.elm) is the
# node-free twin of run.js, and its refusal voice is `errLine`: `"elmc: <msg>"`
# on stdout (the printed model), `err <msg>` in ./elmc.err, and the process
# EXIT CODE left at 0 — every manifest-level refusal has always answered 0, so
# a caller must read ./elmc.err, not $?.  Each refusal below was once a SILENT
# SUCCESS instead, because a read that maps a failed open to "" compiles empty
# text and reports `wrote N outputs`:
#
#   1. missing manifest      was `manifest has no groups` (a verdict about the
#                            contents of a file that does not exist)
#   2. no corpus root        was `wrote 1 outputs` + a 60-byte output holding
#                            the core's `err parse error at row 1 column 1`
#   3. runtime.mid absent    was `wrote 1 outputs` + a 106-byte output holding
#                            `err qbe: rawCall to Rt.@p.surface-seat — not a
#                            defun of this program`, in 31.8 s, with NO elmc.err
#                            (an empty runtime.mid parses as a valid runtime
#                            with no defuns, so `Rt.loadArm` answers Ok)
#   4. missing manifest src  was `wrote 1 outputs` + the same 60-byte parse error
#
# The stat-before-read guards in NativeMain.elm are what turn each into a
# refusal BY NAME, and this script is the pin that goes red if a guard is
# removed.  THE ORACLE IS THE BUILT BINARY, not a grep of the source: the driver
# is in the self-host manifest and NOT in elm's build graph, so nothing else
# type-checks it, and a text grep would pass with the guard dead.
#
# WHAT IT DOES.  Builds the driver FROM THIS TREE (the chain
# tools/qbe-bootstrap.sh --freeze uses: jq-patched selfhost manifest ->
# RUN_STACK_KB=131072 node osier-compiler/run.js --batch -> vendor/qbe/qbe ->
# cc -lc) and then runs four scenarios, each from its own throwaway CWD:
#
#   1. missing manifest      -- the manifest path does not exist
#   2. no corpus root        -- the CWD has no ./osier-compiler/
#   3. runtime.mid absent    -- ./osier-compiler/ holds the corpus, not runtime.mid
#   4. missing manifest src  -- corpus complete, the manifest names a file that
#                              is not there
#
# For each it asserts: the exact refusal line on STDOUT, the exact `err <msg>`
# in ./elmc.err, EMPTY stderr, exit 0 (the documented contract), and that the
# group's output .ssa was NOT written.
#
# Everything it creates lives under one mktemp -d (removed on exit); it writes
# nothing into the repo except itself.  Scenario 3 needs a real corpus beside
# the missing runtime.mid, so it links the tree's src/ and core-libs/ and copies
# runtime.mid where the scenario needs one present.
#
# Env:   TMPDIR (artifacts), RUN_STACK_KB (default 131072, as qbe-bootstrap.sh).
# Usage: tools/qbe/selfhost-refusals.sh
# Exit:  0 every scenario passed; 1 a scenario failed; 2 tooling (a missing
#        prerequisite, the emit failed, the binary did not link).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENTRY="NativeMain.main"
MANIFEST="$ROOT/osier-compiler/selfhost/manifest.json"
QBE="$ROOT/vendor/qbe/qbe"

die() { echo "selfhost-refusals: $*" >&2; exit 2; }

for t in node jq cc; do
  command -v "$t" >/dev/null 2>&1 || die "$t not found (needed to build the driver)"
done
[ -f "$MANIFEST" ] || die "no selfhost manifest at $MANIFEST"
[ -x "$QBE" ]      || die "no qbe backend at $QBE"
[ -f "$ROOT/osier-compiler/runtime.mid" ] || die "no runtime.mid in the tree"

W="$(mktemp -d "${TMPDIR:-/tmp}/selfhost-refusals.XXXXXX")" || die "mktemp failed"
cleanup() { rm -rf "$W"; }
trap cleanup EXIT

# ---------------------------------------------------------------- build ----
echo "building the driver from this tree (node emit -> qbe -> cc) ..."
jq --arg out "$W/emit.ssa" --arg entry "$ENTRY" \
   '.groups[0].output = $out | .groups[0].entry = $entry' "$MANIFEST" > "$W/emit.json" \
  || die "jq could not build the batch manifest"

if ! (cd "$ROOT" && RUN_STACK_KB="${RUN_STACK_KB:-131072}" \
        node osier-compiler/run.js --batch "$W/emit.json") > "$W/build.log" 2>&1; then
  tail -n 20 "$W/build.log" >&2
  die "the tree emit failed (log above)"
fi
[ -s "$W/emit.ssa" ] || die "the emit wrote no .ssa"
case "$(head -c 4 "$W/emit.ssa")" in
  "err "*) die "the emit refused: $(head -c 200 "$W/emit.ssa")";;
esac
"$QBE" "$W/emit.ssa" > "$W/emit.s" || die "vendor/qbe/qbe failed"
cc "$W/emit.s" -o "$W/qelmc" -lc       || die "cc failed to link the driver"
[ -x "$W/qelmc" ] || die "no driver binary at $W/qelmc"
BIN="$W/qelmc"
echo "built $(wc -c < "$BIN") bytes of driver from $(wc -c < "$W/emit.ssa") bytes of .ssa"
echo

# --------------------------------------------------------------- harness ----
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'PASS %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$*"; }

expect() { # <label> <want> <got>
  if [ "$2" = "$3" ]; then
    ok "$1"
  else
    bad "$1"
    printf '  want: %s\n  got:  %s\n' "$2" "$3"
  fi
}

# A corpus root that is PRESENT and readable, minus runtime.mid (and minus
# runtime.mid's absence when the scenario needs it present).
corpus_root() { # <dir> [with-runtime]
  mkdir -p "$1/osier-compiler" || die "mkdir $1/osier-compiler"
  ln -s "$ROOT/osier-compiler/src"       "$1/osier-compiler/src"
  ln -s "$ROOT/osier-compiler/core-libs" "$1/osier-compiler/core-libs"
  if [ "${2:-}" = with-runtime ]; then
    cp "$ROOT/osier-compiler/runtime.mid" "$1/osier-compiler/runtime.mid" \
      || die "cp runtime.mid into $1"
  fi
}

scenario() { # <label> <dir> <manifest> <output> <expected message, no prefix>
  local label="$1" dir="$2" man="$3" out="$4" want="$5"
  printf '%s\n' "--- $label"
  ( cd "$dir" && AOTRUN_ARGV=1 QBE_HEAP_MB=16384 \
      "$BIN" NativeMain.main --ssa M.main "$man" >stdout.txt 2>stderr.txt
    echo $? >exit.txt )
  local rc stdout errtext stderr
  rc="$(cat "$dir/exit.txt")"
  stdout="$(cat "$dir/stdout.txt")"
  stderr="$(cat "$dir/stderr.txt")"
  errtext="$(cat "$dir/elmc.err" 2>/dev/null)"
  expect "$label: exit 0 (the refusal is in elmc.err, not in \$?)" "0" "$rc"
  expect "$label: stdout"   "\"elmc: $want\"" "$stdout"
  expect "$label: elmc.err" "err $want" "$errtext"
  expect "$label: stderr empty" "" "$stderr"
  if [ -e "$out" ]; then
    bad "$label: no output written"
    printf '  want: %s absent\n  got:  %s bytes\n' "$out" "$(wc -c < "$out")"
  else
    ok "$label: no output written"
  fi
  echo
}

# ------------------------------------------------------------- scenarios ----
# 1. the manifest path is not there (refused before any corpus access).
D="$W/c1"; mkdir -p "$D"
scenario "missing manifest" "$D" "$D/nosuch-manifest.txt" "$D/out.ssa" \
         "manifest not found: $D/nosuch-manifest.txt"

# 2. the CWD has no corpus root at all.
D="$W/c2"; mkdir -p "$D"
printf '%s\n' "$ROOT/tools/qbe/word-arm-diff/int7.elm" "-> $D/out.ssa" > "$D/manifest.txt"
scenario "no corpus root" "$D" "$D/manifest.txt" "$D/out.ssa" \
         "corpus not found: osier-compiler"

# 3. the corpus root is there and runtime.mid is not.
D="$W/c3"; corpus_root "$D"
printf '%s\n' "$ROOT/tools/qbe/word-arm-diff/int7.elm" "-> $D/out.ssa" > "$D/manifest.txt"
scenario "runtime.mid absent" "$D" "$D/manifest.txt" "$D/out.ssa" \
         "runtime.mid not found: osier-compiler/runtime.mid"

# 4. the corpus is complete and the manifest names a source that is not there.
D="$W/c4"; corpus_root "$D" with-runtime
printf '%s\n' "$D/nosuchfile.elm" "-> $D/out.ssa" > "$D/manifest.txt"
scenario "missing manifest source" "$D" "$D/manifest.txt" "$D/out.ssa" \
         "source not found: $D/nosuchfile.elm"

# ---------------------------------------------------------------- verdict ----
printf 'selfhost refusals: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
