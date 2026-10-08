# QBE native backend — stage 1 slice (design, evidence, open questions)

STAGE 1 VERTICAL SLICE, committed as the proof that the pipeline works and
both design cruxes are solvable.  NOT full coverage — the point was the
pipeline, the cruxes, and honest numbers, not a backend.

```
elm source ─► Mid.Ir (FromAst, NO mid-tier passes) ─► Mid.Qbe.Lower
            ─► QBE IL as an ELM DATATYPE (Mid.Qbe.Il)
            ─► Mid.Qbe.Peephole (blit forwarding, jump-to-next, dead defs)
            ─► Mid.Qbe.Print ─► .ssa text
            ─► vendor/qbe/qbe (.ssa -> .s, UNMODIFIED) ─► cc with tools/qbe/rt.o
```

One IR, a trivially-testable printer, no QBE modification, no SSA layer of
our own (QBE builds SSA itself: `vendor/qbe/doc/il.txt:1020`; the emitted IL
is deliberately non-SSA and exercised on branch joins, loops and nesting).

## Commands (the whole proof; read exit codes directly)

```
tools/qbe/qbe-check.sh        # 22/22 PASS, exit 0
tools/qbe/qbe-mk.sh tests/elm-fixtures/fib.elm Fib.fib /tmp/out  # -> /tmp/out/fib
```

`qbe-check.sh` compiles every slice fixture BOTH ways from the same source,
runs the SAME entry+args on `zig-out/bin/elmvm` and on the native binary, and
requires IDENTICAL stdout; then reruns the native binary at the 16MB minimum
heap (`QBE_HEAP_MB=16`; `MIN_HEAP_BYTES`, heap.zig:61) so the moving
collector runs constantly — the behavioural proof that the pooled-frame roots
actually root.  Fixtures: fib 10/20, countdown 100000, applytwice, closure,
const42, idn, ifx, churn 150000 (13MB live, constant scavenges), churn
500000, mutualtail 20000.  The MIDTIER=0 byte-identity anchor still holds
(fib.csexp sha256 == `tools/withe-corpus-baseline.sha256`).

## Coverage (and the loud failures)

Supported: `Lit` (all five), `Var`, `App` with a GRef head (saturated direct
call; under/over-application via `rt_apply`, exactly the VM's partial
semantics), `GRef` as value/force, `Let` (plain binders), `If`, 2-ary integer
`PrimApp` (`+ - * < <= > >= =` inline with VM-exact semantics transcribed
from prims.zig; every other prim and every non-fast path runs the REAL VM
primitive via `rt_prim`), and inner `Lam` (closures with captures).

Everything else is a LOUD compile error naming the construct: Case,
LetDestruct, Con, Tup, RecordLit/Get/Update, ListLit, StreamRef, ShortAnd/
ShortOr/NotEqual, non-ASCII literals, arity > 8 (rt_callN table), recursive
let-functions (FromAst itself rejects those).  `Mid/Ir.elm`'s `Case` with
match steps was NOT reached — no slice fixture needs it.

## Crux 1 — tail calls: QBE has none; self-tail is a loop, cross-tail grows

EVIDENCE: `rg -n tail vendor/qbe/doc/il.txt` hits only line 944 ("width less
than a word") — there is NO tail-call instruction; the CALL BNF (il.txt:912)
has no tail form; jump targets are intra-function only.

- **Saturated self-call in tail position → an IN-FRAME LOOP** (args blitted
  into the param slots, `jmp @body`): REAL tail-call behaviour, constant
  native stack.  Proven by countdown 1000000 (12ms, no stack growth) and
  churn 500000 (an allocating self-tail loop at the 16MB heap).
- **Every other tail position — cross-defun calls, `rt_apply`, thunk forces —
  is a PLAIN CALL and grows the native stack.**  MEASURED: `Mutual.even`
  (mutual tail recursion) survives between 20k and 40k hops on this host's
  8MB stack (2 native frames/hop, QBE prologues ~200B) then SIGSEGVs; the VM
  runs 1e6+ hops fine (`appterm` = constant stack).  The AOT's fix (bounce
  loop returning a `.tail` request + a native-depth guard,
  tools/aot/runtime.zig) is the known design for the next stage; it maps
  cleanly onto this backend (rt_apply's saturation path is the natural
  bounce point), but it was out of slice scope.

## Crux 2 — GC rooting: pooled runtime frames, with both proofs

The brief's measured constraint reproduces on the vendored qbe: a
NON-ESCAPING stack slot's store+reload are DELETED (the value is promoted to
a callee-saved register across `callq` — silently stale under a moving GC).

Design: every generated function starts with `rt_frame_enter(nslots) ->
*Value`, a frame block from a size-classed free list (malloc-backed, never
in the GC heap, address stable), registered as ONE `ROOT_VALUE_ARRAY` for
the whole body; `rt_frame_leave()` pops it.  The frame ADDRESS is an opaque
call result, so QBE cannot promote slot accesses.  Slots: 0 result, 1..N
params, N+1..N+K captures, then temps + contiguous call-arg staging.

