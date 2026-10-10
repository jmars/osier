# zinc-vm

The ZINC VM INTERPRETER for fixpoint-linux — the bytecode eval loop, the
csexp parser/bundle loader, and the host-call shims that drive bundled
closures.  This is the half that DIES at P8 of the retire-the-VM plan
(handoff-osier-rtsplit): the runtime it executes lives in the sibling
**osier-rt** package (`../osier-rt`), which this package depends on and
re-exports.

A Zig 0.16 native library package. Exposes one module:

- `vm` — the interpreter (`src/vm.zig`: parser + interp + hostcall) plus
  re-exports of osier-rt's runtime modules (state/values/symbols/tables/
  varray/prims/streams/execplan) so existing `@import("vm").values`-style
  references keep working until P8.

Not here anymore (moved to osier-rt with the split): the GC, the value
model, the Vm state + global tables, the primitives, streams, and the
exec-plan layer.  Deleted with the split: `marshal.zig` (only the
Osier-unreachable `eval-kl` prim used it) and the Shen catch machinery
(`CatchSite`/`catch_chain`/`in_trap_error`) that existed only for
`trap-error`, which the Elm front end cannot emit.

## Consumers

- **fx-ui** — Elm → ZINC-csexp compiler + runtime (`src/effectloop.zig` is consumer-side)
- **shen** — the self-hosting Shen OS (shensh, zincdec)

Both consume this package via a `build.zig.zon` path dependency (later a git
submodule / `zig fetch`).

## The shared-executor consolidation

The org previously had two divergent copies of this VM (fx-ui's and shen's).
This package is the single canonical source: fx-ui's newer base (M6–M11 perf:
frame-stack pool, tail-env reuse, single-probe global lookup) reconciled with
shen's eval-kl chain (marshal, catching hostcalls, wait/kill). Arithmetic prims
deliberately carry **no type guards** (bare `+%`/`-%`/`*%`/`@divTrunc`
semantics) — per AGENTS.md the metacircular interpreter relies on it and type
errors belong to the safe-wrapper layer, not the VM.

## Build & test

```sh
zig build            # library
zig build gate       # gc+vm tests in Debug/ReleaseSafe/ReleaseFast (3 × 138)
zig build test       # Debug tests
```

## Repo conventions

- Native-only (no wasm target).
- `build.zig` exposes `gc` and `vm` via `b.addModule` for package consumers;
  per-mode gate instances use `b.createModule` (independent optimize).
- Commits follow conventional style (`feat:`/`fix:`/`chore:`/`refactor:`).
