#!/usr/bin/env bash
# probe-midgc-io.sh — the SCRIPTED fail-before / pass-after probe for the
# zigretire stage-5 PART 5 HOST-IO CENSUS REFUSAL (the reproduced cross-heap
# hole: the Zig effect loop builds read-file/getenv/getcwd/glob/exec strings
# and conses in the Zig nursery, which the scavenge reclaims while a Mid
# object still references them).
#
# THE ASYMMETRY.  tools/qbe/fixtures/midgc-io.elm reads a 150-byte file into a
# Mid cons (`keeper s = [s]`), churns a 4-arg MUTUAL tail recursion (a self-tail
# lowers to an in-frame loop, so mutual recursion is REQUIRED to reach
# rt_tail_known's nargs>3 g.allocArray fallback — the Zig-nursery trigger),
# then content-compares the kept string AND prints its length.
#
#   * PASS-AFTER (this tree): QBE_MIDGC=1 REFUSES the program at compile time —
#     it is effect-loop-driven (Platform.program -> Runtime.program), named in
#     the refusal (Lower.elm's effect-loop arm).  The DEFAULT path (no MIDGC)
#     still compiles and prints "100|150" (the kept string is evacuated, not
#     reclaimed).  This arm asserts BOTH: the refusal fires, AND the default
#     path is unchanged.
#   * FAIL-BEFORE: reverting ONE line in elm-compiler/src/Mid/Qbe/Lower.elm
#     (`hostSeam` -> `False` — disabling ONLY the effect-loop arm, leaving the
#     census arm intact) lets the program compile under QBE_MIDGC=1; it then
#     prints "0|150": content equality FAILS (the kept string's data bytes
#     were reclaimed by the Zig scavenge) while String.length prints 150 (the
#     Value — and its length field — survived inside the Mid cons).  The exact
#     cross-heap signature.
#
# Usage:
#   tools/qbe/probe-midgc-io.sh          # PASS-AFTER (current tree)
#   tools/qbe/probe-midgc-io.sh --before # FAIL-BEFORE: revert, rebuild, run,
#                                        # RESTORE
#
# The --before arm restores Lower.elm under a trap, so even a failed run never
# leaves the tree edited.  It rebuilds compiler.js itself (ELM_BIN defaults to
# the npm-global elm, the same path osier-numbers.sh documents).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

LOWER="elm-compiler/src/Mid/Qbe/Lower.elm"
FIXTURE="tools/qbe/fixtures/midgc-io.elm"
INPUT="tools/qbe/fixtures/input/midgc-io.txt"
ENTRY="MidgcIo.main"
GOLDEN='"100|150"'
FAIL_BEFORE='"0|150"'
CHURN_MB=16
ELM_BIN="${ELM_BIN:-$HOME/.npm-global/lib/node_modules/elm/bin/elm}"

# The one reverted line, anchored on the unique `hostSeam =` binding (the
# effect-loop refusal's derivation site), so the replacement cannot hit any
# other `hostSeam` in Lower.elm.
BEFORE_BLOCK=$'                hostSeam =\n                    List.any (\\k -> k == "Runtime.program" || k == "Runtime.worker") surfaceKeys'
AFTER_BLOCK=$'                hostSeam =\n                    False'

need() { command -v "$1" >/dev/null 2>&1 || { echo "probe-midgc-io: $1 not found" >&2; exit 2; }; }

rebuild() {
  (cd "$ROOT/elm-compiler" && ELM_HOME="$PWD/.elm-cache" "$ELM_BIN" make src/Main.elm --output=compiler.js >/dev/null) \
    || { echo "probe-midgc-io: elm make compiler.js failed" >&2; exit 1; }
}

