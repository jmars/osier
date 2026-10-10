#!/usr/bin/env bash
# gen-fixture-matrix.sh — render tests/elm-fixtures/MATRIX.md from the GATE'S
# OWN REGISTRY (the run / run2 / run_io / compile_clean / compile_error /
# out_cmp / rawrun / sigdeath / depth / natdepth calls at the foot of
# tests/elm-fixtures/run-elm-gate.sh).
#
# The matrix is never hand-copied: the gate dumps its registered checks
# (ELM_GATE_MATRIX=<path>) and this script formats that dump, so the file
# cannot drift from the gate it documents.
#
# USAGE (from anywhere):
#   tools/gen-fixture-matrix.sh            # (re)write tests/elm-fixtures/MATRIX.md
#   tools/gen-fixture-matrix.sh --check    # exit 1 (with a diff) if it is stale
#   tools/gen-fixture-matrix.sh --stdout   # print it, write nothing
#
# Prerequisites: none (bash + awk + sed) — the gate's dump mode stops before it
# loads elm, elmvm, node or jq.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GATE="$ROOT/tests/elm-fixtures/run-elm-gate.sh"
OUT="$ROOT/tests/elm-fixtures/MATRIX.md"

mode=write
case "${1:-}" in
    --check)  mode=check ;;
    --stdout) mode=stdout ;;
    "")       ;;
    *) echo "usage: $(basename "$0") [--check|--stdout]" >&2; exit 2 ;;
esac

[ -x "$GATE" ] || { echo "FAIL: gate not found at $GATE" >&2; exit 2; }

TSV="$(mktemp)"
trap 'rm -f "$TSV"' EXIT

# The gate writes the TSV itself (a path, not a pipe: a multi-line expected
# value would otherwise interleave with a short reader).
if ! ELM_GATE_MATRIX="$TSV" "$GATE"; then
    echo "FAIL: $GATE did not produce a matrix dump" >&2
    exit 1
fi
if [ ! -s "$TSV" ]; then
    echo "FAIL: the gate's matrix dump is empty" >&2
    exit 1
fi

n_checks=$(( $(wc -l < "$TSV") - 1 ))

