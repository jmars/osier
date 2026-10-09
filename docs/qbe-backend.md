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
(fib.csexp sha256 == `tools/osier-corpus-baseline.sha256`).

## Coverage (and the loud failures)

Supported: `Lit` (all five, incl. non-ASCII strings — UTF-8 encoded), `Var`,
`App` with a GRef head (saturated direct call; under/over-application via
`rt_apply`, exactly the VM's partial semantics), `GRef` as value/force, `Let`
(plain binders + destructuring), `If`, 2-ary integer `PrimApp` (`+ - * < <= >
>= =` inline with VM-exact semantics transcribed from prims.zig; every other
prim and every non-fast path runs the REAL VM primitive via `rt_prim`), inner
`Lam` (closures with captures), `Case`/`Con`/match steps (MCons/MEmpty/MVector/
MTagEq/MLitEq), `LetDestruct`, `RecordLit`/`RecordGet`/`RecordUpdate`
(desugared to the VM's assoc-list prim sequence), `Tup` (right-nested cons
chain), `ListLit`, and `ShortAnd`/`ShortOr`/`NotEqual` (the VM's jmpf
semantics).  Aggregates reuse `rt_prim`'s cons/@p/emptylist/assoc/snd, so
their representation is the VM's by construction.

Still a LOUD compile error naming the construct: `StreamRef` (the effect loop)
and arity > 8 (rt_callN table).  Recursive let-functions are rejected by
FromAst itself.

## Crux 1 — tail calls: QBE has none; self-tail is a loop, cross-tail grows

EVIDENCE: `rg -n tail vendor/qbe/doc/il.txt` hits only line 944 ("width less
than a word") — there is NO tail-call instruction; the CALL BNF (il.txt:912)
has no tail form; jump targets are intra-function only.

- **Saturated self-call in tail position → an IN-FRAME LOOP** (args blitted
  into the param slots, `jmp @body`): REAL tail-call behaviour, constant
  native stack.  Proven by countdown 1000000 (12ms, no stack growth) and
  churn 500000 (an allocating self-tail loop at the 16MB heap).  This stays
  the hot path.
- **Every other tail position — cross-defun calls, `rt_apply`, thunk forces —
  returns a `.tail` and is bounced.**  Every generated function returns the
  80-byte `:ret` aggregate (`{ :val, w, l, l, l, w }` = `.done` value |
  `.tail` request), transcribed from the AOT's `Ret = .done | .tail`
  (tools/aot/runtime.zig).  `rt_bounce` chases a `.tail` chain at constant
  native stack; `rt_tail_known` / `rt_apply_tail` build the `.tail` (fresh
  self-contained env array, surviving the caller's `rt_frame_leave`).  The
  mutual-tail check (`qbe-check.sh`) now ASSERTS unboundedness: `Mutual.even
  1000000` completes, where the pre-bounce ceiling was 20k-40k hops (2
  native frames/hop, QBE prologues ~200B).

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

## Aggregate flattening — what it buys, and on what

`Mid/Qbe/Flatten.elm` rewrites, per defun, an aggregate (`Con`/`RecordLit`/`Tup`/`ListLit`) that is
consumed only locally — by a `Case` test, `RecordGet`, `LetDestruct` or `VField` — into its components
in pooled frame slots, so the heap object and its `rt_con`/`cons`/`@p`/`assoc`/`snd` sequence never
exist. It is **on by default**; `QBE_NOFLATTEN=1` disables it. It is a Mid→Mid rewrite, so it is
invisible to the ZINC path (the corpus stays byte-identical) and `Value` boxing stays uniform — only
the heap objects go — which is why it is far smaller than MLton's flatten: types are unreachable from
Mid, so nothing can decide to unbox.

**Measured on the compiler's own 58-source corpus, it buys nothing**: `rt_prim` sites 13,830 → 13,819
(−0.08%), the aggregate prims (`assoc` 1819, `snd` 1819, `@p` 1365, `emptylist` 1120, `rt_con` 197)
all unchanged, and wall clock 271.107 s → 270.725 s (−0.14%, noise).

**Why — measured, not inferred**: the corpus contains only **9** let-bound record *literals*. Its 667
record literals are returned, passed or stored, and all 459 `RecordUpdate` sites have *parameter*
bases. Records here flow **in as parameters and out as results**; they are never born and consumed
inside one defun.

**That is a statement about this corpus, not about the pass.** The compiler's own code is not a
representative workload: a program that writes `let r = { a = 1, b = 2 } in r.a + r.b` — the shape the
pass targets — is exactly what is absent here, so **nothing above measures the case the pass exists
for**. It is kept on that basis. Two known gaps are where that case most likely lands: nested
aggregates, and `RecordUpdate` on a flattened base.

Two things the pass did establish. It is the surface a **silent miscompile** came from and was caught
by: `decideMatch` returned a **decided** `False` for an **undecidable** tag test, and since `Tup
[Var a, Var b]` put `[]`/`::` on opaque components, `Type/Exhaustive.unifyList`'s whole body collapsed
to `Nothing` in the self-hosted compiler. Fixed by making undecidable deny by default, plus a
tuple-vs-list representation fix, and pinned by `tools/qbe/fixtures/flatnest.elm`, whose `zipPair` is
`unifyList`'s shape verbatim (6915 pre-fix, 4949 == `elmvm` after). And separately: `Mid.Ir.Con` is
**unreachable from Elm source today** — its only producer (`ctorDefun`) returns its own vector, so it
always escapes — meaning the `Con`/`rt_con` half is correct but cannot be exercised.

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

1. **~~The bounce loop + depth guard~~** — DONE: cross-defun tails now bounce
   (see Crux 1).  What remains is a **native-depth guard** for NON-tail deep
   recursion (the AOT's nat_depth cap, which falls back to the interpreter),
   still out of scope.
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
