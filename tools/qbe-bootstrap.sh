#!/usr/bin/env bash
# qbe-bootstrap.sh — THE BOOTSTRAP: a committed .ssa + qbe + cc, no node, no elm.
#
#   tools/qbe-bootstrap.sh [--out <path>] [--verify] [--check] [--freeze]
#
# WHAT THIS IS FOR.  Since P8 (osier-delete-zinc) the only way to get a
# compiler out of a bare checkout was: build compiler.js with elm 0.19.2, then
# run the whole compiler through node (run.js) to emit QBE IL, then qbe+cc —
# i.e. node and elm were the root of the compiler's own build.  They are not
# any more for the QBE lane: the whole compiler's .ssa is a FIXED POINT
# (qbe-selfhost.sh's oracle: the compiler the .ssa builds re-emits the same
# .ssa byte-for-byte), so that one file plus the vendored backend and a C
# compiler rebuild the compiler — no node, no elm, no interpreter.
#
# THE CHAIN (default mode, and the only mode that is node-free):
#   1. ABI GUARD   the seed's marker vs the CURRENT tree (abi-fingerprint.sh).
#                  A .ssa and an rt.o from different runtime revisions link
#                  cleanly and then read each other's structs at the wrong
#                  offsets — a silent wrong answer.  Refuses on a mismatch.
#   2. rt.o        tools/qbe/rt-o.sh (the ONE copy of the freshness-guarded
#                  graph: fail-safe probe, loud refusal on a failed rebuild).
#   3. qbe         vendor/qbe/qbe (built by tools/qbe-build.sh: cc + make only).
#   4. cc          seed.ssa -> .s -> the native compiler, linked with rt.o.
#   5. (--verify)  that compiler's OWN --ssa emit, cmp'd against the seed —
#                  the fixed point, in the direct form (see BELOW).
#
# WHY --verify IS NOT qbe-selfhost.sh.  qbe-selfhost.sh is the whole-corpus
# ORACLE: it emits the .ssa twice from node (determinism), budget-checks the
# emit, and runs the native compiler at QBE_HEAP_MB=32768.  Bootstrapping does
# not need any of that, and a bootstrap must not depend on the thing it
# bootstraps away.  --verify therefore runs the native emit ONCE, at a heap
# the caller sizes (QBE_BOOTSTRAP_HEAP_MB), straight against the committed
# seed.  The .ssa is BYTE-IDENTICAL to the stock emit, so "cmp the re-emit
# with the seed" IS "cmp the re-emit with the stock emit" — that is the
# fixed point, and no node process is involved in establishing it.
#
# TEXT, NOT COMPRESSED, AND WHY.  tools/bootstrap/compiler.ssa is 12.6 MB of
# plain QBE IL committed to git.  Compressing it would save ~11 MB and cost
# the whole property: the chain above would need a decompressor, i.e. a tool
# that is not qbe and not cc.  The seed's entire value is that two binaries
# the tree already vendors rebuild the compiler from it.
#
# THE SEED IS A SEED, NOT A CURRENCY.  It WILL drift as sources change, and
# that is fine: a stale seed still bootstraps, and the compiler it builds
# compiles the CURRENT sources.  `--status` (and tools/osier-numbers.sh's
# `seed status:` line) reports FRESH/DRIFTED and NEVER fails.  The load-bearing
# correctness oracle is the .ssa fixed point and the test suites — not this
# file's age.  Do not add a gate on staleness.
#
# REGENERATION (the only path here that touches node; see PROVENANCE.md):
#   tools/qbe-bootstrap.sh --freeze
# re-emits the seed from the CURRENT manifest with the stock compiler and
# re-freezes the marker with it.  Both must move together.
#
# Usage / env:
#   --out <path>              where the native compiler lands
#                             (default $ROOT/zig-out/bin/qbe-bootstrap; zig-out/
#                             is gitignored).  Also QBE_BOOTSTRAP_BIN.
#   QBE_BOOTSTRAP_WORK        scratch dir instead of a fresh mktemp -d.
#   QBE_BOOTSTRAP_HEAP_MB     GC heap for --verify's native emit (default
#                             below).  The corpus's live set is multi-GB: too
#                             small a heap is a LOUD panic, not a wrong answer.
#   QBE_BOOTSTRAP_VERIFY=1    same as --verify.
#
# Exit: 0 bootstrapped; 1 the ABI guard fired (seed vs tree mismatch — the
#       message names the component); 2 tooling failure; 4 --verify's
#       byte-identity failed (a FINDING about the seed, not the tree).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SEED="$ROOT/tools/bootstrap/compiler.ssa"
ABI="$ROOT/tools/bootstrap/compiler.ssa.abi"
MANIFEST="$ROOT/elm-compiler/selfhost/manifest.json"
ENTRY="NativeMain.main"
BIN="${QBE_BOOTSTRAP_BIN:-$ROOT/zig-out/bin/qbe-bootstrap}"
# The native emit's GC heap.  16384 is the value the whole-compiler runs have
# used since the manifest grew the middle tier; it is NOT free (the live set
# is multi-GB) and it is a knob because a smaller machine can lower it and pay
# with time (or a loud `heap exhausted` panic).  Only --verify reads it.
HEAP_MB="${QBE_BOOTSTRAP_HEAP_MB:-16384}"
VERIFY=0
if [ "${QBE_BOOTSTRAP_VERIFY:-0}" = 1 ]; then VERIFY=1; fi

