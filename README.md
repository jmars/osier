# osier

The Osier language — the Elm→QBE compiler, the Lean mechanization, and the
language's evidence chain — as its own repository. The terminal/GUI toolkit
that consumes it lives in the separate
[`fx-ui`](https://github.com/fixpoint-linux/fx-ui) repo.

**Artifact evaluation:** what this is, the tag to check out, the one command
that reproduces the paper's numbers and what they should be, and every
prerequisite — see **[ARTIFACT.md](ARTIFACT.md)**.

Contents:

- `elm-compiler/` — the Elm→QBE compiler (corpus `Prelude`/`Runtime`/core-libs,
  the `run.js` batch driver, and the selfhost group) **and the whole runtime**:
  `runtime.mid` is the Mid-written runtime (collector, roots, write barrier,
  printer, float text, boot) that every artifact links, emitted INTO the `.ssa`.
  There is no Zig in this repo any more — the Zig runtime, its vendored GC
  package (`vendor/osier-rt/`), `tools/qbe/hostshim.zig`, the `rt.o` object and
  the language host (`src/effectloop.zig`, retired at O4) were deleted by the
  zighost arc, whose last act is `Z6`; the tombstone in `docs/gc-zig.md` and the
  `BRIDGES` table in `plan.md` are the record.
- `lean/` — the Lean 4 mechanization.
- `tests/elm-fixtures/` — the language fixtures + `run-elm-gate.sh` gate
  (`MATRIX.md` lists every registered check, generated from the gate).
- `tools/` — the evidence chain (`osier-numbers.sh`, the corpus baseline, the
  runTask recount) and the QBE native backend (`tools/qbe/`: the gate's native
  twins, `qbe-check.sh`, `qbe-selfhost.sh`).
- `docs/` — the paper and research notes.

## Build

There is deliberately no build step here, and no Zig. `elm-compiler/run.js`
drives the Elm→QBE front end (`elm-compiler/build.sh` builds `compiler.js`), and
the native backend is built on demand by `tools/qbe/qbe-mk.sh`: the vendored
`vendor/qbe/qbe` turns the emitted `.ssa` into assembly and `cc` links it
against libc — the runtime is Mid and is already inside the `.ssa`, so there is
no runtime object to build. The evidence chain is `tools/osier-numbers.sh`.

## Recursion and the native stack

The QBE native backend gives **proper tail calls**. A saturated self-call in
tail position compiles to an in-frame loop, and every other tail position
(cross-defun calls, partial applications, thunk forces) returns a `.tail` that
a bounce loop chases — so tail recursion, **including mutual tail recursion**,
runs in constant native stack. This is verified, not asserted:
`tools/qbe/qbe-check.sh`'s mutual-tail check runs `Mutual.even 1000000` —
1,000,000 hops of mutual recursion — to completion against a pinned golden;
before the bounce loop the same shape died between 20k–40k hops on an 8 MB
stack. This is stronger than Elm's own treatment, which optimises self-tail
calls only.

**Non-tail recursion is not optimised and consumes native stack — one frame per
call.** That is inherent, not a defect of this implementation: a non-tail call
must be resumed after the callee returns, so no tail-call optimisation can
remove it, in any ML-family language including Elm.

The idiom is the usual one: **build the result in an accumulator parameter and
reverse at the end.** Both examples in this repo were real: the retired csexp
emitter's `fuse` and `Prelude.elm`'s `filterMap` were non-tail list walkers that
exhausted the native stack on large inputs, and both are now tail-recursive
accumulator walks. The finishing reverse is cheap on both build paths:
`Prelude.elm`'s `listRevGo` (behind `List.reverse`) is already tail-recursive,
as is elm/core's (`foldl cons [] list`).

As a mitigation — explicitly **not** a guarantee — the native runtime raises
the stack soft limit to 64 MB at startup (`Rt.main` in
`elm-compiler/runtime.mid`). That net covers
every C-stack exhaustion up to 64 MB, and deep non-tail recursion can still
exhaust it and crash. The backend mechanism (in-frame loops, the bounce loop,
frame rooting) is described in [docs/qbe-backend.md](docs/qbe-backend.md).

## Evidence chain

```sh
tools/osier-numbers.sh
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
