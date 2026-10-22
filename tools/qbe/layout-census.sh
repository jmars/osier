#!/usr/bin/env bash
# layout-census.sh — THE ONE-PLACE LAYOUT CENSUS (handoff-osier-zigretire-plan
# STAGE 2).
#
# WHAT THIS EXISTS FOR.  The heap/value layout is a cross-ABI contract: the
# emitted QBE IL (`:val`/`:ret`/`:desc`, payload word offsets, tag integers),
# the Zig runtime that scans and builds those objects (`types.zig`, `rt.zig`),
# and — after Phase 4b — the Mid-written collector.  Every one of those used
# to carry its own copy of the numbers, and a mismatch LINKS CLEANLY and then
# reads another struct's bytes at the wrong offset.  Since stage 2 the numbers
# are defined once, in `elm-compiler/src/Mid/RtLayout.elm`, and this script is
# how the OTHER copies are brought to it — loudly.
#
# THE THREE LEGS.
#   MID    `elm-compiler/src/Mid/RtLayout.elm` is parsed as TEXT (the module
#          states every constant as `name =` / `    <digits>`, and the parse
#          is checked against an EXPECTED NAME LIST below — a renamed or
#          dropped constant is a census FAILURE, never a silent skip).
#   GEN    the same numbers are written as Zig consts into
#          `vendor/osier-rt/src/gc/layout_gen.zig`; `--check` regenerates and
#          diffs, so a Mid edit that was not carried into the Zig copy fails
#          LOUDLY.  `types.zig` and `tools/qbe/hostshim.zig` each carry a `comptime`
#          row asserting their own declarations equal those consts, so the
#          collector's own suite (`zig build gate`, step 6 of
#          tools/osier-numbers.sh) fails to COMPILE on a mismatch.
#   ZIG    `tools/qbe/layout-probe.zig` PRINTS what the Zig compiler computes
#          for `types.Value`/`types.ValTag` (`@sizeOf`/`@alignOf`/`@offsetOf`/
#          `@intFromEnum` — the ABI as laid out, not as re-parsed), and
#          `max_arity` is read from hostshim.zig's own declaration.  Both are diffed
#          against MID.  The Desc/Meta/Ret offsets live in rt.zig, which the
#          probe cannot import (rt.zig exports `main`); they are covered by
#          the comptime row in rt.zig, and this script SAYS SO rather than
#          implying a diff it did not make.
#
# NAMES WITH NO ZIG COUNTERPART: none — every constant in Mid/RtLayout.elm is
# attested by one of the three legs (MID_ONLY_NAMES below is the escape hatch
# for a constant that has no Zig declaration at all, and it is EMPTY on
# purpose: a number with no reader on either side is a seat nobody sits in).
#
# USAGE
#   tools/qbe/layout-census.sh            -- full check: names, --check, --zig
#   tools/qbe/layout-census.sh --values   -- print the canonical Mid block
#   tools/qbe/layout-census.sh --gen      -- write layout_gen.zig (stdout)
#   tools/qbe/layout-census.sh --check    -- regenerate + diff vs the committed file
#   tools/qbe/layout-census.sh --zig      -- probe the Zig side + diff vs Mid
#   tools/qbe/layout-census.sh --marker   -- sha256 of the canonical block
#                                            (abi-fingerprint.sh's gc:layout)
# Exit: 0 consistent; 1 a MISMATCH (loud, names the constant); 2 tooling.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MID="$ROOT/elm-compiler/src/Mid/RtLayout.elm"
# (ZIGHOST Z6) GEN / PROBE / RTZ named the three Zig artifacts this census used
# to cross-check against — layout_gen.zig, layout-probe.zig and hostshim.zig.
# All three are deleted; only the Mid leg is left.