MODE=bootstrap
while [ $# -gt 0 ]; do
  case "$1" in
    --out)    BIN="$2"; shift 2;;
    --verify) VERIFY=1; shift;;
    --check)  MODE=check; shift;;
    --freeze) MODE=freeze; shift;;
    --status) MODE=status; shift;;
    *) echo "qbe-bootstrap: unknown argument '$1'" >&2; exit 2;;
  esac
done
if [ "$MODE" = bootstrap ] && [ "$VERIFY" = 1 ]; then MODE=verify; fi

say()   { printf '%s\n' "$*"; }
step()  { printf '%s\n' "$*" >&2; }
die()   { printf 'qbe-bootstrap: %s\n' "$*" >&2; exit 2; }
now()   { date +%s%N; }
secs()  { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", (b - a) / 1000000000 }'; }

# ---- --freeze: regenerate the seed AND its marker, together ---------------
# The ONLY node-using path in this file.  It runs the stock compiler (node
# run.js --batch) over the CURRENT selfhost manifest, because the seed must be
# the stock emit's own bytes; a seed from anywhere else would not be the fixed
# point.
if [ "$MODE" = freeze ]; then
  command -v node >/dev/null 2>&1 || die "node not found (--freeze needs the stock compiler)"
  command -v jq   >/dev/null 2>&1 || die "jq not found (--freeze builds the batch manifest)"
  [ -f "$MANIFEST" ] || die "manifest missing: $MANIFEST"
  mkdir -p "$(dirname "$SEED")"
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/qbe-freeze.XXXXXX")"
  trap 'rm -rf "$WORK"' EXIT
  jq --arg out "$SEED" --arg entry "$ENTRY" \
     '.groups[0].output = $out | .groups[0].entry = $entry' "$MANIFEST" > "$WORK/emit.json"
  t0=$(now)
  node "$ROOT/elm-compiler/run.js" --batch "$WORK/emit.json" || die "the stock emit failed"
  t1=$(now)
  case "$(head -c 4 "$SEED")" in
    "err "*) die "the stock emit FAILED: $(head -c 300 "$SEED")";;
  esac
  [ -s "$SEED" ] || die "the stock emit produced no output"
  "$ROOT/tools/qbe/abi-fingerprint.sh" --write "$ABI" "$SEED" >&2
  say "qbe-bootstrap: seed frozen — $(stat -c %s "$SEED") bytes in $(secs "$t0" "$t1") s, marker in $ABI"
  exit 0
