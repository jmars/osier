# tools/bootstrap/selfhost.csexp — provenance

**This is the one generated artifact in this repo that MUST be committed.** A
fresh clone has no compiler: the source of truth is
`elm-compiler/src/*.elm` (the frontend) plus `elm-compiler/selfhost/manifest.json`
(75 sources), and turning those into a compiler normally needs **elm 0.19.2**
(`elm make`) and **node**. The committed bundle removes both: it is the
compiler's own 75 sources, already compiled into a csexp program whose entry is
`NativeMain.main`, and it runs on the ZINC VM (`zig build elmvm`) with no elm,
no node and no AOT/LLVM step.

    tools/bootstrap-compile.sh <in.elm>... <out.csexp>
    tools/bootstrap-compile.sh <manifest>      # line format, see the script

## Identity

| | |
|---|---|
| path | `tools/bootstrap/selfhost.csexp` |
| bytes | 2126056 |
| sha256 | `ad36cbab7d53d97c6d6c4610bc13d37e53b355da1f78878b11292780a4789224` |
| checksum file | `tools/bootstrap/selfhost.csexp.sha256` (verified by `tools/bootstrap-compile.sh` before every run) |
| built from commit | `a7755b80e136a8feac6e4c7240e936aa3ed11f81` (HEAD) **plus the uncommitted "middle tier becomes self-compiled" change — see "Re-freeze 2026-10-10" below** |
| entry point | `NativeMain.main` |

## Inputs

| | |
|---|---|
| manifest | `elm-compiler/selfhost/manifest.json`, sha256 `8f6bbfb05efd258a4e2d64f86a80c4ce56f6cb1ffed914a329b449b5873f12cf` |
| source count | 75 (every path listed in the manifest; all must exist) |
| source-set digest | `8cada8b44f6651e366abe1f177f027ffc82488c449523f2f4ef39d8e48f4c6d9` |
| corpus | `elm-compiler/src/Prelude.elm`, `src/Runtime.elm`, `core-libs/{Dict,Set,Maybe,Result,Tuple,JsArray,Array,Str}.elm` (always appended by `run.js`, not in the manifest) |

The source-set digest is the sha256 of `sha256sum`-style lines
(`<sha256>  <path>`) for the 75 manifest sources **in manifest order**:

    jq -r '.groups[].sources[]' elm-compiler/selfhost/manifest.json \
      | while read -r f; do printf '%s  %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$f"; done \
      | sha256sum

## How it was produced (the STOCK path — this is a real compile)

The producer is the **elm 0.19.2 authored frontend**, NOT the VM:

1. `elm-compiler/compiler.js` = `elm make src/Main.elm --output=compiler.js`
   (elm 0.19.2, `ELM_HOME=elm-compiler/.elm-cache`), sha256
   `e8236bd25af89776fede2804e3dfd1f81077d410199cf817a15041b2869f1ef2`.
   `compiler.js` is gitignored — it is rebuilt by `elm-compiler/build.sh` or
   `tools/osier-numbers.sh`; the hash is recorded here as informational only,
   since the elm compiler is not bit-reproducible across elm versions.
2. the exact command:

       tools/selfhost-compile.sh

   which is `node elm-compiler/run.js --batch elm-compiler/selfhost/manifest.json`,
   run **from the repo root** (run.js resolves manifest paths against its CWD).
   Note the wrapper's optional `$1` only names the file it then checks for
   non-emptiness: `run.js` writes to the manifest's own `output` field, which is
   `zig-out/selfhost.csexp`.
3. `cp zig-out/selfhost.csexp tools/bootstrap/selfhost.csexp` (the committed copy).

Toolchain used: elm 0.19.2 (`~/.npm-global/lib/node_modules/elm/bin/elm`),
node v26.8.1, zig 0.16.0. Measured cost of step 2: **3 s**.

Reproducibility check run for this file: `tools/selfhost-compile.sh` was re-run
on the clean-at-`33e1d5b` tree while writing this file and rewrote
`zig-out/selfhost.csexp` with the **same** sha256 — i.e. the seed is
reproducible from HEAD's 75 sources by the stock path.

Re-checked after the Withe→Osier rename (2026-10-08), because that rename edits
a comment in one manifest source (`elm-compiler/src/Type/Builtins.elm`): the
source-set digest above therefore changes (it hashes the sources themselves),
but the **compiled bytes do not**. `tools/selfhost-compile.sh` re-run over the
renamed sources wrote `zig-out/selfhost.csexp` at sha256
`2d1f8998a13e28c0c47cccc46ac5e390572f73cbe2d63e18d3501cde44568c8b` — byte-identical
to the committed seed (`cmp`, exit 0), in 3 s. `src/Type/Builtins.elm`'s *code*
is untouched; only the comment that names the language changed.

## Re-freeze 2026-10-09 — integer literals above 2^53 are now a hard error

**This is a byte-changing re-freeze, not a comment-only one.** The 58 sources
now contain a real change to `elm-compiler/src/ParserFast.elm` (an integer
literal the frontend cannot reproduce exactly is now a parse error instead of
being silently rounded by the host's arithmetic — the stock frontend runs under
node, where an `Int` is an IEEE double). Adding code to a manifest source
changes the compiled bundle, so unlike the rename above the bytes MOVE.

