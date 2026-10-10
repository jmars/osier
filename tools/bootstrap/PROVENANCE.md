# The bootstrap seed

`compiler.ssa` — the whole compiler, lowered to ONE QBE IL module — plus
`compiler.ssa.abi`, its ABI marker. Together with the vendored backend and a C
compiler they rebuild the compiler with **no node and no elm**:

```sh
tools/qbe-bootstrap.sh            # from a clean checkout
```

## What this file is, and what it is not

| | |
|---|---|
| size | 12,597,185 bytes (12.0 MiB) of PLAIN TEXT |
| sha256 | `dfa17db58432c1e67ff83df35da5089af0218713f005be4949f999ecf6231670` |
| provenance | MEASURED: emitted once by the stock (elm+node) compiler at HEAD `53f19b6`, from the 64-source manifest `elm-compiler/selfhost/manifest.json` (sha256 `7fc2bd69f9bcb382ffd0f436c3895d3798da369be2aea2a625da2a204d360564`), entry `NativeMain.main` |
| the exact emit | `tools/qbe-bootstrap.sh --freeze` (it is `node elm-compiler/run.js --batch <manifest with output=this file>`; `tools/qbe/qbe-selfhost.sh` step 1 is the same emit) |
| compiler.js mode | DEV — `elm make` **without** `--optimize`, the mode `tools/osier-numbers.sh` builds. NOT verified for an `--optimize` build; re-freezing under release mode could land different bytes |
| what it contains | the compiler's whole middle tier: parser, type checker, Mid, and the QBE backend itself (`Mid/Qbe/{Il,Lower,Peephole,Print}`, `Mid/QbeModule`) — 2,542 functions, 520,180 lines |

It is a **fixed point**: the compiler this file builds re-emits this file,
byte for byte.

```
MEASURED (this host, 2026-10-10, HEAD 53f19b6; shared host, so wall clock varies)
  emit (stock, node)          6.9 s   12,597,185 B  compiler.ssa   <- this file
  vendor/qbe/qbe compiler.ssa 18.5 s  40,288,789 B  compiler.s
  cc compiler.s rt.o           3.2 s  14,629,880 B  the native compiler
  that compiler --ssa (QBE_HEAP_MB=8192)
                             733.0 s  12,597,185 B  == this file, byte for byte
```

(The native re-emit's heap is the one knob with a real bill attached: at
`QBE_HEAP_MB=8192` the run peaked at **8.55 GiB RSS**; the GC was told to
reserve 128 GiB, was refused, mapped 64 GiB instead, and grew the heap to
whatever the live set needed. Too small a heap is a loud `heap exhausted`
panic, never a wrong answer.)

## Text, not compressed — deliberately

The whole value of this seed is that **two binaries the tree already vendors**
(`vendor/qbe/qbe`, built by `cc`+`make`; and `cc` itself) turn it into a
compiler. Compressing it would save ~11 MiB and put a decompressor — some third
tool, in *some* revision — between a clean checkout and a compiler. That is the
property, traded for a rounding error of disk. The file is committed as emitted.

The cost is real and is not hidden: **12.6 MB of text in git**, and it will
drift as sources change (see *Staleness* below).

## The ABI marker — the actual hazard this guards

`compiler.ssa` is not self-contained. It CALLS the runtime's exported symbols
(`rt_frame_enter`, `rt_apply`, `rt_string`, `rt_prim`, …), DECLARES its own
view of three aggregates

```
type :val  = align 8 { w, l, l, l, l }        (the runtime's Value, 40 B)
type :ret  = align 8 { :val, w, l, l, l, w }  (the runtime's Ret,   80 B)
type :desc = align 8 { l, w, w }              (the runtime's Desc,  16 B)
```

and DEFINES the arity table (`export function :ret $rt_call0..$rt_call16`) that
`rt.o` dispatches into through `Desc.code`. **Nothing in that pairing is checked
by QBE or by `cc`.** A `.ssa` and an `rt.o` built from different revisions of
the runtime link cleanly and then read each other's structs at the wrong
offsets — a silent wrong answer, this repo's stale-artifact class, and the
reason `tools/qbe/qbe-mk.sh` carries a freshness probe at all.

