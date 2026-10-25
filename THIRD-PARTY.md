# Third-party code in this repository

This repository carries derived code from the following third-party packages.
Each entry names the package, its licence and copyright line, where the
derived files live, and how they diverge from upstream. The per-file
attribution comments at the top of each derived file are the primary notice;
this file is the central record. An entry may also record code that is
*vendored verbatim* rather than derived; such an entry says so, and carries no
per-file comments because adding them would itself modify the upstream tree.

## (ZIGHOST Z6) the vendored Zig runtime — DELETED, no longer third-party here

`vendor/osier-rt/` (the Zig GC + values/state/streams/symbols/tables/varray
package, itself derived from the Shen `zincvm.c` runtime) was deleted in the
zighost arc's last act, together with `tools/qbe/hostshim.zig`, the `rt.o`
object, `src/effectloop.zig` and the root `build.zig`/`build.zig.zon`.  Nothing
in this repository links, builds or derives from it any more: the runtime is
Mid (`osier-compiler/runtime.mid`), written for this project, and every artifact
links against libc and nothing else.  The entry is kept as a RECORD so a reader
comparing this file against the tree does not conclude the vendoring vanished by
accident; the provenance history lives in `docs/gc-zig.md` and in `plan.md`'s
BRIDGES table.

## stil4m/elm-syntax 7.3.9

- **Licence:** MIT — Copyright (c) 2018 Mats Stijlaart
- **Upstream:** https://package.elm-lang.org/packages/stil4m/elm-syntax/7.3.9
- **Derived files (40):**
  - `osier-compiler/src/Elm/Syntax/*.elm` (17 files)
  - `osier-compiler/src/Elm/Parser/*.elm` (12 files) and `osier-compiler/src/Elm/Parser.elm`
  - `osier-compiler/src/Elm/{Dependency,Interface,Processing,RawFile}.elm`
  - `osier-compiler/src/Elm/Internal/RawFile.elm`
  - `osier-compiler/src/ParserFast.elm`, `osier-compiler/src/ParserWithComments.elm`, `osier-compiler/src/Rope.elm`
  - `osier-compiler/src/List/Extra.elm`
  - `osier-compiler/src/Char/Extra.elm` (which additionally carries miniBill/elm-unicode code — see below)
