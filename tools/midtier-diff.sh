#!/usr/bin/env bash
# midtier-diff.sh — the middle tier's DIFFERENTIAL (`Mid.Simplify`'s oracle).
#
# Stage 1 (S1) introduced the Mid IR behind MIDTIER with ZERO passes and a
# BYTE-IDENTITY contract: MIDTIER=1 had to emit the same bytes as MIDTIER=0.
# That contract DIES with the first optimization pass (plan decision D5,
# accepted by the user), and this script is what replaces it.
#
# WHAT REPLACES IT — the safety story, in the two halves that matter:
#
#   * MIDTIER=0 IS A BYTE-IDENTITY ANCHOR THAT MUST HOLD FOREVER.  Step 2
#     hashes every gate artifact compiled with MIDTIER=0 and diffs the list
#     against `tools/withe-corpus-baseline.sha256`, and step 5 requires the
#     MIDTIER=0 selfhost bundle to reproduce the committed seed
#     (`tools/bootstrap/selfhost.csexp`, sha256 2d1f8998…).  The middle tier
#     cannot reach that path (Main.elm picks `Lower.Module` before a pass
#     config exists), so a MIDTIER=0 byte that moves is a BUG, never a
#     re-baseline.
#   * MIDTIER=1 IS VERIFIED BEHAVIOURALLY.  Step 4 compiles every gate group
#     under BOTH modes and RUNS both bundles on the VM with the same entry,
#     args and stdin, diffing the outputs; the whole gate is additionally run
#     under each mode against the pinned `expected/*.txt` (including the `err`
#     fixtures, whose error TEXT is part of the contract).  Step 3 reports how
#     many artifacts the passes actually moved and by how many instructions
#     (`tools/midtier-emit-stats.py`) — a pass that changes nothing is not a
#     failure, but it must be VISIBLE, because that is what makes "this pass
#     does not fire on this corpus" sayable.
#   * STEP 1 GUARDS THE WHOLE THING AGAINST VACUITY.  `MIDTIER_TRACE=1` must
#     report `mode=mid` / `mode=lower`, and MIDTIER=1 with EVERY pass switch
#     off (`MIDTIER_NO*=1`) must be BYTE-IDENTICAL to MIDTIER=0 — which is
#     what separates "the passes changed this" from "the wiring changed this".
#   * STEP 5's SECOND GENERATION is the largest program available: the
#     MIDTIER=1 selfhost bundle (the optimized compiler, 1.46 MB) is RUN
#     INTERPRETED over the whole gate manifest and its artifacts must equal
#     the MIDTIER=0 ones byte-for-byte.  A pass that miscompiles the compiler
#     shows up here as wrong bytes or a crash.  (The 807 s full fixed point —
#     B1 compiling its own 58 sources — is the once-per-series measurement,
#     run by hand with `MIDTIER=1 tools/bootstrap-compile.sh <manifest>`; see
#     the pass reports, because it costs ~14 minutes.)
#
# Fixture set: the LANGUAGE gate's OWN registry (`ELM_GATE_MATRIX=1` dumps the
# registered checks as TSV; `ELM_GATE_MANIFEST_ONLY=1` prints the batch
# manifest it builds), so nothing here can drift from
# tests/elm-fixtures/run-elm-gate.sh — there is no second copy of the fixture
# declarations.
#
# Env:
#   MIDTIER_DIFF_FAST=1  skip the two expensive steps: 4b's per-row
#                        run-and-diff and 5b's second generation.  Use it while
#                        iterating; a pass's COMMIT evidence uses the default
#                        (full) run.
#   MIDTIER_DIFF_TRACE=1 echo each step's raw command
#
# Usage: tools/midtier-diff.sh
# Exit:  0 all steps pass; 1 a step failed; 2 the environment is unusable.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ELMVM="$ROOT/zig-out/bin/elmvm"
CDIR="$ROOT/elm-compiler"
GATE="$ROOT/tests/elm-fixtures/run-elm-gate.sh"
FIX="$ROOT/tests/elm-fixtures"
BASELINE="$ROOT/tools/withe-corpus-baseline.sha256"
STATS="$ROOT/tools/midtier-emit-stats.py"
SEED_SHA="2d1f8998a13e28c0c47cccc46ac5e390572f73cbe2d63e18d3501cde44568c8b"

# Every pass switch, so "all passes off" stays complete as passes are added.
# A missing switch here would silently leave that pass ON in the bisection and
# make the byte-identity check in step 1 lie.
PASS_OFF="MIDTIER_NOSHRINK=1 MIDTIER_NOCONSTFOLD=1 MIDTIER_NOINLINE=1 MIDTIER_NOARITY=1 MIDTIER_NODEADGLOBALS=1"

