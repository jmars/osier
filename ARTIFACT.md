# Withe — artifact evaluation note

This note is the referee's entry point. It says what the artifact is, which tag the paper's
numbers are frozen at, the one command that reproduces them, what that command must print, what
to do when a prerequisite is missing, and what is deliberately not in this repository.

**License:** the code (everything outside `docs/`) is MIT-licensed; `docs/` — the paper and the
research notes — is CC-BY-4.0. See `LICENSE` and `LICENSE-CC-BY-4.0` at the repository root.

## 1. What this is

Withe is a small statically-typed functional language, its compiler and its host runtime, plus
the machine-checked metatheory behind the row-refinement discipline the paper
(`docs/research/withe-paper.md`) describes and measures. Concretely:

- **`elm-compiler/`** — the compiler and its corpus. Frontend (lexer/parser, arrow-spelling GADT
  constructors), the type checker (`src/Type/`: unification with a row rewrite, branch-local row
  refinement, GADT-style index refinement, let-generalization, exhaustiveness/refutation,
  the escape/discharge checks), the lowerer, the corpus it is built from (`src/Prelude.elm`,
  `src/Runtime.elm`, and the eight core libraries in `core-libs/`), the batch driver `run.js`,
  and the compiler's own unit suite `src/TestMain.elm`.
- **`src/effectloop.zig` + `vendor/zinc-vm/`** — the language host: a CEK effect manager over
  exec plans (stream/file prims, monotonic time, `stat`/`listDir` leaves, `Quit`) that runs
  compiled bundles. Built as `zig-out/bin/elmvm`. The UI effects (renderer, terminal input) are
  **not** handled here — see §6.
- **`lean/`** — the Lean 4 mechanization of the calculus's metatheory (§4).
- **`tests/elm-fixtures/`** — the fixture gate: 152 registered checks (`MATRIX.md`, §5).
- **`tools/`** — the evidence chain: `withe-numbers.sh` (the one command), the committed corpus
  byte-identity manifest `withe-corpus-baseline.sha256`, the runTask branch recount, the
  fixture-matrix generator.
- **`docs/research/`** — the paper and its related-work survey.

Nothing in this note is a new claim about the work: every figure below is printed by
`tools/withe-numbers.sh`, whose output the paper cites as the source of its numbers.

## 2. The one command

```sh
git clone <this repository's URL> withe
cd withe
git checkout withe-paper-artifact-1     # the tag the paper's numbers are frozen at
tools/withe-numbers.sh
```

Run it from the repository root (the script `cd`s there itself). It performs, in order:

1. builds the gate harness `zig-out/bin/elmvm` (skipped if already built);
2. rebuilds **both** compiler artifacts from source (`elm-compiler/compiler.js` and
   `test-compiler.js`) — deliberately always, so a stale gitignored artifact cannot answer with
   the wrong bytes;
3. runs the fixture gate (`tests/elm-fixtures/run-elm-gate.sh`) — PASS/FAIL counts;
4. compiles the corpus once as a batch and sha256-compares **every** artifact against
   `tools/withe-corpus-baseline.sha256` (byte-identity);
5. runs the compiler's unit suite `TestMain`;
6. runs `lake build` in `lean/` and counts theorems / axioms / `sorry`;
7. re-derives the runTask branch recount (`tools/withe-recount-runTask.sh`).

### What a good run prints

Exactly this (verbatim from a clean clone at the tag, cold — no `zig-out/`, no `compiler.js`,
no `lean/.lake`; the only machine-dependent lines are the `@ <commit>` header and the absolute
paths on the `lean axioms:` lines):

