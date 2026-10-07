#!/usr/bin/env bash
# midtier-diff.sh — the middle tier's DIFFERENTIAL (the S0 oracle for Mid.Ir).
#
# Stage 1 introduces the Mid IR (`Mid.Ir` / `Mid.FromAst` / `Mid.ToZinc`)
# behind the MIDTIER switch and claims the tier is a PURE REFACTOR: with ZERO
# optimization passes, MIDTIER=1 must emit the SAME BYTES as MIDTIER=0 and
# every fixture must behave identically on the VM.
#
# This script checks that claim.  It is driven by the LANGUAGE gate's OWN
# fixture registry (`ELM_GATE_MATRIX=1` dumps the registered checks as TSV;
# `ELM_GATE_MANIFEST_ONLY=1` prints the batch manifest it builds), so the
# fixture set cannot drift from tests/elm-fixtures/run-elm-gate.sh — there is
# no second copy of the fixture declarations here.
#
#   1. ENGAGEMENT — MIDTIER_TRACE=1 must report `mode=mid` / `mode=lower`.
#      Without this, a wiring bug would make every later step pass vacuously
#      (the two modes would silently be the same mode).
#   2. BYTE IDENTITY — compile the gate's manifest twice (MIDTIER=0 into
#      out0/, MIDTIER=1 into out1/) and `cmp` EVERY artifact.  Each bundle
#      carries the whole corpus, so this covers the corpus as well as the
#      fixture set.  Any difference fails.
#   3. BEHAVIOURAL DIFFERENTIAL — run the whole gate under each mode and
#      require exit 0 on both AND byte-identical transcripts.  This is the
#      run-and-diff step, driven by the gate's own dispatcher (args, stdin,
#      entry lookup, `expected/*.txt`, and the pinned `err <msg>` fixtures for
#      the rows that must NOT compile) instead of a second, drifting copy of
#      it; every PASS line carries the value the VM printed.
#   4. SELFHOST — compile the compiler's own 58 sources
#      (tools/selfhost-compile.sh) under BOTH modes; both must reproduce the
#      committed bootstrap seed's sha256.  That bundle is the largest program
#      available and the one artifact whose bytes a compiler change is
#      otherwise expected to move, so it is the strongest single check here.
#
#      The MIDTIER=1 half of step 4 sets MIDTIER_STACK (see run.js): under the
#      default optimizing JIT that group needs a deeper JS stack in the
#      mid-tier path than in the Lower path, in the one defun that dominates
#      them all (Char.Extra.unicodeIsAlphaNumOrUnderscoreFast: ~6991 emitted
#      instructions + 2756 labels + 1442 closures in a single 1378-deep nested
#      if-chain, so Zinc.Emit.fuse's own non-tail recursion is ~10k frames deep
#      for it).  MEASURED, and it is NOT a difference in the emitted stream:
#      the two modes' bundles are byte-identical, and with the optimizing JIT
#      DISABLED (node --no-opt) the two modes' minimum stacks for that file are
#      within 50 KB of each other (1050 KB vs 1000 KB) instead of ~25% apart.
#      The residue is a V8 tiering/frame-size artifact.  Zinc.Emit is closed to
#      this stage, so MIDTIER_STACK is the honest, documented workaround.
#
# WHAT THIS SCRIPT IS NOT: it is not the MIDTIER=0 anchor.  The anchor is
# `tools/withe-numbers.sh` (step 2: the corpus must stay byte-identical to
# tools/withe-corpus-baseline.sha256), and it stays valid whatever MIDTIER
# says.  Never loosen it to make a middle-tier pass land — replacing it is
# plan decision D5, i.e. the user's call.
#
# Usage: tools/midtier-diff.sh
# Exit:  0 all four steps pass; 1 a step failed; 2 the environment is unusable.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ELMVM="$ROOT/zig-out/bin/elmvm"
CDIR="$ROOT/elm-compiler"
GATE="$ROOT/tests/elm-fixtures/run-elm-gate.sh"
SEED_SHA="2d1f8998a13e28c0c47cccc46ac5e390572f73cbe2d63e18d3501cde44568c8b"

for tool in node jq cmp; do
    command -v "$tool" >/dev/null 2>&1 || { echo "FAIL: $tool not on PATH" >&2; exit 2; }