for tool in node jq cmp sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || { echo "FAIL: $tool not on PATH" >&2; exit 2; }
done
[ -x "$ELMVM" ] || { echo "FAIL: $ELMVM missing (run: zig build elmvm)" >&2; exit 2; }
[ -f "$CDIR/compiler.js" ] || { echo "FAIL: $CDIR/compiler.js missing (run elm-compiler/build.sh)" >&2; exit 2; }
[ -f "$BASELINE" ] || { echo "FAIL: $BASELINE missing" >&2; exit 2; }

TMP="$(mktemp -d)"
mkdir -p "$TMP/out0" "$TMP/out1" "$TMP/gen1"
trap 'rm -rf "$TMP"' EXIT

fail=0
step() { printf '%-34s %s\n' "$1:" "$2"; }
trace() { [ "${MIDTIER_DIFF_TRACE:-0}" = "1" ] && echo "    \$ $*"; true; }

# ---------------------------------------------------------------- 1. engagement
run_mode() { # <env…> <out.err>
    local err="$1"; shift
    env "$@" MIDTIER_TRACE=1 node "$CDIR/run.js" tests/elm-fixtures/fib.elm "$TMP/probe.csexp" 2>"$err" >/dev/null
}

run_mode "$TMP/mid.err" MIDTIER=1
probe_mid_rc=$?
run_mode "$TMP/lower.err"
probe_low_rc=$?
# shellcheck disable=SC2086
run_mode "$TMP/off.err" MIDTIER=1 $PASS_OFF
probe_off_rc=$?

if [ "$probe_mid_rc" -eq 0 ] && grep -q 'mode=mid' "$TMP/mid.err"; then
    step "engagement (MIDTIER=1)" "mode=mid"
else
    step "engagement (MIDTIER=1)" "FAILED (exit $probe_mid_rc; wanted 'mode=mid' on stderr)"
    fail=1
fi
if [ "$probe_low_rc" -eq 0 ] && grep -q 'mode=lower' "$TMP/lower.err"; then
    step "engagement (MIDTIER=0)" "mode=lower"
else
    step "engagement (MIDTIER=0)" "FAILED (exit $probe_low_rc; wanted 'mode=lower' on stderr)"
    fail=1
fi

# The pass-off bisection: the tier with every pass disabled must be the S1
# refactor exactly.  This is the ONLY byte-identity claim left in the tier.
# Checked over a FIXTURE SET, not one file: a pass that silently stayed ON and
# moved bytes only on a construct fib.elm lacks (ADTs, records, lists,
# higher-order calls, let+case) must still trip this check.
PASS_OFF_FIXTURES="fib boolcase adtcase insrec biglist curry closure letcase"
if [ "$probe_off_rc" -eq 0 ] && grep -q 'mode=mid' "$TMP/off.err"; then
    off_bad=0
    for fx in $PASS_OFF_FIXTURES; do
        # NOTE `env`: the switches are EXPANDED here, and bash only recognises an
        # assignment prefix in a LITERAL word — `MIDTIER=1 $PASS_OFF node …` finds
        # no command at all (exit 127) and the cmp below then compares a missing
        # file, i.e. the check would report a byte difference for a wiring bug.
        env MIDTIER=1 $PASS_OFF node "$CDIR/run.js" "tests/elm-fixtures/$fx.elm" "$TMP/off.csexp" >/dev/null 2>&1
        node "$CDIR/run.js" "tests/elm-fixtures/$fx.elm" "$TMP/base.csexp" >/dev/null 2>&1
        cmp -s "$TMP/off.csexp" "$TMP/base.csexp" || {
            off_bad=$((off_bad + 1))
            [ "$off_bad" -le 3 ] && echo "    PASSES-OFF DIFFERS: $fx"
        }
    done
    if [ "$off_bad" -eq 0 ]; then
        step "engagement (passes off)" "mode=mid, $PASS_OFF_FIXTURES all bytes == MIDTIER=0"
    else
        step "engagement (passes off)" "FAILED — the tier moved a byte with every pass disabled on $off_bad fixture(s)"
        fail=1
    fi
else
    step "engagement (passes off)" "FAILED (exit $probe_off_rc; wanted 'mode=mid' on stderr)"
    fail=1
fi

# ------------------------------------------------------- 2. the MIDTIER=0 anchor
manifest="$(ELM_GATE_MANIFEST_ONLY=1 "$GATE" 2>/dev/null)"
if [ -z "$manifest" ] || [ ! -f "$manifest" ]; then
    step "anchor (MIDTIER=0)" "FAILED — the gate produced no batch manifest"
    fail=1
    manifest=""