fi

# ---- the seed + its marker must both be present ---------------------------
[ -s "$SEED" ] || die "no committed seed at $SEED"
[ -f "$ABI" ]  || die "no ABI marker at $ABI (regenerate: tools/qbe-bootstrap.sh --freeze)"

# ---- 1. THE ABI GUARD -----------------------------------------------------
# Fails LOUDLY and SPECIFICALLY: abi-fingerprint.sh names which component of
# the runtime interface moved.  A guard that cannot be shown to fire is not
# delivered — tools/qbe/abi-fingerprint.sh --check against a perturbed copy is
# the demonstration (see $ROOT/tools/bootstrap/PROVENANCE.md).
guard_rc=0
"$ROOT/tools/qbe/abi-fingerprint.sh" --check "$ABI" || guard_rc=$?
if [ "$guard_rc" = 3 ]; then
  printf 'qbe-bootstrap: REFUSING — the seed does not match this tree (above).\n' >&2
  printf '   Regenerate the seed and the marker TOGETHER: tools/qbe-bootstrap.sh --freeze\n' >&2
  exit 1
elif [ "$guard_rc" != 0 ]; then
  die "the ABI guard could not run (exit $guard_rc)"
fi

if [ "$MODE" = status ]; then
  printf 'seed %s bytes, %s\n' "$(stat -c %s "$SEED")" "$(sha256sum "$SEED" | cut -c1-16)…"
  printf 'abi %s\n' "$(grep -E '^abi-marker=' "$ABI" | cut -d= -f2)"
  printf '%s\n' "$("$ROOT/tools/qbe/abi-fingerprint.sh" --status "$ABI")"
  exit 0
fi

# ---- preflight (before anything expensive, and before any output) ---------
command -v cc >/dev/null 2>&1 || die "cc not found"
if [ "$MODE" = verify ]; then
  command -v jq >/dev/null 2>&1 || die "jq not found (--verify builds the run manifest)"
fi

# ---- 2. the runtime object (ONE shared freshness-guarded graph) -----------
step "== 1/4 rt.o (tools/qbe/rt-o.sh)"
RT="$("$ROOT/tools/qbe/rt-o.sh")" || die "rt.o unavailable"
[ -s "$RT" ] || die "rt-o.sh returned $RT but it is empty"

# ---- 3. the vendored backend ----------------------------------------------
QBE="$ROOT/vendor/qbe/qbe"
if [ ! -x "$QBE" ]; then
  step "== 2/4 $QBE missing — building it (tools/qbe-build.sh: cc + make only)"
  "$ROOT/tools/qbe-build.sh" >&2 || die "qbe build failed"
fi

if [ "$MODE" = check ]; then
  say "qbe-bootstrap: CHECK OK — seed $(stat -c %s "$SEED") B, ABI marker matches, rt.o + qbe present"
  exit 0
fi

# ---- scratch ---------------------------------------------------------------
CLEAN=1
if [ -n "${QBE_BOOTSTRAP_WORK:-}" ]; then
  WORK="$QBE_BOOTSTRAP_WORK"; CLEAN=0; mkdir -p "$WORK"
else
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/qbe-bootstrap.XXXXXX")" || die "mktemp -d failed"
fi
if [ "$CLEAN" = 1 ]; then trap 'rm -rf "$WORK"' EXIT; else trap ':' EXIT; fi
mkdir -p "$(dirname "$BIN")"

# ============================ 4. .ssa -> .s ============================
step "== 3/4 $QBE $SEED -> compiler.s"
t1=$(now)
"$QBE" "$SEED" > "$WORK/compiler.s" || die "qbe exited non-zero"
[ -s "$WORK/compiler.s" ] || die "qbe produced no output"
t2=$(now)