done
[ -x "$ELMVM" ] || { echo "FAIL: $ELMVM missing (run: zig build elmvm)" >&2; exit 2; }
[ -f "$CDIR/compiler.js" ] || { echo "FAIL: $CDIR/compiler.js missing (run elm-compiler/build.sh)" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail=0
step() { printf '%-34s %s\n' "$1:" "$2"; }

# ---------------------------------------------------------------- 1. engagement
out_mid="$TMP/probe-mid.err"
out_low="$TMP/probe-lower.err"
MIDTIER=1 MIDTIER_TRACE=1 node "$CDIR/run.js" tests/elm-fixtures/fib.elm "$TMP/probe1.csexp" 2>"$out_mid" >/dev/null
probe_mid_rc=$?
MIDTIER_TRACE=1 node "$CDIR/run.js" tests/elm-fixtures/fib.elm "$TMP/probe0.csexp" 2>"$out_low" >/dev/null
probe_low_rc=$?

if [ "$probe_mid_rc" -eq 0 ] && grep -q 'mode=mid' "$out_mid"; then
    step "engagement (MIDTIER=1)" "mode=mid"
else
    step "engagement (MIDTIER=1)" "FAILED (exit $probe_mid_rc; wanted 'mode=mid' on stderr)"
    fail=1
fi
if [ "$probe_low_rc" -eq 0 ] && grep -q 'mode=lower' "$out_low"; then
    step "engagement (MIDTIER=0)" "mode=lower"
else
    step "engagement (MIDTIER=0)" "FAILED (exit $probe_low_rc; wanted 'mode=lower' on stderr)"
    fail=1
fi

# ------------------------------------------------------------- 2. byte identity
manifest="$(ELM_GATE_MANIFEST_ONLY=1 "$GATE" 2>/dev/null)"
if [ -z "$manifest" ] || [ ! -f "$manifest" ]; then
    step "byte identity" "FAILED — the gate produced no batch manifest"
    echo "    (see why: ELM_GATE_MANIFEST_ONLY=1 $GATE)"
fi

if [ -n "$manifest" ] && [ -f "$manifest" ]; then
    manifest_dir="$(dirname "$manifest")"
    mkdir -p "$TMP/out0" "$TMP/out1"
    # Same groups, same order, different output dirs: the driver writes each
    # group's bundle text to the path in the manifest.
    jq --arg d "$TMP/out0" '{groups: [.groups[] | .output = ($d + "/" + (.output | split("/") | last))]}' \
        "$manifest" > "$TMP/manifest0.json"
    jq --arg d "$TMP/out1" '{groups: [.groups[] | .output = ($d + "/" + (.output | split("/") | last))]}' \
        "$manifest" > "$TMP/manifest1.json"

    node "$CDIR/run.js" --batch "$TMP/manifest0.json" 2>/dev/null
    run0_rc=$?
    MIDTIER=1 node "$CDIR/run.js" --batch "$TMP/manifest1.json" 2>/dev/null
    run1_rc=$?

    if [ "$run0_rc" -ne 0 ] || [ "$run1_rc" -ne 0 ]; then
        step "byte identity" "FAILED — compile exited $run0_rc (MIDTIER=0) / $run1_rc (MIDTIER=1)"
        fail=1
    else
        n=0
        bad=0
        for f in "$TMP"/out0/*.csexp; do
            n=$((n + 1))
            if ! cmp -s "$f" "$TMP/out1/$(basename "$f")"; then
                bad=$((bad + 1))
                [ "$bad" -le 5 ] && echo "    DIFFERS: $(basename "$f")"
            fi
        done
        if [ "$n" -eq 0 ]; then
            step "byte identity" "FAILED — no artifacts were produced"
            fail=1
        elif [ "$bad" -eq 0 ]; then
            step "byte identity" "MIDTIER=0 == MIDTIER=1, $n artifacts byte-identical"
        else
            step "byte identity" "FAILED — $bad of $n artifacts differ"
            fail=1
        fi
    fi
    rm -rf "$manifest_dir"
fi

# -------------------------------------------------------- 3. behavioural diff
"$GATE" > "$TMP/gate0.txt" 2>&1
gate0_rc=$?
MIDTIER=1 "$GATE" > "$TMP/gate1.txt" 2>&1
gate1_rc=$?

if [ "$gate0_rc" -ne 0 ]; then
    step "gate MIDTIER=0" "FAILED (exit $gate0_rc) — last line: $(tail -1 "$TMP/gate0.txt")"
    fail=1
else
    step "gate MIDTIER=0" "$(tail -1 "$TMP/gate0.txt") (against expected/*.txt)"
fi

if [ "$gate1_rc" -ne 0 ]; then
    step "gate MIDTIER=1" "FAILED (exit $gate1_rc) — last line: $(tail -1 "$TMP/gate1.txt")"
    fail=1
else
    step "gate MIDTIER=1" "$(tail -1 "$TMP/gate1.txt") (against expected/*.txt)"
fi

if diff -u "$TMP/gate0.txt" "$TMP/gate1.txt" > "$TMP/gate.diff" 2>&1; then
    step "run-and-diff" "identical transcripts ($(grep -c '^PASS' "$TMP/gate0.txt") PASS lines)"
else
    step "run-and-diff" "FAILED — the two runs' transcripts differ:"
    sed 's/^/    /' "$TMP/gate.diff" | head -20
    fail=1
fi

# ----------------------------------------------------------------- 4. selfhost
tools/selfhost-compile.sh > /dev/null 2>&1
sh0_rc=$?
sha0="$(sha256sum zig-out/selfhost.csexp 2>/dev/null | cut -d' ' -f1)"
MIDTIER=1 MIDTIER_STACK=2400 tools/selfhost-compile.sh > /dev/null 2>&1
sh1_rc=$?
sha1="$(sha256sum zig-out/selfhost.csexp 2>/dev/null | cut -d' ' -f1)"

if [ "$sh0_rc" -ne 0 ] || [ "$sh1_rc" -ne 0 ]; then
    step "selfhost bundle" "FAILED — selfhost-compile exit $sh0_rc (MIDTIER=0) / $sh1_rc (MIDTIER=1, MIDTIER_STACK=2400)"
    fail=1
elif [ "$sha0" != "$sha1" ]; then
    step "selfhost bundle" "FAILED — MIDTIER=0 $sha0 != MIDTIER=1 $sha1"
    fail=1
elif [ "$sha0" != "$SEED_SHA" ]; then
    step "selfhost bundle" "CHANGED — both modes agree ($sha0) but != the committed seed $SEED_SHA"
    fail=1
else
    step "selfhost bundle" "MIDTIER=0 == MIDTIER=1 == committed seed (${sha0:0:16}…)"
fi

echo
if [ "$fail" -eq 0 ]; then
    echo "VERDICT: mid-tier differential clean"
else
    echo "VERDICT: FAILURES above"
fi
exit "$fail"