fi

ngroup=0
if [ -n "$manifest" ]; then
    manifest_dir="$(dirname "$manifest")"
    # The gate leaks its temp dir on purpose (that is how the manifest is
    # readable here).  Take a COPY: steps 4b and 5b need the manifest AFTER
    # step 2 deletes the gate's dir, and a missing manifest made the second
    # generation compare against nothing and report all 150 artifacts as
    # different (a false failure this comment exists to prevent recurring).
    cp "$manifest" "$TMP/gate.json"
    manifest="$TMP/gate.json"
    # One output per GROUP INDEX (the manifest reuses basenames: `sub` is
    # registered twice), so the per-row run-and-diff in step 4 can key on it.
    jq --arg d "$TMP/out0" '.groups = [ .groups | to_entries[] | .value.output = ($d + "/g" + (.key|tostring) + ".csexp") | .value ]' \
        "$manifest" > "$TMP/man0.json"
    jq --arg d "$TMP/out1" '.groups = [ .groups | to_entries[] | .value.output = ($d + "/g" + (.key|tostring) + ".csexp") | .value ]' \
        "$manifest" > "$TMP/man1.json"
    ngroup="$(jq '.groups | length' "$manifest")"

    trace "node run.js --batch man0.json   (MIDTIER=0)"
    node "$CDIR/run.js" --batch "$TMP/man0.json" >/dev/null 2>&1
    run0_rc=$?
    trace "MIDTIER=1 node run.js --batch man1.json"
    MIDTIER=1 node "$CDIR/run.js" --batch "$TMP/man1.json" >/dev/null 2>&1
    run1_rc=$?

    # The ANCHOR is path-keyed like tools/withe-numbers.sh: the same manifest
    # into THE SAME output basenames, hashed and diffed against the committed
    # baseline.  (The differential below needs index-keyed names instead —
    # the gate registers `sub` twice, so basenames collide — hence two
    # manifests over one fixture set.)
    mkdir -p "$TMP/anchor"
    jq --arg d "$TMP/anchor" '{groups: [ .groups[] | .output = ($d + "/" + (.output | split("/") | last))]}' \
        "$manifest" > "$TMP/man-anchor.json"
    node "$CDIR/run.js" --batch "$TMP/man-anchor.json" >/dev/null 2>&1
    anchor_rc=$?
    ( cd "$TMP/anchor" && for f in *.csexp; do sha256sum "$f"; done ) | sort -k2 > "$TMP/current.sha"
    sort -k2 "$BASELINE" > "$TMP/baseline.sha"
    if [ "$anchor_rc" -ne 0 ]; then
        step "anchor (MIDTIER=0)" "FAILED — compile exited $anchor_rc"
        fail=1
    elif diff -u "$TMP/baseline.sha" "$TMP/current.sha" > "$TMP/anchor.diff" 2>&1; then
        step "anchor (MIDTIER=0)" "BYTE-IDENTICAL to the corpus baseline ($(wc -l < "$BASELINE" | tr -d ' ') entries)"
    else
        step "anchor (MIDTIER=0)" "FAILED — MIDTIER=0 MOVED A BYTE (that is a bug, not a re-baseline):"
        sed 's/^/    /' "$TMP/anchor.diff" | head -10
        fail=1
    fi
    rm -rf "$manifest_dir"
fi

# --------------------------------------------- 3. what the passes changed
if [ -n "$manifest" ] && [ "$ngroup" -gt 0 ]; then
    if [ "$run1_rc" -ne 0 ]; then
        step "MIDTIER=1 compile" "FAILED — compile exited $run1_rc"
        fail=1
    else
        changed=0
        for ((i=0;i<ngroup;i++)); do
            if [ -s "$TMP/out0/g$i.csexp" ] && [ -s "$TMP/out1/g$i.csexp" ]; then
                cmp -s "$TMP/out0/g$i.csexp" "$TMP/out1/g$i.csexp" || changed=$((changed+1))
            fi
        done
        n_art0="$(ls "$TMP/out0"/*.csexp 2>/dev/null | wc -l | tr -d ' ')"
        n_art1="$(ls "$TMP/out1"/*.csexp 2>/dev/null | wc -l | tr -d ' ')"
        if [ "$n_art0" -ne "$n_art1" ] || [ "$n_art0" -eq 0 ]; then
            step "artifact count" "FAILED — MIDTIER=0 produced $n_art0, MIDTIER=1 produced $n_art1"
            fail=1
        else
            step "artifacts moved" "$changed of $n_art0 differ (byte identity is NOT the contract)"
        fi
        if [ -x "$STATS" ] || [ -f "$STATS" ]; then
            delta="$(python3 "$STATS" "$TMP/out0" "$TMP/out1" 2>/dev/null | grep '^DELTA' | head -1)"
            [ -n "$delta" ] && step "emitted-size delta" "${delta#DELTA }"
        fi
    fi
