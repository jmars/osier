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
#          LOUDLY.  `types.zig` and `tools/qbe/rt.zig` each carry a `comptime`
#          row asserting their own declarations equal those consts, so the
#          collector's own suite (`zig build gate`, step 6 of
#          tools/osier-numbers.sh) fails to COMPILE on a mismatch.
#   ZIG    `tools/qbe/layout-probe.zig` PRINTS what the Zig compiler computes
#          for `types.Value`/`types.ValTag` (`@sizeOf`/`@alignOf`/`@offsetOf`/
#          `@intFromEnum` — the ABI as laid out, not as re-parsed), and
#          `max_arity` is read from rt.zig's own declaration.  Both are diffed
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
GEN="$ROOT/vendor/osier-rt/src/gc/layout_gen.zig"
PROBE="$ROOT/tools/qbe/layout-probe.zig"
RTZ="$ROOT/tools/qbe/rt.zig"

die()  { printf 'layout-census: FAIL: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || { printf 'layout-census: %s not found\n' "$1" >&2; exit 2; }; }

[ -f "$MID" ] || { echo "layout-census: no $MID" >&2; exit 2; }

# ---- the expected name set (the parse contract), split by which leg ---------
# MID_ONLY: no Zig declaration is asserted (see NAMES WITH NO ZIG COUNTERPART).
# The ep* exec-plan blob constants moved here at 3B-2b: the blob is now
# MID-INTERNAL (the Mid decode writes it, the Mid Rt.execGo run reads it; the
# rt_exec_run seat that once read it is DELETED as of 3B-2c), so there
# is no Zig counterpart to assert against anymore.
MID_ONLY_NAMES="epChainOpIdx epChainPipeIdx epChainWords epCmdArgcIdx epCmdArgvIdx epCmdNredirsIdx epCmdRedirsIdx epCmdSubIdx epCmdWords epKindAppend epKindDup epKindHdoc epKindHstr epKindIn epKindOut epOpAnd epOpOr epOpSeq epPipeCmdArrIdx epPipeCmdCountIdx epProgChainsIdx epProgCountIdx epRedirBodyIdx epRedirDupfdIdx epRedirFdIdx epRedirKindIdx epRedirPathIdx epRedirTmpfdIdx epRedirWords"
# COMPTIME: attested by a comptime row against layout_gen.zig, in a file the
# probe cannot import (an `export fn main`/`pub fn main` collides with an
# executable's): rt.zig carries the Desc/Meta/Ret rows;
# vendor/osier-rt/src/rt/execplan.zig carries direntNameOffset (its own
# `Dirent` declaration — the one Zig statement of the libc struct's layout);
# (the ep* exec-plan blob rows lived here from 3B-2a until 3B-2b moved the
# RUN into Mid and the seat stopped reading the blob).
COMPTIME_FILES="tools/qbe/rt.zig vendor/osier-rt/src/rt/execplan.zig"
COMPTIME_NAMES="descArityOffset descCacheOffset descCodeOffset descNcapsOffset descTotalBytes \
direntNameOffset \
metaArityOffset metaCodeOffset metaNameOffset metaSizeBytes \
retArgsOffset retArityOffset retEOffset retFOffset retKindOffset retSizeBytes retValOffset"
# REGEX: read from rt.zig's own declaration text (a non-pub const no probe can see).
REGEX_NAMES="maxArity"
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

# ---- the ZIG leg: the probe, plus the one const only text can reach ---------
zig_values() {
  # std.debug.print writes to STDERR; the pattern filter keeps the probe's own
  # lines and drops any compiler chatter.
  local raw
  raw="$( ( cd "$ROOT" && zig run -lc --dep gc \
      -Mroot=tools/qbe/layout-probe.zig -Mgc=vendor/osier-rt/src/gc.zig ) 2>&1 )"
  if ! printf '%s\n' "$raw" | grep -qE '^abiAlign=[0-9]+$'; then
    printf 'layout-census: FAIL: the Zig probe did not run.  Its own output:\n' >&2
    printf '%s\n' "$raw" | tail -12 | sed 's/^/    /' >&2
    exit 1
  fi
  printf '%s\n' "$raw" | grep -E '^[a-z][a-zA-Z0-9_]*=[0-9]+$' | sort
  awk 'match($0, /^const max_arity: i32 = [0-9]+;$/) {
         v = $0; sub(/^const max_arity: i32 = /, "", v); sub(/;$/, "", v);
         print "maxArity=" v; found = 1
       }
       END { if (!found) exit 1 }' "$RTZ" || die "rt.zig: no anchored 'const max_arity: i32 = N;' declaration to read"
}

