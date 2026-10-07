# withe

The Withe language — compiler, ZINC VM, Lean mechanization, and the language's
evidence chain — as its own repository. The terminal/GUI toolkit that consumes
it lives in the separate [`fx-ui`](https://github.com/fixpoint-linux/fx-ui) repo.

**Artifact evaluation:** what this is, the tag to check out, the one command
that reproduces the paper's numbers and what they should be, and every
prerequisite — see **[ARTIFACT.md](ARTIFACT.md)**.

Contents:

- `elm-compiler/` — the Elm→ZINC compiler (corpus `Prelude`/`Runtime`/core-libs,
  the `run.js` batch driver, and the selfhost group).
- `vendor/zinc-vm/` — the shared GC + ZINC VM executor package (path dep).
- `src/effectloop.zig` — the language host: the CEK effect-manager over the
  compiler's Task effects (execplan + stream/file prims + time + Quit). The UI
  effects (renderer + terminal input) are not handled here; they live in fx-ui.
- `lean/` — the Lean 4 mechanization.
- `tests/elm-fixtures/` — the language fixtures + `run-elm-gate.sh` gate
  (`MATRIX.md` lists every registered check, generated from the gate).
- `tools/` — the evidence chain (`withe-numbers.sh`, the corpus baseline, the
  runTask recount) and the AOT tooling (`elmvm.zig`, `vmbench.zig`, `aot/`).
- `docs/` — the paper and research notes.

## Build

```sh
zig build elmvm    # build the gate harness (zig-out/bin/elmvm)
zig build          # same (elmvm is the default install target)
zig build vmbench  # the throughput benchmark
zig build aot      # the AOT spike exes
```

## Evidence chain

```sh
tools/withe-numbers.sh
```

This runs, from a clean checkout, the whole reproducible measurement chain the
paper cites: the fixture gate, the corpus byte-identity diff, `TestMain`,
`lake build` (Lean), and the runTask branch recount. It is self-contained
(it builds everything it needs) and idempotent (~45s from a clean clone).

The expected output, the prerequisites and what each line means live in
[ARTIFACT.md](ARTIFACT.md); the registered fixture checks are listed in
[tests/elm-fixtures/MATRIX.md](tests/elm-fixtures/MATRIX.md).

Also in `tools/`: `gen-fixture-matrix.sh` (regenerate/verify the matrix list).

Split from `fx-ui` (see the initial commit message for the exact source hash).

**License:** the code is MIT-licensed and `docs/` (the paper and research notes) is CC-BY-4.0 —
see [LICENSE](LICENSE) and [LICENSE-CC-BY-4.0](LICENSE-CC-BY-4.0).