fi

# ------------------------------------------------- 4. behavioural differential
# 4a. the whole gate under each mode, against the pinned expected/*.txt.
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
    step "gate transcripts" "identical ($(grep -c '^PASS' "$TMP/gate0.txt") PASS lines)"
else
    step "gate transcripts" "FAILED — the two modes' transcripts differ:"
    sed 's/^/    /' "$TMP/gate.diff" | head -20
    fail=1
fi

# 4b. the SAME row run from BOTH bundles, diffed against each other.  The gate
# compares each mode against the pinned expectation; this compares the two
# modes' OUTPUTS to one another, so a change that both modes make in the same
# (wrong) way still shows up as an output difference only if the values differ
# — which is why 4a's expectation check is the stronger of the two.
if [ "${MIDTIER_DIFF_FAST:-0}" = "1" ]; then
    step "run-and-diff (both bundles)" "SKIPPED (MIDTIER_DIFF_FAST=1)"
elif [ -n "$manifest" ] && [ "$ngroup" -gt 0 ] && [ "$run0_rc" -eq 0 ] && [ "$run1_rc" -eq 0 ]; then
    # The dump is TSV, and a TAB is IFS *whitespace*: `IFS=$'\t' read` would
    # COLLAPSE the empty fields (the `args` column of a run_io row, the whole
    # tail of an out_cmp row) and silently shift every later column onto the
    # wrong variable.  Rewriting the separator to US (unit separator, not IFS
    # whitespace) keeps the empty fields.
    matrix="$(ELM_GATE_MATRIX=1 "$GATE" 2>/dev/null | tr '\t' '\037')"
    ran=0
    mismatched=0
    skipped=0
    gi=0
    while IFS=$'\037' read -r helper name entry kind expected args stdin fixture; do
        [ "$helper" = "helper" ] && continue
        # Only the check kinds that registered a compile GROUP advance the
        # group index; rawrun/out_cmp use committed or previously-written files.
        # Only the helpers that CALL register_group advance the group index.
        case "$helper" in
            rawrun|out_cmp) continue ;;
        esac
        idx="$gi"
        gi=$((gi + 1))
        case "$kind" in
            run|io|run2) ;;
            *) continue ;;
        esac
        b0="$TMP/out0/g$idx.csexp"
        b1="$TMP/out1/g$idx.csexp"
        if [ ! -s "$b0" ] || [ ! -s "$b1" ] || head -c 4 "$b0" | grep -q '^err ' || head -c 4 "$b1" | grep -q '^err '; then
            skipped=$((skipped + 1))
            continue
        fi
        mod="$(awk '/^module /{print $2; exit}' "$FIX/$fixture")"
        qname="$mod.$entry"
        # shellcheck disable=SC2086
        o0="$("$ELMVM" "$b0" "$qname" $args < "/dev/null" 2>&1)"
        # shellcheck disable=SC2086
        o1="$("$ELMVM" "$b1" "$qname" $args < "/dev/null" 2>&1)"
        if [ "$kind" = "io" ]; then
            o0="$("$ELMVM" "$b0" "$qname" < "$FIX/input/$stdin" 2>&1)"
            o1="$("$ELMVM" "$b1" "$qname" < "$FIX/input/$stdin" 2>&1)"
        fi
        case "$o0" in
            "unknown global: $qname"|"unknown name: $qname")
                # The gate's own legacy fallback: the bare function name.
                # shellcheck disable=SC2086
                o0="$("$ELMVM" "$b0" "$entry" $args 2>&1)"
                # shellcheck disable=SC2086
                o1="$("$ELMVM" "$b1" "$entry" $args 2>&1)"
                ;;
        esac
        ran=$((ran + 1))
        if [ "$o0" != "$o1" ]; then
            mismatched=$((mismatched + 1))
            [ "$mismatched" -le 5 ] && echo "    OUTPUT DIFFERS: $name ($qname): mid[$o1] lower[$o0]"
        fi
    done <<< "$matrix"
    if [ "$ran" -eq 0 ]; then
        step "run-and-diff (both bundles)" "FAILED — no rows were run (the matrix parse is broken)"
        fail=1
    elif [ "$mismatched" -eq 0 ]; then
        step "run-and-diff (both bundles)" "$ran rows, identical outputs ($skipped skipped: compile_err/no bundle)"
    else
        step "run-and-diff (both bundles)" "FAILED — $mismatched of $ran rows differ"
        fail=1
    fi
