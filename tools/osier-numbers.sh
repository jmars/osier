#!/usr/bin/env bash
# osier-numbers.sh — the paper's single reproducible measurement chain.
#
# Runs, from a clean checkout, the WHOLE evidence chain for the Osier / λρG
# paper (handoff `rowgadt`, gap G2) and PRINTS every number the paper cites:
#
#   1. the fixture gate        — PASS/FAIL count (run-elm-gate.sh)
#   2. the corpus batch        — byte-identity of every compiled artifact
#                                against tools/osier-corpus-baseline.sha256
#   3. TestMain                — assertion count (114/114)
#   4. `lake build`            — exit code + output bytes, theorem count and
#                                the axiom list, from lean/
#   5. the runTask branch recount — the corrected G5 figure (16 of 20 branches
#                                check honestly under the `type x a.` binder),
#                                reproduced by tools/osier-recount-runTask.sh
#
# It is SELF-CONTAINED (builds elmvm/compiler.js/test-compiler.js and the Lean
# build on first use) and IDEMPOTENT (re-runs reproduce the same numbers; the
# corpus diff is empty on an unmodified tree).  Verified from a CLEAN CLONE of
# the artifact tag with no zig-out/, no compiler.js and no lean/.lake: ~45s and
# exit 0 on the paper's build host.
#
# USAGE (from the repo root):
#   tools/osier-numbers.sh
#
# PREREQUISITES — checked up front, each with its own message if missing:
#   on PATH: node, jq, zig (0.16), rg (ripgrep), python3.
#   The elm 0.19.2 binary and the Lean 4 toolchain are located as below:
#
#   ELM_BIN      elm 0.19.2 binary
#                (default: ~/.npm-global/lib/node_modules/elm/bin/elm — NOT on
#                PATH in the paper's build host; elm-compiler/build.sh's PATH
#                probe finds nothing there)
#   ELAN_HOME    Lean toolchain home (default: /var/data/workspace/lean/elan;
#                lake is ELAN_HOME/bin/lake).  A bare `lean <file>` does NOT
#                work — lean/ is a Lake project, built with `lake build`.
#
# Exit codes: 0 = every check passed; 1 = a check ran and failed; 2 = the
# environment is incomplete (a prerequisite above is missing).  The corpus
# baseline (one sha256 sum per LANGUAGE-gate artifact — the 19 UI-host fixtures
# left the corpus in osier split Phase 1) is the repo-frozen byte-identity
# oracle; a gate run that adds/removes/changes ANY artifact makes step 2 print
# a diff.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ELM_BIN="${ELM_BIN:-$HOME/.npm-global/lib/node_modules/elm/bin/elm}"
ELAN_HOME="${ELAN_HOME:-/var/data/workspace/lean/elan}"
BASELINE="$ROOT/tools/osier-corpus-baseline.sha256"
CDIR="$ROOT/elm-compiler"

fail=0
note() { printf '%-28s %s\n' "$1:" "$2"; }

# --- prerequisite preflight --------------------------------------------------
# Every missing tool is named HERE, with the variable to set where there is one,
# instead of surfacing as "No such file or directory", "command not found", or —
# worst — a silently ZERO theorem count from a missing `rg`.  Exit 2 = the
# environment is incomplete (no measured behaviour is involved); exit 1 = a
# check ran and failed.
need() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'FAIL: %s is required and was not found on PATH.\n' "$1" >&2
        printf '      %s\n' "$2" >&2
        exit 2
    }
}

need node   "node (any recent version) runs the compiler driver run.js / test-run.js."
need jq     "jq builds the fixture gate's batch manifest."
need zig    "zig 0.16 builds the gate harness (zig build elmvm)."
need rg     "ripgrep counts the Lean theorems/axioms — WITHOUT it those counts print 0."
need python3 "python3 runs the runTask recount (tools/osier-recount-runTask.sh)."

if [ ! -x "$ELM_BIN" ]; then
    cat >&2 <<EOF
FAIL: the elm 0.19.2 binary was not found.
      ELM_BIN=$ELM_BIN
      elm 0.19.2 is NOT on PATH in the paper's build host, so ELM_BIN must be
      set to your elm binary, e.g.

          ELM_BIN="\$(npm root -g)/elm/bin/elm" tools/osier-numbers.sh

      (the default is \$HOME/.npm-global/lib/node_modules/elm/bin/elm)
EOF
    exit 2
fi

LAKE="$(command -v lake 2>/dev/null || true)"
if [ -z "$LAKE" ] && [ ! -x "$ELAN_HOME/bin/lake" ]; then
    cat >&2 <<EOF
