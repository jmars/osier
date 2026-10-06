# withe

The Withe language — compiler, ZINC VM, Lean mechanization, and the language's
evidence chain — as its own repository. The terminal/GUI toolkit that consumes
it lives in the sibling [`fx-ui`](https://github.com/fixpoint-linux/fx-ui) repo.

Contents:

- `elm-compiler/` — the Elm→ZINC compiler (corpus `Prelude`/`Runtime`/core-libs,
  the `run.js` batch driver, and the selfhost group).
- `vendor/zinc-vm/` — the shared GC + ZINC VM executor package (path dep).
- `src/effectloop.zig` — the language host: the CEK effect-manager over the
  compiler's Task effects (execplan + stream/file prims + time + Quit). The UI
  effects (renderer + terminal input) are not handled here; they live in fx-ui.
- `lean/` — the Lean 4 mechanization.
- `tests/elm-fixtures/` — the language fixtures + `run-elm-gate.sh` gate.
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
paper cites: the fixture gate (169 checks), the corpus byte-identity diff
(167 artifacts), `TestMain` (114 assertions), `lake build` (Lean), and the
runTask branch recount (25/30). It is self-contained and idempotent.

Split from `fx-ui` (see the initial commit message for the exact source hash).
