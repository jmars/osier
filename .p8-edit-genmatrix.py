#!/usr/bin/env python3
"""Batch-2 edits to tools/gen-fixture-matrix.sh: kind table + header notes."""
import sys
DONE = True
p = 'tools/gen-fixture-matrix.sh'
s = open(p).read()
n = 0
def sub(old, new):
    global s, n
    c = s.count(old)
    if c != 1:
        print(f"MISMATCH ({c}) for: {old[:100]!r}"); sys.exit(1)
    s = s.replace(old, new); n += 1

sub("""# gen-fixture-matrix.sh — render tests/elm-fixtures/MATRIX.md from the GATE'S
# OWN REGISTRY (the run / run2 / run_io / compile_clean / compile_error /
# out_cmp / rawrun / sigdeath / depth / natdepth calls at the foot of
# tests/elm-fixtures/run-elm-gate.sh).""",
"""# gen-fixture-matrix.sh — render tests/elm-fixtures/MATRIX.md from the GATE'S
# OWN REGISTRY (the run / run2 / run_io / compile_clean / compile_error /
# out_cmp / sigdeath / natdepth calls at the foot of
# tests/elm-fixtures/run-elm-gate.sh).""")

sub("""# Prerequisites: none (bash + awk + sed) — the gate's dump mode stops before it
# loads elm, elmvm, node or jq.""",
"""# Prerequisites: none (bash + awk + sed) — the gate's dump mode stops before it
# loads elm, node or jq.""")

sub("The dump it is rendered from (no elm/elmvm/node/jq needed in that mode):",
    "The dump it is rendered from (no elm/node/jq needed in that mode):")

sub("""| column | meaning |
|---|---|
| \\`check\\` | the name the gate prints (\\`PASS <name> …\\`) |
| \\`kind\\` | the gate function that registered it (see the mapping below) |
| \\`entry point\\` | the function the VM calls; \\`<Module>.<fn>\\` is resolved from the fixture's \\`module\\` header |
| \\`expected\\` | what must be observed: a single-line printed value, an escaped multi-line value (\\`\\\\n\\`), or a substring the compile error must contain |
| \\`args\\` | argv passed to the entry point |
| \\`stdin\\` | file under \\`input/\\` redirected into the VM |
| \\`fixture\\` | the fixture source (or the committed \\`.csexp\\` bundle for \\`rawrun\\`) |""",
"""| column | meaning |
|---|---|
| \\`check\\` | the name the gate prints (\\`PASS <name> …\\`) |
| \\`kind\\` | the gate function that registered it (see the mapping below) |
| \\`entry point\\` | the function the native binary runs; \\`<Module>.<fn>\\` is resolved from the fixture's \\`module\\` header |
| \\`expected\\` | what must be observed: a single-line printed value, an escaped multi-line value (\\`\\\\n\\`), or a substring the compile error must contain |
| \\`args\\` | argv passed to the entry point |
| \\`stdin\\` | file under \\`input/\\` redirected into the binary's stdin |
| \\`fixture\\` | the fixture source |""")