FAIL: the Lean 4 toolchain was not found — no \`lake\` on PATH and none at
      ELAN_HOME/bin/lake.
      ELAN_HOME=$ELAN_HOME
      Set ELAN_HOME to your elan home (the default is
      /var/data/workspace/lean/elan), or put \`lake\` on PATH.  Note that a bare
      \`lean <file>\` does NOT work: lean/ is a Lake project and must be built
      with \`lake build\` from lean/.
EOF
    exit 2
fi

# --- build prerequisites (skip if already present) ---------------------------
if [ ! -x "$ROOT/zig-out/bin/elmvm" ]; then
    zig build elmvm || { echo "FAIL: zig build elmvm" >&2; exit 1; }
fi

# compiler.js / test-compiler.js are the compiler UNDER TEST — always rebuild
# them (a stale gitignored artifact would otherwise answer with the wrong exit
# code/bytes: the "stale build artifact lies about a mutation" failure mode).
(cd "$CDIR" && ELM_HOME="$PWD/.elm-cache" "$ELM_BIN" make src/Main.elm --output=compiler.js >/dev/null) \
    || { echo "FAIL: elm make compiler.js" >&2; exit 1; }

(cd "$CDIR" && ELM_HOME="$PWD/.elm-cache" "$ELM_BIN" make src/TestMain.elm --output=test-compiler.js >/dev/null) \
    || { echo "FAIL: elm make test-compiler.js" >&2; exit 1; }

echo "osier-numbers @ $(git rev-parse --short HEAD 2>/dev/null || echo 'no-git')"
echo

# --- 1. gate -----------------------------------------------------------------
gate_out="$(tests/elm-fixtures/run-elm-gate.sh 2>&1)"
gate_rc=$?
gate_line="$(printf '%s\n' "$gate_out" | sed -n 's/^PASS=//p' | tail -1)"
if [ "$gate_rc" -eq 0 ]; then
    note "gate" "$(printf '%s\n' "$gate_out" | tail -1)"
else
    note "gate" "FAILED (exit $gate_rc) — last line: $(printf '%s\n' "$gate_out" | tail -1)"
    fail=1
fi

# --- 2. corpus batch + byte-identity ----------------------------------------
# Build the SAME manifest the gate uses (ELM_GATE_MANIFEST_ONLY=1 leaves the
# output dir in place), compile it once, hash every artifact, and diff the
# sorted hash list against the committed baseline.
manifest="$(ELM_GATE_MANIFEST_ONLY=1 tests/elm-fixtures/run-elm-gate.sh 2>/dev/null)"
if [ -z "$manifest" ] || [ ! -f "$manifest" ]; then
    # The gate refuses (exit 2) without jq / elmvm / compiler.js.  Bail HERE:
    # with an empty path, `dirname` below would resolve to "." and compare the
    # hashes in the repo root.
    note "corpus" "FAILED — the gate produced no batch manifest"
    echo "    (see why: ELM_GATE_MANIFEST_ONLY=1 tests/elm-fixtures/run-elm-gate.sh)"
    fail=1
else
    outdir="$(dirname "$manifest")"
    node "$CDIR/run.js" --batch "$manifest" 2>/dev/null

    n_artifacts="$(ls "$outdir"/*.csexp 2>/dev/null | wc -l | tr -d ' ')"
    n_manifest="$(wc -l < "$BASELINE" | tr -d ' ')"
    (cd "$outdir" && for f in *.csexp; do sha256sum "$f"; done) | sort -k2 > "$outdir/.current.sha"
    sort -k2 "$BASELINE" > "$outdir/.baseline.sha"
    if diff -u "$outdir/.baseline.sha" "$outdir/.current.sha" > "$outdir/.diff" 2>&1; then
        note "corpus" "BYTE-IDENTICAL ($n_artifacts artifacts = $n_manifest manifest entries)"
    else
        note "corpus" "DIFFERS ($n_artifacts artifacts vs $n_manifest manifest entries)"
        sed 's/^/    /' "$outdir/.diff"
        fail=1
    fi
    rm -rf "$outdir"
fi

# --- 3. TestMain -------------------------------------------------------------
test_out="$(cd "$CDIR" && node test-run.js 2>&1)"
test_rc=$?
test_line="$(printf '%s\n' "$test_out" | tail -1)"
if [ "$test_rc" -eq 0 ]; then
    note "TestMain" "$test_line"
else
    note "TestMain" "FAILED (exit $test_rc): $test_line"
    fail=1
fi

# --- 4. lean ----------------------------------------------------------------
lean_out="$(cd "$ROOT/lean" && ELAN_HOME="$ELAN_HOME" PATH="$ELAN_HOME/bin:$PATH" lake build -q 2>&1)"
lean_rc=$?
note "lake build" "exit $lean_rc, output ${#lean_out} bytes"
if [ "$lean_rc" -ne 0 ] || [ -n "$lean_out" ]; then
    printf '%s\n' "$lean_out" | sed 's/^/    /'
    fail=1
fi

theorem_total=0
for f in "$ROOT"/lean/*.lean; do
    c="$(rg -c '^\s*theorem\b' "$f" 2>/dev/null || true)"
    c="${c:-0}"
    [ -z "$c" ] && c=0
    theorem_total=$((theorem_total + c))
    printf '    %-20s %s\n' "$(basename "$f")" "$c"
done
note "lean theorems" "$theorem_total total"

axioms="$(rg -n '^\s*axiom\b' "$ROOT"/lean/*.lean 2>/dev/null | sed 's/^/    /')"
if [ -n "$axioms" ]; then
    note "lean axioms" "$(printf '%s\n' "$axioms" | grep -c 'axiom') declared:"
    printf '%s\n' "$axioms"
else
    note "lean axioms" "0 declared"
fi

sorry_admit="$(rg -n '^\s*(sorry|admit)\b' "$ROOT"/lean/*.lean 2>/dev/null || true)"
if [ -n "$sorry_admit" ]; then
    note "lean sorry/admit" "FOUND:"
    printf '%s\n' "$sorry_admit" | sed 's/^/    /'
    fail=1
else
    note "lean sorry/admit" "0"
fi

# --- 5. runTask branch recount (G5 corrected figure) -------------------------
# Reproduce the 16-of-20 interpreter-branch count by temp-copy bisection (see
# tools/osier-recount-runTask.sh for the method and the honest condition).
recount_out="$(tools/osier-recount-runTask.sh 2>&1)"
recount_rc=$?
printf '%s\n' "$recount_out"
if [ "$recount_rc" -ne 0 ]; then
    note "runTask recount" "FAILED (exit $recount_rc) — the corrected 16/20 figure is NOT reproduced"
    fail=1
fi

echo
if [ "$fail" -eq 0 ]; then
    echo "VERDICT: all checks pass"
else
    echo "VERDICT: FAILURES above"
fi
exit "$fail"