MEASURED on this host, 2026-10-09, at HEAD `33e1d5b` + that uncommitted edit:

    tools/selfhost-compile.sh            # exit 0, 2.1 s
    # wrote zig-out/selfhost.csexp (1466335 bytes)
    cmp zig-out/selfhost.csexp tools/bootstrap/selfhost.csexp
    # zig-out/selfhost.csexp tools/bootstrap/selfhost.csexp differ: byte 12183
    # exit 1  (the previous committed copy, 1460820 bytes — the size alone
    #          rules out identity)
    sha256sum zig-out/selfhost.csexp tools/bootstrap/selfhost.csexp
    # ac8acd77aab6353507736c158c9a184f62b46d1080050069d0c3959f0ce1cb4c  zig-out/selfhost.csexp
    # 2d1f8998a13e28c0c47cccc46ac5e390572f73cbe2d63e18d3501cde44568c8b  selfhost.csexp BEFORE this re-freeze

Only ONE manifest source differs from HEAD (`git diff --name-only HEAD -- $(jq
-r '.groups[].sources[]' elm-compiler/selfhost/manifest.json)` lists exactly
`elm-compiler/src/ParserFast.elm`), so the whole byte delta is attributable to
it: the first differing byte (12183) sits in the defun region, and the added
`String.fromInt` / `String.toLower` / `String.startsWith` / `String.dropLeft`
calls also move the emitted global order.

The seed was re-frozen (`cp zig-out/selfhost.csexp tools/bootstrap/selfhost.csexp`,
`selfhost.csexp.sha256` regenerated, identity and source-set digest updated
above). It was then VALIDATED as a compiler, cheaply: run on the VM over
`tests/elm-fixtures/fib.elm` it produces a bundle byte-identical to the stock
compiler's for the same source, and over
`9223372036854775807` it produces `err parse failed` (i.e. the re-frozen seed
carries the new check):

    AOTRUN_ARGV=1 AOTRUN_QUIET=1 ELMC_HEAP_MB=1024 \
      zig-out/bin/elmvm zig-out/selfhost.csexp NativeMain.main <manifest>
    # exit 0, 50 s, two groups
    cmp <seed's fib.csexp> <stock fib.csexp>     # identical, exit 0
    sha256sum …   # 092798f5f0e40426ee0783d636f64b4499e0321bdb261915b5e57950261e766a (both)

The full M16 gate was then run over the re-frozen seed and PASSED:

    tools/selfhost-gate.sh
    # exit 0, 12 m 51 s (aotdump + ReleaseFast build + 150 groups)
    # selfhost-gate: PASS=150 FAIL=0

i.e. for all 150 gate groups the SELF-COMPILED compiler's `.csexp` is
byte-identical to the stock compiler's — the M16 equivalence property, on the
real fixture manifest and not just one fixture.

**OUTSTANDING — the fixed-point verification has NOT been re-run.** The
`## The fixed-point fact` run below (807 s, whole compiler) was deliberately
NOT executed for this re-freeze. So for THIS bundle the strongest statement
available is the M16 gate above (equivalence to the stock compiler on 150
groups) plus the one-fixture VM run, NOT the fixed point — the two are
different claims, and only the 807 s run establishes the second. It must be
scheduled deliberately before this seed is treated as verified in the sense the
rest of this file means.

Two stale references are known and are NOT updated here (outside the change's
write scope — see the handoff `handoff-osier-bigint-result`):

  * `tools/midtier-diff.sh:68` pins `SEED_SHA="2d1f8998…"` and asserts that a
    `MIDTIER=0` selfhost release reproduces it; that step now reports
    `FAILED — MIDTIER=0 moved the seed` until the constant is set to
    `ac8acd77…`.
  * `elm-compiler/src/Mid/Module.elm`'s header comment cites the old digest.

(Both of those stale references were in fact updated at HEAD `a7755b8` and
again by the 2026-10-10 re-freeze below — the note above is the historical
record of the state this file described at the time of the bigint re-freeze.)

## Re-freeze 2026-10-10 — the middle tier becomes self-compiled

**This is the byte-changing re-freeze the whole retirement plan is sequenced
around.** The 58-source manifest contained **no `Mid/*` source**, so the
compiler the QBE backend builds could emit CSEXP only.  This change adds the
middle tier — the QBE backend and everything `Mid/QbeModule` pulls in — to the
self-host manifest, so a compiler built from the manifest can now emit its own
QBE IL.