# ============================ 5. .s -> native compiler ============================
step "== 4/4 cc compiler.s rt.o -> $BIN"
t3=$(now)
cc "$WORK/compiler.s" "$RT" -o "$BIN" -lc || die "cc failed"
[ -x "$BIN" ] || die "cc produced no executable"
t4=$(now)

# ---- the arity table, explicitly -------------------------------------------
# rt.o dispatches into `$rt_call0..$rt_callN` — functions the SEED defines
# (Il/Lower.emitRTCall...): the arity ceiling is an ABI term shared by two
# files that never see each other's source, and a truncated table is a
# runtime `arity exceeds the qbe rt_callN table` death (loud), not a wrong
# answer.  cc's link already refuses a MISSING symbol; this asserts the two
# halves in ONE artifact, which is what a reader wants to see.
expect_n="$(grep -cE '^extern fn rt_call[0-9]+' "$ROOT/tools/qbe/rt.zig" || true)"
if command -v nm >/dev/null 2>&1; then
  have_n="$(nm "$BIN" 2>/dev/null | grep -cE ' T rt_call[0-9]+$' || true)"
  say "qbe-bootstrap: rt_callN table — rt.zig externs $expect_n, the linked compiler defines $have_n"
  [ "$expect_n" = "$have_n" ] \
    || die "the linked compiler defines $have_n of the $expect_n rt_callN symbols rt.zig externs"
else
  say "qbe-bootstrap: nm not found — the rt_callN table cross-check was NOT run" >&2
fi

say "qbe-bootstrap: qbe      $(secs "$t1" "$t2") s  ($(stat -c %s "$WORK/compiler.s") B .s)"
say "qbe-bootstrap: cc       $(secs "$t3" "$t4") s  ($(stat -c %s "$BIN") B native compiler)"
say "qbe-bootstrap: OK — $BIN built from the committed seed; node and elm not invoked"
[ "$CLEAN" = 1 ] || say "qbe-bootstrap: scratch kept at $WORK"

if [ "$MODE" != verify ]; then
  exit 0
fi

# ============================ 6. --verify: the .ssa fixed point ============================
# A DIRECT comparison (see the header): one native emit, cmp'd with the seed.
step "== verify: AOTRUN_ARGV=1 QBE_HEAP_MB=$HEAP_MB $BIN $ENTRY --ssa $ENTRY <manifest>"
jq -r --arg out "$WORK/selfhost2.ssa" '.groups[] | (.sources[] | .), "-> \($out)"' \
  "$MANIFEST" > "$WORK/run.manifest"
t5=$(now)
AOTRUN_ARGV=1 QBE_HEAP_MB="$HEAP_MB" "$BIN" "$ENTRY" --ssa "$ENTRY" "$WORK/run.manifest" \
  || die "the native compiler's --ssa run exited non-zero"
t6=$(now)
[ -s "$WORK/selfhost2.ssa" ] || die "the native compiler wrote no .ssa"
case "$(head -c 4 "$WORK/selfhost2.ssa")" in
  "err "*) die "the native --ssa run FAILED: $(head -c 300 "$WORK/selfhost2.ssa")";;
esac

say "qbe-bootstrap: ssa-emit $(secs "$t5" "$t6") s  ($(stat -c %s "$WORK/selfhost2.ssa") B .ssa)"
if cmp -s "$WORK/selfhost2.ssa" "$SEED"; then
  say "qbe-bootstrap: FIXED POINT — the compiler built from the seed re-emits the seed byte-for-byte"
  exit 0
fi
say "qbe-bootstrap: FIXED POINT FAILED — the seed-built compiler's .ssa differs from the seed." >&2
say "   The committed seed is NOT a fixed point of this tree; re-freeze it (--freeze)" >&2
say "   ONLY after establishing why the emit moved.  Reporting." >&2
cmp "$WORK/selfhost2.ssa" "$SEED" | head -3 >&2 || true
exit 4
