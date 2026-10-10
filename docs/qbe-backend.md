# QBE native backend — stage 1 slice (design, evidence, open questions)

> **STATUS AFTER P8 (handoff `osier-delete-zinc`, 2026-10-10).** This document
> is a **development log**: it records the backend's state at each stage, and
> most of the file/flag names in it (CSEXP, `MIDTIER`, `vendor/zinc-vm`,
> `elmvm`, `tools/aot`, `tools/elmc.sh`) name things that were deleted when the
> ZINC interpreter went. The stages are kept verbatim because the measurements
> are evidence. Two anchors moved **after** the last stage recorded here, so
> read the stage text with these corrections:
> - the corpus byte anchor is now `tools/osier-corpus-baseline.ssa.sha256`
>   (`tools/osier-corpus-ssa.sh`), not the retired csexp
>   `tools/osier-corpus-baseline.sha256`;
> - `qbe-check.sh` is no longer a VM/native **differential** — it compares the
>   native run against committed goldens (`tools/qbe/golden/`); `PASS=221`, not
>   the 153 quoted in stage 1;
> - the interpreter, all mid-tier passes, `vendor/zinc-vm` and the csexp
>   emitter are gone, so `MIDTIER=*` and `.csexp` invocations below cannot run.

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
tools/qbe/qbe-check.sh        # 221 PASS / 0 FAIL, exit 0
tools/qbe/qbe-mk.sh tests/elm-fixtures/fib.elm Fib.fib /tmp/out  # -> /tmp/out/fib
tools/qbe/qbe-selfhost.sh     # the .ssa FIXED POINT
```

`qbe-check.sh` compiles every slice fixture from the same source, runs the
SAME entry+args on the native binary, and requires stdout IDENTICAL to that
check's **committed golden** (`tools/qbe/golden/`, 104 files — frozen at P8
from the last agreeing run of the retired VM/native differential, see the
status note above); then reruns the native binary at the 16MB minimum
heap (`QBE_HEAP_MB=16`; `MIN_HEAP_BYTES`, heap.zig:61) so the moving
collector runs constantly — the behavioural proof that the pooled-frame roots
actually root.  Fixtures: fib 10/20, countdown 100000, applytwice, closure,
const42, idn, ifx, churn 150000 (13MB live, constant scavenges), churn
500000, mutualtail 20000, and the float matrix
(`tools/qbe/fixtures/float.elm` — 27 matrix entries plus `float-main` and
4 float/int entry-arg runs = 32 builds, each also at the 16MB
heap: literals, the inline fast-path ops and the ops that must decline to
`rt_prim`, non-finite spellings, and float/int entry args through
`rt.zig:isFloatArg`).  The MIDTIER=0 byte-identity anchor that used to be
quoted here (fib.csexp sha256 vs `tools/osier-corpus-baseline.sha256`) is
**gone** with the CSEXP backend and that manifest; its successor is the `.ssa`
anchor `tools/osier-corpus-baseline.ssa.sha256`, checked by
`tools/osier-numbers.sh` step 2.

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
- `tools/qbe/fixtures/` — const42, idn, ifx, churn, mutualtail, float (the
  Float differential matrix, the fix for the old "floats cannot reach this
  backend" gap; extended with the S4f hostile cases), norep (the unboxed-
  Int-AND-Float-locals differential, items 6 and 7)

## What the next stage must settle

1. **~~The bounce loop + depth guard~~** — DONE: cross-defun tails now bounce
   (see Crux 1), and NON-tail deep recursion fails LOUD at the real C-stack
   boundary — see "The native stack-depth guard" at the foot of this file
   (handoff osier-natdepth).  Unlike the AOT's nat_depth cap there is no
   interpreter to fall back to, so the guard names the failure instead of
   capping it.
2. **Case/pattern matching** (the biggest coverage gap; `Mid.Ir.Case` with
   MEmpty/MVector/MTagEq/MLitEq was never reached).  Records/tuples/lists
   follow (Con/ListLit are straightforward vector/cons work on this runtime).
3. **Calling-convention cost**: 40-byte blit hops per Value move, by-value
   aggregate args, frame zeroing.  Candidates: register-passed unboxed
   values at known-arity direct calls, live-range-aware `live` counts, the
   AOT's rooting elision for non-allocating bodies.  **PARTLY DONE — see
   items 6 and 7**: Int LOCALS *and* Float LOCALS now skip the frame slot
   (item 7 is the Float half, and it also deletes the `rt_prim` call that
   every float op used to make).  The "register-passed unboxed values at
   known-arity direct calls" candidate is the *parameter* half; for Int it is
   still open because it IS the ABI change, and for Float it is BLOCKED on a
   measured semantic ground — see item 7 (b).
4. **~~Float args~~** — CLOSED: float entry args and Float values end to end
   now work on this backend (was "int-only by design here";
   `tools/qbe/fixtures/float.elm` is the differential matrix, `rt.zig` takes
   float args, and the suite's `mono_float` measures on both backends).
   Still open from this item: non-ASCII literals (Elm 0.19 has no byte
   API — needs an honest length source).
5. **Whether the mid-tier passes help or hurt this backend** — they were
   tuned to the ZINC cost model and are deliberately OFF on this path; the
   arity/saturation repairs the reviewer flagged are exactly what a native
   path wants.
6. **Unboxed Int locals (monomorphisation step S4/M1)** — LANDED.  Inside a
   defun the checker typed as a CLOSED MONOTYPE, an Int local is held in a raw
   `l` QBE operand instead of a 40-byte frame slot, and `+ - *` /
   `< <= > >=` / `=` on operands PROVEN Int emit the native i64 op with no tag
   test and no `rt_prim` fallback.  Switch `QBE_NOREP=1` (default ON, mirroring
   `QBE_NOFLATTEN`); differential `tools/qbe/fixtures/norep.elm`; the gate grew
   153 -> 179 PASS / 0 FAIL.

   MEASURED, structural (the .ssa's own counters, pass ON vs OFF —
   `NoRep.slotCount` is 16 chained Int locals plus one Int parameter):
   frame slots 83 -> 3 and `rt_prim` sites 16 -> 0; `NoRep.chain` 32 -> 3 and
   6 -> 0; `NoRep.boxed` 24 -> 12 and 15 -> 8.  MEASURED, byte-level: built the
   PRE-PASS compiler (the working tree with only this step's hunks reversed)
   and dumped all 83 (fixture, entry, flags) pairs `qbe-check.sh` drives from
   both — with `QBE_NOREP=1` the two are BYTE-IDENTICAL on all 83, and with
   the pass on 25 differ.

   MEASURED, wall clock, `tools/osier-bench.sh` at `OSIER_BENCH_RUNS=5`
   median-of-5, 10 repetitions per arm with the ARM ORDER ALTERNATED (the
   first five ran ON-then-OFF, the next five OFF-then-ON — an arm always
   measured second is systematically penalised, and the VM column is the
   control that exposes it).  QBE ms, median of the ten; the two right-hand
   columns are the `.ssa` counters from the SAME source, summed over every
   function in the build:

     program       qbe ON   qbe OFF   wall    frame slots   rt_prim sites
     numloop           19        51   -62%      47 -> 17        7 -> 0
     localrec          12        29   -59%      29 -> 13        4 -> 0
     deepnontail       74       109   -32%      42 -> 26        6 -> 2
     mono_float       121       140   -14%     206 -> 190      33 -> 29
     mono_int         102       117   -13%     150 -> 142      25 -> 23
     listbuild         57        61    -7%      71 -> 55        8 -> 4
     adtmatch         149       157    -5%     148 -> 140      11 -> 9
     nestagg          252       260    -3%     117 -> 109      17 -> 15
     recupd_local     500       514    -3%     102 -> 94       23 -> 21
     mono_record      339       346    -2%     213 -> 197      41 -> 37
     recupd_param     406       414    -2%      92 -> 84       21 -> 19
     recflow          383       379    +1%      92 -> 92       23 -> 23  <- UNREACHED
     TOTAL           2417      2580    -6%

   THE MECHANISM CONFIRMS, which is what the two counter columns are for: the
   programs that move are the ones whose counters move (the `rt_prim`-site
   count removed tracks the wall delta's ordering exactly), and `recflow` is
   the internal control — the pass does not reach it at all, its counters are
   IDENTICAL, and its clock reads +1% with the VM column at +1.3%.  So the
   -32..-62% band is attributable while the -2..-5% band sits inside the
   instrument's spread and is reported as a NULL, not as a win: `mono_int`,
   `mono_float` and `mono_record` weight a POLYMORPHIC `fold` body, so only
   their monomorphic call sites benefit — reaching those bodies is S5's job,
   not this step's, and a null result here is what the plan predicted rather
   than a number reached for.  `numloop` is the predicted mover and it moved:
   its loop body is `let k = inv * 3 + 7; j = k * k + inv in ...` under an
   all-Int monotype signature, so both locals and all three arith sites leave
   the frame on every iteration.

   HONEST LIMITS, named rather than papered over:
   (a) **Int only** — SUPERSEDED BY ITEM 7 (S4f landed the Float half; the
       claim below was true of THIS step and is kept, not rewritten, because
       it is the record of what was measured then).  Float locals were DENIED
       by construction: every float arithmetic route goes through `rt_prim`,
       so a raw `d` temp would be reboxed into a staging slot at each use and
       buy nothing.  Native float arithmetic needs `addd`/`subd`/`muld` and
       float compares in `Mid/Qbe/Il.elm`/`Print.elm`, which this step did not
       own.  `NoRep.floatLocal`'s `.ssa` was byte-identical ON/OFF — that
       identity was the control that the pass did not overreach.  ITEM 7
       REVERSED THAT EXPECTATION DELIBERATELY: `NoRep.floatLocal` now DIFFERS
       ON/OFF (the flip is the S4f entry test) and the byte-identical control
       moved to `NoRep.floatParam`.
   (b) **Where the type comes from.**  The plan's seat was the per-BINDER half
       of `Mid/Qbe/Types`.  That half does not exist and cannot at S1:
       `Type.Infer` exposes only `inferUnit`/`CheckedUnit`, and
       `CheckedUnit.file` is the UNTYPED elm-syntax `File.File`, so per-binder
       types live only in an `InferState` nothing exposes (that is the plan's
       S2 accumulator plus the S3 seed re-freeze).  This step therefore reads
       the half the table HAS — the defun's closed monotype — peeled in
       parameter order for PARAMETER types, plus a deny-by-default proof over
       the Mid tree for `let` binders.  The second half is not a guess about
       the checker: the VM has one integer tag and a separate float tag, so
       "this operand is an Int" is decidable from the IR, and it holds inside a
       POLYMORPHIC defun too (measured: `NoRep.polyLocal`'s `rt_prim` 3 -> 1 —
       the monotype gate alone would have missed it).
   (c) **The trust boundary this introduces**: the tag test it deletes WAS a
       runtime check, and the static claim that replaces it is only as strong
       as the checker's word.  Across units that word is the rigid signature;
       the exposure is a caller in the SAME group whose re-inference failed
       (`Qbe.Types.Table.notes` records the group failure but not which defun).
       S5's refusal predicate is where the sharper handling belongs.
   (d) **What it does not buy**: parameters stay boxed (no ABI change, by
       design), so the win is the locals and the tag tests, not the call
       boundary.  Under a uniform 40-byte Value representation is the payoff
       and specialisation is what extends it past monomorphic bodies.

7. **Unboxed Float locals (S4f, the Float half of S4/M1)** — LANDED.  A Float
   local whose Float-ness is PROVEN is held in a raw `d` QBE operand with no
   frame slot, `+ - *` and `f/` on two such operands emit the native f64 op
   (`%r =d add`/`sub`/`mul`/`div`), `< <= > >= ==` on two such operands emit
   one `cltd`/`cled`/`cgtd`/`cged`/`ceqd`, and every one of those sites loses
   both the tag test and the `rt_prim` CALL.  Switch: the SAME `QBE_NOREP=1`
   (both predicates read `s.rep`; there is no second switch).  Gate grew
   179 -> 213 PASS / 0 FAIL; differential `tools/qbe/fixtures/norep.elm`
   (`floatLocal`/`floatParam`/`floatCapture`) plus 13 new hostile entries in
   `tools/qbe/fixtures/float.elm`.

   WHAT THE IL NEEDED, MEASURED RATHER THAN ASSUMED: `Bin dst D Add` ALREADY
   prints `%r =d add` — QBE's `addd` with the type letter supplied by the
   assignment — so no `Addd`/`Subd`/`Muld` variant was added (verified by
   compiling the emitted IL through `vendor/qbe/qbe`).  The float arithmetic
   was NOT the gap.  The gaps were (i) `div` (`f/` is Elm's float division;
   `Bin dst D Div` is the only `div` this backend builds) and (ii) the FLOAT
   COMPARE FAMILY, which is a different QBE instruction family and cannot be
   reached by reusing `Cslt`: QBE's op table has `cltd`/`cged` and NO `csltd`
   (`vendor/qbe/doc/il.txt:1126-1163`), so `Cmp _ D Cslt` would misprint.  The
   six `Ceqd/Cned/Cltd/Cled/Cgtd/Cged` variants were added; the printer is
   unchanged (mnemonic + operand-type suffix), and a `w`/`l` operand type with
   one of them misprints into a mnemonic QBE does not know — loud, not silent.

   ONE ROUTING TRAP, FOUND BY PROBE AND FIXED: `f/` must NOT be sent through
   `lowerArith`.  Its inline's integer arm is correct only for `+ - *`, so
   routing `/` there computed an i64 divide for `7 / 2` (3 where the VM's
   primFdiv promotes to 3.5) and for `1 / 0` (Infinity in the VM, SIGFPE with
   no output on the native side).  `f/` therefore has its OWN branch in
   `lowerPrimApp`, taken only when both operands are proven Float (otherwise
   the ordinary `rt_prim` route does the promotion), and `arithOp` stays
   `+ - *`.  `Flt.fdivIntTokens` (7 / 2), `Flt.fdivZero` (1 / 0) and
   `Flt.fdivMixed` (a raw float over an integer token — the fast path must
   DECLINE) are in the gate as the regression cases.

   COMPARISON SEMANTICS ARE THE VM'S, NOT "IEEE BY ASSUMPTION": the VM's
   primEq on two floats is `asFloat a1 == asFloat a2` and primLt/Le/Gt/Ge is
   `asFloat a1 < asFloat a2` (vendor/osier-rt/src/rt/prims.zig:806-925,
   primEq/primLt/primLe/primGt/primGe), i.e.
   the ORDERED compares — so `NaN == NaN` is false, `NaN < x` is false and
   `-0.0 == 0.0` is true, which is what QBE's `ceqd`/`cltd`/... answer.  Pinned
   by `nanEq`/`nanLt`/`nanGe`, `negZeroEq` (`(-1.0 * 0.0) == 0.0`),
   `negZeroInv` (`1.0 / -0.0` = -Infinity), `infArith`/`infCmp`,
   `maxF`/`denormSum` and `floatCmpChain` — every one byte-identical to elmvm
   on both arms, plus the `QBE_HEAP_MB=16` churn rerun.

   (a) **THE FLOAT-PARAMETER HALF IS DENIED, AND THIS IS MEASURED, NOT A
   SCOPING PLEA.**  S4's Int proof has two halves; mirroring the monotype half
   for Float produces a SILENT WRONG ANSWER on this front end.  Every integer
   TOKEN is materialized as `storew tagNumber; storel n` (Mid/FromAst.elm) —
   including a token the checker types FLOAT, because `3` unifies with Float.
   The VM is tag-directed and PROMOTES (`+ - *` take the f64 arm when EITHER
   operand is `.float`), so `f : Float -> Float; f x = x + 1.0; main = f 3` is
   4.0 in the VM.  MEASURED: that program's call site is
   `storew 0; storel 3` (tagNumber = 0), and hand-patching into its .ssa the
   raw `loadd` of the parameter payload — exactly what the monotype half would
   emit — gives native `1.0` against elmvm's `4.0`, BOTH exit 0.  A raw read
   reinterprets the i64 payload bits.  So there is no `floatParamsOf`, and a
   Float parameter keeps its slot.  `NoRep.floatParam` is that deny control
   (byte-identical ON/OFF, 17 slots and 3 `rt_prim` sites in both arms), run
   BEHAVIOURALLY with an INT argument (`norep-floatparam-i`, 8.5) beside a
   float one, and `Flt.intAtFloat` (`addF 3 1.0` = 4.0) keeps the shape in the
   differential.  A tag-safe parameter half would need an entry-time
   normalization (tag test + an int->f64 conversion op) or S2's per-binder
   types; neither is in this step, and the second would not reach a
   POLYMORPHIC body anyway.

   (b) **What IS proven, and why it is a fact about the VM's values** (the
   posture `isIntKnown` has): `LFloat` lowers to `storew tagFloat` + the
   double, and `+ - * f/` over proven-Float operands returns `valFloat(...)`
   because the promote rule takes the f64 arm — float arithmetic is CLOSED
   under the representation.  Everything else (parameters, `App` results,
   record/list/tuple reads, case and destructure binds, `Basics.toFloat`) is
   denied with its slot and its `rt_prim` route.  Since no boxed binder can be
   proven Float, one map (`S.rawFloat`) is the whole binder half.

   MEASURED, structural (`.ssa` counters, pass ON vs OFF; `f64ops` is the
   count of native `=d add/sub/mul/div`):

     entry (fixtures)        frame slots   rt_prim sites   f64ops OFF -> ON
     Flt.main                  19 -> 11       35 -> 28         0 -> 5
     Flt.add/sub/mul/div        6 ->  2        1 ->  0         0 -> 1 each
     Flt.ltc/lec/gtc/gec        6 ->  2        1 ->  0         0 -> 0 (cmp)
     Flt.eqc/neq                6 ->  2        1 ->  0         0 -> 1 (cmp)
     Flt.nanEq                 14 ->  2        3 ->  0         0 -> 2 + 1 cmp
     Flt.nan / infArith / infCmp / denormSum   6 -> 2, 1 -> 0   0 -> 1
     Flt.floatCmpChain          4 ->  4        8 ->  0         0 -> 6 cmps
     Flt.recFieldRaw           11 ->  2        2 ->  0         0 -> 1
     Flt.listRaw               16 -> 16        5 ->  4         0 -> 1
     NoRep.floatLocal          23 ->  7        4 ->  1         0 -> 3
     NoRep.floatCapture         8 ->  8        2 ->  1         0 -> 0
     NoRep.floatParam          17 -> 17        3 ->  3         0 -> 0  <- DENY
     Flt.viaFn                  8 ->  8        1 ->  1         0 -> 0  <- DENY
     Flt.intAtFloat             8 ->  8        1 ->  1         0 -> 0  <- DENY

   NOTE the OFF column: it is ZERO f64 ops EVERYWHERE, including the suite —
   before this step every float operation in every program on this backend was
   an `rt_prim` call.

   THE CONTROL FLIP, which is the point of the unit: `NoRep.floatLocal` used to
   be the byte-identical DENY control (item 6 (a)).  It now DIFFERS ON/OFF,
   and the identity moved to `NoRep.floatParam`.  The gate asserts BOTH, so
   neither can be satisfied by the pass simply not running: `norep-float-fired`
   (differs, slots 23 -> 7, `rt_prim` 4 -> 1), `norep-float-denied`
   (byte-identical, 17/3 both arms), `norep-float-capture` (differs, 2 -> 1) —
   alongside the pre-existing `norep-structural`/`norep-fired` Int checks in the
   same fixture.

   MEASURED, wall clock, `tools/osier-bench.sh` — and THE HONEST RESULT IS A
   NULL ON THE SUITE.  Ten runs (five ON/OFF pairs; best of 3 per run, heap
   512MB): every run exit 0, 12/12 measured, and "12 VM/native cross-check(s)
   compared byte-identical" — `mono_float` included.  Per program ms, the five
   QBE reps ON against the five OFF:

     program        ON reps                     OFF reps
     numloop        14 14 14 14 14               44 44 44 43 43
     localrec       11 11 11 11 11               19 19 19 19 20
     deepnontail    63 66 56 58 55              101 96 90 91 94
     listbuild      49 50 50 50 49               52 52 52 52 52
     nestagg       232 243 237 237 231          256 251 239 238 237
     mono_int       82 81 81 80 79              220 83 82 83 85
     mono_float    105 101 103 102 104          170 106 105 109 105
     mono_record   310 829 308 306 309          308 310 312 305 328
     adtmatch      137 138 135 136 137          137 138 136 136 139
     recupd_param  338 338 337 337 335          349 330 331 330 333
     recupd_local  482 505 478 480 478          482 478 480 479 496
     recflow       355 351 346 346 344          349 350 348 354 346

   TWO things are visible and both are reported rather than smoothed:
   (i) the OFF column carries single-rep LOAD SPIKES — `mono_int` 220,
   `mono_float` 170, `mono_record` 829 and `recupd_local` 496 are windows where
   the machine was busy (my own concurrent verification work), against
   83/105/306/478 in the neighbouring rep — so a single pair of runs is not a
   measurement; (ii) the run TOTALs are ON 2178 2727 2156 2157 2146 against OFF
   2487 2257 2238 2239 2278, i.e. the instrument's spread is LARGER than the
   effect being reported, so the TOTAL is not evidence of anything here.  What
   IS evidence is the pairing of each program's clock with its counters below.

   THE STRUCTURAL COUNTER SAYS WHY: all twelve programs' counter pairs are
   IDENTICAL to item 6's row (numloop 47 -> 17 slots, 7 -> 0 `rt_prim`;
   mono_float 206 -> 190, 33 -> 29; recflow 92 -> 92, 23 -> 23; ...) and the
   new counter reads ZERO native f64 ops in all twelve, ON and OFF.  So the
   Float half moves NO suite program — the -68/-42/-34% band is item 6's Int
   half, `mono_float`'s -4.7% sits inside the spread, and `recflow` remains the
   named control: `.ssa` BYTE-IDENTICAL ON/OFF, counters identical, clock
   +0.6%.  The reason is structural and was visible before the code was
   written: every float operand in the suite is either a Float PARAMETER
   (`Floats.iter`'s accumulator: denied by (a)) or a POLYMORPHIC lambda
   parameter (`fold (\x acc -> x + acc)`: S5's specialiser, not this step).
   The Float half's measured payoff is therefore at the FIXTURE level — one
   removed `rt_prim` call per float op, and a frame slot per Float local — and
   it is reported as a NULL on the suite rather than dressed up as a win.  The
   ZINC path is untouched: `tools/osier-numbers.sh` exit 0, corpus
   BYTE-IDENTICAL (149 = 149), gate PASS=152 FAIL=0, TestMain 114 assertions.

## Self-host: the QBE backend compiles the WHOLE compiler

`tools/qbe/qbe-selfhost.sh` is the SCRIPTED form of the QBE self-host
milestone.  The milestone itself was proved once by hand; nothing committed
reproduced it and no gate exercised it, so it could rot silently — and it is
load-bearing.  AS OF THE 2026-10-10 RE-FREEZE the self-host manifest DOES
contain the `Mid/*` tier (75 sources, the QBE backend among them), so the
compiler that `NativeMain` drives can emit QBE IL via its new `--ssa <entry>
<manifest>` mode — the csexp output path can now be retired once the `.ssa`
fixed point below is the seed (P6).  The historical form of the claim is kept
below for the record: before that re-freeze the manifest held NO `Mid/*`
module, so the compiler could emit CSEXP ONLY.

```
tools/qbe/qbe-selfhost.sh
  node run.js --batch (QBE=1 QBE_ENTRY=NativeMain.main)  -> selfhost.ssa
  vendor/qbe/qbe selfhost.ssa                            -> selfhost.s
  cc selfhost.s tools/qbe/rt.o                           -> zig-out/bin/qelmc
  AOTRUN_ARGV=1 QBE_HEAP_MB=16384 zig-out/bin/qelmc NativeMain.main <manifest>
                                                         -> out.csexp
  cmp out.csexp tools/bootstrap/selfhost.csexp           -> BYTE IDENTITY
```

THE INVOCATION, settled from the source rather than guessed.  The emit takes
the BATCH-JSON manifest with `.groups[0].output` forced to a SCRATCH path: the
manifest's own output is `zig-out/selfhost.csexp`, so writing QBE IL there
clobbers an artifact (the by-hand milestone re-paid exactly this).  The
compile must run from the REPO ROOT — `run.js` resolves manifest source paths
and `NativeMain` resolves the fixed corpus against the process CWD, and the
wrong directory yields a bogus `err parse failed` that looks like a compiler
bug.  The RUN takes the LINE manifest (`<source>` lines, then `-> <out>`) that
`NativeMain.manifestJobs` parses; `rt.zig:716` reads the entry name from
`c_argv[1]` and the app's arguments from `c_argv[2..]`, and only under
`AOTRUN_ARGV`.  `AOTRUN_QUIET` is a NO-OP on this runner (`rt.zig` reads only
`AOTRUN_ARGV` and `QBE_HEAP_MB`), so the driver's final model line still lands
on stdout: the oracle is the OUTPUT FILE and the exit code read directly,
never stdout and never a pipeline's `$?`.

MEASURED (2026-10-09, HEAD 1df8530, x86_64, default env; a peer agent ran the
same whole-compiler emit concurrently on 1 core of 32):

  stage                     wall      artifact
  emit (#1)               1636.1 s   10,613,899-byte .ssa (whole compiler, 1 group)
  emit (#2)               1631.3 s   IDENTICAL to #1 — the .ssa IS deterministic
  qbe                       17.3 s   32,977,198-byte .s
  cc                         3.2 s   12,789,832-byte native compiler
  run (QBE_HEAP_MB=16384)  281.5 s   out.csexp == the committed seed

  both files sha256 `ac8acd77aab6353507736c158c9a184f62b46d1080050069d0c3959f0ce1cb4c`,
  1,466,335 bytes; `cmp` exit 0; whole script 59m32s, exit 0.
  For scale, the SAME 58 sources compiled by the OTHER engine: the csexp seed
  run under the VM takes 807 s per `tools/bootstrap/PROVENANCE` and 11m29.8 s
  (690 s) as last re-measured, against this native run's 281.5 s.

TWO THINGS TO KNOW BEFORE THIS GOES ON A GATE.  (i) STAGE 1 DOMINATES: the
stock emit is ~27 min — ~6x the native compile of the same corpus and 85% of
the script's wall clock.  The day-to-day cost of the proof is the tail
(qbe + cc + run ≈ 5 min).  `elm-compiler/compiler.js` is a DEV-mode elm build
(the driver prints "Compiled in DEV mode"; `elm make` without `--optimize`),
and an optimized build was NOT measured here, so that headroom is
unquantified.  (ii) THE HEAP IS NOT SMALL, and the recorded values conflicted
(16384 for the full native compile; 3072 said to panic).  MEASURED on this
workload: `QBE_HEAP_MB=3072` panics after 1m57s ("gcalloc - Unable to allocate
1 pages in a 6291456 page heap") and `QBE_HEAP_MB=8192` panics after 4m12s
("... in a 16777216 page heap") — both exit 134 (SIGABRT) with NO output file
written, i.e. loud, never a wrong answer, and both matching the recorded
`grow_heap` accounting (`reservation = 2x heap`).  16384 works.  The exact
lower bound is bracketed only to (8192, 16384], so the script's default is
16384, overridable with `QBE_HEAP_MB`.

The determinism oracle (emit twice, `cmp`) is not a formality: a .ssa that did
not reproduce byte-for-byte would break the "commit the .ssa as the seed"
option, whose fixed point IS a byte comparison — so the script reports
DIFFERENT as a FINDING, in the manner of a failed byte identity, rather than
retrying.

Note on the counts above: `qbe-check.sh` is 219 PASS / 0 FAIL at this commit
(the Commands section near the top of this document still says 153 — that is a
measurement from before the float / norep fixtures landed, left as written
rather than silently reworded), and `tools/osier-numbers.sh` exits 0 with
`corpus: BYTE-IDENTICAL (149 artifacts = 149 manifest entries)`.

## The emit was quadratic: one argument flip, 293x (MEASURED 2026-10-09/10)

`elm-compiler/src/Mid/Qbe/Peephole.elm:248` — one line, inside `usedInBlock`:

```elm
Set.union condTmps (List.foldl (\i a -> Set.union a (readsTmps i)) acc b.body)
                                                        ^^^^^^^^^^^^^^^^^^^^^^^^  THE BUG
```

`acc` is the ACCUMULATED used-temp set threaded across blocks by `dropDeadDefs`
(`Peephole.elm:161-180`) and grown to a function's TOTAL DISTINCT TEMPS.
elm/core's `Set.union t1 t2` **iterates `t1`** — MEASURED in the generated
driver, `elm-compiler/compiler.js:6861`:

```js
var $elm$core$Dict$union = F2(function (t1, t2) { return A3($elm$core$Dict$foldl, $elm$core$Dict$insert, t2, t1); });
```

so `Set.union acc (readsTmps i)` iterated the whole accumulated set once per
instruction, to fold in a 1-2 element per-instruction set: O(n_instrs x
k_temps) per function, quadratic in the function's own size — and
`dropDeadDefs` re-runs `usedInBlock` as a FIXPOINT (`:160-180`), multiplying it
again. THE FIX is the argument flip, `Set.union (readsTmps i) a`: provably
output-preserving, because union is content-commutative and `used` is only ever
read through `Set.member` (the set's SHAPE changes, its content cannot).

MEASURED, whole-compiler emit, same manifest, same host, the flip reverted by
rebuilding `compiler.js` (`elm-compiler/build.sh`; `elm` must be on PATH) and
back:

```
emit (pre-fix)   1674.5 s  10,613,899 B  sha c75ce616b9192563052822e2876c408b65922bfff89f7cd19bbb35e34beba3e4
emit (post-fix)     5.7 s  same sha, same size   -> cmp exit 0, BYTE IDENTICAL   293x
emit (in script)    9.2 s / 10.7 s (the two emits, identical to each other)
```

(The 1674.5 s re-measures the 1636.1 s / 1631.3 s recorded above on the same
input and the same byte size; the spread is a shared 32-core host. The 293x is
the pre/post ratio of the SAME input — it is not the frontend getting faster,
it is 27 minutes of quadratic disappearing.)

The fix is visible in the field as a TWO-LINE, same-size delta of the built
`compiler.js` (1,371,530 B before and after, `diff` = exactly `a, readsTmps(i)`
-> `readsTmps(i), a` at `compiler.js:41448-41449`).

FULL SCRIPT, MEASURED (`tools/qbe/qbe-selfhost.sh`):

```
                        pre-fix      post-fix
emit (x2, identical)    59m32s      9.2 + 10.7 s
qbe                     17.3 s       16.8 s
cc                       3.2 s        2.5 s
run (HEAP_MB=16384)    281.5 s      291.2 s
whole script           59m32s        5m30.4 s   exit 0
cmp out.csexp seed     exit 0        exit 0 (both sha ac8acd77aab6353507736c158c9a184f62b46d1080050069d0c3959f0ce1cb4c, 1,466,335 B)
```

BYTE IDENTITY held at three levels: the whole-compiler `.ssa` before vs after
(`cmp` exit 0), the `.ssa` emitted twice in one run (the determinism oracle),
and the final `out.csexp` vs the committed seed. `tools/qbe/qbe-check.sh` is
still 219 PASS / 0 FAIL (exit 0) and `tools/osier-numbers.sh` still exits 0 with
`corpus: BYTE-IDENTICAL (149 artifacts = 149 manifest entries)`,
`gate: PASS=153 FAIL=0`, `TestMain: All 114 assertions passed.` — the ZINC path
is untouched, as a Peephole change must leave it.

### The emit now has a BUDGET (oracle 0)

`tools/qbe/qbe-selfhost.sh` fails LOUDLY (exit 1) if one emit exceeds
`QBE_SELFHOST_EMIT_BUDGET` seconds, default **60** — ~10x the measured 5.7 s
baseline, ~4x the worst (13.9 s) seen on this loaded shared host, and ~28x
BELOW the 1674.5 s the quadratic cost, so the accident above is caught in
seconds instead of costing half an hour. The message prints the 5.7 s baseline
AND the 1674.5 s pre-fix figure, so a reader can tell a regression from a
budget set too low. PROVEN TO FIRE, not merely written: with
`QBE_SELFHOST_EMIT_BUDGET=1` the script exits 1 at

```
qbe-selfhost: EMIT BUDGET EXCEEDED — the first emit took 13.9 s, budget 1 s
```

### The `--optimize` probe: REFUSES, and would not have helped

`compiler.js` is built by `elm make` in DEV mode (the driver prints the DEV-mode
banner). MEASURED: `elm make src/Main.elm --output=<scratch> --optimize` exits
**1** in 0.3 s and writes NO output file —

```
There are uses of the `Debug` module in the following modules:  Mid.Qbe.Flatten
```

— root: `elm-compiler/src/Mid/Qbe/Flatten.elm:172` (`{ defun | value = Debug.todo
msg }`; the only real `Debug` use in `src/`, `ParserFast.elm:2083` is inside a
comment). When that ONE unreachable site (`Err` from `rw`; the DEV build
completed, so the path is never taken on this corpus — MEASURED) is replaced by
`Var 0` in a SCRATCH COPY, `--optimize` BUILDS (exit 0, 1,301,862 B vs
1,371,530 B) and its whole-compiler emit is **byte-identical** — but **9.1 s,
i.e. no faster** than the DEV build's 5.7-9.2 s. So `--optimize` is NOT a free
multiplier here, and it is definitely not a substitute for the flip: an
optimized build of the UNFLIPPED source was left running 12m33s and killed
still burning CPU, quadratic intact. Recommendation: do not switch the emit to
`--optimize` on this evidence.

### The post-flip profile: the rest of the optional sweep is NOT worth doing

`node --cpu-prof` over the whole-compiler emit, post-fix (7,800 ms sampled):

```
elm/core Dict/Set path   none measurable — every such frame reads 0.00 ms self
                                  (PRE-fix profile put this path at 86.9%)
_Utils_update           22.22%   (record copies; 13.9% attributed under compileAll,
                                  4.8% under Lower.freshTmp, 2.3% under freshSlot)
_Utils_eqHelp           11.50%   (6.4% under Elm.Parser.parseToFile, 3.3% under Print.escapeChar)
A2 / A3 (curried apply)  7.07% / 4.23% (self)
_Utils_cmp               3.96%   (2.1% under Peephole.dropDeadDefs)
GC                       7.79%
Peephole (all)           1.38%     Lower (all) 0.46%   Print (all) 1.27%   Flatten 0.04%
```

With the quadratic gone the emit is 19.9 s of a 5m30s script — **6%** — and the
291 s native run is **88%**. One caveat on reading any of this: elm/core's small
helpers (`List.append`, `_List_appendHelp`, `List.member`, `Dict.insert`,
`Set.union`, ...) all read 0.00 ms self time in the post-fix profile because V8
INLINES them, so an absent frame is not evidence of an absent cost — only of an
inlined one. The measurements below therefore lean on (a) the inlining-proof
wall clock and (b) the NAMED, non-inlinable callers, whose own self time absorbs
the inlined work. Verdicts (the ceiling is the whole bucket, and the bucket is a
few percent of a stage that is now 6% of the script):

- **`S` hot/cold split (`Lower.elm:168-190`)** — the `_Utils_update` bucket is
  22.2% and `S`'s per-instruction copy is a large part of it, so the ceiling is
  ~1-1.5 s of a 330 s script. NOT WORTH a refactor of a large file.
- **`freshTmp`/`freshLbl`/`slotTmp` string building (`Lower.elm:210-227`)** —
  `_String_fromNumber` 0.36%, `Mid.Qbe.Il.Tmp` 0.28%. NOT WORTH it.
- **`acc ++ [x]` sites** — bounded by their CALLERS' self time, which absorbs
  the inlined append: `Flatten` (all) 0.04%, `Mid.QbeModule` 0.00%, `Types`
  0.02% of samples. NOT WORTH it.
- **`dropDeadDefs` fixpoint -> one reverse-pass liveness** — `Peephole` is 1.38%
  in total, of which the fixpoint's remaining `_Utils_cmp` is 2.1%. NOT WORTH it
  (and a rewrite that must reproduce the same result set is the riskier half of
  a 1% win).
- **`reach` (`Lower.elm:334-349`) Set-visited** — its `foldl` defines the output
  order, and the profile does not support it: `reach` itself (a named,
  non-inlinable recursive function) registers NO measurable self time, and the
  `_Utils_eqHelp` bucket that a `List.member` over a growing `List String` would
  produce is NOT that site — it is attributed to the frontend PARSER and to the
  printer (above). An O(V^2) `List.member` there is still real in principle; it
  is not measurable here. NOT WORTH it on this evidence.

If the emit is ever the bottleneck again (it was 85% of this script; it is 6%
now), the profile to re-run is the one above — the first question is whether
`elm/core`'s Dict/Set path is back, and the gate that answers it in seconds is
oracle 0.

INSTRUMENT: `tools/qbe/perf-emit.sh <fixture.elm> <Entry.key> <out.ssa>` is the
emit-only slice of `qbe-mk.sh` (timed, sha256, size) used for the fixture
before/after ladder `d400` 8.37 s -> 7.21 s and `b400` 7.55 s -> 7.72 s, both
`.ssa` byte-identical. It is an addition beyond the files this fix was scoped
to; it exists because the "before" numbers have to be reproducible. Note the
fixture ladder stops at the 400 scale: a 1500-let chain overflows the JS stack
inside `Mid.Qbe.Flatten.rwList` — MEASURED to do so with the PRE-FIX compiler.js
too, i.e. a pre-existing frontend recursion limit, unrelated to this fix.

## The native stack-depth guard (handoff osier-natdepth)

NON-tail recursion runs on the C stack — that is the documented limitation the
bounce loop cannot remove (`n + deep (n-1)` keeps every frame live).  Until
this stage, a recursion deep enough to exhaust `RLIMIT_STACK` died with a BARE
SIGSEGV: exit 139, empty stderr.  Non-zero, so never a silent wrong answer,
but unnamed, unassertable by any gate, and silent about the remedy — and the
plan retires the interpreter whose `CALL_STACK_DEPTH` cap used to carry this
semantic (`tests/elm-fixtures/calloverflow.elm` pins the VM side; the gate's
`depth` check reads the constant out of `vendor/zinc-vm`).  The native path
has no frame cap and NO interpreter to fall back to (the AOT's `nat_depth`
cap falls back; we cannot), so the only honest behaviour is a LOUD failure at
the real resource boundary.

**Design — option (b) of the plan: classify the fault, don't count the
calls.**  `tools/qbe/rt.zig` installs a 64 KiB static `sigaltstack` and an
`SA_ONSTACK | SA_SIGINFO` SIGSEGV handler at startup, right AFTER the
RLIMIT_STACK raise so the computed floor matches the budget actually in
force.  The handler classifies a fault as a stack exhaustion iff BOTH hold:

```
rsp      in [stack_low - 1 MiB, stack_low + 64 KiB]
si_addr  in [stack_low - 1 MiB, rsp + 4 KiB]
```

where `stack_low = ([stack] VMA top, parsed from /proc/self/maps) -
rlimit_soft` is the furthest down the kernel will grow the main stack.  A
real exhaustion fault is a push or a downward frame probe by code already
running AT that boundary; each condition alone is weak (rsp is inside the
stack region on every healthy frame; a wild pointer can point anywhere), but
a non-overflow SEGV from a healthy frame has rsp megabytes above
`stack_low` and fails the first condition, and the 1 MiB slack window below
`stack_low` is the stack's own unmapped growth reserve — the mmap region
(where the GC heap lives) sits at least `max(rlimit, 128 MiB)` below the
stack top on the default x86_64 layout, MEASURED on this host to be terabytes
away in `/proc/self/maps`.  The slack also bounds the largest single-frame
overshoot a sound classification admits: QBE frames are `nslots*40 B` +
fixed (tens of KiB at worst); a >1 MiB frame faults outside the window and
stays a bare SIGSEGV, which is the honest answer for an alloca that large.

Why not a per-call counter (the AOT's shape, option a): it changes the
emitted `.ssa` BY DESIGN, forfeiting the byte-identity oracle
(`qbe-selfhost.sh`'s `cmp`, the corpus 149=149, `qbe-check.sh`'s 219), costs
two instructions on EVERY generated call, and needs a cap tuned to a guessed
stride.  The handler costs nothing per call, changes zero emitted bytes, and
fires at the kernel's actual refusal to grow the stack — so it composes with
whatever budget is in force: the default 8 MiB, this driver's 64 MiB raise,
or `QBE_NO_RLIMIT=1` + an external `ulimit -s` (which is how the gate owns
the number).

**What happens to everything else.**  A SIGSEGV that fails the
classification is NOT named: the handler restores the default disposition and
re-sends the signal, so the process dies with the SAME bare SIGSEGV it would
have died with had the guard never existed — proven live by sending
`kill -SEGV` to a waiting native binary (rc 139, empty stderr, no
diagnostic).  Two honest deactivations: a soft limit of `RLIM_INFINITY`
gives no computable floor, and an unreadable `/proc/self/maps` gives no
`[stack]` top — in both cases the guard is not installed and crashes stay
bare rather than risk naming a different fault.  The guard is
single-threaded by construction (the GC and the effect loop are); a future
thread's stack would need its own bounds.  The x86_64 `ucontext_t` is read
through a local `extern struct` overlay with comptime offset assertions
(there is no std `ucontext_t`).

**MEASURED, before -> after** (bisected on `natcalloverflow.elm`,
`deep n = n + deep (n-1)`, exactly **256 B of stack per level** — the stride
falls out of the three budgets agreeing):

| budget | last-good depth | first-fault, BEFORE | first-fault, AFTER |
|---|---:|---|---|
| raised 64 MiB (default) | ~261,800 | rc 139, stderr empty | rc 1, diagnostic |
| 8 MiB (`QBE_NO_RLIMIT=1`) | ~32,400 | rc 139, stderr empty | rc 1, diagnostic |
| 1 MiB (`ulimit -s 1024`) | ~3,780 | rc 139, stderr empty | rc 1, diagnostic |

(The exact boundary wobbles a few tens of levels with the size of
argv/environ — base usage, not stride; the guard's window is 1 MiB, four
orders wider.)  The diagnostic, one line, all numbers live:

```
qbe-rt: native stack depth exceeded: deep non-tail recursion exhausted the C stack (64.0 MiB in use of a 64.0 MiB limit) — rewrite the recursion as tail-recursive, or raise the stack limit (ulimit -s; this runtime raises it to 64 MiB unless QBE_NO_RLIMIT=1).  See docs/qbe-backend.md.
```

stdout is EMPTY on the failure — a printed value there would be the
wrong-answer-with-success-status class this project has been bitten by twice.

**The gate arm** (`natdepth`, `tests/elm-fixtures/natcalloverflow.elm`):
same non-tail shape and same control value as the VM fixture (`deep 1000 ==
500500`), depth from argv, compiled on demand via `qbe-mk.sh` (no compile
group — the corpus baseline pins the batch artifact set).  Three invocations:
a control at depth 1000 under the check's OWN budget (`QBE_NO_RLIMIT=1` +
`ulimit -s 1024`, boundary ~3.8k levels) must print the sum; depth 20000
(far past that budget) must exit non-zero with `native stack depth exceeded`
on stderr and NO value on stdout; and depth 100000 (25.6 MiB of stack) must
still print `5000050000` at the driver's RAISED limit — the guard must not
refuse work the raise exists to allow.  Unlike the VM arm this check reads
NO constant from the tree: the boundary is a byte budget, so the check owns
the budget.  `NAT_DEPTH_MSG` ("native stack depth exceeded") is distinct
from the VM's `DEPTH_MSG` ("call stack depth exceeded") so neither arm's
grep can match the other backend's message.

## The runtime split: rt.o links osier-rt, never the interpreter (2026-10-10)

`tools/qbe/rt.o` is now built against the **osier-rt** package
(`vendor/osier-rt`) instead of the old `vendor/zinc-vm` monolith:

```
zig build-obj -O ReleaseFast -lc -femit-bin=rt.o \
  --dep gc --dep rt --dep effectloop -Mroot=tools/qbe/rt.zig \
  -Mgc=vendor/osier-rt/src/gc.zig \
  --dep gc -Mrt=vendor/osier-rt/src/rt.zig \
  --dep gc --dep rt -Meffectloop=src/effectloop.zig
```

`vendor/zinc-vm` is not on the QBE path at all anymore.  The runtime package
(gc + values/state/symbols/tables/varray/prims/streams/execplan) imports
nothing but `std` and `gc` — no interpreter — and `src/effectloop.zig` links
only `gc` + `rt` too.  The interpreter (interp/parser/hostcall, the csexp
bundle loader) stays in `vendor/zinc-vm`, which now *depends on* osier-rt;
it dies at P8.

Consequences visible in this file's domain:

- **rt_prim calls the same prims the interpreter did**, but through
  `osier-rt`'s prims table, which now has **58 rows** (was 80): the 22
  Shen-only prims are deleted (`boolean? element? error? error-to-string
  eval-kl function? gensym get-time hdstr kill newvar n->string pos set
  shen.fail! stream? string->n symbol? tlstr trap-error variable? wait`) —
  none is emission-reachable from the Elm front end, so the corpus stayed
  BYTE-IDENTICAL (149 = 149) and qbe-check stayed 219/219.  `trap-error` is
  gone outright (Osier has no exceptions; the old loud rejection branch in
  rt.zig went with it — an unreachable name now dies through the ordinary
  unknownPrim path), and `eval-kl` took `marshal.zig` with it.
- **The effect-loop seam** (`effectloop.host_apply`) defaults to a LOUD stub:
  the host module cannot link the interpreter's applier, so each driver
  installs its own at startup — elmvm and the AOT driver install
  `hostcall.applyClosureN` (from zinc-vm), the QBE runtime installs its
  native `hostApply` (unchanged behaviour, new plumbing).
- **The depth-guard message** no longer claims "this runtime raises it to
  64 MiB unless QBE_NO_RLIMIT=1" unconditionally: the raise clause prints
  only when the raise actually took effect (a hard RLIMIT_STACK cap or
  QBE_NO_RLIMIT=1 means it did not, and the live numbers speak for
  themselves).

The va* stack helpers (`vaInit`/`vaPush`/`vaPop`/`vaFree`) the runtime stages
prim args through moved from `interp.zig` to `osier-rt`'s `varray.zig`;
`rt.zig` and `effectloop.zig` import them from there.

### Follow-up: the split's second rt.o site, and the coverage it cost (2026-10-10)

The P3 review (`handoff-osier-rtsplit-review`) landed one blocker on this
section's own account: the split re-pointed `tools/qbe/qbe-mk.sh`'s rt.o build
line but **missed the duplicate in `tools/qbe/qbe-selfhost.sh`**, whose
freshness guard already watched `vendor/osier-rt/src` while the command it
then ran still named `vendor/zinc-vm/src/gc.zig` (gone) and `vm.zig` (not
imported by `rt.zig` any more).  MEASURED: that graph fails
`vendor/zinc-vm/src/gc.zig:1:1: error: unable to load 'gc.zig': FileNotFound`;
the script now runs the command quoted above verbatim.

A correction to the review's account of *why* it hid, worth recording because
it changes how the failure is classified.  The review says `tools/qbe/rt.o` is
**TRACKED**, so a checkout gives it the checkout timestamp.  MEASURED: it is
**not** tracked — `git check-ignore -v tools/qbe/rt.o` reports
`.gitignore:25:tools/qbe/rt.o`, `git ls-tree HEAD tools/qbe/` holds only
`rt.zig`, and `git log --all -- tools/qbe/rt.o` is empty.  MEASURED: the repo
has no active git hooks (`core.hooksPath` unset; `.git/hooks/` holds no
executable hook), so a checkout does not produce the object either.  Together
those give the stronger reading — on a FRESH CLONE the object is **absent**,
the guard's `[ ! -f "$RT" ]` arm fires **deterministically**, and the pre-fix
script died on every fresh clone rather than only when mtimes happened to order
the wrong way.  (Marked as a reading: the fresh clone itself was not cut here;
what was measured is the untracked-ness, the absence of hooks, the missing-file
arm firing, and the old graph's failure — the deleted-object run below exercises
exactly the state a fresh clone is in.)  VERIFIED end to end
after the fix, with the object deleted first: `qbe-selfhost.sh` exit 0,
`BYTE IDENTITY vs tools/bootstrap/selfhost.csexp: PASS (cmp exit 0)`,
sha256 `ac8acd77…` on both sides.

Two things the same review found that were *not* about this file, fixed in the
same pass:

- `tools/elmc.sh`'s freshness probe watched `vendor/zinc-vm/src` but not
  `vendor/osier-rt/src`, while its build compiles `osier-rt`'s gc + rt into
  `elmc` — an edit to the runtime left the compiler answering from a stale
  binary.  The probe now watches both packages.
- `waitStatusCode`'s 128+sig arm — the translation this whole file depends on
  when a QBE-built binary's child dies by signal — lost its only test with the
  deleted `wait/kill` prim test.  The gate now pins it at BOTH of its live call
  sites (`tests/elm-fixtures/signaldeath.elm` for the synchronous runner,
  `signaldeathasync.elm` for the effect loop): both run `sh -c 'kill -9 $$'`
  and require `137`.  The rows are asymmetry-proven — mutating the arm to
  `EXITSTATUS` in a scratch tree turns both into `0||` (see the `sigdeath`
  helper in `tests/elm-fixtures/run-elm-gate.sh`).

## Dead frame slots: implemented, measured, and REVERTED (2026-10-10)

`rt_frame_enter(nslots)` roots ALL `nslots` slots of a pooled frame for the
frame's whole life and slots were never cleared when their value died, so every
scavenge scans and promotes the whole slot set of the active call chain
(`docs/gc-zig.md`, "NOT done here: the conservative-rooting multiplier":
~53-69 KB promoted per scavenge, and a post-collect live old-gen read as
tracking `heap/4`).  The clearing was implemented here, verified, and then
**taken back out**: it does not reduce the compiler's memory.  The measurement
is below, and the exact patch is preserved (`/tmp/Peephole-with-slotclear.elm`
at the time of writing) so it can be re-applied deliberately.

### What was implemented

`Mid/Qbe/Peephole.elm` pass 4 (`clearDeadSlots`): a backward CFG liveness
fixpoint over frame-slot indices, then one `storew tagNumber, %sK`
(`storew 0`, the same non-pointer tag word the lowering's own rebox emits)
immediately after each slot's last read.  Three things that are NOT optional,
each found by a control rather than by reasoning:

- **Derived addresses must resolve back to their slot.**  The lowering takes a
  slot's address constantly — `%t =l add %sK, 8` for an unboxed Int/Float
  payload, and `%sK_i =l add %sK, 40*i` from `stageSlots`, which IS the
  address of slot K+i.  There are **83,432** such derived temporaries in the
  corpus `.ssa`.  A name-only liveness clears `%sK` while `%sK_i` still holds
  the only reference.  A census of every other instruction shape that mentions
  a slot temp found **none** outside `=l add`, so the alias model is complete
  for this emitter.
- **A whole-cell overwrite is a DEFINITION, not a read.**  `blit _, %sK, 40`
  and `storew _, %sK` at offset 0 kill the cell's old value; a partial write
  (`n /= 40`, or an interior offset) is left conservative.
- **The clear must not name a slot pointer the emit no longer has.**
  `dropDeadDefs` drops a pure def whose result is unused, and a slot whose
  address is only ever taken through a staging alias leaves `%sK` unused and
  dropped while the slot is alive.  Naming it emits a reference to an undefined
  temp and QBE refuses: MEASURED, `qbe: ...: invalid type for second operand
  %s36 in storew`, on 8 fixtures (`match`, `aggchurn`, `vfield-rooted`,
  `vfield-main`, `io-read`, `io-write`, `io-fail`, `flatten`, `flatnest`, the
  float entries, `norep-main`, `norep-boxed`, `norep-main-off`).  A clear is
  now emitted only for slots whose `%sK` is defined in the FIRST block (where
  `Lower.withPrologue` puts it, so it dominates every use site); an ALIAS is not
  a substitute, because an alias is defined wherever its staging block sits and
  a clear in an earlier block would be a use before its def.

`tools/qbe/rt.zig` gained a gated `QBE_GC_STATS=1` exit line (stderr): scavenge
count, full-collect count, heap MB, old-gen in use, and
`last_collect_live_pages`.  It exists because the figures ALREADY available
cannot answer the question — the full-collect banner prints `allocatedpages` at
the TRIGGER, and the trigger is `heappages/4`, so that number is invariant
under any change to what stays reachable.

Census over the corpus `.ssa` (same 75 sources, one group): 512,138
instructions and 137,133 frame slots before; **+116,204 clears** after, i.e.
+19.1% on the compiler's own `$q_*` defuns (73,469 clears on 385,256
instructions).  Shape (b) — lowering `hdr.live` when the dead slots are a
suffix — was rejected on two measured grounds: a static census over the same
`.ssa` gives it 4,579 update points and 270,663 of the 321,625 dead slot-scans
at call sites (84%), but it is **unsound alone** (a slot excluded from `live` is
not scanned, so a nursery pointer in it is left dangling by the scavenge, and
the next call that raises `live` re-includes it, where `gcMove` chases the
dangling pointer); and it is only sound on cells that are already non-pointer,
so it REQUIRES (a) rather than replacing it.

### The measurement — the clearing does not reduce memory

Three workloads, all `QBE_HEAP_MB=4096` unless stated.  In every pair the
WORKLOAD is fixed — same sources, same manifest, same entry, same mode — so an
arm differs from its partner only in the code generator, or (last two rows)
only in whether the RUNNING code carries the clears.  What was CHECKED, exactly:
both fixture pairs' program stdout is byte-identical (the `fxcmp.sh` control
line); the corpus `--ssa` pair's emitted `.ssa` differs BY DESIGN (that is the
mechanism) and each arm's `.ssa` was checked against the stock emit for its own
tree; and for the corpus csexp pair the evidence that both arms did the same
work is the IDENTICAL scavenge count and the IDENTICAL full-collect count below
— NOT a byte comparison of the two bundles, which was NOT done: both arms write
the single path the manifest names, so the second overwrote the first.  Claiming
that second comparison would be claiming a control that was not run.

| workload | arm | scavenges | full collects | live old-gen | old-gen in use | RSS | wall |
|---|---|---|---|---|---|---|---|
| corpus `--ssa`, same 75 sources | pass OFF | 562,344 | 491 | 479 MB | 742 MB | 4439.8 MiB | 910.0 s |
| corpus `--ssa`, same 75 sources | pass ON | 883,932 | 627 | **498 MB** | 691 MB | 4460.1 MiB | 1413.2 s |
| corpus csexp, same 75 sources | clears OFF | 279,387 | 40 | 187 MB | 637 MB | 4363.7 MiB | 399.1 s |
| corpus csexp, same 75 sources | clears ON | 279,387 | 40 | **185 MB** | 271 MB | 4364.7 MiB | 415.0 s |
| `vfield.rootedField` @ QBE_HEAP_MB=16 | pass OFF / ON | 27 / 27 | 3 / 3 | 16 / 16 MB | 18 / 18 MB | equal | 66 / 65 ms |
| `aggchurn.main` @ QBE_HEAP_MB=16 | pass OFF / ON | 16 / 16 | 2 / 2 | 8 / 8 MB | 11 / 11 MB | equal | 46 / 46 ms |

The `--ssa` rows: the BEFORE arm reproduces the figures this repo already
recorded for that workload (556,075 scavenges / 472 full collects / 4441 MiB /
944.2 s) to within 1-4%, so the protocol is the one the earlier unit used.  Its
`+116,204` clears cover essentially every dead frame slot at every safepoint of
the compiled program — if conservative frame-slot rooting dominated the live
set, the fall would be unmistakable.  There is none (479 -> 498 MB).

The two `--ssa` rows also differ in that the AFTER compiler EXECUTES the new
pass (alias maps and a liveness fixpoint per function), which allocates
heavily: scavenges +57%.  **That confound is why the last two rows exist.**
They run the CSEXP path, which never executes `Mid.Qbe.Peephole` at all, from
two binaries built out of the two emits: nothing in either arm pays the pass's
cost, and the only difference is the clears in the compiler's OWN generated
code — the mechanism by itself.  There:

- the scavenge count is **identical to the digit** (279,387), i.e. the clears
  change no allocation at all, and the +57% in the row above is entirely the
  pass's own data structures;
- the full-collect count is identical (40).  That is the integral measure of
  promotion volume for a fixed workload: the trigger is `allocatedpages >
  heappages/4`, so an unchanged collect count with an unchanged live set means
  an unchanged promoted-byte total.  **The dead slots were promoting
  essentially nothing**;
- the live set moves by 2 MB out of 187 (1%), RSS by 1 MiB out of 4364;
- the `old-gen in use` column is a POINT SAMPLE at process exit (`Gc.allocatedpages`
  at that instant), and it oscillates between the post-collect live set and the
  1024 MB full-collect trigger on every cycle — 637 and 271 MB are both inside
  that band, so the 637 -> 271 entry is NOT evidence of anything. The integral
  measure is the full-collect COUNT, and it is identical (40);
- the wall clock is **+4.0%** (399.1 -> 415.0 s), which is the clears' own cost
  on the hot path.

VERDICT: **the conservative frame-slot rooting is not the dominant term in this
runtime's live set.**  The earlier "post-collect live old-gen tracks `heap/4`"
reading was a signature of the anti-thrash GROWTH policy, not evidence that
frame slots dominated retention: at this heap the live set is ~1/22 of the heap
(187 MB of 4096 MB), and it is the same with and without the clears.  The
mechanism that would have explained the memory profile is elsewhere, and the
clearing was reverted rather than landed as a measured 4% regression with no
memory benefit.  What survives from this unit is the instrument, the
measurement, and the re-pointed oracle below.

### The self-host oracle now compares two compilers built from ONE tree

`tools/qbe/qbe-selfhost.sh`'s csexp oracle used to be
`tools/bootstrap/selfhost.csexp`, a FROZEN past artifact.  `Mid/Qbe/Lower.elm`
and `Mid/Qbe/Peephole.elm` are themselves entries in `elm-compiler/selfhost/
manifest.json`, so any real change to the backend changes the compiled
compiler, hence the csexp — the strongest check in the repo would fail for a
LEGITIMATE change and the only route back to green would be to re-freeze the
seed, i.e. to re-record whatever the tree now emits as "the truth".

The oracle is now a FRESHLY COMPILED reference of the SAME current sources
(stage 1c: `tools/selfhost-compile.sh`, the stock elm+node compiler over the
same manifest, snapshotted into scratch).  The claim it checks is stronger in
the sense that matters — two different compilers, built from one tree, agreeing
byte-for-byte on a whole-corpus 75-source bundle, one of them a binary the QBE
backend itself produced — and it can no longer be broken by a source change.
The committed seed is still REPORTED (present / matches its recorded sha256)
but no longer decides the exit code, so it may drift harmlessly.  This is
exactly the change that lets a backend change like the one above land without a
false failure, which is also why it was kept when the clearing itself was not.