die()  { printf 'layout-census: FAIL: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || { printf 'layout-census: %s not found\n' "$1" >&2; exit 2; }; }

[ -f "$MID" ] || { echo "layout-census: no $MID" >&2; exit 2; }

# ---- the expected name set (the parse contract), split by which leg ---------
# MID_ONLY: no Zig declaration is asserted (see NAMES WITH NO ZIG COUNTERPART).
# The ep* exec-plan blob constants moved here at 3B-2b: the blob is now
# MID-INTERNAL (the Mid decode writes it, the Mid Rt.execGo run reads it; the
# rt_exec_run seat that once read it is DELETED as of 3B-2c), so there
# is no Zig counterpart to assert against anymore.
MID_ONLY_NAMES="descArityOffset descCacheOffset descCodeOffset descNcapsOffset descTotalBytes \
direntNameOffset maxArity \
metaArityOffset metaCodeOffset metaNameOffset metaSizeBytes \
retArgsOffset retArityOffset retEOffset retFOffset retKindOffset retSizeBytes retValOffset \
epChainOpIdx epChainPipeIdx epChainWords epCmdArgcIdx epCmdArgvIdx epCmdNredirsIdx epCmdRedirsIdx epCmdSubIdx epCmdWords epKindAppend epKindDup epKindHdoc epKindHstr epKindIn epKindOut epOpAnd epOpOr epOpSeq epPipeCmdArrIdx epPipeCmdCountIdx epProgChainsIdx epProgCountIdx epRedirBodyIdx epRedirDupfdIdx epRedirFdIdx epRedirKindIdx epRedirPathIdx epRedirTmpfdIdx epRedirWords"
# COMPTIME: attested by a comptime row against layout_gen.zig, in a file the
# probe cannot import (an `export fn main`/`pub fn main` collides with an
# executable's): rt.zig carries the Desc/Meta/Ret rows;
# vendor/osier-rt/src/rt/execplan.zig carries direntNameOffset (its own
# `Dirent` declaration — the one Zig statement of the libc struct's layout);
# (the ep* exec-plan blob rows lived here from 3B-2a until 3B-2b moved the
# RUN into Mid and the seat stopped reading the blob).
# (ZIGHOST Z6) THE ZIG LEG IS DELETED.  These three groups used to be asserted
# against hostshim.zig / rt.zig / execplan.zig by a comptime row, a text regex
# and a probe.  There is no Zig side at all now, so they join MID_ONLY_NAMES:
# what the census still checks is that Mid.RtLayout.elm PARSES to this exact
# name set — a constant added, renamed or dropped without the census noticing
# is still a loud failure.  The VALUES are checked where they are read (the
# emitted IL, which the corpus pins byte-for-byte).
COMPTIME_FILES=""
COMPTIME_NAMES=""
REGEX_NAMES=""
# everything else is PROBED.

all_names() {
  printf '%s\n' "$MID_ONLY_NAMES" "$COMPTIME_NAMES" "$REGEX_NAMES" \
    abiAlign i32Bytes lenFieldOffset lenFieldWord payloadBase \
    tagBoolean tagCons tagError tagFloat tagLambda tagMark tagNil tagNumber \
    tagPrim tagRecord tagStream tagString tagSymbol tagVector \
    valSizeBytes valuePayloadWords valueTagBytes wordBytes | tr ' ' '\n' | grep -v '^$' | sort
}

# ---- the MID leg: parse Mid/RtLayout.elm as text ----------------------------
mid_values() {
  awk '
    /^[a-z][a-zA-Z0-9_]* =$/ { name = substr($0, 1, length($0) - 2); pend = 1; next }
    pend && /^    [0-9]+$/   { print name "=" ($0 + 0); pend = 0; next }
    { pend = 0 }
  ' "$MID" | sort
}

# (ZIGHOST Z6) the ZIG leg — `zig run tools/qbe/layout-probe.zig` plus the
# `max_arity` text read — is DELETED with the files it read.

# (ZIGHOST Z6) gen_file() is DELETED: it printed the Zig constants file
# (vendor/osier-rt/src/gc/layout_gen.zig) that `Mid.RtLayout.elm` used to be
# mirrored into, and that file is gone with the package.  `--gen` refuses by
# name (see the case arm below).  What the census still OWNS is the Mid block
# itself: --values prints it, --marker digests it (the ABI marker's gc:layout
# component), --check asserts its NAME SET against this script's list.

# ---- checks -----------------------------------------------------------------
check_names() {
  local got want
  got="$(mid_values | cut -d= -f1)"
  want="$(all_names)"
  if [ "$got" != "$want" ]; then
    printf 'layout-census: FAIL: Mid.RtLayout.elm parses to a DIFFERENT name set than this script expects.\n' >&2
    printf '  only in Mid.RtLayout.elm: %s\n' "$(printf '%s\n' "$got" | grep -vxF -e "$want" | paste -sd' ' || true)" >&2
    printf '  only in the census list:  %s\n' "$(printf '%s\n' "$want" | grep -vxF -e "$got" | paste -sd' ' || true)" >&2
    printf '  (a layout constant was added/renamed/removed without a census leg: make it checkable, then update this script)\n' >&2
    exit 1
  fi
}

# (ZIGHOST Z6) check_gen / check_zig are DELETED: their subjects were
# vendor/osier-rt/src/gc/layout_gen.zig (generated) and the Zig probe that read
# the runtime's own declarations.  Both files are gone, so the census has ONE
# leg — the Mid block — and --gen/--zig refuse by name rather than print a
# half-truth (see the case arm at the bottom).

values_block() {
  echo "# layout census — Mid.RtLayout.elm, the single definition"
  mid_values
}

case "${1:-}" in
  --values)  values_block ;;
  --marker)  values_block | sha256sum | cut -c1-64 ;;
  --check)   check_names ;;
  ""|--all)  check_names ;;
  --gen)
    echo "layout-census: --gen is RETIRED at ZIGHOST Z6 (its output, vendor/osier-rt/src/gc/layout_gen.zig, was deleted with the Zig runtime)" >&2
    exit 2 ;;
  --zig)
    echo "layout-census: --zig is RETIRED at ZIGHOST Z6 (there is no Zig side to probe)" >&2
    exit 2 ;;
  *) echo "layout-census: usage: layout-census.sh [--values|--check|--marker]" >&2; exit 2 ;;
esac