- **Local divergence from upstream:**
  1. **JSON codecs pruned** from 24 files by `osier-compiler/selfhost/prune_codecs.py`
     (now retired; kept as the record of the derivation): every
     `encode`/`decoder` and codec-only helper is deleted, because the
     parse -> typecheck -> lower path never serializes the AST.
  2. **Three additive parser patch hunks** (recorded in the headers of the
     touched files; the former `.elm-cache` copy carried the full
     `FXUI-PATCHES.md`):
     - hunk 1 — `Elm/Syntax/Expression.elm`: new `InsertionValue (Node Expression)`
       constructor (the record-INSERTION setter RHS, `{ r | f <- v }`);
     - hunk 2 — `Elm/Parser/Expression.elm`: the record-setter separator accepts
       `<-` as well as `=`, wrapping an `<-` RHS in `InsertionValue`;
     - hunk 3 — `Elm/Parser/TypeAnnotation.elm`: `recordTypeAnnotation` accepts an
       optional `| tailvar` producing `GenericRecord`, so both tail-first
       (`{ r | x : Int }`) and tail-last (`{ x : Int | r }`) record syntax parse.
  3. `osier-compiler/src/Parser.elm` is **not** upstream code — it is original to
     this project (a minimal stub of elm/parser's `Problem`/`DeadEnd` surface).
- **Note:** this package was previously consumed as a dependency and vendored
  under `osier-compiler/selfhost/vendor/`; the `elm/parser`,
  `rtfeldman/elm-hex` and `stil4m/structured-writer` transitive dependencies
  went with it.

### Upstream licence text

```
The MIT License (MIT)

Copyright (c) 2018 Mats Stijlaart

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## miniBill/elm-unicode (code carried inside `Char/Extra.elm`)

- **Copyright:** 2021 Leonardo Taglialegne
- **Licence:** BSD 3-Clause — the full notice is retained verbatim inside
  `osier-compiler/src/Char/Extra.elm` (immediately below the module declaration),
  and that file is included unmodified from the elm-syntax package copy of it.

## QBE (qbe) — compiler backend, vendored verbatim

**A verbatim vendoring with TWO recorded patches: every file under `vendor/qbe/`
is byte-identical to upstream at the pinned commit except the files named under
"Local patches" below — `copy.c` (2026-10-18) and the eight files carrying the
`tcall` instruction (2026-10-23). (Before 2026-10-18 this section read "nothing
is patched"; each patch updated the claim the same day it landed, and the file
says so rather than leaving the claim standing.)**

- **Licence:** MIT — upstream's `LICENSE` opens with the copyright line
  `© 2015-2026 Quentin Carbonneaux <quentin@c9x.me>`; the file is reproduced
  in full at the end of this section.
- **Upstream:** https://c9x.me/git/qbe.git — the canonical repository. (A GitHub
  mirror exists at `ibara/qbe`; it is **not** the source vendored here.) Fetched
  over `git://c9x.me/qbe.git`: the HTTPS endpoint serves the repository over
  *dumb* HTTP, and a full clone over it aborted mid-fetch here ("Cannot obtain
  needed ..."), so the git protocol was used. Only this fetch needed the network.
- **Pinned commit:** `e786f06032fefa2e3790d6b1c9e31ed138f475a6`
  ("rv64: use pc-relative addressing for globals", 2026-06-02) — the commit
  `master` pointed at when the pin was taken (2026-10-07). Tree hash
  `0e5c4c0dcca7e9ab1d125f11ef2b1edbfbc7c23d`. The nearest release tag is `v1.3`
  = `c0818978acec60ebb6167fade60fb7012cbf20ca` (2026-05-13), three commits behind
  the pin. **No branch is tracked.**
- **Where it lives:** `vendor/qbe/` — upstream's layout unaltered: 153 tracked
  files, 1,699,585 bytes. `doc/il.txt` is the IL specification, `doc/abi.txt`
  the ABI notes, `minic/` an example C frontend, `test/` upstream's testsuite.
- **Verification of the copy (2026-10-07):** every one of the 153 files was
  re-hashed as a git blob (`sha1("blob <len>\0" + contents)`) and compared
  against `git ls-tree -r e786f06` — 153/153 identical. After the local patch
  below, 152/153 are still identical and `copy.c` is the one exception.
- **Local patch (2026-10-18) — `copy.c`, `phicopyref()`.** The "dominating jnz
  arg" substitution returned the jnz argument (a `w`-class 0/1 condition) for
  any 2-armed phi whose arms are the constants `$0`/`$1`. qbe's constants are
  untyped, so `req(p->arg[n], con01[c])` also matches an `l`-class phi — what
  qbe's own `ssa()` builds from `storel 0` / `storel 1` in the two arms of a
  diamond, read back by an `l` load (a boxed boolean stored as an 8-byte
  value). The substitution then left a `w` temp used where `l` is required:
  **ill-typed IL.** MEASURED consequences on the unpatched pin: `qbe -t rv64`
  ABORTS (`rv64/isel.c:80: fixarg: Assertion 'k == fn->tmp[r0.val].cls'
  failed`) on such legal IL — including `x + (if c then 0 else 1)` compiled
  from plain Elm — while amd64/arm64 accept it and silently rely on the
  backend zero-extending a 32-bit value into an 8-byte slot. The patch adds
  the missing class test (a jnz-arg TEMP may only stand in when its class
  equals the phi's); a constant argument is untyped and still substitutes.
  This *removes* an unsound optimization, never adds one, and upstream has it
  in neither `master` (= this pin) nor `dev` (checked 2026-10-18), so there is
  no commit to move the pin to. Verified after patching: `make -C vendor/qbe
  check` → "All is fine!", and `tools/qbe/qbe-check.sh`'s
  `cross-rv64-lphi` row (a hand-written IL fixture with exactly this shape)
  is RED on the unpatched pin and GREEN with it. **A future pin bump must
  re-apply this patch or confirm upstream fixed it.**
- **Local patch (2026-10-23) — the `tcall` tail-call instruction.** Files
  touched: `ops.h`, `all.h`, `parse.c`, `util.c`, `live.c`, `spill.c`, `rega.c`,
  `load.c`, `amd64/sysv.c`, `amd64/isel.c`, `amd64/emit.c`, `amd64/winabi.c`,
  `arm64/abi.c`, `rv64/abi.c`. It adds one instruction, `tcall`, spelled
  `tcall [ret-annotation] $f(args...)`: a call that returns to the CALLER's
  caller, with no result, that must be the last instruction of its block and be
  followed by a bare `ret`. It carries `call`'s pinned flag, so gcm/ifopt/gvn/
  fold/promote treat it as an immovable effect by table. On amd64/sysv the
  epilogue `ret` and `tcall` share (`sysv_epilogue`), and `tcall` emits that
  teardown followed by `jmp`; the argument copies abi1 emits before it read the
  frame, so the load-before-teardown order falls out of the existing lowering
  order. **Every condition it cannot honour is a loud `err()` naming the
  condition — never a silent fallback to `call`**: stack arguments, variadic
  callees, a callee return convention that differs from the enclosing
  function's (the callee returns to OUR caller, so they must agree, and the
  check is per-tcall in abi1 so hand-written IL cannot bypass it), not
  block-final, or not followed by a bare `ret`. A silent fallback would cancel
  the unbounded-depth guarantee a tail call exists to provide, turning a
  program that ran into one that overflows the stack at depth; the refusal is a
  statement about a contract, not about an optimization. arm64, rv64 and the
  win64 ABI `die()` loudly instead of emitting a wrong tail. **This is
  additive and inert**: nothing in Mid emits `tcall` yet, and the corpus .ssa
  gate stays byte-identical (159/159) across it. Upstream has no such
  instruction in `master` (= this pin) or `dev`, so there is no commit to move
  the pin to; a future pin bump must re-apply this patch or adopt a successor.
  Verified: `make -C vendor/qbe check` → "All is fine!", and
  `tools/qbe/tcall-probe.sh` (wired into `qbe-check.sh`) exercises it — the
  decisive row being an ASYMMETRY under `ulimit -s 8192`: 1e7 `tcall` hops
  complete, the same fixture hand-mutated to `call` dies of stack exhaustion.
- **How it is built:** `tools/qbe-build.sh` → `vendor/qbe/qbe`. It drives
  upstream's own `Makefile` unmodified, with the system `cc` and `make`, and
  needs no network. Its artifacts (`qbe`, `*.o`, `config.h`) are covered by
  upstream's own `vendor/qbe/.gitignore`, so a build leaves the tree clean.
- **Verified working (2026-10-07):** upstream's testsuite passes against the
  vendored build (`make -C vendor/qbe check` → `All is fine!`, exit 0), and a
  hand-written IL file assembled and linked with `cc` executes.

### Upstream licence text

```
© 2015-2026 Quentin Carbonneaux <quentin@c9x.me>

Permission is hereby granted, free of charge, to any person obtaining a
copy of this software and associated documentation files (the "Software"),
to deal in the Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, sublicense,
and/or sell copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.
```

## Upstream `Parser.elm` stub

`osier-compiler/src/Parser.elm` is original to this project (no upstream licence
claim); listed here only to make explicit that it is *not* part of the
elm-syntax derivation above.