sub("""| \\`kind\\` (registered by) | dispatcher kind | what it asserts |
|---|---|---|
| \\`run\\` | \\`run\\` | compiles, runs the entry point through the VM, printed value == \\`expected\\` |
| \\`run2\\` | \\`run2\\` | multi-module: \\`fixture\\` compiled *with* its aux module, then as \\`run\\` |
| \\`run_io\\` | \\`io\\` | as \\`run\\`, with stdin redirected from \\`input/<stdin>\\` |
| \\`compile_clean\\` | \\`ok\\` | compilation must yield a real bundle, not an \\`err …\\` payload (no value check — the fixture's value cannot be driven from argv) |
| \\`compile_error\\` | \\`err\\` | compilation must emit \\`err <message>\\` containing \\`expected\\` |
| \\`out_cmp\\` | \\`cmp\\` | the raw file an earlier run wrote must equal its \\`expected/*.txt\\` bytes |
| \\`rawrun\\` | \\`rawrun\\` | runs a committed \\`.csexp\\` bundle no Elm source can produce (e.g. an unknown Task ctor) |
| \\`sigdeath\\` | \\`sigdeath\\` | a child that dies BY SIGNAL must be reported as \\`128+num\\` (compiles its own bundle; \\`expected\\` = the \\`<code>|<out>|<err>\\` tuple): \\`sh -c 'kill -9 $$'\\` is reaped WIFSIGNALED, so the code must be 137 — a decoder without \\`waitStatusCode\\`'s signal arm answers \\`EXITSTATUS(9) = 0\\` |
| \\`depth\\` | \\`depth\\` | deep NON-tail recursion past \\`CALL_STACK_DEPTH\\` must be LOUD (compiles its own bundle; \\`args\\` = control-depth past-cap-margin): control depth and \\`CAP-1\\` print \\`expected\\`; past the cap the process exits non-zero with the \\`call stack depth exceeded\\` diagnostic on stderr and no value on stdout |
| \\`natrun\\` (registered by \\`run\\`) | \\`natrun\\` | P7 native twin of \\`run\\`: the same sources build through the QBE backend (elm \\`->\\` .ssa \\`->\\` vendored qbe \\`->\\` cc + rt.o) and the binary must print \\`expected\\` — the successor execution model; \\`ELM_GATE_NATIVE=0\\` registers none |
| \\`natrun2\\` (by \\`run2\\`) | \\`natrun2\\` | native twin of \\`run2\\` (aux module + fixture compiled together) |
| \\`natio\\` (by \\`run_io\\`) | \\`natio\\` | native twin of \\`run_io\\` (stdin redirected from \\`input/<stdin>\\`) |
| \\`natsig\\` (by \\`sigdeath\\`) | \\`natsig\\` | native twin of \\`sigdeath\\` (signal-death reap on the native effect loop) |
| \\`natdepth\\` | \\`natdepth\\` | the NATIVE twin of \\`depth\\`: deep NON-tail recursion past the C-stack budget must be LOUD (builds its own binary via \\`tools/qbe/qbe-mk.sh\\`; \\`args\\` = control-depth past-depth deep-depth): the control prints \\`expected\\` under the check's own 1 MiB \\`ulimit -s\\` (\\`QBE_NO_RLIMIT=1\\`); past the boundary the process exits non-zero with the \\`native stack depth exceeded\\` diagnostic on stderr and no value on stdout; deep-depth must still complete at the driver's r""",
"""| \\`kind\\` (registered by) | dispatcher kind | what it asserts |
|---|---|---|
| \\`run\\` | \\`natrun\\` | the fixture builds through the QBE backend (elm \\`->\\` .ssa \\`->\\` vendored qbe \\`->\\` cc + rt.o) and the binary must print \\`expected\\` — the gate's execution model since the interpreter retired at P8 |
| \\`run2\\` | \\`natrun2\\` | multi-module: \\`fixture\\` compiled *with* its aux module, then as \\`run\\` |
| \\`run_io\\` | \\`natio\\` | as \\`run\\`, with stdin redirected from \\`input/<stdin>\\` |
| \\`compile_clean\\` | \\`ok\\` | compilation must yield a real output, not an \\`err …\\` payload (no value check — the fixture's value cannot be driven from argv) |
| \\`compile_error\\` | \\`err\\` | compilation must emit \\`err <message>\\` containing \\`expected\\` |
| \\`out_cmp\\` | \\`cmp\\` | the raw file an earlier run wrote must equal its \\`expected/*.txt\\` bytes |
| \\`sigdeath\\` | \\`natsig\\` | a child that dies BY SIGNAL must be reported as \\`128+num\\` (builds its own binary; \\`expected\\` = the \\`<code>|<out>|<err>\\` tuple): \\`sh -c 'kill -9 $$'\\` is reaped WIFSIGNALED, so the code must be 137 — a decoder without \\`waitStatusCode\\`'s signal arm answers \\`EXITSTATUS(9) = 0\\` |
| \\`natdepth\\` | \\`natdepth\\` | deep NON-tail recursion past the C-stack budget must be LOUD (builds its own binary via \\`tools/qbe/qbe-mk.sh\\`; \\`args\\` = control-depth past-depth deep-depth): the control prints \\`expected\\` under the check's own 1 MiB \\`ulimit -s\\` (\\`QBE_NO_RLIMIT=1\\`); past the boundary the process exits non-zero with the \\`native stack depth exceeded\\` diagnostic on stderr and no value on stdout; deep-depth must still complete at the driver's r""")

open(p,'w').write(s)
print(f"OK: {n} edits")
