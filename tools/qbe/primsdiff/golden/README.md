# primsdiff reference goldens

Reference-arm outputs for the prims behaviours that **no surface Elm spelling can
reach**, captured BEFORE the flip (`handoff-osier-midrt-fix`, capture item 3).
After the flip the Zig bodies in `vendor/osier-rt/src/rt/prims.zig` are deleted —
they are the differential's reference arm — so these files are the only remaining
record of what the reference answered.

## What is here, and why it is not a differential batch

`symbol-eq.spec` drives the `=` prim with **symbol** operands:

| vector | reference answer | which arm of `primEq`/`deepEq` |
| --- | --- | --- |
| `y:w` vs `y:w` | true | sym/sym, equal name — `symEq`'s byte walk |
| `y:w` vs `y:z` | false | sym/sym, unequal name |
| `y:` vs `y:` | true | sym/sym, both empty |
| `y:hello` vs `y:hello` | true | sym/sym, multi-byte |
| `y:hello` vs `y:hellp` | false | sym/sym, same length, last byte differs |
| `y:w` vs `s:w` | false | sym vs string (tag mismatch) |
| `y:w` vs `n:5` | false | sym vs number |
| `n:5` vs `y:w` | false | number vs sym (the swapped order) |
| `y:w` vs `f:1.5` | false | sym vs float |
| `y:w` vs `l(n:1,n:2)` | false | sym vs list — the value arm, not a name comparison |

Surface Elm has **no symbol literal**, so the Mid arm cannot be driven with these
vectors and they cannot be a `primsdiff.sh` batch. They are captured as goldens
(and the `y:` spec kind exists in the harness for exactly this).

## Status of the same semantics through a path that IS executed

The `=` symbol arms are not untested in the sense of "never run": `assoc` and
`assocGo` compare **field-name symbols** through the same `deepEq`/`symEq`
machinery, and the differential's `assoc-int` / `assoc-str` / `assoc-pat`
batches genuinely execute them — MEASURED: removing only `Rt.assocGo`'s key
comparison moves the first divergence to vector index 1 (a `.g` deferred read)
and leaves vector 0 (a `.f` head read) byte-identical. So `symEq`'s walk is
pinned by an executed differential path; what these goldens add is the DIRECT
`=` entry with symbol operands, including the sym/prim arms that `assoc` never
reaches.

## Verify (pre-flip only)

    tools/qbe/primsdiff/primsdiff.sh --golden

runs the reference arm on every `*.spec` here and diffs against the committed
`*.out`; `--golden=freeze` re-captures. After the flip the reference arm no
longer exists, so the mode will fail to build it — that is expected; the `.out`
files then stand as the frozen record (they are read by humans and by any
future Mid-side check written against them).

## POST-FLIP (handoff osier-flip): `batches/` is the batch reference

`batches/` holds the FROZEN reference outputs of the 46 differential batches
(2 modes each: `default` + `heap16-rerun`), captured at git `8f581b8` with the
Zig handlers still present (`--freeze-batch-ref`; `MANIFEST.txt` records the
tree, n, seed and the op list).  After the flip deleted the handlers, the
default mode of `primsdiff.sh` runs ONLY the Mid arm and compares against
these bytes; the `.gcstats` files carry the reference arm's collection
counters at freeze time (frozen evidence, printed by the churn PASS lines,
not re-measured).

Nothing on the post-flip tree can re-derive either directory: `--golden` is
retired (exit 2) and `--freeze-batch-ref` dies loudly on the deleted names.
What these files still falsify: any future change to the Mid implementations.
What they can no longer falsify: a live Zig-vs-Mid divergence.