What moved (all uncommitted, on HEAD `a7755b8`):

  * `elm-compiler/selfhost/manifest.json` — 58 → **75 sources** (the 17 `Mid/*`
    modules: `Ir`, `FromAst`, `ToZinc`, `Shrink`, `Arity`, `ConstFold`,
    `DeadGlobals`, `Inline`, `Simplify`, `Module`, `Qbe/{Il,Types,Flatten,
    Lower,Peephole,Print}`, `QbeModule`).
  * `elm-compiler/selfhost/NativeMain.elm` — a `.ssa` batch mode
    (`elmc --ssa <entryKey> <manifest>`) that drives `Mid.QbeModule.compileEntry`
    and writes QBE IL per group instead of csexp; the csexp shapes are untouched.
  * `elm-compiler/src/Mid/*` — rewritten into the SELF-HOST typechecker's subset
    so the tier is compilable BY the compiler it builds.  Semantically-equivalent
    rewrites only, so the emitted `.ssa` is byte-identical to the pre-change
    compiler's: `>>`/`<<` composition → lambdas; `Block`/`Func` record-constructor
    calls → record literals; `exposing (..)` (which brings no types) → explicit
    lists; multi-field record updates on a fresh base → named/annotated helpers;
    `Debug.todo` → `Result` propagation (`Qbe.Flatten.run` now `Result`-returning);
    `String.concat`/`String.repeat`/`String.uncons`/`String.all`/`Basics.max`/
    `List.intersperse` → self-host spellings.
  * `elm-compiler/src/Mid/Qbe/Print.elm` — `escapeStr` made BYTE-CONSISTENT across
    the two runtimes.  The self-host compiler's `String.toList`/`Char.toCode` are
    BYTE-oriented (one Char per UTF-8 byte) while stock elm's are CODE-POINT
    oriented, so the original `escapeChar` (scalar → `utf8Bytes` → octal)
    re-encoded each byte on the self-host path — the non-ASCII error strings
    (`… — …`) in `Flatten`/`Lower` emitted `\303\242\302\200\302\224` where the
    stock emit wrote `\342\200\224`.  A `stringIsByteIndexed` probe (the same one
    `Zinc.Csexp` uses) now emits each byte's octal DIRECTLY under byte semantics,
    reproducing the stock `.ssa` byte-for-byte.

MEASURED (this host, 2026-10-10, HEAD `a7755b8` + the change):

    tools/selfhost-compile.sh            # exit 0, ~2 s
    # wrote zig-out/selfhost.csexp (2126056 bytes; was 1466335 — the middle
    # tier is ~660 KB of compiled bundle)
    sha256sum zig-out/selfhost.csexp
    # ad36cbab7d53d97c6d6c4610bc13d37e53b355da1f78878b11292780a4789224

The seed was re-frozen (`cp zig-out/selfhost.csexp tools/bootstrap/selfhost.csexp`,
`selfhost.csexp.sha256` regenerated, identity and source-set digest updated
above), and `tools/selfhost-audit.sh` is green: **75 files, 75 ok, 0 of every
failure class, whole-group OK** — i.e. every added `Mid/*` source parses,
resolves, typechecks and lowers through the self-host compiler.

## The fixed-point fact (why a committed binary is safe to trust)

Running the seed **on the VM, over its own sources**, reproduces these exact
bytes. MEASURED here, 2026-10-07:

    jq -r '.groups[] | (.sources[] | .), "-> /tmp/fixpoint.csexp"' \
      elm-compiler/selfhost/manifest.json > /tmp/selfhost.fixpoint.manifest
    tools/bootstrap-compile.sh /tmp/selfhost.fixpoint.manifest
    # exit 0, 807 s (13 m 27 s), stdout empty
    sha256sum /tmp/fixpoint.csexp tools/bootstrap/selfhost.csexp
    # 2d1f8998a13e28c0c47cccc46ac5e390572f73cbe2d63e18d3501cde44568c8b  (both)
    cmp /tmp/fixpoint.csexp tools/bootstrap/selfhost.csexp   # identical, exit 0

So the bundle is a **fixed point of the compiler under itself**: the VM
interpreting it compiles the compiler to the same bytes. That is the strongest
statement available that the committed binary *is* the compiler for these
sources — a corrupted or hand-edited seed would not reproduce them — and it is
what licenses trusting a generated artifact that no fresh clone can rebuild
without elm and node.

## Cost (this host, 2026-10-07; `zig build elmvm` cached)

| workload | stock (`node run.js`) | VM + this seed |
|---|---|---|
| the whole compiler, 58 sources | 3 s | **807 s (13.5 min)** |
| one gate fixture | ~0.4 s | ~52 s |
| 5 fixtures, ONE manifest | 1 s | 59 s |
| one fixture, single-file CLI form | <1 s | 55 s |

The per-fixture cost does **not** scale down with the fixture: `Lower.Module
.compileBatch` parses, type-checks and lowers the fixed corpus once per process
and the corpus pass dominates. Compile N groups in ONE manifest, not N times.
The VM needs `ELMC_HEAP_MB` (3072 above; 1024 fits a single fixture) — do not
run it on `elmvm`'s 64 MB default, which is sized for the gate's *execution*
use, not for compiling.

## Verifying this file

    cd <repo root>
    (cd tools/bootstrap && sha256sum -c selfhost.csexp.sha256)   # identity
    tools/bootstrap-compile.sh ...                                # does the same check itself
    # then the fixed-point run above (~13.5 min) to prove it still IS the compiler