`tools/qbe/abi-fingerprint.sh` derives a marker from the *declarations* of that
interface (comments and whitespace stripped, so a comment edit does not move
it):

| component | source |
|---|---|
| `rt:exports` | every `export fn` signature in `tools/qbe/rt.zig`, sorted |
| `rt:callN` | every `extern fn rt_callN` signature in `tools/qbe/rt.zig`, sorted |
| `rt:types` | `max_arity`, `Desc`, `Meta`, `Ret` in `tools/qbe/rt.zig` |
| `gc:layout` | the `ValTag` enum and the `Value` struct in `vendor/osier-rt/src/gc/types.zig` |

`tools/qbe-bootstrap.sh` recomputes it before it builds anything and **refuses**
on a mismatch, naming the component that moved. To watch the guard fire, see
*Proving the guard fires* below.

**What the marker does NOT cover, and what covers it instead:**

- *The seed's own mirror of the layout.* If `Mid/Qbe/Il.elm` ever declares
  `:val`/`:ret`/`:desc` differently from the runtime, the marker does not move.
  This is the `Il`-revision half of the hazard, and it is caught by the seed
  *bytes*: the seed is pinned, the emit is not re-derived, and the fixed-point
  oracle (`--verify`, and `qbe-selfhost.sh` in the full form) compares a
  *current* compiler's emit against it.
- *Missing symbols.* The linker already refuses an undefined reference —
  including a `rt_callN` the seed fails to define, because `rt.zig` externs all
  of them. An explicit symbol cross-check would be redundant with `cc`, so
  instead `tools/qbe-bootstrap.sh` asserts the one thing a reader wants in one
  place: `nm` on the linked compiler shows exactly as many `rt_callN` symbols
  as `rt.zig` externs (17). A *truncated* arity table dies loudly at runtime
  through `rt_prim`/`callArity` ("arity exceeds the qbe rt_callN table"), not
  silently — but the count check makes it visible before the first run.
- *Prim name strings.* `rt_prim` takes a name string the seed embeds; those are
  checked only at runtime, where an unknown name dies loudly through
  `diePrim`. A silent mismatch is not reachable on this path.

### Proving the guard fires

```sh
# in a scratch COPY of the tree, perturb the runtime interface:
cp -r . /tmp/guardprobe && cd /tmp/guardprobe
sed -i 's/^const max_arity: i32 = 16;/const max_arity: i32 = 17;/' tools/qbe/rt.zig
tools/qbe-bootstrap.sh --check      # exit 1, naming rt:types
```

A guard that cannot be shown to fire is not delivered; this one is shown in the
task record.

## Staleness: REPORT-ONLY, never a gate

The seed is a *seed*, not a currency. It will drift: any change to a manifest
source, to the fixed corpus, or to `run.js` means the tree would no longer emit
these exact bytes. That is expected and acceptable — a stale seed still
bootstraps, and the compiler it builds compiles the **current** sources.

So staleness is reported and nothing more:

```
tools/qbe-bootstrap.sh --status          # FRESH | DRIFTED | ABI-STALE
```

and `tools/osier-numbers.sh` prints the same as its `seed status:` line
(step 2c, report-only, never a failure). **Do not turn this into a gate.** The
load-bearing correctness oracle is the `.ssa` fixed point plus the test suites;
a check that a legitimate source change breaks is a check that generates
re-freeze rituals, and this project has paid for those twice.

## Regeneration — one command, both halves together

```sh
tools/qbe-bootstrap.sh --freeze
```

It re-emits the seed from the **current** `elm-compiler/selfhost/manifest.json`
with the stock compiler (this is the only path in the bootstrap tooling that
runs node) and re-freezes the marker from the resulting bytes. The seed and its
marker must move together: a re-frozen marker with an old seed is exactly the
silent mismatch the marker exists to prevent.
