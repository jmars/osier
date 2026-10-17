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
| size | 20511095 bytes (19.6 MiB) of PLAIN TEXT |
| sha256 | `edc1ff885e038b8556da6655dcbba9a7f9c5967412aa23af00f949701b2f0bd5` |
| runtime.mid | the seed now READS the runtime surface text at run time instead of baking it: `elm-compiler/runtime.mid`, sha256 `31fe648b40da32d1251a773c4723d0898f30162c07c05d23d380377eaa285dda` (the moved home of `Mid/RtSource.elm`'s `source` blob, byte-identical after the `//` header comment). A seed-built compiler EMITS depending on this file — the fixed point now spans **seed + runtime.mid + rt.o** |
| provenance | MEASURED: emitted once by the stock (elm+node) compiler, from the selfhost manifest `elm-compiler/selfhost/manifest.json` (sha256 `50168c9ca87cd056ad6d8cb1d1fddf03645d72ccac7940f2fcc218afa5362540`), entry `NativeMain.main`. RE-FROZEN at stage-6 A5 (the driver flip: `QBE_MIDDRIVER` default ON), then at M1 (the runtime-surface move: `Mid/RtSource.elm` deleted, the text lives in `elm-compiler/runtime.mid` and is read by both drivers), then at stage-6 B0 (the frame machinery retarget), then at stage-6 B1 (the apply-family retarget: `Rt.frame-enter`/`Rt.frame-leave` as Mid rawAbi defuns, the prologue/return retarget behind `QBE_MIDDRIVER` — 125/159 corpus artifacts and the selfhost emit moved), then at stage-6 B0perf (the frame-zero slot loop: `Rt.frameZero` zeroes a full 40-byte slot per iteration with a header-held raw counter — the 175x fix), then at stage-6 B0perf-2 (the frame-zero WORD loop: `Rt.frameZero` is now a rawAbi `word -> word` defun whose `recur` is an in-frame word self-tail — no `:val` on the path, the 3.4x->~1.6x close; `lowerTailWord` gains the word-If join and word self-tail arms), then at stage-6 B1fix (the copyWords WORD loop: `Rt.copyWords`/`Rt.copyWordsGo` are rawAbi word defuns — no `:val` on the copy path — plus the rtApply ret-class DERIVATION from `rawAbiRetClass` and the `.tail` no-collect invariant comments) — see below |
| the exact emit | `tools/qbe-bootstrap.sh --freeze` (it is `node elm-compiler/run.js --batch <manifest with output=this file>`; `tools/qbe/qbe-selfhost.sh` step 1 is the same emit) |
| compiler.js mode | DEV — `elm make` **without** `--optimize`, the mode `tools/osier-numbers.sh` builds. NOT verified for an `--optimize` build; re-freezing under release mode could land different bytes |
| what it contains | the compiler's whole middle tier: parser, type checker, Mid, and the QBE backend itself (`Mid/Qbe/{Il,Lower,Peephole,Print}`, `Mid/QbeModule`) — 4,007 functions, 829,121 lines |

It is a **fixed point**: the compiler this file builds (given
`elm-compiler/runtime.mid`, the `rt.o` it links) re-emits this file, byte for
byte.

```
MEASURED (shared host, so wall clock varies).  ONLY the first row was re-measured
at the B1fix re-freeze (HEAD `08d48f8` + the uncommitted B1fix work — stage-6
B1fix, the copyWords word loop + ret-class derivation); the
three native rows are the 2026-10-10 measurement at HEAD `53f19b6` and have NOT
been re-run (`--verify` is a ~742 s native emit, deliberately kept out of the
loop), so their sizes are that HEAD's, not today's.
  emit (stock, node)          13.9 s  20,511,095 B  compiler.ssa   <- this file
  vendor/qbe/qbe compiler.ssa 18.5 s  40,288,789 B  compiler.s            [53f19b6]
  cc compiler.s rt.o           3.2 s  14,629,880 B  the native compiler   [53f19b6]
  that compiler --ssa (QBE_HEAP_MB=8192)
                             733.0 s  12,597,185 B  == this file, byte for byte  [53f19b6]
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
type :desc = align 8 { l, w, w }              (the Desc PREFIX, 16 B; the
                                              descriptor OBJECT is 24 B — the
                                              emitted data carries one more
                                              word, the global-closure cache)
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
| `gc:layout` | the LAYOUT CENSUS: the digest of `elm-compiler/src/Mid/RtLayout.elm`, the single definition of every cross-ABI number (`tools/qbe/layout-census.sh --marker`). `types.zig` and `rt.zig` are checked *against* it — see below |

`tools/qbe-bootstrap.sh` recomputes it before it builds anything and **refuses**
on a mismatch, naming the component that moved. To watch the guard fire, see
*Proving the guard fires* below.

**What the marker does NOT cover, and what covers it instead:**

- ~~*The seed's own mirror of the layout.*~~ **CLOSED by the layout census
  (handoff-osier-zigretire-plan STAGE 2).** The emitted `:val`/`:ret`/`:desc`
  are no longer a mirror: `Mid.Qbe.Il` DERIVES them from `Mid.RtLayout`, which
  is also what `gc:layout` digests, so an `Il` that disagreed with the runtime
  would disagree with `RtLayout` and the marker would move. The remaining
  half — the seed *bytes* being a fixed point — is still the `--verify` /
  `qbe-selfhost.sh` oracle.
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
tools/qbe-bootstrap.sh --status          # FRESH | STALE (exact emit+cmp) | ABI-STALE
```

and `tools/osier-numbers.sh` prints the same as its `seed status:` line
(step 2c, report-only, never a failure). **Do not turn this into a gate.** The
load-bearing correctness oracle is the `.ssa` fixed point plus the test suites;
a check that a legitimate source change breaks is a check that generates
re-freeze rituals, and this project has paid for those twice.

Since 2026-10-12 the `STALE` verdict is the **exact check**: `--status` emits
the current manifest (the same work `--freeze` does minus the write) and
`cmp`s the result against the committed seed.  The previous status hashed the
manifest INPUTS — a proxy that reported FRESH for four units while the emit
had been impossible since stage 4 (a missing manifest source made `--freeze`
die with `unknown name: gcProgram`).  Hashing inputs cannot see an emit that
fails or produces different bytes; only running the emit can.  The cheap ABI
marker (`abi-fingerprint.sh --status`) is kept as a second, cheaper signal —
it is not wrong, it is just insufficient.

## Regeneration — one command, both halves together

```sh
tools/qbe-bootstrap.sh --freeze
```

It re-emits the seed from the **current** `elm-compiler/selfhost/manifest.json`
with the stock compiler (this is the only path in the bootstrap tooling that
runs node) and re-freezes the marker from the resulting bytes. The seed and its
marker must move together: a re-frozen marker with an old seed is exactly the
silent mismatch the marker exists to prevent.