fi

# ---------------------------------------------------------------- 5. selfhost
tools/selfhost-compile.sh > /dev/null 2>&1
sh0_rc=$?
sha0="$(sha256sum zig-out/selfhost.csexp 2>/dev/null | cut -d' ' -f1)"
cp -f zig-out/selfhost.csexp "$TMP/seed0.csexp" 2>/dev/null

MIDTIER=1 MIDTIER_STACK=2400 tools/selfhost-compile.sh > /dev/null 2>&1
sh1_rc=$?
sha1="$(sha256sum zig-out/selfhost.csexp 2>/dev/null | cut -d' ' -f1)"
cp -f zig-out/selfhost.csexp "$TMP/gen1.csexp" 2>/dev/null

if [ "$sh0_rc" -ne 0 ]; then
    step "selfhost MIDTIER=0" "FAILED — selfhost-compile exited $sh0_rc"
    fail=1
elif [ "$sha0" != "$SEED_SHA" ]; then
    step "selfhost MIDTIER=0" "FAILED — MIDTIER=0 moved the seed: $sha0 != $SEED_SHA"
    fail=1
else
    step "selfhost MIDTIER=0" "== committed seed (${sha0:0:16}…)"
fi
if [ "$sh1_rc" -ne 0 ]; then
    step "selfhost MIDTIER=1" "FAILED — selfhost-compile exited $sh1_rc (MIDTIER_STACK=2400)"
    fail=1
else
    delta="$(python3 "$STATS" "$TMP/seed0.csexp" "$TMP/gen1.csexp" 2>/dev/null | grep '^DELTA' | head -1)"
    step "selfhost MIDTIER=1" "bundle ${sha1:0:16}… ${delta#DELTA }"
fi

# 5b. SECOND GENERATION: run the OPTIMIZED compiler (still a VM bundle) over
# the whole gate manifest and require the UNSOPHISTICATED bytes back.  The
# self-hosted compiler drives `Lower.Module` (Mid is not one of the 58 manifest
# sources until S7), so its output must be the MIDTIER=0 bytes exactly: this is
# a semantic check of the optimized compiler binary, not a byte check of the
# optimized bytes.
if [ "${MIDTIER_DIFF_FAST:-0}" = "1" ]; then
    step "second generation" "SKIPPED (MIDTIER_DIFF_FAST=1)"
elif [ ! -s "$TMP/gen1.csexp" ]; then
    step "second generation" "FAILED — no MIDTIER=1 bundle to run"
    fail=1
elif [ -z "$manifest" ]; then
    step "second generation" "SKIPPED (no manifest)"
else
    jq -r --arg d "$TMP/gen1" '.groups | to_entries[] | (.value.sources[] | .), "-> " + ($d + "/g" + (.key|tostring) + ".csexp")' \
        "$manifest" > "$TMP/gen1.manifest"
    trace "AOTRUN_ARGV=1 elmvm gen1.csexp NativeMain.main gen1.manifest"
    AOTRUN_ARGV=1 AOTRUN_QUIET=1 ELMC_HEAP_MB=8000 ZINCVM_INSTR_LIMIT=1000000000000 \
        "$ELMVM" "$TMP/gen1.csexp" NativeMain.main "$TMP/gen1.manifest" >/dev/null 2>&1
    gen_rc=$?
    gen_bad=0
    for ((i=0;i<ngroup;i++)); do
        [ -s "$TMP/out0/g$i.csexp" ] || continue
        cmp -s "$TMP/out0/g$i.csexp" "$TMP/gen1/g$i.csexp" || {
            gen_bad=$((gen_bad + 1))
            [ "$gen_bad" -le 3 ] && echo "    GENERATION-2 DIFFERS: g$i"
        }
    done
    if [ "$gen_rc" -ne 0 ]; then
        step "second generation" "FAILED — the optimized compiler exited $gen_rc"
        fail=1
    elif [ "$gen_bad" -ne 0 ]; then
        step "second generation" "FAILED — $gen_bad of $ngroup artifacts differ from MIDTIER=0"
        fail=1
    else
        step "second generation" "optimized compiler reproduces $ngroup/$ngroup MIDTIER=0 artifacts"
    fi
fi

echo
if [ "$fail" -eq 0 ]; then
    echo "VERDICT: mid-tier differential clean"
else
    echo "VERDICT: FAILURES above"
fi
exit "$fail"