```
withe-numbers @ de57bad

gate:                        PASS=152 FAIL=0
corpus:                      BYTE-IDENTICAL (149 artifacts = 149 manifest entries)
TestMain:                    All 114 assertions passed.
lake build:                  exit 0, output 0 bytes
    lakefile.lean        0
    Preserve.lean        18
    RowGadtEscape.lean   4
    RowGadt.lean         28
    Typing.lean          0
    TypingStore.lean     29
    Update.lean          11
lean theorems:               90 total
lean axioms:                 3 declared:
    /tmp/withe-clean/lean/Preserve.lean:213:axiom unifies_field_projection (R : Rigid) (r : Row) (ℓ : Label) (a : TyVar) (β : RowVar) (tᵢ : Ty) :
    /tmp/withe-clean/lean/Typing.lean:221:axiom Unifies : Rigid -> Ty -> Ty -> Prop
    /tmp/withe-clean/lean/Typing.lean:229:axiom Captures : Rigid -> Ty -> Ty -> Store -> Prop
lean sorry/admit:            0
withe-recount-runTask @ de57bad

CONDITION (honest): runTask is UNTRUSTED (removed from trustedBodies) and
  its body is checked under a `type x a.` binder.  The committed signature
  has NO binder; the binder is what the branch-local discharge the paper
  measures requires (a rigid result index).  This count is UNDER that binder.

runTask branches: 20 total

fail-fast (untrusted, no masks):
    err type error at 156:29: type variable a is rigid (from the signature) and cannot be unified with List a
    -> exactly ONE error (TaskExec) — this is how "29 of 30" was born
    class: TaskExec = DEFECT: existential cast a ~ List a

bisection (mask each failure to reveal the next):
  [1] mask TaskExec     -> reveals TaskNow
        err type error at 179:13: cannot unify number with a
        OK : expected line 179 (TaskNow)
        class: DEFECT: number literal FlexConflict
  [2] mask TaskNow      -> reveals TaskQuit
        err type error at 185:13: type variable a is rigid (from the signature) and cannot be unified with ()
        OK : expected line 185 (TaskQuit)
        class: DESIGN: un-annotated nullary ctor
  [3] mask TaskQuit     -> reveals TaskStat
        err type error at 195:13: escaping row equation: the branch's refinement of a ({size:number, mode:number, mtimeMs:number, isDir:Bool, isFile:Bool}) is needed to type the result, but a branch equation may not escape its branch
        OK : expected line 195 (TaskStat)
        class: OVER-APPROX: closed-record discharge
  [4] mask TaskStat     -> no runTask branch error remains
        (([11:s]Prelude.not (c (a [1:n]0 f [1:n]4 b [5:b]false j [1:...
        OK : no further runTask branch fails

RESULT: 16 of 20 branches check honestly; 4 fail —
  1 existential cast (TaskExec)
  1 number literal FlexConflict (TaskNow)
  1 deliberate generalization (TaskQuit)
  1 record-discharge over-approximation (TaskStat)

VERDICT: count reproduced (16/20 under the `type x a.` binder)
working tree:                byte-identical (Builtins.elm + Runtime.elm sha256 unchanged)

VERDICT: all checks pass
```

Exit status **0**, last line `VERDICT: all checks pass`.

Note on the `err …` lines in the middle: they are the *output* of the recount measurement (four
interpreter branches that fail on purpose to reveal the next one), not failures. Only the exit
code and the final `VERDICT:` line decide.

### What each line means

| line | what it is |
|---|---|
| `gate: PASS=152 FAIL=0` | all 152 registered fixture checks passed — the language gate (`MATRIX.md`, §5) |
| `corpus: BYTE-IDENTICAL (149 artifacts = 149 manifest entries)` | the corpus (Prelude + Runtime + eight core-libs) compiled once, and each of the 149 compiled artifacts matches the committed sha256 manifest entry-for-entry |
| `TestMain: All 114 assertions passed.` | the compiler's own unit suite |
| `lake build: exit 0, output 0 bytes` | `lake build -q` from `lean/`: no errors, no warnings, no output |
| per-file counts, `lean theorems: 90 total` | theorems per mechanization file (§4) |
| `lean axioms: 3 declared:` … | the three axiom **parameters**, listed with file:line (§4) |
| `lean sorry/admit: 0` | no `sorry`/`admit` anywhere in the mechanization |
| `runTask branches: 20 total` … `VERDICT: count reproduced (16/20 under the `type x a.` binder)` | the corrected branch-honesty count, re-derived by masking each failure in a scratch copy; the script proves the working tree is byte-identical afterwards |
| `VERDICT: all checks pass` | every check above passed — this is the exit code |