# Compile the fixture under QBE_MIDGC=1.  With $1 = expect_refusal (default 1),
# asserts the compile FAILS with the refusal naming the effect-loop seam; with
# 0, asserts the compile SUCCEEDS (the --before arm, where the refusal is
# reverted).  Prints the qbe-mk output dir.
midgc_compile() {
  local expect_refusal="${1:-1}"
  local out
  out="$(mktemp -d "${TMPDIR:-/tmp}/probe-midgc-io.XXXXXX")"
  if QBE_MIDGC=1 "$ROOT/tools/qbe/qbe-mk.sh" "$FIXTURE" "$ENTRY" "$out" >/dev/null 2>&1; then
    if [ "$expect_refusal" = "1" ]; then
      echo "probe-midgc-io: QBE_MIDGC=1 did NOT refuse the host-IO program (it compiled) — the effect-loop refusal is missing" >&2
      exit 1
    fi
  else
    if [ "$expect_refusal" = "0" ]; then
      echo "probe-midgc-io: QBE_MIDGC=1 still refuses the program under --before (the reversion did not disable the refusal)" >&2
      exit 1
    fi
    if ! head -c 4 "$out/midgc-io.ssa" | grep -q '^err '; then
      echo "probe-midgc-io: QBE_MIDGC=1 failed but the .ssa is not an 'err' — unexpected compile failure" >&2
      exit 1
    fi
    if ! grep -q 'Runtime.program' "$out/midgc-io.ssa"; then
      echo "probe-midgc-io: the refusal does not NAME the effect-loop seam (Runtime.program)" >&2
      exit 1
    fi
  fi
  echo "$out"
}

# Default-path control: the fixture must print the golden with the Zig
# collector (the kept string is rooted -> evacuated, not reclaimed).
default_control() {
  local out
  out="$(mktemp -d "${TMPDIR:-/tmp}/probe-midgc-io.XXXXXX")"
  trap 'rm -rf "$out"' RETURN
  "$ROOT/tools/qbe/qbe-mk.sh" "$FIXTURE" "$ENTRY" "$out" >/dev/null 2>&1 \
    || { echo "probe-midgc-io: default qbe-mk failed" >&2; exit 1; }
  MIDGC_IO_IN="$ROOT/$INPUT" QBE_HEAP_MB=$CHURN_MB timeout 120 "$out/midgc-io" "$ENTRY" 2>&1
}

case "${1:-}" in
  "")
    need node; need cc
    rebuild
    out="$(midgc_compile 1)"
    rm -rf "$out"
    ctrl="$(default_control)"
    if [ "$ctrl" = "$GOLDEN" ]; then
      echo "PASS-AFTER: QBE_MIDGC=1 refuses the host-IO program (names Runtime.program, the effect-loop seam); the default path prints $GOLDEN (the kept string is evacuated, not reclaimed)"
      exit 0
    else
      echo "FAIL-AFTER: the default path printed '$ctrl', want '$GOLDEN' — the refusal changed the default path" >&2
      exit 1
    fi
    ;;
  --before)
    need node; need cc
    # Revert the ONE line (hostSeam -> False), then always restore it.
    python3 - "$LOWER" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
before = "                hostSeam =\n                    List.any (\\k -> k == \"Runtime.program\" || k == \"Runtime.worker\") surfaceKeys"
after = "                hostSeam =\n                    False"
assert s.count(before) == 1, f"expected exactly one reversion site, found {s.count(before)}"
open(p, "w").write(s.replace(before, after))
PY
    restore() {
      python3 - "$LOWER" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
after = "                hostSeam =\n                    False"
before = "                hostSeam =\n                    List.any (\\k -> k == \"Runtime.program\" || k == \"Runtime.worker\") surfaceKeys"
assert s.count(after) == 1, f"expected exactly one reverted site, found {s.count(after)}"
open(p, "w").write(s.replace(after, before))
PY
      (cd "$ROOT/elm-compiler" && ELM_HOME="$PWD/.elm-cache" "$ELM_BIN" make src/Main.elm --output=compiler.js >/dev/null) || true
    }
    trap restore EXIT
    rebuild
    out="$(midgc_compile 0)"
    corrupt="$(MIDGC_IO_IN="$ROOT/$INPUT" QBE_HEAP_MB=$CHURN_MB timeout 120 "$out/midgc-io" "$ENTRY" 2>&1)"
    rm -rf "$out"
    if [ "$corrupt" = "$FAIL_BEFORE" ]; then
      echo "FAIL-BEFORE REPRODUCED: with the refusal reverted, the host-IO program printed '$corrupt' (== $FAIL_BEFORE, the exact cross-heap signature) — content equality failed while the length field survived (the Zig scavenge reclaimed the kept string's data)"
      exit 0
    else
      echo "FAIL-BEFORE NOT REPRODUCED: printed '$corrupt', want the exact cross-heap signature '$FAIL_BEFORE' — the probe does not pin the mechanism" >&2
      exit 1
    fi
    ;;
  *)
    echo "usage: tools/qbe/probe-midgc-io.sh [--before]" >&2
    exit 2
    ;;
esac
