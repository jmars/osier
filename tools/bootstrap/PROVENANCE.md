# tools/bootstrap/selfhost.csexp — provenance

**This is the one generated artifact in this repo that MUST be committed.** A
fresh clone has no compiler: the source of truth is
`elm-compiler/src/*.elm` (the frontend) plus `elm-compiler/selfhost/manifest.json`
(58 sources), and turning those into a compiler normally needs **elm 0.19.2**
(`elm make`) and **node**. The committed bundle removes both: it is the
compiler's own 58 sources, already compiled into a csexp program whose entry is
`NativeMain.main`, and it runs on the ZINC VM (`zig build elmvm`) with no elm,
no node and no AOT/LLVM step.

    tools/bootstrap-compile.sh <in.elm>... <out.csexp>
    tools/bootstrap-compile.sh <manifest>      # line format, see the script

## Identity

| | |
|---|---|
| path | `tools/bootstrap/selfhost.csexp` |
| bytes | 1460820 |
| sha256 | `2d1f8998a13e28c0c47cccc46ac5e390572f73cbe2d63e18d3501cde44568c8b` |
| checksum file | `tools/bootstrap/selfhost.csexp.sha256` (verified by `tools/bootstrap-compile.sh` before every run) |
| built from commit | `33e1d5bba463671f0154545f0b5133537db6c0c6` (HEAD) |
| entry point | `NativeMain.main` |

## Inputs

| | |
|---|---|
| manifest | `elm-compiler/selfhost/manifest.json`, sha256 `369e6a735af3de6f6d2b2ad2afc000fc55fec9cab6218a98deec5c4f8e8901eb` |
| source count | 58 (every path listed in the manifest; all must exist) |
| source-set digest | `b0c655da780f9a831c63b03f4d89e57042b40c3eb7afa0c818d08fb805a1a331` |
| corpus | `elm-compiler/src/Prelude.elm`, `src/Runtime.elm`, `core-libs/{Dict,Set,Maybe,Result,Tuple,JsArray,Array,Str}.elm` (always appended by `run.js`, not in the manifest) |

The source-set digest is the sha256 of `sha256sum`-style lines
(`<sha256>  <path>`) for the 58 manifest sources **in manifest order**:

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
reproducible from HEAD's 58 sources by the stock path.

Re-checked after the Withe→Osier rename (2026-10-08), because that rename edits
a comment in one manifest source (`elm-compiler/src/Type/Builtins.elm`): the
source-set digest above therefore changes (it hashes the sources themselves),
but the **compiled bytes do not**. `tools/selfhost-compile.sh` re-run over the
renamed sources wrote `zig-out/selfhost.csexp` at sha256
`2d1f8998a13e28c0c47cccc46ac5e390572f73cbe2d63e18d3501cde44568c8b` — byte-identical
to the committed seed (`cmp`, exit 0), in 3 s. `src/Type/Builtins.elm`'s *code*
is untouched; only the comment that names the language changed.

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