### Runtime, self-containedness, idempotence

- **Runtime: ~45 s cold** (clean clone, everything built from scratch, paper's build host) and
  **~20 s warm**. The Lean project is the slowest part.
- **Self-contained**: it builds `elmvm`, both compiler artifacts and the Lean project itself. Nothing
  is downloaded, and no network access is needed — verified by running the whole chain inside
  `unshare -rn` (a network namespace with no interfaces) from a checkout stripped of
  `zig-out/`, `compiler.js` and `lean/.lake`: same numbers, exit 0. The elm package cache is
  committed (`elm-compiler/.elm-cache/`), and `lean/lake-manifest.json` has no external packages.
- **Idempotent**: re-runs print the same numbers and the corpus diff stays empty; the recount
  edits only a scratch copy and asserts the working tree is unchanged.
- **One tracked file is refreshed on the first run of a fresh checkout**:
  `elm-compiler/.elm-cache/0.19.2/packages/registry.dat`, which elm 0.19.2 rewrites
  (deterministically, same bytes every time) when it has to rebuild `elm-compiler/elm-stuff/`.
  So `git status` shows that one file as modified after the first run. It is a cache refresh, not
  a change to the artifact, and it does not affect any number.

## 3. Prerequisites

| prerequisite | version measured on the build host | how it is found | if missing |
|---|---|---|---|
| `node` | v26.8.1 (any recent) | `PATH` | exits 2: `FAIL: node is required and was not found on PATH.` |
| `jq` | 1.8.2 | `PATH` | exits 2, naming `jq` |
| `zig` | 0.16.0 | `PATH` | exits 2, naming `zig` |
| `rg` (ripgrep) | 15.2.0 | `PATH` | exits 2, naming `rg` — **it counts the Lean theorems/axioms, so without the guard those lines would silently print `0`** |
| `python3` | 3.13 | `PATH` | exits 2, naming `python3` (the recount is a python script) |
| elm | 0.19.2 | `$ELM_BIN`, default `$HOME/.npm-global/lib/node_modules/elm/bin/elm` | exits 2 with the `ELM_BIN` block below |
| Lean 4 + lake | `leanprover/lean4:v4.34.1` (from `lean/lean-toolchain`) | `lake` on `PATH`, else `$ELAN_HOME/bin/lake` | exits 2 with the `ELAN_HOME` block below |

Each missing prerequisite prints its own message and exits **2** (a complete run exits 0, a check
that ran and failed exits 1).

### Gotcha (a): `elm` is not on `PATH`

The elm 0.19.2 binary on the build host is a local install, not a `PATH` entry. The script takes
`ELM_BIN` and defaults to `~/.npm-global/lib/node_modules/elm/bin/elm`. If that default does not
exist you get, before anything is measured:

```
FAIL: the elm 0.19.2 binary was not found.
      ELM_BIN=/no/such/elm
      elm 0.19.2 is NOT on PATH in the paper's build host, so ELM_BIN must be
      set to your elm binary, e.g.

          ELM_BIN="$(npm root -g)/elm/bin/elm" tools/withe-numbers.sh

      (the default is $HOME/.npm-global/lib/node_modules/elm/bin/elm)
```

### Gotcha (b): the Lean toolchain, `ELAN_HOME`, and why a bare `lean` does not work

`lean/` is a **Lake project**. `lake` is looked up on `PATH` first, then at
`$ELAN_HOME/bin/lake`; `ELAN_HOME` defaults to `/var/data/workspace/lean/elan` (the paper
author's elan home) and must be set to yours if `lake` is not on `PATH`:

```
FAIL: the Lean 4 toolchain was not found — no `lake` on PATH and none at
      ELAN_HOME/bin/lake.
      ELAN_HOME=/no/such/elan
      Set ELAN_HOME to your elan home (the default is
      /var/data/workspace/lean/elan), or put `lake` on PATH.  Note that a bare
      `lean <file>` does NOT work: lean/ is a Lake project and must be built
      with `lake build` from lean/.
```

**A bare `lean Foo.lean` does not check these files.** The six mechanization files are one
project with a shared module graph; `lake build` (run from `lean/`) is the only way to build it.
Lake also needs no network here: `lean/lake-manifest.json` declares no external packages.

## 4. The Lean layout

`lean/` is **one Lake project** holding the whole mechanization:

| file | role | theorems |
|---|---|---|
| `lean/lakefile.lean` | the project: package `rowgadt`, `lean_lib RowGadtLib` with roots `RowGadt, RowGadtEscape, Update, Typing, TypingStore, Preserve` | — |
| `lean/lean-toolchain` | `leanprover/lean4:v4.34.1` | — |
| `lean/lake-manifest.json` | no external packages (nothing to fetch) | — |
| `lean/RowGadt.lean` | the row algebra; H1, H2-a, H2-b, the counterexample lemmas | 28 |
| `lean/RowGadtEscape.lean` | the two hunt counterexamples, mechanized | 4 |
| `lean/Update.lean` | the update theorem and its insertion dual | 11 |
| `lean/Typing.lean` | the constraint-based judgment skeleton — the rule set, with `Unifies`/`Captures` as axiom parameters (no theorems by design) | 0 |
| `lean/TypingStore.lean` | store lemmas: weakening, monotonicity, the R-LET refined-tail exclusions | 29 |
| `lean/Preserve.lean` | record-operation preservation and the two-tier soundness | 18 |
| | **total** | **90** |

**90 theorems, 3 axiom parameters, 0 `sorry`/`admit`** — the same inventory as the paper's
Appendix B. The three axioms are **parameters, not holes**:

- `Typing.lean:221` `axiom Unifies : Rigid -> Ty -> Ty -> Prop`
- `Typing.lean:229` `axiom Captures : Rigid -> Ty -> Ty -> Store -> Prop`
- `Preserve.lean:213` `axiom unifies_field_projection …`

`Unifies`/`Captures` are the unifier taken as a parameter of the theory; `unifies_field_projection`
is the one property the plain-selection preservation case needs of that abstract unifier. Every
other theorem closes against the local Lean binary with no `sorry`.

## 5. The fixture matrix

`tests/elm-fixtures/MATRIX.md` lists **every** check the gate registers — name, kind (`run` /
`compile_clean` / `compile_error` / `run_io` / `run2` / `out_cmp` / `rawrun`), entry point, expected
value or expected error substring, argv, stdin, fixture — with the count printed by the gate.

It is **generated from the gate's own registration calls**, never hand-copied, and can be
regenerated or checked for staleness:

```sh
tools/gen-fixture-matrix.sh           # (re)write tests/elm-fixtures/MATRIX.md
tools/gen-fixture-matrix.sh --check   # exit 1 + a diff if the listing has gone stale
tools/gen-fixture-matrix.sh --stdout  # print it
```

The raw dump it is rendered from is `ELM_GATE_MATRIX=1 tests/elm-fixtures/run-elm-gate.sh` (TSV;
no elm, elmvm, node or jq needed in that mode). The paper's **Appendix A** is the prose
counterpart: the *designed* programs the paper cites and the claim each one pins. Appendix A is a
selected subset; `MATRIX.md` is the complete registry, and where the two disagree the gate is the
oracle.

## 6. What is **not** in this repository

- **The UI/toolkit.** It lives in the sibling `fx-ui` repository
  (`https://github.com/fixpoint-linux/fx-ui`): the renderer, terminal input, the pty/GUI examples
  and the terminal-UI fixtures. This artifact is the language, its host effect loop, the
  mechanization and the language evidence chain.
- **The terminal-UI fixtures — deferred, and they do not run.** The 19 UI-host rows that used to
  be part of the gate were moved out to `fx-ui`'s `tests/elm-fixtures/run-ui-gate.sh`, which
  **exits 1 on purpose** (`run-ui-gate: DEFERRED — all rows require the re-attached renderer /
  UI libs`). They require a renderer that is not part of this artifact; the 152 checks here do not
  cover them, and nothing in this note claims they pass.
- **UI effects in the host.** `src/effectloop.zig` handles exec plans, stream/file prims, time and
  the `stat`/dir leaves; an effect the host does not implement fails loudly and fast by design.
- No network access, no external Lean packages, no apt/npm installs: everything the command needs
  is in the checkout (plus the toolchain versions in §3).

## 7. Provenance

- **The tag the numbers are frozen at: `withe-paper-artifact-1`** — the annotated tag the paper's
  §6 provenance line names, and the commit it was made on (`de57bad`) is therefore fixed even as
  later commits move the branch tip. Its message records the expected figures.
- **This note's tag: `withe-artifact-eval-1`** — the same tree plus this note, the
  fixture matrix, the matrix generator and the prerequisite messages. Only docs and tooling
  differ; you can check that yourself:

  ```sh
  git diff --stat withe-paper-artifact-1 withe-artifact-eval-1
  ```

  The changes are `README.md`, this file, `tests/elm-fixtures/MATRIX.md` (new),
  `tools/gen-fixture-matrix.sh` (new), and the preflight/dump additions to
  `tests/elm-fixtures/run-elm-gate.sh`, `tools/withe-numbers.sh` and
  `tools/withe-recount-runTask.sh`. **No fixture, expected output or measured number changed:**
  the gate's output is byte-identical between the two tags (156 lines, `PASS=152 FAIL=0`), and
  `tools/gen-fixture-matrix.sh --check` confirms the registered checks and their expected values
  are unchanged. On `withe-paper-artifact-1` itself, run the command from §2 without checking out
  anything else: it prints the same numbers.
- **Split out of `fx-ui`.** This repository was created by importing the language tree from the
  fx-ui toolkit repository; the source commit is recorded in withe's first commit message
  (`Split from fx-ui at c022efa…`, with the intervening fx-ui commits listed in the paper's
  provenance paragraph).

## 8. How this artifact was made (AI use)

Per the ACM Policy on Authorship, AI assistance that *conducts the research* — implementing,
testing, validating, and archiving the artifacts the conclusions rest on — must be described
in detail; the paper states the same facts as §6.7 of `docs/research/withe-paper.md`.

- **What was AI-assisted.** The project's own code was written by AI coding agents (several
  underlying models, dispatched per work unit), working from the author's briefs and reviewed
  by the author: the compiler (`elm-compiler/`, including the eight core libraries), the host
  effect loop (`src/effectloop.zig`), the branch-local refinement extension
  (`elm-compiler/src/Type/`), the frontend lambda-lifting pass
  (`elm-compiler/src/Frontend/Lift.elm`), the Lean mechanization (`lean/`), the verification
  harness (`tools/withe-numbers.sh`, `tests/elm-fixtures/run-elm-gate.sh`,
  `tools/withe-corpus-baseline.sha256`, `tools/withe-recount-runTask.sh`), the adversarial
  test passes and their fixtures, and this note's own packaging (`ARTIFACT.md`,
  `tests/elm-fixtures/MATRIX.md`, `tools/gen-fixture-matrix.sh`).
- **The degree, as the record shows it.** Every commit in this repository is authored by the
  author, but the project's working records show the code was agent-written and the author
  committed the results; two early commits in the parent repository (`fx-ui`) carry the
  coding agents' sandbox identity. No per-line percentage is claimed. Parts of the artifact
  are ports of third-party code — the vendored elm-syntax parser, the zinc-vm (a Zig port of
  the Shen ZINC VM), the elm/core core libraries — where the assistance was in the porting.
- **The human role.** The author directed the work, made the design decisions, constructed
  the motivating example, and independently re-verified the numbers printed above. No AI
  system is an author — the ACM policy bars listing generative AI tools as authors under any
  conditions — and the author is accountable for the content regardless of its source.
- **Writing.** Drafting and review of the paper's prose were also AI-assisted; the policy
  does not require that disclosure, and it is stated here for completeness.
