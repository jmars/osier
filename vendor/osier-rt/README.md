# osier-rt

The Osier RUNTIME package — what every backend links and what survives the
interpreter's retirement: the GC and the primitives, vendored as first-class
components per the project's ruling ("vendor the GC" + "the prims"), plus the
value model, symbol interner, global tables, Vm state, ValueArray stack ops,
stream I/O, and the process exec-plan layer they stand on.

A Zig 0.16 native library package. Exposes two modules:

- `gc` — the precise moving generational collector
  (`src/gc.zig`: types/heap/collect/scan/roots).  Imports nothing outside
  itself and std.
- `rt` — the runtime (`src/rt.zig`: state/values/symbols/tables/varray/
  prims/streams/execplan).  Imports `gc` only — NEVER the ZINC interpreter,
  which lived in the sibling `../zinc-vm` package and depended on this one, not
  the reverse.  The interpreter was retired at P8 (2026-10-10) and that package
  is gone; nothing here ever imported it.

## The split (handoff-osier-rtsplit)

Everything here moved out of `vendor/zinc-vm` when the runtime was split from
the interpreter.  Two deletions came with the move, both Osier-scope calls:

- **trap-error and its whole machinery** (CatchSite, `Vm.catch_chain`,
  `in_trap_error`, hostcall's catching flavors): Osier has no exceptions and
  the Elm front end cannot emit the prim; the QBE backend already refused it
  loudly.  This removed the interpreter-loop calls from prims, which is most
  of what makes an interpreter-free runtime possible.
- **eval-kl and `marshal.zig`**: it marshalled through `marshal.zig` and then
  called three bundle functions by name that exist only in a Shen image Osier
  never loads — dead by construction.

22 Shen-only prims went with them (80 -> 58 table rows); the compile corpus
stayed byte-identical because none is ever emitted.

## Build & test

    zig build test   # gc suite (+ the T9 expected-panic exe)
    zig build gate   # the gc suite in Debug + ReleaseSafe + ReleaseFast