emit() {
    cat <<EOF
<!-- GENERATED FILE — DO NOT EDIT BY HAND.
     Regenerate with: tools/gen-fixture-matrix.sh
     Staleness check: tools/gen-fixture-matrix.sh --check -->

# The fixture-gate matrix (machine-readable counterpart of Appendix A)

Every check the language gate REGISTERS, in declaration order. Generated from
the gate's own registration calls, not copied by hand:

\`\`\`sh
tools/gen-fixture-matrix.sh            # write this file
tools/gen-fixture-matrix.sh --check    # fail if this file is stale
tools/gen-fixture-matrix.sh --stdout   # print it
\`\`\`

The dump it is rendered from (no elm/elmvm/node/jq needed in that mode):

\`\`\`sh
ELM_GATE_MATRIX=/tmp/matrix.tsv tests/elm-fixtures/run-elm-gate.sh
\`\`\`

**${n_checks} registered checks.** Run from the repo root, the gate prints
\`PASS=${n_checks} FAIL=0\` on the frozen artifact. \`docs/research/osier-paper.md\`
**Appendix A** is the paper's prose counterpart: the *designed* programs the
paper cites, with the claim each one pins. Appendix A is a selected subset;
this file is the complete registry. Where the two disagree, **this file and the
gate win** — the gate is the oracle, and \`tools/gen-fixture-matrix.sh --check\`
fails loudly rather than letting this listing go stale.

## How to read a row

| column | meaning |
|---|---|
| \`check\` | the name the gate prints (\`PASS <name> …\`) |
| \`kind\` | the gate function that registered it (see the mapping below) |
| \`entry point\` | the function the VM calls; \`<Module>.<fn>\` is resolved from the fixture's \`module\` header |
| \`expected\` | what must be observed: a single-line printed value, an escaped multi-line value (\`\\n\`), or a substring the compile error must contain |
| \`args\` | argv passed to the entry point |
| \`stdin\` | file under \`input/\` redirected into the VM |
| \`fixture\` | the fixture source (or the committed \`.csexp\` bundle for \`rawrun\`) |

| \`kind\` (registered by) | dispatcher kind | what it asserts |
|---|---|---|
| \`run\` | \`run\` | compiles, runs the entry point through the VM, printed value == \`expected\` |
| \`run2\` | \`run2\` | multi-module: \`fixture\` compiled *with* its aux module, then as \`run\` |
| \`run_io\` | \`io\` | as \`run\`, with stdin redirected from \`input/<stdin>\` |
| \`compile_clean\` | \`ok\` | compilation must yield a real bundle, not an \`err …\` payload (no value check — the fixture's value cannot be driven from argv) |
| \`compile_error\` | \`err\` | compilation must emit \`err <message>\` containing \`expected\` |
| \`out_cmp\` | \`cmp\` | the raw file an earlier run wrote must equal its \`expected/*.txt\` bytes |
| \`rawrun\` | \`rawrun\` | runs a committed \`.csexp\` bundle no Elm source can produce (e.g. an unknown Task ctor) |
| \`sigdeath\` | \`sigdeath\` | a child that dies BY SIGNAL must be reported as \`128+signum\` (compiles its own bundle; \`expected\` = the \`<code>|<out>|<err>\` tuple): \`sh -c 'kill -9 \$\$'\` is reaped WIFSIGNALED, so the code must be 137 — a decoder without \`waitStatusCode\`'s signal arm answers \`EXITSTATUS(9) = 0\` |
| \`depth\` | \`depth\` | deep NON-tail recursion past \`CALL_STACK_DEPTH\` must be LOUD (compiles its own bundle; \`args\` = control-depth past-cap-margin): control depth and \`CAP-1\` print \`expected\`; past the cap the process exits non-zero with the \`call stack depth exceeded\` diagnostic on stderr and no value on stdout |
| \`natdepth\` | \`natdepth\` | the NATIVE twin of \`depth\`: deep NON-tail recursion past the C-stack budget must be LOUD (builds its own binary via \`tools/qbe/qbe-mk.sh\`; \`args\` = control-depth past-depth deep-depth): the control prints \`expected\` under the check's own 1 MiB \`ulimit -s\` (\`QBE_NO_RLIMIT=1\`); past the boundary the process exits non-zero with the \`native stack depth exceeded\` diagnostic on stderr and no value on stdout; deep-depth must still complete at the driver's raised 64 MiB limit |

## The registered checks

| # | check | kind | entry point | expected | args | stdin | fixture |
|---:|---|---|---|---|---|---|---|
EOF

    awk -F'\t' '
        function esc(s) { gsub(/\|/, "\\|", s); return s }
        function cell(s) { return (s == "" ? "—" : "`" esc(s) "`") }
        NR > 1 {
            printf "| %d | `%s` | `%s` | %s | %s | %s | %s | %s |\n",
                   NR - 1, $2, $1, cell($3), cell($5), cell($6), cell($7), cell($8)
        }' "$TSV"

    cat <<EOF

---
Generated from \`tests/elm-fixtures/run-elm-gate.sh\`; ${n_checks} checks.
EOF
}

case "$mode" in
    stdout) emit ;;
    write)
        emit > "$OUT"
        echo "wrote $OUT ($n_checks checks)"
        ;;
    check)
        cur="$(mktemp)"; trap 'rm -f "$TSV" "$cur"' EXIT
        emit > "$cur"
        if diff -u "$OUT" "$cur" > "$cur.diff" 2>&1; then
            rm -f "$cur.diff"
            echo "OK: $OUT is up to date with the gate registry ($n_checks checks)"
        else
            echo "STALE: $OUT does not match the gate's registry — regenerate:" >&2
            echo "    tools/gen-fixture-matrix.sh" >&2
            sed 's/^/    /' "$cur.diff" >&2
            rm -f "$cur.diff"
            exit 1
        fi
        ;;
esac