POSITIVE PROOF (fib.s, current emitted code): the `+` operands of
`fib (n-1) + fib (n-2)` are RELOADED from the rooted frame after the last
safepoint — `movq 288(%rbx), %rax` and `movq 328(%rbx), %rcx` feed `addq`,
where `%rbx` is the pooled-frame pointer; the stores into `280..352(%rbx)`
sit immediately after each `callq q_Fib`.  A GC during the second call
rewrites those slots (they are inside the ROOT_VALUE_ARRAY range) and the
reload sees the moved address.  `qbe-check.sh` also counts the frame-pointer
memory ops (136 around fib's two recursive callq) as a regression gate, and
the 16MB-heap churn runs are the behavioural proof (a promotion bug =
silently wrong output, and the churn fixtures would catch it — one did:
see bug 3 below).

Why POOLED and not per-function globals: a global frame cannot nest under
recursion (a callee would zero its caller's frame).  Why zeroed at enter: a
reused block's stale slots can point into freed pages, which scanValue would
chase.

## Wall clock (first honest runtime numbers; read with care)

| fixture      | VM (elmvm) | native | ratio |
|--------------|-----------:|-------:|------:|
| fib 30       | ~590-640 ms | ~230-256 ms | ~2.5x |
| countdown 1e6 | 239 ms   | 12 ms  | ~20x  |
| churn 500k    | 267 ms   | 88 ms  | ~3x   |

Single runs, this host, wall-clock including process+heap startup (~5-8ms of
the native column; fib's spread is that noise).  WHAT IT MEANS: the native
path is real and the direction is right — but this is the UNOPTIMIZED slice:
every local lives in a pooled frame slot with 40-byte blit hops, every call
copies args through frame staging, frames are zeroed at enter, and every
Value stays boxed exactly as in the VM.  The AOT path (which unboxes frames
and elides rooting for non-allocating bodies) reaches 3.3-3.5x on the same
class of fixtures; matching that is later-stage work, and the instruction-
count metric remains a poor proxy either way (docs/aot-spike.md's lesson).

## Three bugs the slice caught (all fixed; the design paid for itself)

1. **`:val` params arrive BY VALUE ON THE STACK.**  QBE's aggregate ABI
   pushed the 40 bytes at the call site; a Zig caller passing `*Value` in a
   register mismatches and the callee reads garbage.  `rt_callN` therefore
   takes plain `l` pointer params and forwards them as `:val` CALL args
   (QBE copies at the call — symmetric with generated code, which always
   passes pointers).
2. **`alloc8 N` is a DYNAMIC `subq $N,%rsp`.**  A staging alloc inside a
   loop body leaks N bytes of stack PER ITERATION (churn crashed at ~110k
   conses with a corrupted-looking heap — it was the guard page).  Staging
   now lives in contiguous pooled-frame slots: no stack growth, and the
   staged copies are rooted as a side effect.
3. **`rt_prim` read unrooted staging args after allocating.**  `vaInit`/
   `vaPush` can collect; the staging block (caller stack) went stale.
   Caught by the churn fixture at the 16MB heap.  rt_prim now copies its
   args into rooted storage before the first allocation.

## Files

- `elm-compiler/src/Mid/Qbe/Il.elm` — the QBE IL subset as Elm data
- `elm-compiler/src/Mid/Qbe/Lower.elm` — the lowering (all contracts in the
  header: ABI, rooting, closures, tails)
- `elm-compiler/src/Mid/Qbe/Print.elm` — the only text surface
- `elm-compiler/src/Mid/Qbe/Peephole.elm` — barrier-delimited blit
  forwarding, jump-to-next removal, dead pure defs
- `elm-compiler/src/Mid/QbeModule.elm` — driver (Mid.Module's orchestration
  reused via additive `exposing`; NO mid-tier passes on this path)
- `elm-compiler/src/Main.elm` + `run.js` — `QBE=1 QBE_ENTRY=<key>` switches
  the group output to .ssa text (ZINC paths byte-identical, anchor verified)
- `tools/qbe/rt.zig` — the runtime (rt.o built on demand by qbe-mk.sh)
- `tools/qbe/qbe-mk.sh`, `tools/qbe/qbe-check.sh` — build + verification
- `tools/qbe/fixtures/` — const42, idn, ifx, churn, mutualtail

## What the next stage must settle

1. **The bounce loop + depth guard** for cross-defun tails (the 20-40k hop
   ceiling is the slice's hardest limitation).  The AOT's Ret/.tail design
   maps onto rt_apply's saturation path.
2. **Case/pattern matching** (the biggest coverage gap; `Mid.Ir.Case` with
   MEmpty/MVector/MTagEq/MLitEq was never reached).  Records/tuples/lists
   follow (Con/ListLit are straightforward vector/cons work on this runtime).
3. **Calling-convention cost**: 40-byte blit hops per Value move, by-value
   aggregate args, frame zeroing.  Candidates: register-passed unboxed
   values at known-arity direct calls, live-range-aware `live` counts, the
   AOT's rooting elision for non-allocating bodies.
4. **Float args** in the driver (int-only by design here), non-ASCII
   literals (Elm 0.19 has no byte API — needs an honest length source).
5. **Whether the mid-tier passes help or hurt this backend** — they were
   tuned to the ZINC cost model and are deliberately OFF on this path; the
   arity/saturation repairs the reviewer flagged are exactly what a native
   path wants.
