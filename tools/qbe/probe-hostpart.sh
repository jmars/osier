#!/usr/bin/env bash
# probe-hostpart.sh — a SATURATED call on a HALF-APPLIED closure, applied by
# the effect HOST: the applied prefix and the new argument must BOTH arrive.
#
# THE SHAPE. `tools/qbe/fixtures/rfpart.elm` is a `Runtime.program` whose
# `Task.andThen` continuation is a PARTIAL APPLICATION — `report "PREFIX:"`,
# arity 2 with one cell already in the closure's env. The host applies it to
# ONE value (the text read through `Io.readFile`), i.e. `args.len ==
# lambda.code_len` (the REMAINING arity) with `napp = arity - remaining = 1`
# applied cells. The model prints the applied prefix, the text's LENGTH and
# its first line, so a call that loses either half cannot print the golden.
#
#   * PASS-AFTER (this tree): both hosts print "PREFIX:34:first line here" —
#     the Mid host through `Rt.apply-at`'s `rt_call2r` bridge and the ZIG host
#     through `hostApply`'s same interleave (params = the applied cells then
#     the new args, `env` advanced past the applied cells).
#   * FAIL-BEFORE: restore the pre-fix `hostApply` (the `napp > 0` arm deleted:
#     `desc.arity` params, only `args.len` cells filled, the closure's env
#     unchanged). MEASURED 2026-10-19 on this fixture: one run printed NOTHING
#     (rc=0, the callee took the garbage) and another printed
#     `"first line here\nsecond line\nthird\n0:"` — prefix gone, length 0, the
#     "first line" replaced by the whole text. rt.o must be rebuilt between the
#     two states (rt-o.sh's freshness probe sees hostshim.zig).
#
# WHY IT MATTERS BEYOND THE FIXTURE: the seed's own compiler driver has this
# shape (`Task.andThen (runSsa entry) (Io.readFile path)` in
# elm-compiler/selfhost/NativeMain.elm). With the pre-fix hostApply the
# seed-built compiler read its manifest into a garbage String and printed
# `"elmc: manifest has no groups"`, so `tools/qbe-bootstrap.sh --verify` was
# RED in 42 s at "the native compiler wrote no .ssa".
#
# Usage:
#   tools/qbe/probe-hostpart.sh
# Exit: 0 both arms print the golden; 1 an arm did not (message names it);
#       2 tooling failure.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

FIXTURE="tools/qbe/fixtures/rfpart.elm"
INPUT="$ROOT/tools/qbe/fixtures/input/rfpart.txt"
ENTRY="Rfpart.main"
GOLDEN='"PREFIX:34:first line here"'
HEAP_MB=16

need() { command -v "$1" >/dev/null 2>&1 || { echo "probe-hostpart: $1 not found" >&2; exit 2; }; }
need node; need cc

OUT="$(mktemp -d "${TMPDIR:-/tmp}/probe-hostpart.XXXXXX")" || exit 2
trap 'rm -rf "$OUT"' EXIT

QBE_MIDGC=0 "$ROOT/tools/qbe/qbe-mk.sh" "$FIXTURE" "$ENTRY" "$OUT/bin" >/dev/null 2>&1 || {
  echo "BUILD_FAILED: tools/qbe/qbe-mk.sh could not build $FIXTURE" >&2
  exit 2
}

run() { # $1 = label, rest = env assignments for the RUN
  local label="$1"
  shift
  env RF_PART_IN="$INPUT" QBE_HEAP_MB=$HEAP_MB "$@" "$OUT/bin/rfpart" "$ENTRY" 2>&1 || true
}

fail() { # $1 = label, $2 = what it printed
  echo "FAIL: $1 printed $(printf '%s' "$2" | head -c 200) — want $GOLDEN" >&2
  exit 1
}

# ARM A — the DEFAULT route (the Mid host: Rt.apply-at -> rt_call2r).
A="$(run "the Mid host")"
[ "$A" = "$GOLDEN" ] || fail "the Mid host (QBE_MIDHOST unset)" "$A"

# ARM B — the ZIG host's native applier (hostApply). This is the arm the fix
# is about: it is the differential oracle and the route the seed-built
# compiler took whenever `Rt.hostIsProgram`'s payload read saw stale padding.
B="$(run "the Zig host" QBE_MIDHOST=0)"
[ "$B" = "$GOLDEN" ] || fail "the Zig host (QBE_MIDHOST=0)" "$B"

echo "PASS-AFTER: a partially applied continuation is applied with its prefix intact on BOTH hosts ($GOLDEN)"