# ---- the generation ---------------------------------------------------------
gen_file() {
  cat <<'HDR'
//! layout_gen.zig — GENERATED by `tools/qbe/layout-census.sh --gen` from
//! `elm-compiler/src/Mid/RtLayout.elm`.  DO NOT EDIT BY HAND.
//!
//! THE LAYOUT IS DEFINED ONCE, IN MID (handoff-osier-zigretire-plan STAGE 2):
//! `Mid/RtLayout.elm` carries the cross-ABI numbers, `Mid.Qbe.Il` and
//! `Mid.Qbe.Lower` DERIVE the emitted IL from them, `Mid.RtPrims` reads the
//! tag integers from them, and this file is that same definition as Zig
//! constants.  `types.zig` and `tools/qbe/rt.zig` each carry a `comptime` row
//! asserting their own declarations equal these values, so a mismatch is a
//! COMPILE ERROR in the collector's own suite (`zig build gate`) rather than a
//! silently wrong offset at run time.
//!
//! Regenerate with `tools/qbe/layout-census.sh --gen > <this file>`; the
//! census's `--check` fails loudly when the committed copy drifts from Mid.
HDR
  mid_values | while IFS='=' read -r name value; do
    printf '\npub const %s = %s;\n' "$name" "$value"
  done
}

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

check_gen() {
  [ -f "$GEN" ] || die "no committed $GEN (generate it: layout-census.sh --gen)"
  local tmp; tmp="$(mktemp)"
  gen_file > "$tmp"
  if ! cmp -s "$tmp" "$GEN"; then
    printf 'layout-census: FAIL: %s is NOT what Mid.RtLayout.elm generates.\n' "${GEN#$ROOT/}" >&2
    diff -u "$GEN" "$tmp" | sed -n '1,40p' | sed 's/^/    /' >&2
    printf '    remedy: tools/qbe/layout-census.sh --gen > %s\n' "${GEN#$ROOT/}" >&2
    rm -f "$tmp"; exit 1
  fi
  rm -f "$tmp"
  echo "layout-census: gen    OK — ${GEN#$ROOT/} matches Mid.RtLayout.elm"
}

check_zig() {
  local want have name probed=0
  want="$(mid_values)"
  have="$(zig_values)"
  local bad=0
  while IFS='=' read -r name value; do
    [ -n "$name" ] || continue
    case " $(printf '%s' "$MID_ONLY_NAMES $COMPTIME_NAMES") " in
      *" $name "*) continue ;;
    esac
    probed=$((probed + 1))
    local got; got="$(printf '%s\n' "$have" | grep -F "$name=" | head -1 | cut -d= -f2)"
    if [ -z "$got" ]; then
      printf 'layout-census: FAIL: Zig side did not report %s at all (the leg lost a name)\n' "$name" >&2
      bad=1
    elif [ "$got" != "$value" ]; then
      printf 'layout-census: FAIL: %s — Mid.RtLayout.elm says %s, the Zig side says %s\n' "$name" "$value" "$got" >&2
      bad=1
    fi
  done <<< "$want"
  if [ "$bad" -ne 0 ]; then
    printf '  (Mid.RtLayout.elm is the definition — fix the ZIG side, or change the definition in Mid and regenerate)\n' >&2
    exit 1
  fi
  echo "layout-census: zig    OK — $probed probed constant(s) agree with Mid.RtLayout.elm"
  echo "layout-census: zig    OK — $(printf '%s\n' $REGEX_NAMES | grep -c .) read from rt.zig's declaration, agree"
  # The COMPTIME_NAMES leg — the census CANNOT verify these VALUES (its probe
  # cannot import the asserting file: `main` collides), so the assertion lives
  # in each file's own comptime row, compiled by rt-o.sh.  What this script
  # CAN and MUST check is that some row still NAMES each constant: without
  # this, deleting an assertion would leave the census GREEN over an
  # unasserted constant — a false pass over exactly the seat this leg exists
  # to cover.
  local missing="" name
  for name in $COMPTIME_NAMES; do
    local found=""
    local f
    for f in $COMPTIME_FILES; do
      grep -q "Mid\.RtLayout\.$name" "$ROOT/$f" && found=1 && break
    done
    [ -n "$found" ] || missing="$missing $name"
  done
  if [ -n "$missing" ]; then
    printf 'layout-census: FAIL: no comptime row asserts:%s\n' "$missing" >&2
    printf '  (a row in %s must name Mid.RtLayout.<constant> for each — see tools/qbe/rt.zig)\n' "$COMPTIME_FILES" >&2
    exit 1
  fi
  echo "layout-census: comptime OK — ${COMPTIME_NAMES// /, } are named by a comptime row in: $COMPTIME_FILES; those rows are compiled by rt-o.sh, NOT by zig build gate"
  if [ -n "$MID_ONLY_NAMES" ]; then
    echo "layout-census: mid    OK — $MID_ONLY_NAMES has no Zig counterpart (checked where it is read instead)"
  else
    echo "layout-census: mid    OK — every constant in Mid.RtLayout.elm has a Zig counterpart"
  fi
}

values_block() {
  echo "# layout census — Mid.RtLayout.elm, the single definition"
  mid_values
}

case "${1:-}" in
  --values)  values_block ;;
  --gen)     gen_file ;;
  --marker)  values_block | sha256sum | cut -c1-64 ;;
  --check)   check_names; check_gen ;;
  --zig)     check_names; check_zig ;;
  ""|--all)
    check_names
    check_gen
    check_zig
    ;;
  *) echo "layout-census: usage: layout-census.sh [--values|--gen|--check|--zig|--marker]" >&2; exit 2 ;;
esac
