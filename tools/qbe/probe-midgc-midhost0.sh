#!/usr/bin/env bash
# probe-midgc-midhost0.sh — stage 7 O3's HAZARD PIN: the RUN-TIME override
# `QBE_MIDHOST=0` on a program built with the Mid collector.
#
# THE HAZARD IT PINS.  O3 flipped `QBE_MIDGC` to DEFAULT ON, so a fresh build
# routes every allocation through the Mid collector's heap — and the build
# still carries BOTH effect hosts, because the host is selected at RUN time by
# `Rt.main`'s getenv hatch.  So `QBE_MIDHOST=0 ./prog` on a default build would
# put the ZIG host (effectloop.zig: values.valString/valCons on the Zig
# nursery) on a MID heap — the stage-5 cross-heap edge, and NO compile-time
# guard can see a later run's environment.  run.js's MIDGC_DEPENDS_ON catches
# the same pairing when it is asked for at BUILD time (exit 2); this probe is
# about the binary that is already built.
#
# THE REFUSAL (chosen over silence, and over deleting the run-time hatch).  A
# QBE_MIDGC build's Rt.main now DIES LOUDLY on `QBE_MIDHOST=0`: runtime.mid's
# QBE_MIDGC-ONLY region calls Rt.die with a message that names the cause and
# the way out, exit 1, BEFORE the hatch can branch.  Silence was rejected
# because a differential user would read "QBE_MIDHOST=0 works" from a build
# where the Zig host never ran — a silent wrong CONCLUSION is worse than a
# refusal, and this arc has already paid for that class twice.
#
# THE ASYMMETRY (the proof, four arms, all MEASURED on this tree):
#   (a) MIDGC build, no env                -> the golden            (exit 0)
#   (b) MIDGC build, QBE_MIDHOST=0         -> the NAMED refusal     (exit 1)
#   (c) QBE_MIDGC=0 build, no env          -> the golden            (exit 0)
#   (d) QBE_MIDGC=0 build, QBE_MIDHOST=0   -> the golden            (exit 0)
#       — the differential survives exactly where it is SOUND (one heap, the
#       Zig collector, for both hosts), which is why the region is spliced OUT
#       of QBE_MIDGC=0 builds rather than dying at O4.
#   Plus the BUILD-time arm (e): `QBE_MIDGC=1 QBE_MIDHOST=0 node run.js` -> 2,
#   so the pair is refused at whichever layer sees it first.
#
# AND THE EMIT-LEVEL PIN: the refusal line is PRESENT in the default build's
# .ssa and ABSENT from the QBE_MIDGC=0 build's — so (b) and (d) are the splice's
# doing, not a coincidence of one fixture's env.
#
# Usage:
#   tools/qbe/probe-midgc-midhost0.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

FIXTURE="tools/qbe/fixtures/hostapply.elm"
MID="tools/qbe/fixtures/Whost.mid"
ENTRY="HostApply.main"
GOLDEN="$(cat tools/qbe/golden/hostapply.txt)"
REFUSAL="qbe-rt: QBE_MIDHOST=0 is refused"

need() { command -v "$1" >/dev/null 2>&1 || { echo "probe-midgc-midhost0: $1 not found" >&2; exit 2; }; }
need node
need cc

out="$(mktemp -d "${TMPDIR:-/tmp}/probe-midgc-midhost0.XXXXXX")"
trap 'rm -rf "$out"' EXIT
rc=0

# build <outdir> <env assignment or ''> — prints the binary path qbe-mk reports
# (the name comes from the LAST source, which here is the .mid, so it is
# `Whost` and not `hostapply` — read it, never assume it).
build() {
  if [ -n "$2" ]; then
    env "$2" "$ROOT/tools/qbe/qbe-mk.sh" "$FIXTURE" "$MID" "$ENTRY" "$1" 2>/dev/null | tail -1
  else
    "$ROOT/tools/qbe/qbe-mk.sh" "$FIXTURE" "$MID" "$ENTRY" "$1" 2>/dev/null | tail -1
  fi
}

# run <binary> <env assignment or ''> ; prints "<rc>|<output>"
run() {
  set +e
  if [ -n "$2" ]; then
    o="$(env "$2" timeout 60 "$1" "$ENTRY" 2>&1)"
  else
    o="$(timeout 60 "$1" "$ENTRY" 2>&1)"
  fi
  r=$?
  set -e
  printf '%s|%s' "$r" "$o"
}

