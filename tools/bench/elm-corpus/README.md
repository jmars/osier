# The Elm package corpus — real code to judge optimizations on

**What this is.** Every optimization verdict in this tree was, until now, judged on the compiler's
own 149-group corpus and a 12-program hand-built suite. `plan.md` §1.3 already said the first of those
*"generalises poorly to general code"* — and §6 has the instance where a corpus census nearly closed a
design question the wrong way. This directory is the instrument that replaces it: **the whole published
Elm package registry** as source.

**Provenance and reproduction.** `tools/bench/fetch-elm-corpus.sh` reads
`https://package.elm-lang.org/all-packages` (the same registry the elm compiler uses) and fetches each
package's **latest** version from GitHub, keeping only `src/**/*.elm` plus the licence.
**The sources are NOT committed** — third-party code is not vendored; the script and `MANIFEST.tsv`
are the committed record and the corpus is reproducible from them. `MANIFEST.tsv` is
`package · version · status · slug · files · loc · kernel_files · src_sha`.

```
tools/bench/fetch-elm-corpus.sh              # the whole registry (~3.5 min at --jobs 10, ~150 MB)
tools/bench/fetch-elm-corpus.sh --limit 50   # a quick subset
```

**MEASURED 2026-10-12** (the fetch the corpus exists for): **3029 packages — 2765 fetched, 151
unresolved (repo renamed/deleted), 102 without `src/` — 17,359 `.elm` files, 6,109,175 lines,
150 MB.** Only **57 files import `Elm.Kernel`**, i.e. the kernel restriction people expect from
`elm/*` core packages is a rounding error across the ecosystem — the corpus is overwhelmingly pure Elm.

**THE FINDING IT ALREADY PRODUCED.** On the question *"how often does a prim operand need an
**expression** type rather than a **binder** type?"* (the Gap B / Gap E split in
`handoff-osier-typespec-plan`):

| sample | operator sites | operand is an application (⇒ needs an expression type) |
|---|---|---|
| the 12-program suite | ~500 | **5** |
| real published Elm (400-file random sample, comments stripped) | 4,957 | **2,457 = 50%** |

So the ratio drawn from the suite understates real code by two orders of magnitude, in the direction
that matters. **Do not close a design question on the compiler's own corpus or on the hand-built suite.**

**Honest limits — these bound what the corpus can prove.**
* A package is a **library, not a program**: this is a source corpus for static shape censuses and for
  building runnable benchmarks **on top of**, not a suite with expected outputs.
* **~8% of the registry does not resolve** (`owner/name` is *usually* but not always `github.com/owner/name`);
  misses are recorded in the manifest, never hidden.
* **Generated files contaminate naive censuses** — e.g. `icidasset/elm-material-icons` (205,977 lines) and
  `agj/elm-simple-icons` are generated data modules. Exclude them (`MANIFEST.tsv` orders by `loc`) or the
  numbers will reflect a code generator, not a programmer.
* A **syntactic** census (such as the one above) is a proxy with residual false positives — it counts
  operator *sites* in source, not lowering opportunities. The authoritative instrument remains the
  compiler's own emit (`nodeTypeMap` coverage over a compiled subset); the corpus is what you point
  **that** at.