# ---- (a)/(b): the DEFAULT build (MIDGC on) ----
mkdir -p "$out/midgc" "$out/zig"
binA="$(build "$out/midgc" "")"
if [ -z "$binA" ] || [ ! -x "$binA" ]; then
  echo "FAIL: the DEFAULT (QBE_MIDGC on) build of $FIXTURE failed — this probe cannot measure anything" >&2
  exit 1
fi
a="$(run "$binA" "")"
b="$(run "$binA" QBE_MIDHOST=0)"

# ---- (c)/(d): the QBE_MIDGC=0 build (the Zig collector, the differential) ----
binC="$(build "$out/zig" QBE_MIDGC=0)"
if [ -z "$binC" ] || [ ! -x "$binC" ]; then
  echo "FAIL: the QBE_MIDGC=0 build failed — the escape hatch is broken, so (d) cannot be measured" >&2
  exit 1
fi
c="$(run "$binC" "")"
d="$(run "$binC" QBE_MIDHOST=0)"

# ---- (e): the BUILD-time half of the same refusal ----
set +e
( cd "$ROOT/elm-compiler" &&
  QBE=1 QBE_ENTRY="$ENTRY" QBE_MIDGC=1 QBE_MIDHOST=0 node run.js \
    "$ROOT/$FIXTURE" "$ROOT/$MID" "$out/buildrefuse.ssa" ) >/dev/null 2>"$out/buildrefuse.err"
e=$?
set -e

check_golden() { # <label> <rc|output>
  local lab="$1" r="${2%%|*}" o="${2#*|}"
  if [ "$r" -ne 0 ] || [ "$o" != "$GOLDEN" ]; then
    echo "FAIL ($lab): exit $r, output '$o' — want exit 0 and the golden '$GOLDEN'" >&2
    rc=1
  else
    echo "PASS ($lab): exit 0, golden '$o'"
  fi
}

check_golden "a: MIDGC build, no env (the DEFAULT route)" "$a"

case "$b" in
  1\|"$REFUSAL"*) echo "PASS (b: MIDGC build, QBE_MIDHOST=0): refused by name, exit 1 — ${b#*|}" ;;
  *) echo "FAIL (b): MIDGC build + QBE_MIDHOST=0 gave '$b' — want exit 1 and a message starting '$REFUSAL'.  SILENCE HERE IS THE HOLE: the Zig host would run on a Mid heap." >&2; rc=1 ;;
esac

check_golden "c: QBE_MIDGC=0 build, no env" "$c"
check_golden "d: QBE_MIDGC=0 build, QBE_MIDHOST=0 (the differential, still runnable)" "$d"

if [ "$e" -eq 2 ] && grep -q "requires the Mid effect host" "$out/buildrefuse.err"; then
  echo "PASS (e: QBE_MIDGC=1 QBE_MIDHOST=0 at BUILD time): exit 2, named by run.js MIDGC_DEPENDS_ON"
else
  echo "FAIL (e): the build-time pair gave exit $e: $(tail -c 200 "$out/buildrefuse.err")" >&2
  rc=1
fi

# THE EMIT-LEVEL ASYMMETRY: the region is spliced by the flag, so the two builds
# differ in a way no fixture can fake.
in_midgc="$(grep -c "$REFUSAL" "${binA}.ssa" 2>/dev/null || true)"
in_zig="$(grep -c "$REFUSAL" "${binC}.ssa" 2>/dev/null || true)"
if [ "${in_midgc:-0}" -ge 1 ] && [ "${in_zig:-1}" -eq 0 ]; then
  echo "PASS (emit): the refusal is in the MIDGC build's .ssa ($in_midgc line) and spliced OUT of the QBE_MIDGC=0 build (0)"
else
  echo "FAIL (emit): refusal lines midgc=${in_midgc:-?} zig=${in_zig:-?} — want >=1 in the MIDGC build and 0 in the QBE_MIDGC=0 build (the splice is not doing what the run-time arms above suggest)" >&2
  rc=1
fi

if [ "$rc" -eq 0 ]; then
  echo "probe-midgc-midhost0: PASS — a MIDGC build refuses the run-time Zig-host override BY NAME (no silent cross-heap arm), and the differential stays runnable in a QBE_MIDGC=0 build."
fi
exit "$rc"
