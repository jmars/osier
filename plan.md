# Osier — the plan

Merged working plan, 2026-10-11. Supersedes-as-a-single-document: `handoff-osier-midpasses-plan`,
`handoff-osier-midruntime-plan` / `-result`, `handoff-osier-mono-plan` / `-result`, and the repr
design pass (`handoff-osier-repr-result`). Those nodes remain the *evidence*; this file is the
*coherent worklist*.

Repo `/home/jaye/futaie/osier` (remote `jmars/osier`; the directory name is
historical, do not rename it). `HEAD = 00cc7da`.

Markers: **MEASURED** (ran it, read the output), **INTERPRETATION**, **PROJECTION**. The oracle is
always the output file / exit code read directly — never `$?` after a pipeline.

---

## 0. What this is

An Elm-family compiler for row-polymorphic records under **branch-local GADT refinement** +
locally abstract types (λρG): a Lean mechanization, a native backend (QBE), and an evidence chain.
Paper: *Rows under Refinement: Branch-Local GADT Equations for Extensible Records* (ICFP 2027).
Zenodo record `23242321`, DOI `10.5281/zenodo.23242321`.

Landed before this document: the ZINC VM/backend is **retired** (QBE-only tree); the Mid-tier
runtime exists and is the default route; the compiler **bootstraps node-free** from a committed
seed. The remaining arc is: finish the perf/representation work, then **Lua** ("Osier without a
compiler"), then node-lane retirement, the GADT-indexed AST, and the corpus/paper.

---

## 1. The discipline (read this before touching anything)

### 1.1 Oracles — the single source of truth

| what | command | expect at `00cc7da` |
|---|---|---|
| QBE structural + behavioural + GC-churn | `./tools/qbe/qbe-check.sh` | exit 0, **270 PASS / 0 FAIL** |
| the language gate | `tests/elm-fixtures/run-elm-gate.sh` | exit 0, **PASS=154 FAIL=0** |
| unit rows | `node test-run.js` (in `elm-compiler/`) | exit 0, **111/111** |
| the whole chain | `tools/osier-numbers.sh` | exit 0, `VERDICT: all checks pass` |
| corpus `.ssa` byte-identity | inside `osier-numbers.sh` (**gating**) | **BYTE-IDENTICAL 149 = 149** |
| seed | `tools/qbe-bootstrap.sh --freeze`, then a stub-PATH build | exit 0; invocation log **0 bytes** |
| prim differential | `tools/qbe/primsdiff/primsdiff.sh` | exit 0, **92/92** |
| cons differential | `tools/qbe/consdiff/consdiff.sh` | exit 0, **14/14** |
| Lean | `lake build` (in `lean/`) | exit 0, 0 bytes; **90 theorems / 3 axioms** |
| the collector's own suite | `zig build gate` (in `vendor/osier-rt/`) | exit 0, 3 optimize modes — **step 6 of `osier-numbers.sh`** since `a53aa2b` |
| runTask branch recount | inside `osier-numbers.sh` | **16 of 20** |
| suite wall-clock | `tools/osier-bench.sh` (12 programs) | see §1.3 |

`elm` is not on PATH: `ELM_BIN="$HOME/.npm-global/lib/node_modules/elm/bin/elm"` or PATH-prepend
the sibling `fx-core/node_modules/.bin`. `build.sh` fails without `ELM_BIN`. **elm is a DEV-lane
build tool only — `elm make` is NOT a gate (§6); do not constrain a change to keep it green.**

### 1.2 Attribution hatches — every `.ssa`-changing step ships the switch that undoes it

```
QBE_NOFLATTEN=1   turn off Flatten
QBE_NOREP=1       turn off the representation passes (S4/S4f unboxing)
QBE_NOPRIMDIRECT=1 turn off pass A
QBE_NOMIDRT=1     no Rt program injection (emit-only post-flip)
QBE_MIDZIG=1      DEAD HATCH: selects the old Zig prim route whose handlers the flip deleted
QBE_NORTLEAN=1    the fat :val-ABI Rt emission (step 1's hatch)
QBE_NOMONO=1      the S5/M2 specialiser OFF (it is ON by default; reproduces `159198d`'s corpus byte-for-byte)
QBE_NOREC=1       the phase-3 E record route OFF (records back to assoc chains) — a WORKING runtime arm
QBE_NOCONSARR=1   the phase-3 (A) cons hatch: EMIT-ONLY, NOT RUNNABLE (reproduces `00cc7da`'s bytes but
                  the new runtime cannot execute the 2-word shape it emits — `mono_record` halts or,
                  with QBE_NOREC=1, core-dumps). Attribution yes; measurement arm NO. See §3 phase 3/§6.
QBE_ENTRY, QBE_HEAP_MB, OSIER_BENCH_RUNS, OSIER_BENCH_STAT
```

A hatch is only evidence if it **reproduces the previous committed baseline byte-for-byte** on the
committed tree — that is what makes a corpus delta *attributable*. Every re-freeze is deliberate
and says why in the commit.

### 1.3 The decision rule (use this template; an explicit UNDECIDED is a valid outcome)

- Instrument: `OSIER_BENCH_RUNS=7 OSIER_BENCH_STAT=median`, arms **alternated**, ≥2 sessions, plus
  a **same-day A/A spread** that an effect must exceed.
- **CONFIRM** only if the named static counters move as predicted (≥90% of the targeted sites
  actually converted) **and** the targeted programs improve by more than the A/A spread. The
  mechanism must confirm; time alone does not.
- **REFUTE** if the counters do not move (it does not fire), or clocks regress >3% median.
- **UNDECIDED** if the effect sits inside the spread, or only shows on untargeted programs — then
  more reps or another day, **never** averaging it away. *An instrument that cannot say UNDECIDED
  will say something else instead.*
- Guards that always apply: selfhost wall regression ≤3%; selfhost `.ssa` growth ≤2x and emit ≤3x.
- Read the verdict **only** off the suite programs, never selfhost ratios (the corpus generalises
  poorly to general code).
- **AND do not settle a question about USER CODE on the suite either — the suite is a fixed sample
  too.** The instrument for that is `tools/bench/elm-corpus/` (the whole published Elm registry,
  2765 packages / 17,359 files / 6.1M lines, fetched by `tools/bench/fetch-elm-corpus.sh`; see its
  README). MEASURED 2026-10-12 on "how often does a prim operand need an **expression** type rather
  than a **binder** type?": the suite says **5** sites, a 400-file random slice of real Elm says
  **50%** of operator sites. Two orders of magnitude apart, in the direction that matters — the
  census had appeared to close a design question and could not. (Owner direction the same day: *do
  not use the compiler corpus to conclude a user-code optimization is unnecessary.*)

### 1.4 How work is executed

- One **writer** per lane. A shared tree with two writers is a hazard to report, not a practice.
- The durable record is the memory graph (`handoff-<slug>-*`); the live channel is
  `fx-agent-bus` / `fx-agent-steer` and only lands at a turn boundary — **name it in every brief
  and say where to poll**, or it is a no-op.
- Implementers publish **evidence**, not verdicts (`stage=implement: VERIFIED <cmd> -> <result>`);
  the orchestrator re-runs the headline itself before crediting it.
- Tiers, cheapest first: `coder` < `fast-coder` < `glm-coder` < `pro-coder` < {`kimi-coder` |
  `claude-coder`}. Escalate one rung at a time, to **break a loop** rather than for difficulty.
  GLM credit is exhausted most weeks (it died mid-unit twice) — `fast-coder` is quota-funded and
  non-rolling, so it is the default for mechanical units.

---

## 2. Settled design decisions (do not re-open without new measurement)

### 2.1 Representation

- **(A) `cons` = ONE pointer to a 2-element array.** `car` stays `*data`, `cdr` becomes
  `*(data+40)`. Kills the **only interior pointer** the collector has (`scan.zig` currently
  identifies it by `fused = car != 0 and cdr == car + sizeof(Value)`) and one store per cons.
- **(E) Records are positional.** ~~read/written at **type-table positions** … **Canonical field
  order = the TYPE TABLE order, never the literals' textual order** (so `{b=2,a=1}` and
  `{a=1,b=2}` build identically and order-sensitive `vecEq` still equals Elm's order-insensitive
  `==`).~~ **CORRECTED 2026-10-11 by measurement (planner pass, `handoff-osier-phase3-ea-plan`) —
  the type-table premise is FALSE.** Rows are insertion-ordered per literal
  (`Infer.elm:800-809`); `Unify.elm:632-660` row-swaps but never sorts; no sort exists in `Type/*`.
  MEASURED at `00cc7da`: `{b=2,a=1} == {a=1,b=2}` compiles and prints `false` (real Elm 0.19: `true`).
  The order must therefore be **DERIVED** (sort the row's field names at each site; stable,
  first-occurrence wins = scoped labels). Also measured: the brief's per-site deny-to-assoc fallback
  is **unsound** — host-built `@p` chains read at closed typed sites (`statunit.elm`), a closed-site
  vector flowing to an open-row access site, and non-Var record subexpressions in the target programs
  (`recflow.elm:36`, `recupd_param.elm:36`, `mono_record.elm:72`) whose types the binder-only side
  table cannot recover.
  **The corrected design — records are ALWAYS compiled as a positional vector of values + a static
  names array** (Variant B, chosen over the interleaved-names Variant A which doubles record object
  bytes): tag-14 `RawMkValue` payload `[word0 data, word1 len, word2 names]`, where `names` is a
  **new word producer `RawDataAddr (List String)`** — the address of a static, content-keyed
  `freshData` array of `"sym:"` refs, built in `Lower` (transient; never enters the audited program).
  `lenOf` (word 1) and `Rt.vecEq` are reused **unchanged**; equality is over **values only** — exactly
  Elm's order-insensitive `==`. Every access site **tag-tests**: tag 14 → positional load at
  `data[rank]` when the row is closed; else the new `Rt.recGet`/`Rt.recUpd` walk the names (byte
  compare via `RawPayload {word=2}`, no new read-side node); tag 4 → the existing assoc/snd chain
  route (host chains). Open-tail rows must take the walk. Tuples stay cons chains.
  (`RawVecAddr` **survives** — the old plan's "deletion" was wrong; only its *cons* use dies.)
- **Tag stays the `ValTag` word**, plus **one new `record` tag** (13 → 14) so errors/printing can
  show records as records.
- **Boxed scalars are REJECTED** — they would kill the unboxed-arithmetic bright spot (numloop
  13 ms, mono_int 68 ms live on i64 frame arithmetic). "Tagged vec for everything" is the change
  most likely to be regretted.
- Boundary that holds: `string` / `lambda` / `error` / `stream` keep their shapes.
- **Float specialization: the IR half is DONE, the monotype half is DENIED — and the fix is Gap E
  (recorded 2026-10-12).** `S4f` already unboxes Float **locals** whose Float-ness is proven *from the
  IR*: `LFloat` literals, and `+ - * f/` / `< <= > >= ==` on two proven-Float operands, closed under
  the representation (`Lower.elm:2861-2905`). What is denied is trusting a Float-**parameter** type.
  The Int half is sound because an Int-typed value is always `tagNumber` (every integer token
  materializes `storew tagNumber; storel n`, and Int/Float do not unify). For Float, THAT SAME literal
  materialization breaks it: an integer token the checker types Float is still emitted as `tagNumber`.
  MEASURED on `f : Float -> Float; f x = x + 1.0; main = f 3` — the call site is `storew 0; storel 3`,
  the VM promotes (f64 arm when either operand is `.float`) and answers 4.0, while a raw `loadd` of the
  parameter reinterprets the i64 bits: **hand-patched, 4.0 (elmvm) vs 1.0 (native), both exit 0.**
  `f 3` is well-typed Elm, so this is reachable from source. Hence `floatParamsOf` does not exist, gated
  by `NoRep.floatParam` + `run norep-floatparam-i` (called with an INT argument). **THE GENERAL RULE
  THIS INSTANTIATES: an admitted shape must yield a value the VM tags unconditionally — a fact about the
  VM's VALUES, never a guess about the checker's types.** Unblocking the parameter half = emitting the
  literal type-directed at a Float-typed site = knowing the type of an ARGUMENT EXPRESSION = **Gap E**.
- **GAP E IS NOW LOAD-BEARING FOR TWO THINGS** (2026-10-12): the general operand specialization
  (typespec Unit B deferred it — its Int half uses only the binder map the tree already carries) **and**
  the Float parameter half above. And the registry corpus says Gap E is the **common** case in real
  code (~50% of top-level operator sites take an application operand, against 5 in the whole suite) —
  so the "we don't need the join key" reading is retired twice over. See `handoff-osier-typespec-plan`.

### 2.2 The collector

Write a **fresh non-moving, non-generational mark-sweep in Mid** — **not** a port of the moving
generational C GC (PROJECTION ~500–700 Mid lines against the plan's 4,500–6,000). Everything hard
in the current 3,075 lines serves *movement + generations*: forwarding bits, per-page space tags,
nursery checks, promotion, the dirty-vector remembered set, the barrier seat. Mark-sweep needs
none of it once (A) holds: walk roots → per `Value` tag mark the head pointer (cons/vector/record/
string/error) or code+env (lambda) → per array mark elements. Roots are already **precise**
(`roots.zig`: no conservative C-stack scan). Honest costs: allocation via freelist bins slows
allocation-heavy programs; full collects replace scavenges (the ~7% GC share may grow 2–3x on
record programs — PROJECTION). Escape hatch if it regresses >5%: a bump/copying nursery in front.

**MEASURED AND ACCEPTED (2026-10-12).** The Mid collector landed at `handoff-osier-zigretire-stage4-result`
(`Mid/RtGc.elm`, ~1090 lines, hatched `QBE_MIDGC=1`, **default OFF** — with the hatch off the corpus is
BYTE-IDENTICAL 152/152 and `zig build gate` is green, so nothing regresses today). On the churn shape
(150k conses), MID vs ZIG: **+114–124% at 16 MB**, +45–55% at 32 MB, +31–40% at 64/128 MB. **OWNER
DECISION: ACCEPTABLE — improve the GC later.** The decomposition is what a later pass should target,
because it is TWO costs, not one:
* **allocation-route overhead** — visible at 64/128 MB where the live set (14.4 MB) means **zero
  collects**, so this residual is not the collector at all but the same Mid-route per-call cost seen at
  stage 3 (allocation now goes through Mid seats `Rt.allocVector`/`Rt.allocRaw`);
* **the real GC difference** — at 16 MB (~4 full collects): mark-sweep's **O(heap) sweep** vs the Zig
  scavenger's **O(live)**. THIS is what the §2.2 escape hatch (a bump/copying nursery in front) would
  address, and the nursery is the natural target when the GC is revisited.
Note the context that makes 2× tolerable: a GC-bound microbenchmark is the worst case by construction,
and the collector is off by default. Outstanding at the boundary is recorded on the result node
(3 of 5 probes, 36 of `gc_test.zig`'s 38 cases, no heap growth — it OOMs loudly where the Zig GC grows,
and record data arrays stay Zig-allocated).

**THE BARRIER-FREE DESIGN NOTE (2026-10-12) — the target for "improve the GC later".**

*The claim.* **Zero** write barriers are needed, not one per mutation. A barrier exists for exactly one
situation: an **old** object gaining a **young** pointer (a generation-crossing edge). In an immutable
language **no object ever gains a field after it is published** — every edge it will ever have is written
at construction, while the container is young. So no old→young edge is ever created by mutation, and the
barrier's premise is absent rather than merely rare. **Syntactic mutation is construction**: `{r | f = e}`,
`Record.insert`, `Record.remove` all build a NEW object (the chain builder prepends; `lowerRecordLitPos`
allocs a fresh vector) — there is no in-place update anywhere in the language. This is already true on the
**Mid** path (non-generational mark-sweep needs no barrier; stage 4's `rt_vec_store_plain` vs the Zig
`rt_vec_store` → `writeBarrierVectorStore`); the Zig path barriers only because its GC is moving +
generational. Payoff beyond speed: the barrier seat is exactly where a collector bug hides — plan.md
already lists "the barrier seat" among the machinery mark-sweep deletes — so deleting it deletes a bug class.

*The price is NOT a barrier — it is an INVARIANT.* **A mid-build object must be neither PROMOTED nor
RECLAIMED.** Promotion matters only once a nursery exists. **Reclamation is the live one**: if a field's
value allocates, a collection could run between the allocation and the fills, and an unreachable half-built
object would be swept — the subsequent stores then write into freed memory.

**VERIFIED — the build is ALREADY ATOMIC, so the hazard does not exist today for records.**
`lowerRecordLitPos` (`Lower.elm:4801-4845`) evaluates **all field values FIRST** (their lowering may
allocate), **then** `rt_vec_alloc`, **then** alloc-free stores + wrap — its own comment states the reason:
*"the data temp stays valid because nothing between the alloc and the wrap can move the heap."* So no
collection can intervene mid-build. **What is NOT established: that every other aggregate builder
(vector/list/tuple/cons) shares this order** — assert it per builder rather than assuming the discipline
is global, because the order IS the invariant.

*The guard.* A **mid-build probe**: force a collection between the allocation and the seal and assert the
object is neither promoted nor reclaimed. Its real job is not to find a live bug (the order is currently
right) but to go **RED if a later change reorders a builder to alloc-first** — a probe whose failure mode
is the *invariant*, not the symptom.

*Why this converges with the deferred improvement.* "Add a nursery" does **double duty**: it addresses the
accepted 2× (the O(heap) sweep vs the scavenger's O(live), above) AND it is the mechanism that makes the
barrier-free argument safe — a bump allocator does not trigger a collection mid-build (collect first, then
allocate). So the recommended "improve the GC later" change is the **nursery**, and it *removes* a barrier
rather than requiring one.

**REVIEW OF STAGE 4 (2026-10-12, `handoff-osier-zigretire-stage4-review`) — verdict: no corruption-class bug
in the sound domain; FOUR should-fixes, and the first one corrects a claim this plan makes.**

1. **THE NAMED BOUNDARY IS WIDER THAN REPORTED — and this gates ever ENABLING the hatch.** The two
   collectors **cannot coexist in general**: `QBE_MIDGC=1` is sound **iff every live pointer-bearing heap
   object is Mid-allocated**. Records are only ONE of THREE unsound shapes — **ADT construction
   (`rt_con`, `Lower.elm:4388`) is not hatch-routed, and closure env arrays (`rt_make_closure` →
   `valLambda` → `g.allocArray`, `values.zig:139`) are the same hole, and both were UNNAMED.** Cross-heap
   edges are unsound in both directions (Zig→Mid and Mid→Zig). So the hatch stays OFF until those shapes
   are routed through Mid seats — and the stage-4 result's "records are the boundary" must not be read as
   "everything else is fine".
2. **THE DIFFERENTIAL DECOMPOSITION IS HALF-PROVEN.** The 64/128 MB residual being route cost is
   **PROVEN** (threshold arithmetic: 14.4 MB < heapBytes/4, and `Rt.collect` has exactly two call sites →
   zero collects). But "the 16 MB delta is the sweep" is **ASSERTED, not measured** — there is no collect
   counter and the mark walk (4× `RawByteLoad` per tag32 plus an if-chain dispatch) could dominate. **And
   the nursery escape hatch does NOT address the 64/128 MB case**, which is route cost, not GC.
3. **THE FREE LIST IS EXACT-MATCH-ONLY** (`RtGc.elm` `gcAllocGoDefun`): no splitting, no bins, so a
   mixed-size program dies `midgc: out of memory` **with free memory available**. Invisible to every
   current fixture, because they are all uniform 12-word cons arrays.
4. **THE 3 UNREGISTERED PROBES LEAVE A REAL HOLE: the per-tag payload-pointer OFFSETS are pinned by
   nothing** (the gate census pins the tag integers and `str.len` only). Today's offsets are correct —
   verified word-by-word against `types.zig:70-88` — but nothing stops drift.
   (nice-to-haves: `Rt.collect`'s collect-before-init guard SIGSEGVs before reaching its loud die; the
   mark-stack bound; and a stray `elm-compiler/index.html` — removed, it was a build product of the
   orchestrator's own compile checks.)
**Tag coverage, re-derived by the reviewer:** proven reachable every collect = tags 0,1,2,4,5 (the
intern-table root scans strings/symbols each time); asserted-by-layout-parity = 3,6,8,9,10,11,12,14;
"two object kinds" **holds by construction for the Mid heap**; no produced-but-unmarked or
marked-but-unproduced tag; 13/`>14` die loudly; tag 7 has no native producer.
**Not falsified:** the fail-before mutation halves (the reviewer had no elm binary on PATH — `ELM_BIN`
must be set; the implementer's 112575/OOM figures are therefore inherited, not independently reproduced),
the mark-vs-sweep split, and cross-target collector behaviour.

**THE CRITERION WAS TOO NARROW — CORRECTED (2026-10-12, stage-5 PART 3 review, REPRODUCED).** The
soundness condition for `QBE_MIDGC=1` was stated as *"every live pointer-bearing object is Mid-allocated"*.
That is a PROXY, and it is the wrong one. The Zig collector frees by **REACHABILITY, not
pointer-bearingness**: any object the Zig side can reclaim, while a MID object references it, is a
use-after-free. REPRODUCED on the string path — `rt_string`'s fallback (`rt.zig:405-408`; it fires on
`QBE_NOSTRINGINTERN=1` **or at run time once `intern_live >= 2048`**) allocates a fresh string in the ZIG
nursery per evaluation; the resulting Value lands in a Mid object; the Zig scavenge scans only Zig roots
and re-reclaims the whole nursery (`collect.zig:713-720`), so the data is overwritten WHILE LIVE. A scratch
probe (a Mid list of 100 strings, ~300k churned strings, content equality) prints 0 under
`MIDGC+NOSTRINGINTERN`. **THE RIGHT CRITERION: no MID object may reference anything the ZIG collector can
reclaim** — and note the second half of the trap: `intern_live >= 2048` is a RUNTIME condition, so this
hole is NOT guardable by a flag at all. Also affected by the same reasoning: the transient tail arrays'
"not live" claim held (verified), but the general lesson is that a *classification by shape* cannot
substitute for the reachability argument.

**THE HATCH GATE — the "still allocates in Zig" list, CORRECTED THREE TIMES (2026-10-12).** This list is the
precondition for ever setting `QBE_MIDGC=1`, under the **corrected criterion above** (no Mid object may
reference anything the Zig collector can reclaim — reachability, not pointer-bearingness). It has now been
wrong three times, in the same direction (too short), so treat it as the artifact it is — verified by
EMITTING, never by intent:

| still Zig-allocated under `QBE_MIDGC=1` | reclaimable-by-Zig? | evidence |
|---|---|---|
| **RECORDS** — `lowerRecordLitPos` / `lowerRecordUpdatePos` emit `rt_vec_alloc` + the **barrier** `rt_vec_store` with NO `midGc` branch (`Lower.elm:4872`, `:5018`) | no longer | CLOSED by stage 5 PART 3 (`midGcAllocSeat "Rt.allocVector"` + `rt_vec_store_plain`); probe `probe-midgc-record.sh` PASS 60209 / FAIL-BEFORE 115409 |
| ADT construction (`rt_con`) | no longer | CLOSED by stage 5 PART 1 (`Rt.con`/`Rt.conFill`, `04344fa`) |
| **CLOSURES** — `rt_make_closure` → `valLambda` → `g.allocArray` (`values.zig:139`) | no longer | CLOSED by stage 5 PART 2 (`Rt.closure`/`Rt.closureFill`); probe `probe-midgc-closure.sh` PASS 22100 / FAIL-BEFORE 49900 |
| **PARTIAL APPLICATION** — `applyGo`'s `rem > nargs` arm (`rt.zig`) | no longer | CLOSED by stage 5 PART 2 (the weak-extern `q_Rt_x2eallocVector` bridge); probe `probe-midgc-partial.sh` PASS 22100 / FAIL-BEFORE 49900 |
| **STRING LITERALS** — `rt_string`'s nursery fallback (`rt.zig:405-408`, fired by `QBE_NOSTRINGINTERN=1` OR `intern_live >= 2048`) allocates a fresh Zig-nursery string whose Value can sit in a Mid object | no longer | CLOSED by stage 5 PART 4: under `QBE_MIDGC=1` a literal is emitted as STATIC data (the `str:` symbol itself), so `rt_string` is never called and both the flag AND the runtime fallback are structurally unreachable; probe `probe-midgc-string.sh` PASS 31200200 / FAIL-BEFORE 31200100 + a zero-`rt_string`-emission pin |
| the transient tail arrays (`rt_apply_tail`'s saturated arm, `rt_tail_known`'s `nargs > 3` fallback) | **reclaimable but NOT live** across any safepoint (the bounce chase copies them before any allocation) | left Zig this unit — allocation-class, GC-triggering, not a soundness hazard (finding 1's honest framing) |
| **the HOST-ONLY surface** — `rt_argv`/`buildArgvList` (`rt.zig:1265`), `effectloop.zig`'s `valString`/`valCons` (the ASYNC host leaves only; the WORKER read-file-as-string LEFT `nurseryHostPrims` at GROUP 3B-3: `Rt.read-file-as-string` accumulates on the C heap and builds the result via RawAllocRaw+mkStr, never values.valString — and with it the MID route has ZERO rt_prim emission; the WORKER exec-plan LEFT at GROUP 3B-2c: with the rt_exec_run seat deleted, `Rt.exec-run` builds the whole TAGGED result GC-side in Mid (RawAllocRaw+mkStr strings, Rt.cons/Rt.intern tree — the glob precedent shapes), so `nurseryHostPrims` is down to `value` alone).  `str` (String.fromFloat of NaN/±Infinity — the last census-arm entry) was CLOSED by stage 3 GROUP 2: it now has a Mid body (`Rt.str` → `rt_float_text` → a GC string), so it LEFT `nurseryHostPrims` (see the `str` note below).  `glob` LEFT in GROUP 3B-1: `Rt.glob` dupes matches onto the C heap (malloc) and builds the tagged list via `Rt.intern`/`Rt.cons`, never `values.valString`/`valCons` — `nurseryHostPrims` is now 3 (read-file-as-string, exec-plan, value). | **YES — still a LIVE hole for the REMAINING host-only prims, REPRODUCED** (the PART 4 "deferred" verdict was wrong on reachability) | **REFUSED at compile time by stage 5 PART 5**: `QBE_MIDGC=1` refuses (a) the host seam (`Runtime.program`/`Runtime.worker`, the effect-loop path — the reproduced hole) and (b) a census containing any of the 4 remaining nursery-building host prims (`read-file-as-string`/`glob`/`exec-plan`/`value`); `getcwd`/`getenv` LEFT the list in stage 3 GROUP 3A (their Mid bodies `Rt.getcwd`/`Rt.getenv` allocate via `RawAllocRaw`, never `values.valString`), alongside `str` (GROUP 2); `intern` (Mid `Rt.intern` → page_allocator symbol) and the scalar/libc prims are deliberately NOT refused. In-tree: `probe-midgc-io.sh` PASS-AFTER (refusal + default `"100|150"`) / FAIL-BEFORE (`"0|150"` — the cross-heap signature), `midgc-io`/`midgc-tail` qbe-check rows, and `midgc-tail` (a PURE 4-arg mutual tail churn does NOT corrupt — the trigger is not the hole). The host-IO fix (route `valString`/`valCons` Mid-side) remains for stage 6/7; the refusal is the deliverable the owner can act on today.  The boundary is COARSER than the holes (stdin/stdout are fd-int Values — safe, yet refused via the `value` entry); over-refusal is the documented interim call (`value`'s *argv* result is still a Zig-nursery valCons list).|
| non-pointer-bearing shapes (symbol/prim names, `record.names`, lambda `code` Desc, stream `FILE*`) | no | static or malloc/libc, never GC-reclaimed |

**THE GUARD WAS INCOMPLETE — a SECOND silent hole, found by the PART 2 review and fixed in `3c2741e`.**
`run.js` refused only `MIDGC+NORTLEAN`. With **`QBE_MIDGC=1 QBE_NOMIDRT=1`** the compiler returned 0 and
emitted a program in which `midRt=False` withholds the Rt program → the Mid seats are never emitted → no
`q_Rt_x2eallocVector` export → the weak extern resolves to 0 → `midgc_active` false → applyGo's partial arm
**silently** reverts to the Zig `g.allocArray` route (a cross-heap edge) and the binary dies with a bare
SEGV. Now refused by name, exit 2. **Lesson: a guard that names ONE incompatible flag is not a guard —
enumerate the combinations.** The same review carried a stage-6 obligation: `selfhost/NativeMain.elm:263`'s
hard-coded vector carries `midGc` **UNPINNED** (correct today, asserted by NOTHING — the only instrument,
bootstrap `--verify`, is never run), so stage 6's default flip must move it in the same commit.

**Two more findings from the same review:** the `<=16` bound on `conFill` is real but UNNAMED — it holds
because `Lower.elm:840` rejects defuns with arity > 16 and constructors are defuns (proved: a 17-arg `Con`
fails loudly), and it is doubly moot because `conFill`'s "recursion" lowers to an **in-frame loop**
(self-tail gate, visible in the emitted `q_Rt_x2econFill`) — a comment citing the enforcement site would
make the invariant falsifiable. And **the stage-5 probe never CONSTRUCTS a 1-arg `Con` under MIDGC**
(`Circle`/`Square` are only *matched*, never built; nullary constructors cannot exist in Elm), so its
coverage is narrower than it looks. A pre-existing gap: **`QBE_MIDGC=1` + `QBE_NORTLEAN=1` is unguarded**
(`lowerCon`'s midGc branch hard-codes the lean call shape), with no oracle row on the combination.
**What the review could NOT falsify** (i.e. what held): tag/shape parity word-for-word against
`rt.zig:418-434` *read in the emitted* `q_Rt_x2econ`/`q_Rt_x2econFill`; rooting across the allocation;
`conFill` really alloc-free; `n=0` correct; corpus byte-identical 152/152 independently reproduced; and
**both probe arms independently reproduced** (PASS 160800, FAIL-BEFORE 229600).

### 2.3 The ordering, and why

`1 midabi → 2 B/S5 → 3 E + (A) → 4 mark-sweep`, because **E needs B**: static record field
positions are only known once a defun's record type is monomorphic. E is the single highest-value
change (MEASURED: 418 ns assoc-chain read → ~2 ns load; 259 ns build → ~18 ns store), it absorbs
the residual left by step 1, and with v1 landed it is a **one-tree** change (the no-skew argument
was v1's whole point). The collector follows because its simplest correct form depends on (A).

*Correction 2026-10-11 (see §2.1):* with the corrected design the dependency is **softer** — the
static names array makes every record site *readable* regardless of monomorphisation, so E no longer
**requires** B for correctness. What B still buys is the **positional fast path**: a closed row reads
`data[rank]` directly, while an open/unresolved row falls back to the `recGet`/`recUpd` name walk.
So B remains the right predecessor (it decides how many sites take the fast path), but E can land
soundly without it.

### 2.4 The specialiser's key (decided by measurement, S2)

Key on **`range` + deny-on-conflict** — not `range+occurrence`. Collision gate MEASURED over
7,504 nodes: **0 duplicate ranges, 0 collisions** in real code; every collision anywhere is a
synthetic `Frontend/Lift.elm` node (snapshot decl/value nodes share the let-block range, lifted
params share the decl range). Occurrence is not even well-defined across the binder-id↔Range join.

---

### 2.5 The Osier ↔ mid-c interface (the `export` block) — DESIGN SETTLED, NOT BUILT

**Why.** `mid-c` (the tier-2 surface, §3 Phase 4b) is the low-level dialect for the runtime,
primitives and other low-level machinery. It becomes Osier's **foreign-module mechanism** — the slot
Elm reserves for JS — so a `.mid` module's defuns are callable from Osier and compiled into the
program by the compiler itself rather than spliced from an Elm blob.

**Where it rides.** Today's injection is a blob (`Mid/RtSource.elm`), and that blob exists *only*
because the builder lane is elm/node, which cannot read files — `run.js` reads everything and passes
text in via flags. **`.mid`-as-a-file and the native driver are the same piece of work**: the
compiler's `main` takes argv, reads its inputs (Osier sources **and** `.mid`) and compiles them
together. That driver is Phase 6's enabler; the blob goes when it lands.

**The `export` block.** A `.mid` module declares its Osier-visible surface in an `export` block,
written in **Osier type syntax**:

```
export Rt.read-file-as-string : Val Int -> Val Int
export Rt.malloc               : Word -> Word
export Rt.exec-run             : Word -> Word -> Val   !io
```

One line per exported defun; the key is the defun name verbatim; `!io` (or whatever effect marker
Osier adopts) marks an impure export. Unexported defuns are module-private.

**The type mapping — three classes, REPRESENTATION-PINNED:**

| mid-c | Osier | why |
|---|---|---|
| `val` | the **boxed** value type (`Val a`) | the tagged constant. S4/S4f unboxing must NOT cross this boundary (boxed scalars are rejected at it) — a `val` parameter arrives boxed whatever Osier does to an `Int` internally. |
| `float` | `Float`, boxed / ABI-pinned | §2.1 and §3 already refuse to trust a Float **parameter** for unboxing; a cross-module call can trust it less. |
| `word` | an **opaque `Word`** (locally abstract) | a raw machine word — pointer-or-int, convention-only. It must NOT unify with Osier `Int`, or every C pointer becomes arithmetic-addable. Osier's locally abstract types (λρG) are the tool. |

**Checking (bidirectional; the seat already exists).** `Mid.RtLang.Check`'s **J1** already proves each
mid-c parameter is used only in positions of its declared class; the Osier side is checked against the
declared Osier types. The `export` block is the join. The compiler's **`externArities`** table — today
arity-only, "extern seats are all-`:val`" (`Check.elm:187`) — is the seat that becomes the **typed
extern table**. A mismatch is loud at one end or the other.

**The three contracts a type check cannot carry** (build the seat, state the gap):
1. **ROOTING.** A `val` argument is a GC reference: it must survive the callee's allocations and must
   not be stashed where the collector cannot see it. The mid-c frame machinery roots; the contract
   must be STATED at the interface.
2. **IMMUTABILITY.** Osier values are immutable; mid-c has `wstore`. Mutation must be reachable **only
   through `word`/raw, never through `val`** — otherwise handing an Osier value to mid-c breaks the
   language's core assumption.
3. **EFFECTS.** Impure exports carry the effect marker; Osier's purity discipline must not be silently
   violated.

Plus **ARITY**: declared and flat (Osier is curried, mid-c is flat) — the one thing `externArities`
already does today.

**Status:** design settled here; NOT built. It rides Phase 6 (the driver) and is a prerequisite for
`import`ing mid-c from Osier.

---

## 3. The plan

### Phase 0 — done (context for the rest)

ZINC/VM retirement and the Mid-tier runtime. Commits worth knowing: `0258326` (A: direct per-prim
calls, suite −38.4%), `6e6d6b1` (C: `rt_tail_known` staging CONFIRM; `rt_string` interning
**UNDECIDED** — the first oracle in this sequence to be contradicted by measurement), `51a59cb`
(Mid node set + `Mid/Audit.elm`), `19dd5b3` (cons end-to-end, consdiff 14/14), `cea1ce6` (the
remaining pure prims, primsdiff 92/92), `8f581b8` (pre-flip fixes), `b6e4990` (**the flip**: Mid
route default, 35 Zig handlers deleted).

### Phase 1 — midabi: the Rt lean ABI  ✅ DONE (PARTIAL) — commit `2d127d1`

**The problem it fixed.** The flip took the Mid route's win and traded pass A's away: a prim
compiled as an ordinary Mid defun paid `:val` by-value 40-byte args, `rt_frame_enter/leave` and
`rt_bounce` where pass A's purpose-built wrappers paid none. Suite 1273 → **3333 ms**.

**What landed.** Every `Rt.*` defun lowers with pass A's convention: 3 pointer params (padded with
the last real slot's address) + a count word, a **direct `:val` return** (no `:ret`, so no
`rt_bounce` on any Rt→Rt edge), one blit to dest. The frame is chosen **per defun** from
`Mid.Rt.allocating` (a whole-tree safepoint walker + a fixed point over `rtDeps`): `PFrame`
(`rt_frame_enter`'s pooled ROOTED block) when the body can reach a GC safepoint, else `PAlloc` (a
plain `alloc8` — a compile-time QBE frame slot, unzeroed and never registered as a root, sound
because roots are precise and no collection is reachable there). `QBE_NORTLEAN=1` is the hatch.

**Result — REFUTE against ≤1273 ms, PARTIAL recovery −49.1%.**

| arm | total | |
|---|---|---|
| PRE (pre-flip post-pass-A binaries) | **1292 ms** | same-day control; it vindicates the historical 1273 |
| LEAN (`QBE_NORTLEAN` off, default) | **1750–1783 ms** | my runs 1742, 1761 |
| FAT (`QBE_NORTLEAN=1`) | **3398–3503 ms** | the flip's shape |

So the regression is **+38% where it was +171%**, and 92% of the residual is record-shaped:
recflow 1.60x, recupd_local 1.51x, recupd_param 1.48x, adtmatch 1.46x, mono_record 1.36x versus
the other seven programs at 1.08–1.22x. INTERPRETATION (undiscredited): that is per-prim-call cost
on assoc-list record walks — exactly what **E** deletes. **The design fact the brief asked to stop
on is therefore answered narrowly: a lean general Mid defun is not inherently worse; the record
programs simply have more prim calls to make.**

**Three bugs it was carrying, each of which had made a green tree unsound** (fixed in `2d127d1`):
`TestMain` filtered for `q_Rt__x2b` where the emitted name is `q_Rt_x2e_x2b`, so a row fell to its
empty-list branch — the claim it guarded had never been verified; `Mid/Rt.elm` referenced a
let-binder defined below it, which elm 0.19.2 accepts and **the tree's own front end rejects**
(`--freeze` exit 2); `selfhost/NativeMain.elm` still said `midCons=False`, so the *native* compiler
emitted a deleted route.

### Phase 2 — B: monomorphisation (S5)  ✅ LANDED — verdict REFUTE, KEPT BY OWNER DECISION

**OUTCOME (2026-10-11).** The specialiser exists: `Mid/Qbe/Monomorphise.elm`, default ON, hatched
by `QBE_NOMONO=1`, plumbed `run.js → Main.elm → QbeModule → the pass` with the selfhost flag vector
updated. Committed as **`00cc7da`**. It passed every oracle (gate 154/0, `qbe-check` 270/0, corpus
149/149, TestRun 111/111), and `QBE_NOMONO=1` reproduces `159198d`'s committed corpus baseline
BYTE-FOR-BYTE 149/149 — the attribution hatch holds. **The pre-stated bar returned REFUTE**
(mono_int +1.5%, mono_float 0.0%, A/A spread up to 6%).

**WHY THE BAR COULD NOT HAVE SAID ANYTHING ELSE — read this before re-running the axis.** Across all
twelve suite programs the pass engages in only three, and the SEVEN clones it produces are all
90-line bodies differing from their originals by EXACTLY ONE LINE (a shared data label). On the
suite the clone is an instruction-identical copy; nine programs engage it not at all. The bar was
pre-stated, honest, and **blind**: its instruments provably cannot see this pass.

**THE MECHANISM IS REAL AND ITS CEILING IS THE BOXED ABI.** On the purpose-built probe
`tools/bench/monoarith.elm` (arithmetic on the POLYMORPHIC parameter — the suite's mono axis puts it
in a closure, where a clone cannot unbox anything), the clone is 80 lines vs 154, frame 16 → 10
slots, and fallback calls **4 → 1** (`<` and both `-` go raw; self-calls rewritten). Timed under the
mandated protocol there (15 runs/read, median, arms alternated, 2 sessions): 47.6 → 47.5 ms,
**−0.2%**, A/A spread 0.4 ms. Root cause, read off the emit: the clone removes tag tests and
fallback calls, but every argument and result is still a boxed `Value` (identical allocation/GC
pattern) and every self-call still pays `rt_bounce`; worse, the reused S4 machinery (`intParamsOf`)
can only prove a value `Int` when it is a PARAMETER, so `+` on two call RESULTS stays dynamic even
in a clone that is Int everywhere.

**KEPT, not reverted** (owner decision, 2026-10-11): it costs nothing measurable and is expected to
pay once the REPRESENTATION changes in phase 3/E — the pass is the consumer that makes unboxing
worth having. Carried cost, stated honestly: +1.958% of emitted corpus `.ssa` (+136 KB over 149
artifacts) for no current win, and it is ON by default. Full evidence: `handoff-osier-mono-s5`
(+ `-result`, `-review`).

**The design record that follows is historical (the brief this unit executed).**

**Why.** The checker's type table (`Mid/Qbe/Types.elm`) covers 316–320 defuns of ~882 keys, and
only **90–95 are monotypes**; S4/S4f's unboxing (deny-by-default) therefore reaches about a third
of tabled defuns. The rest need a **specialiser**. Concrete mechanism, MEASURED on
`tests/elm-fixtures/fib.elm`: `fib n = ...` has **no annotation**, so it generalises to
`number -> number` — polymorphic — and its `+ - <` route through real `q_Rt_*` calls (5 functions
in the `.ssa`, 4 `q_Rt_*` defined and all 4 called, 0 `rt_prim_*`). Cloning `Fib.fib` at `Int`
is what makes those disappear.

**Steps.** S1 (defun-level table, zero-touch schemes) ✅; **S2/M0b** ✅ (`159198d`): the per-binder
map, **additive** — a write-only `nodeTypes` on `InferState`, ONE hook wrapping `inferExpr` (body
renamed `inferExprGo` so every recursive site records), one zonk in `inferUnit`; no
`unify`/`discharge`/`rewrite` touched, proven by corpus byte-identity 149/149. Also the
binder-id↔`Range` join, emitted by `FromAst` at issue time. **S5/M2** 🔄: `Mid/Qbe/Monomorphise.elm`
— clone-do-not-replace, key `defunKey + "$" + pretty monotype`, worklist from entry reachability,
trigger = saturated direct calls with a `GRef` head, `QBE_NOMONO=1`, unboxed specialist params at
direct calls only (first-class/`rt_apply` flow keeps the boxed original), `completeArities`
ordering preserved, **and the specialist must refuse `Rt.*` keys** (hand-built, absent from the
type table).

**The refusal predicate is the research-specific risk — deny by default.** Refuse any
instantiation containing (a) a `TVar`/open row tail, (b) a `scheme.bound` variable (GADT indices +
`type x a.` prefixes), (c) **any variable mentioned by the unit's `refinedTypeEqs`**. A
branch-local refinement is valid *only inside its branch*; cloning on such a monotype bakes a
branch-scoped fact into a body that runs outside it. Under boxed `Value` that merely wastes code —
once params are unboxed it is a **wrong answer**. MEASURED stakes: `hlist2` has eqEnd **14/15**;
`gNeg_letcase` and `probeA_neg` are checker-REJECTED by design and cannot serve as fixtures.

**Verdict rule.** CONFIRM only if `mono_int` **and** `mono_float` drop ≥20% (≤54 ms / ≤62 ms of the
current 68 / 77) **and** the static counters move. REFUTE if both <10%, or if time improves while
counters do not. UNDECIDED at 10–20%. `mono_record` <10% is **pending, not refuting** (its payoff
is phase-3 fields).

**S5 additionally needs a THIRD additive field, and correctly says so.** `nodeTypes` alone cannot
supply refusal clause (c): a zonked type *shows* a refined variable as a `TVar` but does not
**mark** it as refinement-touched, and `refinedTypeEqs` keeps only `KType` equations (bodies are
dropped at branch end). So S5 adds `refinedVars` = the union, over pushed branch equations, of the
target id and the free variables of its body — accumulated **monotonically** onto
`state.refinedVars` with membership dedup, in `unifyBranchM`, exactly the shape of the existing
`refinedTargets` (the clause-level record that already survives branch end by design). Same
additive claim as `nodeTypes`: a pure recording of state the checker already computed, read once
at unit end. It is per-unit var-id namespaced, so a consumer must intersect a defun's
binder-type variables with **its own** unit's set only.

**S6/M3 (unboxed aggregates) is DEFERRED and its precondition has CHANGED**: the mono plan gated
it on "owner approval for `vendor/zinc-vm`", but the VM was deleted in P8. The packed record layout
and its GC layout descriptor now belong to the **new mark-sweep** (§2.2), not to a VM that no
longer exists.

### Phase 3 — E + (A), ONE epoch  ✅ LANDED — commit `42abb97` — verdict **CONFIRM** (adtmatch UNDECIDED)

**OUTCOME (2026-10-11).** Implemented as one epoch (`handoff-osier-ea-impl-ctx/-result`, tier `engineer`),
reviewed (`handoff-osier-ea-review`), the review's three blockers fixed, and re-reviewed CLEAN. All
oracles green **including `zig build test` 38/38** (which the first pass omitted and which was RED —
see below). Tree uncommitted.

**The measurement — RE-RUN 2026-10-12 after the host was found loaded** (the first pass measured on a
loaded machine and reported a spurious `adtmatch` regression). Orchestrator-run,
`OSIER_BENCH_RUNS=7 OSIER_BENCH_STAT=median`, 2 sessions, arms alternated `default` vs `QBE_NOREC=1`,
load snapshotted per arm (~8–10 on 32 cores — still NOT a quiet window):

| program | E-ON | E-OFF | ratio |
|---|---|---|---|
| recflow | 64 / 62 | 305 / 295 | **4.8× faster** |
| recupd_local | 84 / 80 | 391 / 385 | **4.7× faster** |
| recupd_param | 67 / 60 | 505 / 510 | **8.0× faster** |
| mono_record | 167 / 161 | 441 / 331 | **2.35× faster** |
| **adtmatch** | 165 / 154 | 164 / 155 | **1.00× — NEUTRAL** |
| total (5) | **547 / 517** | 1806 / 1676 | 3.3× faster |

**Verdict: CONFIRM** on `recflow`/`recupd_local`/`recupd_param`/`mono_record` — every effect is far
beyond the A/A spread (E-ON 547/517 = 5.8%; E-OFF 1806/1676 = 7.8%). **`adtmatch` is UNDECIDED** (1.00×
sits inside the spread), *not* the REFUTE the loaded run suggested — same-session E-ON 165 vs E-OFF 164
is dead even. `mono_record`'s never-tested "<10%, pending, not refuting" claim is **resolved in E's
favour** (2.35×).

**LOAD SENSITIVITY — a trap for this repo's discipline.** Absolute totals are NOT comparable across
sessions while the host is loaded: the same tree measured `adtmatch` 222 and `mono_record` 248 in the
loaded run and 165 / 167 in the re-run, and the pre-fix suite total (933/964, un-snapshotted load) is
below the post-fix (1079/1061, load ~6.5). **Only within-session alternated pairs are evidence** —
snapshot the load with every arm, and never compare a total against another day's total (§1.3's
quiet-window caveat, paid for here).

**The three blockers the review found (all fixed and re-verified — the class is the lesson):**
1. use-after-free: `Rt.recAppend` built the names array in the nursery while `scan.zig` evacuated the
   record's `data` word only (comment falsely asserted names was static). Probed: segfault 139 → 123.
2. silent wrong answer: `recAppend` stored the new field at index `len` instead of its sorted position,
   so closed-site positional reads returned the wrong field — and the gate's own `insrec.elm` passed
   **by cancellation** (1+99+5 == the expected output). Probed: 1 → 123.
3. `zig build test` RED (36/38) and **in no oracle** — `gc_test.zig` still built the classic two-cell
   cons. The collector's memory-safety net was failing while every language oracle was green.

**The transferable lesson (recorded in §6):** the implementer's "all oracles green ⇒ complete" was a
true statement about the **wrong instruments** — the battery pins compile output and language
behaviour, and the two worst bugs are exactly the class green language oracles **cannot** see. The
runtime's own test suite was in no oracle at all.

**The `(A)` hatch is EMIT-ONLY.** `QBE_NOCONSARR=1` alone makes `mono_record` halt (32 ms, "a Mid prim
reached its halt arm"); with `QBE_NOREC=1` it core-dumps. It emits the fused 2-word cons
(`RtPrims.elm:1620-1690`) whose stored `cdr` the new runtime never evacuates. It satisfies §1.2
(it reproduces the `00cc7da` **bytes** — 148/149, `remrec.ssa` the one exception, cause
`Prelude.removeFieldImpl → recToChain`, flag-independent) but it is **not a usable runtime arm** and
must never be used as a measurement control. Document it as emit-only.

**Committed** as `42abb97` (the epoch), `a53aa2b` (`zig build gate` wired into
`tools/osier-numbers.sh` as step 6 — the oracle hole that let three blockers past a green battery is
closed), `42fff12` (the `todo-osier.md` refresh). **Not pushed.**

**Still open:** `recUpd`/`recInsert`/`recAppend` primsdiff batches (accepted residual — no Zig
reference arm; `recGet` IS now fired, 4 Mid call sites); and a **quiet-window** re-run of the record
arms, if this host ever offers one.

See §2.1 (E), **corrected 2026-10-11** — the plan for this phase is `handoff-osier-phase3-ea-plan`
(7 + 4 `stage=plan` observations; the refinement supersedes the first pass's interleaved-names design).

Scope, in the corrected design:
- **(A) first**, and the runtime change and the Mid cons change land **in one step** (or the cons
  differential stops being meaningful): `gc/types.zig:21` `record` tag 13→14; `gc/scan.zig:35-58`
  (the fused-pair dual-shape test dies, cons merges into the vector arm),
  `rt/values.zig` (`valCons` one allocation, `printValue`/`strValue`/`deepEqual` read `cdr` via
  `data[1]`), and **`cons.cdr` readers in five files, not three** — also `rt/prims.zig:226,232,311,413`,
  `rt/execplan.zig:220,229-230`, `gc/collect.zig:790` (`verifyPtr`) — grep-guard after the change;
  `Mid/RtPrims.elm:1036` `consDefun` `RawMkValue` 2→1 word. Hatch `QBE_NOCONSARR=1` must reproduce
  `00cc7da` 149/149.
- **(E)**: `Lower.elm:3887-3929` `buildRecord*` + `VField` sites (`:3593-3617`) → the positional-vector
  + static-names lowering (§2.1); new `Rt.recGet`/`Rt.recUpd` in `Mid/RtPrims.elm`; `eqDefun`/`deepEqArms`
  tag-14 arms; printer record arms; the `calledPrims` census (`:592-600`, `:1041-1047`, `:677-688`)
  updated to mirror the new lowering exactly. Hatch `QBE_NOREC=1`. `QBE_NOREC=1 + QBE_NOCONSARR=1`
  reproduces `00cc7da` 149/149; both flags also go into `selfhost/NativeMain.elm`'s hard-coded vector.
- **The new Mid node is authorised** (my earlier "no new Mid node" was a *scope observation* — E maps
  onto existing nodes — not a rule; it wrongly blocked this design). `RawDataAddr (List String)`, an
  `Unsafe`-class word producer built in `Lower`; blast radius is mechanical and verified:
  `Mid/Ir.elm`, `Mid/Audit.elm` (`nodeName` arm **only** — the node's trees are transient and outside
  the audit's domain), `Mid/Rt.elm` (`unsafeSafepoint → False`), `Mid/Qbe/Monomorphise.elm`
  (`unsafeChildren → []`, `unsafeRebuild → identity`), `Mid/Qbe/Lower.elm` (the `rawWordArg` arm + five
  exhaustive `case` matches). `FromAst`/`Module`/`QbeModule`/`Flatten`/`rt.zig`: **zero changes**.
- **Three goldens MOVE BY NECESSITY** — `record.txt`, `record-upd.txt`, `censusseats.txt`: field names
  are no longer printable from a vector, so the printer cannot reproduce the old assoc dumps. The
  "goldens stay byte-identical" claim holds for every **non**-record golden (only `rowgadt_eval.txt`
  contains a cons, and it is a tuple). Re-freeze deliberately, with the reason. `qbe-check`'s
  **count-based** structural rows (`flatten-structural`, `noflatten` escape counts, `censusseats`
  seats) change premises too — re-derive them with the same A/B discipline, never weaken to pass.
- `Rt.assoc`/`Rt.assocGo`/`Rt.snd` drop from seeding (the chain route survives only as the tag-4
  fallback for host-built records). `primsdiff` batches must be re-verified non-tautological.

**Land F first if the lane is free.** F = `Flatten`'s `rwBinders` linearisation (one use-collection
traversal feeding `usesOK`; today it scans the whole remaining scope per candidate binder —
quadratic in principle, 0.04% of emit). It is compile-time only and `.ssa` byte-identical, and the
mono plan says land it **before** E grows Flatten's domain.

**E OWNS THE S5 PAYOFF — re-measure it, with the right instrument.** Phase 2's verdict is that the
specialiser fires but its win is capped by the BOXED ABI, so the representation change is what makes
the clone worth having: once a record/cons is positional and its fields are raw, a clone's
arithmetic can stop boxing. So E must re-run the mono axis — and NOT on the suite, whose mono
programs are provably inert for this pass (7 clones, all differing from their originals by one data
label; 9 of 12 programs engage it not at all). Use `tools/bench/monoarith.elm` (the arithmetic on the
polymorphic parameter) with the §1.3 rule, arms alternated (QBE_NOMONO=1 vs default), plus
`mono_record` as the record-shaped axis (`osier-bench.sh:408`). Also re-check `mono_record`'s own
latency: the claim that its <10% is "pending, not refuting" has never been tested with the pass in
the tree. **Pre-stated E bar:** ≥90% of record build/get sites in the suite `.ssa` emit the positional
form **and** the five record programs (recflow 1.60x, recupd_local 1.51x, recupd_param 1.48x,
adtmatch 1.46x, mono_record 1.36x) move toward the 1.08–1.22 band beyond the A/A spread.

### Phase 4 — the fresh mark-sweep  ⏭

See §2.2. Delete on the way: the `mark` `ValTag` (`valMark` has **zero callers**) and 3 of the 5
`GcTypeTag`s (`instr_array`, `callframe_array`, single-cell `value` — no producers; the live heap
has exactly two object kinds, `value_array` and `raw`). The `<=7B` word-padding tail of `raw`
stays dirty but nothing reads it. Barriered stores become plain stores. Oracle: a Zig-GC vs Mid-GC
churn differential across `QBE_HEAP_MB` sweeps plus the suite rule.

### Phase 4b — retiring Zig: the runtime written in Mid  ⏭ (plan pass DONE — gate NOT REFUTED)

**PLAN PASS `handoff-osier-zigretire-plan` (12 `stage=plan` observations) — it RAN the decision gate,
it did not merely specify it.** It reconstructed the pre-flip Zig arm (commit `8f581b8`) from
`git archive` in /tmp and benchmarked it against HEAD, arms alternated, `loadavg` snapshotted per arm.

**GATE VERDICT (owner decision 2026-10-12): NOT REFUTED, with `adtmatch` a NAMED, BLOCKING
EXCEPTION — and the gate is SPLIT.** Stages 1–2 (emit-inert) proceed and are DONE; the collector
(stage 4) is justified by leg (ii); **stages 5–6 (the allocating seats and the ABI swap) are BLOCKED
until `adtmatch`'s regression is explained.**

Stage 0 was re-run with the FULL protocol (4 sessions × 7 reps × median, arms alternated, `loadavg` per
arm; `Z` = a real `git archive 8f581b8` build, `M` = HEAD, `M2` = the HEAD A/A twin, `MNOREC` = HEAD
with `QBE_NOREC=1`):
- leg (a) **default route**: record/cons programs **3–5× faster** on `M` (recflow −70…−76%,
  recupd_param −82…−86%, recupd_local −70…−75%, mono_record −30…−39%) — E's win reproduces against the
  real Zig arm. Route penalty on the rest: numloop ~0%, mono_int ~+3%, localrec ≤0%, **nestagg
  +5…10%, listbuild +2…13%, mono_float +10…28%, `adtmatch` +26…+45%**.
- leg (b) **churn — the collector's own stress shape**: `M/Z` inside **±9% at every heap**
  (16/32/64/128 MB) against a +50% bar → **not tripped**. The frozen Zig-GC baseline reproduces at
  `QBE_HEAP_MB=16` (Z 23 ms cold / 35 ms warm, M 21/36).
- leg (c) **fallback walks** (`QBE_NOREC=1`): recflow +55…+60.5%, recupd_local +44…+49%, adtmatch
  +33…+41% — against a >+60% bar → **not tripped**, but recflow sits *on* the line (over in 1 of 4
  sessions), so that residual is bounded, not cleared.

**THE EXCEPTION — ATTRIBUTION CORRECTED BY REVIEW (2026-10-12), and the correction moves the owner.**
The implementer's first attribution ("per-call cost on an ALLOCATION-heavy program") is **REFUTED**.
The reviewer ran 7 scratch variants, each compiled with BOTH compilers and alternated: 400k
equality+arith prim calls with **no alloc → 0%** gap; 400k **string**-equality, no alloc → **+20–25%**;
**one** alloc + one case/round, no recursion → **+55%**; 6 allocs + case + recursion +44%; 3 allocs
+26%; 6 allocs flat +12%; 4 arith prims only 0%. **Allocation is EXONERATED** — `rt_con` is the same
Zig seat in both arms and the gap does not scale with allocation count. The residual is the **Mid
equality handler (`q_Rt_x2e_x3d`) on its non-numeric paths** (string → `bytesEqGo`, symbol → nested
`symEq`) under the lean-ABI protocol, hit at **case-dispatch density** — constructor tag tests lower to
`x3d` calls, ~1–4 per eval, ~1M per `adtmatch` run.

**Consequence for the gate:** the block on stages 5–6 was justified by a mechanism that is now refuted.
`adtmatch`'s residual is **stage 3's deliverable** — stage 3 kills the `rt_prim` fallback and routes the
equality prim directly, which is exactly this cost — so **leg (i) becomes stage 3's acceptance test**
rather than a blocker on 5–6. Stages 5–6 stay gated on stage 3's exit condition (zero `rt_prim` sites)
and on leg (i) closing. The `QBE_NOREC=1`/default ≈2-point agreement is still what proves the
**representation** is not the cause; §3 Phase 1's "92% record-shaped" was nonetheless wrong about the
whole, and Phase 3's CONFIRM is about the record axis only.

**STAGES 1–2 — LANDED (uncommitted, `REVIEW NEEDED = review`).** Stage 1: `RawWordLoad`/`RawWordStore`
across all six seats, **emit-inert** (corpus BYTE-IDENTICAL 149/149, qbe-check 270/0 — nothing emits
them yet); `unsafeSafepoint` **recurses into the operands** (the node allocates nothing, but a nested
operand can — the brief's literal `False` would have misclassified a defun as frame-free). Stage 2:
`Mid/RtLayout.elm` as the single layout definition, with readers derived from it, a **census**
(`tools/qbe/layout-census.sh` + a Zig probe) generating a committed `layout_gen.zig`, and
`abi-fingerprint`'s layout component taken from the census digest. One-seat-breaks-one-gate re-proved
four ways. **Honest gaps it stated:** the census probe cannot import `rt.zig` (it exports `main`), so
`Desc`/`Meta`/`Ret` are comptime-only, and `rt.zig`'s comptime row is compiled by `rt-o.sh` — **not by
`zig build gate`**, so half the layout contract is outside the suite wired in at `a53aa2b`. Oracles:
`osier-numbers.sh` exit 0 (gate 154/0, corpus 149/149, TestMain 111/111, GC suite 3 modes, seed FRESH),
seed re-frozen 18,746,694 B, node-free bootstrap with node+elm stubbed: 0-byte invocation log.

**THE BAR WAS UNDER-SPECIFIED — the gate's bug was in its control, not its measurement (new trap, §6).**

**TWO FINDINGS THAT DE-RISK THE ABI STAGE:** `main` as a Mid defun is **measured-expressible** — the
vendored qbe assembles `export function w $main(w %argc, l %argv)` and `Print.elm:222` already emits
export-function (`rt_callN` does this today); and **the runtime is already largely injected** (the flip
put **21,086 `q_Rt_` sites** in the seed), so the `.ssa`-growth projection is +5–15%, inside the ≤2×
guard. The named swap gap: `RawCallRaw` is word→word but `rt_apply` needs an aggregate (`:ret`)
returning call — a small node extension (`Il.Call` already carries aggregate results).

**SETTLED STAGING:** 0 gate (full 2-session protocol, implementer re-runs) · 1 `RawWordLoad`/
`RawWordStore` (emit-inert; corpus byte-identity + 270/0) · 2 **one layout** in a new `Mid.RtLayout`,
with Zig proven equal by a census (not assumed) and `abi-fingerprint` re-derived from it · 3 **kill the
prim fallback FIRST** (`Lower` still emits `rt_prim` for float/eq and the fd/state prims; exit condition
= ZERO `rt_prim` sites, so `prims.zig`'s dispatch dies *at* the swap) · 4 the mark-sweep in Mid
(`Mid.RtGc`, trigger inside the Mid allocating seats; differential = churn sweeps vs the frozen ~39 ms
baseline, hatched) · 5 allocating seats / values helpers · 6 **the ABI swap — `rt.zig` dies**
(`QBE_MIDDRIVER=1` as the attribution hatch) · 7 effect loop — **MANDATORY, NOT A GO/NO-GO (owner decision 2026-10-12: "its not no/go-go, i want to
remove the zig dep").** There is NO "keep the Zig effect loop" end state. Two acceptable finishes, both
ZERO ZIG: (i) the effect loop ported to Mid, or (ii) replaced by Phase 5's Lua host shim.

**RANKED RISKS:** the unsafe surface with no static checking (per-seat fail-before/pass-after probes);
the layout known twice; the +29–52% fallback-walk penalty; the fallback not dying (stage 3's exit
condition); seed/bootstrap (all 14 `Mid/*` files are seed-bearing; `--verify` stays unrun); the
effectloop surface; the SEGV stack-guard diagnostic; emit-time growth; the loaded-host trap.

**Honest exit if the bar trips:** keep the Zig GC/ABI, move the rest to Mid.

**STATUS (2026-10-14):** stage 0 DONE (gate NOT REFUTED, owner: `adtmatch` a named exception; the gate is
SPLIT) · 1 DONE `64515c6` · 2 DONE `64515c6` · **3 DONE (UNCOMMITTED, all sub-groups landed) — `e3091bb` +
GROUP 1 (fd, `df00ff9`) + GROUP 2 (value/intern/str, `da6b45b`) + GROUP 3A (getpid/getcwd/cd/getenv/setenv) +
GROUP 3B-1 (glob) + GROUP 3B-2a (exec-plan DECODE in Mid, `a8ed9fa`..) + GROUP 3B-2b (exec-plan RUN in Mid,
`2f8f136` — Rt.execGo, a single self-tail STATE-MACHINE defun over a malloc'd run-state block because the
3-arg lean ABI forbids the mutually recursive runProgram/runPipeline pair as separate defun calls: modes
program-loop / pipeline-dispatch / pipe-loop / fork-loop / wait-loop / funnel / kill-loop, with
applyRedirects, childBuiltin (echo/true/false/:/cd/pwd), the heredoc tmpfile wiring and waitStatusCode as
helpers, all over RawCallRaw libc seats; the blob gained a tmpfd slot (epRedirWords 5→6) and an argv NULL
terminator; the rt_exec_run seat SHRANK to the SLURP+RESULT half; new gate rows execchain (the multi-chain
&&/|| short-circuit) + execnofile (the redirect-open-failure path), both with the ZIG arm's own output as
golden) + GROUP 3B-3 (read-file-as-string in Mid — `Rt.read-file-as-string` + the C-heap read loop
`Rt.readFileGo` + the byte memcpy `Rt.memGo`, one malloc'd 72-byte state block, malloc-new/copy/free-old
growth, readFull for Zig's EINTR-retrying std.posix.read parity, the stderr note + "" on ANY open failure;
new gate row readfile (existing/missing/empty/70000-byte arms) with the ZIG arm's own output as golden) +
GROUP 3B-2c (exec-plan SLURP+RESULT in Mid, UNCOMMITTED — `Rt.exec-run` arity 3: lseek-rewind +
`Rt.readFileGo` per capture fd into ONE shared 72-byte C block + 65536 tmp (acc/len/cap RESET between the
two slurps), then per stream ONE `RawAllocRaw(len+1)` + memGo copy + NUL + free-acc + mkStr, then the
TAGGED tree in Zig's root-dance order (each intermediate a rooted frame binder — the direct Mid form of
the rootPushValue dance); the rt_exec_run seat, ep_result_slot, slurpFd's pub and Rt.elm's MANUAL
OVERRIDE are all DELETED (Rt.exec-plan is classified allocating through its rtDeps edge to Rt.exec-run);
new gate row execbig (the >64 KiB slurp GROW through exec, golden = the ZIG seat's own output)) —
**THE EXIT CONDITION (zero `rt_prim` sites) IS MET, BY EMISSION: 0 rt_prim sites across all gate
groups (was 11, all read-file-as-string, at `2f8f136`; 117 at the stage's start, `64515c6`). The exit
condition had stood unmet since `e3091bb`.** What still lives in Zig BEHIND the bridges:
`rt_ss_*`/`rt_sym_intern`/`rt_value_slot`/
`rt_float_text` (stage 6, die with rt.zig), and the HOST effect loop's own readFile leaves (stage 7 —
the async host path, not the worker prim this stage converted). Stage 3 CLOSED the real residual it found —
`adtmatch` 1.443 → 1.072 (`Rt.=`'s symbol path was a byte walk, one lean-ABI call per byte; now a
pointer-identity fast path with a gate guard proven fail-before/pass-after). **4 (the collector in Mid)
is NEXT**; 5–6 were gated on stage 3's exit condition, which is now the open item rather than the
`adtmatch` residual.

**BRIDGES — every temporary Zig dependency, named, with the stage that removes it (2026-10-12).**
The end state is **ZERO Zig**; the owner's direction is explicit and the whole phase exists to get
there. So any Zig dependency a stage introduces is a BRIDGE, and each one is listed here with its
removal stage — a bridge that is not on this list is not allowed to exist. (This is the repo's
"build the seat, put the honest current value in it, state the gap explicitly" rule applied to the
retirement itself.)

| bridge | introduced by | removed by | why it is needed |
|---|---|---|---|
| the Zig collector (`gc/*.zig`) | pre-existing | stage 4 complete + its coverage ported, deleted at the swap | it is the ORACLE for the Mid collector's differential |
| 4 root seats `rt_gc_roots_len` / `rt_gc_root_kind` / `rt_gc_root_slot` / `rt_gc_root_np` (`tools/qbe/rt.zig:548-560`) | stage 4 | **stage 6** — they die with `rt.zig`, by construction | the root set IS the frame machinery (`rt_frame_enter`'s pooled ROOTED block), which is ABI; stage 4 cannot own roots without owning frames, which is stage 6's job |
| `rt_gc_heap_bytes` | stage 4 | stage 6 | harness fairness only: the Mid collector mmaps a region of `main`'s `QBE_HEAP_MB` so the churn differential's heap sweeps steer BOTH arms alike |
| `rt_vec_store_plain` | stage 4 | stage 6 | the non-barriered store the mark-sweep needs (Phase 4: "barriered stores become plain stores") |
| `rt_midgc_die` | stage 4 | stage 6 | a loud-failure seat carrying a message table — the C-level abort mechanism folds into `rt_halt`'s class; **the MESSAGE TABLE (six strings) folds into whatever Mid-level halt stage 6 provides** (it is Mid's data held in Zig today) |
| **`rt_midgc_region` / `rt_midgc_set_region`** | stage 4 | **REMOVED (stage 6 U1c)** | they held the Mid collector's region pointer in a **Zig global** (`var midgc_region: i64`); the gap they recorded ("Mid has no mutable-global-state facility") is **REFUTED** (plan correction C3, MEASURED: `vendor/qbe/emit.c:92` puts an all-zero data def in `.bss`, writable). The pointer now lives at word 0 of the Mid-owned globals block `export data $rt_glob = { z N }` (`.bss`), addressed through the Lower-built 0-arg accessor `rt_glob_addr` (`ret $rt_glob` — a global symbol is a legal `l` ret operand), read/written with the existing `RawCallRaw` + `RawWordLoad`/`RawWordStore` at `RtGc.elm`'s six former `callW` sites. Both seats deleted from `rt.zig` (`rg 'rt_midgc_region' tools/qbe/rt.zig` is empty, as this row demanded); the block + accessor are emitted gated on QBE_MIDGC so the default route stays byte-identical. |
| **`q_Rt_x2eallocVector` (exported Mid seat) + rt.zig's weak-extern `midgc_alloc_vector` / `midgcVecAlloc`** | stage 5 PART 2 | **stage 6** | the Zig→Mid direction of the apply path: `applyGo`'s partial arm allocates the partial's env array from the MID collector by calling the exported `Rt.allocVector` seat (a WEAK extern, resolved to a zero address when the hatch is off — that is the ON/OFF discriminator). It dies with rt.zig at the swap (the partial arm becomes Mid anyway) |
| the frame/apply/bounce ABI, `main`, the prim fallback | pre-existing | stage 6 | it is the ABI the generated code links against |
| `src/effectloop.zig` + the host/streams surface | pre-existing | **stage 7 — MANDATORY** (ported to Mid, OR replaced by Phase 5's Lua host shim); NO "Zig survives here" option (owner decision 2026-10-12) | host I/O |
| **`rt_ss_in` / `rt_ss_readbyte` / `rt_ss_close`** (`tools/qbe/rt.zig`, alloc-free word→word) | stage 3 GROUP 1 (the fd prims) | **stage 6** — they die with `rt.zig`; the Mid fd bodies re-point to the Mid-owned string-stream registry (the stage-7 "8 raw-blob slots in the Mid driver state") | the compiled Mid `open`/`read-byte`/`close` bodies reach the Vm-owned string-stream registry while `rt.zig` still owns it |
| **`rt_sym_intern` / `rt_value_slot` / `rt_float_text`** (`tools/qbe/rt.zig`, alloc-free word→word; page_allocator / static BSS only — no GC) | stage 3 GROUP 2 (the value/intern/str prims) | **stage 6** — they die with `rt.zig`; the Mid bodies re-point to the Mid-owned state (values table / symbol interner / a Mid float renderer) at the swap | the compiled Mid `value`/`intern`/`str` bodies reach the Vm-owned values table, the symbol interner and `values.floatText` while `rt.zig` still owns them |
| `rt_root_push_value_array` | stage 6 U1b | stage 7 | the Mid frames register roots into the Zig shadow stack (C1) |
| `rt_root_push_value` | stage 6 U1b | stage 7 | the Mid frames register roots into the Zig shadow stack (C1) |
| `rt_root_push_ptr` | stage 6 U1b | stage 7 | the Mid frames register roots into the Zig shadow stack (C1) |
| `rt_root_pop` | stage 6 U1b | stage 7 | the Mid frames register roots into the Zig shadow stack (C1) |
| `rt_root_watermark` | stage 6 U1b | stage 7 | the Mid frames register roots into the Zig shadow stack (C1) |
| `rt_root_pop_to` | stage 6 U1b | stage 7 | the Mid frames register roots into the Zig shadow stack (C1) |

**A check so stage 6 cannot forget:** at the swap, `rg 'rt_gc_root' tools/qbe/rt.zig` must be EMPTY
and no `Mid/*` defun may call the seats — assert it as a row rather than trusting the list above.
**And a rule for stages 4–5:** if you must add a new Zig seat or symbol, ADD IT TO THIS TABLE with its
removal stage in the same change. The failure mode this prevents is a bridge nobody remembers — the
reason "roots stay in Zig" reads as a permanent design in a stage-4 report.

**STAGE 7 PLAN — `handoff-osier-zighost-plan` (2026-10-12, 12 `stage=plan` obs). PREMISE NOT REFUTED: PORT, NOT REWRITE.**
- **THE CONCURRENCY QUESTION IS ANSWERED (MEASURED), and it was the arc's largest unknown.** `src/effectloop.zig` is
  NOT goroutines/threads/stack-switching: it is a single-threaded, **fixed-capacity cooperative state machine** —
  one `HostLoop` struct with bounded compile-time tables (33,026 rooted Value slots, 128 eval slots, 258 pollfds,
  128 children; ~1.94 MB, page-allocated, rooted once at `:1196`), stepping by a **tag-symbol dispatch loop**
  (`stepEval :298`) over the 20 Task ctors. A Mid loop can hold that.
- **THE LIBC SURFACE, ENUMERATED.** `RawCallRaw` fits **as-is** for fork/execvp/waitpid/`_exit` (noreturn — the
  `rt_halt` precedent)/pipe/dup2/close/read/write/poll/`fstatat` (raw Stat buffer → its layout moves to
  `Mid/RtLayout` per the stage-2 rule)/`clock_gettime`/`getdents64`/`__errno_location()`/getcwd/getenv/setenv/
  chdir/unlink/mkstemp/lseek/kill/getpid.
- **STREAMS: PORT THE MODEL, REPLACE NOTHING.** There is **no `FILE*` anywhere** — the `stream` ValTag is an
  fd-int-in-pointer plus two flags and all I/O is raw fd read/write. Only the producers move; the C-quirk
  ENOENT→string-stream behaviour must be reproduced verbatim (pinned by `io-fail`).
- **THE HOST-IO HOLE CLOSES AS A BY-PRODUCT** (the port's equivalents allocate via `Rt.allocRaw`/`Rt.con`, so no
  Zig allocator remains) — but the compile-time refusal must STAY between stage 6 and the deletion, while the Zig
  host still exists.
- **LUA/FFI PRICING.** Recommend **LuaJIT, vendored from source** (FFI is LuaJIT-only; a MicroOS package install
  costs a reboot). FFI is **load-bearing for parity**: without it the shim (~250 Lua lines) silently degrades the
  host (synchronous exec, wrong clock for Now/Sleep); with it (~400–500 lines) full parity, and its `cdef` list is
  mechanically the SAME call list as the Mid port's. **SUBSUMPTION VERDICT: NO** — stage 6 is the QBE backend's own
  retirement, so the Lua route does not make it unnecessary. The real fork is (i) Mid port (default) vs (ii) Lua
  shim, which saves the port but moves the selfhost oracle to Lua.
- **SIZE (PROJECTION, and the plan undercounts):** the effect loop drags ~1,100 lines of `execplan.zig` with it,
  and the 56 process-layer `rt_prim` sites force those prim bodies at stage 6 anyway. Honest stage-7 total
  **~2,700–3,600 Mid lines** (+ ~1,300–1,700 stage-6-owned prim bodies), in **six bounded units 7A–7F** (CEK core →
  sync leaves → readFile+poll → exec async + concurrency proof → listDir/stat → integration + the deletion act).
- **ZERO-ZIG CENSUS, FILE BY FILE (MEASURED — 25 `.zig`, the complete set, nothing unowned).** Stage 6:
  `tools/qbe/rt.zig`, `rt.o`, `rt-o.sh`, all of `vendor/osier-rt/*` + its build/tests, top-level `build.zig`,
  `layout-probe.zig`, `consdiff-zig.zig`, `primsdiff-zig.zig`, and every script's rt.o step. Stage 7 (ONE deletion
  commit): `src/effectloop.zig`.
- **PLAN CORRECTION — stage 6's deletion list AS WRITTEN UNBUILDS THE HOST:** `effectloop.zig` imports `gc`+`rt`
  (part of `rt-o.sh`'s freshness graph), so `vendor/osier-rt` must SURVIVE the swap and die in the stage-7 deletion
  act, with the Zig host serving as the differential oracle until fixture parity. **THE CORRECTED ORDER: finish
  stage 3's exit condition (ALL 117 sites, including the 56 process-layer prim bodies) → stage 6 (`rt.zig` only) →
  7A–7F behind a hatch.**
- **OPEN OWNER DECISIONS:** (i) Mid port (default) vs (ii) Lua shim; confirm the SEGV-net removal at stage 6; and
  promote the concurrency-proof fixture into `qbe-check` at 7D.

**STAGE 6 PLAN — `handoff-osier-stage6-plan` (2026-10-15, 8 `stage=plan` obs + `handoff-osier-stage6-artifact-1`).**
**PREMISE: `rt.zig` the FILE dies; its ABI surface (frames, apply/apply_tail/tail_known/bounce, die/halt,
the driver `main`) becomes Mid-emitted defuns behind hatch `QBE_MIDDRIVER=1`; the Zig object then SHRINKS
to a named host/collector shim — it does NOT disappear until the stage-7 deletion act.** Three plan-level
corrections, all MEASURED by the planner against the code:
- **C1 — `QBE_MIDGC` CANNOT become the default at stage 6.** The seam refusal (`Lower.elm:559`) refuses
  every `Runtime.program` compile under midGc and **the selfhost driver is one** (`selfhost/NativeMain.elm:66`),
  so flipping would make the seed un-freezable and kill the ioecho/exec/task fixtures. The default route
  therefore KEEPS the Zig collector; the Mid frames register roots into the **Zig shadow stack** via 6 new
  alloc-free shim seats (`rt_root_push_value_array/value/ptr`, `rt_root_pop`, `rt_root_watermark`,
  `rt_root_pop_to` wrapping `vendor/osier-rt/src/gc/roots.zig:120` — MEASURED collect-free). So the 4
  `rt_gc_root_*` seats keep working unchanged and **move to the shim, dying at stage 7** — the BRIDGES row
  "the 4 root seats die at stage 6 by construction" is UNBUILDABLE as written.
- **C2 — "bootstrap loses its `rt.o` step" is FALSE at stage 6.** `rt.o` survives (the shim), so `qbe-mk`/
  `bootstrap` keep linking it; the honest stage-6 payoff is "the ABI is Mid; `rt.o` shrinks to the
  collector+host seam (a named seat list)".
- **C3 — the recorded gap "Mid has no mutable-global-state facility" is REFUTED.** `vendor/qbe/emit.c:92`
  puts an all-zero data def in **`.bss` (writable)**; `Il.DZero` + `export_` on a `DataDef` + `RawDataAddr`
  (`Ir.elm:471`, `Lower.elm:2211`) + stage-1's `RawWordLoad/Store` give accessors — a Mid-owned mutable
  global IS `export data $rt_glob = { z N }`. So `rt_midgc_region`/`set_region` die at stage 6 as the table
  says (`RtGc.elm`'s ~6 `callW` sites re-point at the block), and the driver/globals block needs NO new mechanism.
- **MEASURED INVENTORY:** the committed seed (`tools/bootstrap/compiler.ssa`) carries **44,215 calls over 17
  `rt_*` symbols** (bounce 20,318 · vec_store 3,798 · frame_enter/leave 3,543 each · string 3,292 ·
  tail_known 3,205 · die 2,171 · vec_alloc 1,341 · make_closure 1,227 · …). **The retarget itself is only
  TEN Lower emission sites** (`:6514` frame_enter, `:1195` frame_leave, `:3577` tail_known, `:3598`+`:1613`+
  `:5957` bounce, `:3622` apply_tail, `:3642` apply, `:4520` die) **+ one in `RtPrims.elm:400`**; the 44k call
  sites move ONLY in the flip commit's corpus re-freeze. The other `rt_*` symbols (vec_*/raw_alloc/string/
  con/make_closure/global_closure/value_slot/float_text/ss_*/sym_intern) are the ZIG COLLECTOR'S surface
  (C1) and are NOT part of the swap. Frame sizes: `rt_frame_enter(w N)` max **4,354** in the seed → a Mid
  freelist array indexed by `nslots`, bound ~8192, giants never pooled.
- **THE AGGREGATE GAP IS ONE NODE.** `rt_apply` returns a `:val` and `applyGo` needs a call through a
  **runtime word** (the Desc code pointer) with an **aggregate `:ret`/`:val`** result. The planner's /tmp
  probe (`handoff-osier-stage6-artifact-1`, assembled by the vendored qbe, exit 0) shows `%r =:ret call %f(l …)`
  through a loaded word is legal AND the sret temp is addressable (`loadl %r`, `loadl (%r+40)`). SMALLEST FIX:
  ONE new `UnsafeNode RawCallAgg` returning the sret buffer address (fields then read with the existing
  `RawWordLoad` at +0/+40/+48/+56/+64/+72). BLAST RADIUS = the established 6-seat node recipe (`Ir.elm`,
  `Audit.elm`, `Rt.elm` `unsafeSafepoint` = **conservatively ALLOCATING** — a `False` misclassifies an
  allocating defun frame-free, the stage-1 lesson; `Monomorphise.elm`; `Lower.elm`; `TestMain.elm`). ~150–250
  lines incl. tests. `Print`/`Il` need NO change (`Il.Call` already carries `Just t`+`Agg ret`+a Tmp callee).
- **THE RAW-WORD DEFUN CONVENTION (the one genuinely new Lower surface):** every Mid defun today takes
  `:val` params under the lean ABI; the frame/apply/bounce/die/halt/driver defuns need **word** params /
  word-or-ptr results. DESIGN: a `rawAbi : Set String` of `Rt.*` keys in `Lower`; defuns in it emit
  `(params Base L, ret Base L/W)` and their Lower-generated callers emit matching word calls; `Mid.Rt`
  exports the list next to `seeds`/`rtDeps` so `Lower` and the program builder agree. The driver additionally
  needs `export` + name `"main"` (the `rt_callN` key→name precedent) and `ret Base W`.
- **THE SPLIT (ten landings, each oracle-green, corpus BYTE-IDENTICAL while the hatch is off):**
  **U0** pin the driver contract (this is dispatched: usage/entry-not-found/too-many-args/exit-codes + the
  partial→over-app chain — see below) → **U1** mechanisms (the `RawCallAgg` node, the globals block, the 6
  root seats, `RtGc` re-point; emit-inert) → **U2** die/halt ports + the `rawAbi` convention (smallest
  consumers) → **U3** frames (`Rt.frame-enter/leave`) → **U4a** apply defuns → **U4b** tail_known + bounce +
  the 6-site retarget + hatch wiring (`run.js` → `Main.elm` flags → `QbeModule.compileEntry` (fold the inner
  3-tuple → 4-tuple; arity stays 12 — the arity>16 trap) → `Lower` + `Mid.Rt.driverProgram`; `NativeMain.elm`
  hard-coded vector + a `TestMain` row pinning it) → **U5a** driver pure half (rlimit, knobs, meta walk, arg
  parse, argv via `Rt.cons` — fixes a latent MIDGC hole, entry call + bounce, `rt_print_value` shim, exit
  codes = U0 goldens) → **U5b** driver host half + the midGc arm + guard enumeration → **U6** the flip
  (default on, vector bit + corpus/seed re-freeze together; hatch OFF reproduces pre-flip bytes = the §1.2
  attribution window) → **U7** the shrink (new `hostshim.zig`, the named seat list, `rt-o.sh` `-Mroot` swap,
  keep the `rt.o` output path; BRIDGES rewrite; the SEGV net + `rt_prim`/NOMIDRT-runtime-arm become
  emit-only = **OWNER DECISIONS**) → **U8** the differential (§1.3 suite rule arms-alternated + churn sweeps
  + emit wall + cross-target smoke + native selfhost run = the deepest oracle).
- **ORCHESTRATION REFUTATIONS (found reading the artifact, not the plan):** two U0 items the plan calls
  "unpinned" ARE pinned — the 1e6-hop mutual-tail bounce (`qbe-check.sh:1724`, `timeout 120`) and the driver
  float-arg path (`qbe-check.sh:1318-1321`). The genuinely-unpinned set is the driver ERROR paths, whose
  **exit codes `run()` never checks** (`run()` merges stdout+stderr but ignores `$?`). **U0 is LANDED**
  (`handoff-osier-stage6-u0-result`; `run_err` + 5 error rows + the `partyapply` partial→over-app chain;
  qbe-check 285 → **292 PASS / 0 FAIL**, each row's exit-code and golden halves proven fail-before).
- **U1a LANDED (MEASURED, `handoff-osier-stage6-u1a-result`):** the `RawCallAgg` node exists — corpus
  **BYTE-IDENTICAL 159/159** (emit-inert), qbe-check 292/0, TestMain 119 → **121**. Two corrections to the
  plan text: (i) `Il.Call`'s target is a bare **`Arg`** (`Il.elm:205`), not an `ArgVal` — the emitted form is
  `Call (Just t) (Agg shape) (Il.Tmp fnT) args`; (ii) the callee must lower to a raw-word **TEMP** (a constant
  target is a loud `Err`, since qbe forbids it). `unsafeSafepoint = True` (conservatively allocating) as specified.
- **U1b LANDED (MEASURED, `handoff-osier-stage6-u1b-result`):** the six alloc-free root seats
  (`rt_root_push_value_array/value/ptr`, `rt_root_pop`, `rt_root_watermark`, `rt_root_pop_to`) exist in
  `rt.zig:603-646` (6 `T` symbols in `rt.o`); 6 BRIDGES rows appended. Zig 0.16 idiom correction:
  `@ptrFromInt(@as(usize, @bitCast(x)))`.
- **U1c LANDED (MEASURED, `handoff-osier-stage6-u1c-result`):** the GLOBALS BLOCK is real — `export data
  $rt_glob = { z 65664 }` + a `ret $rt_glob` accessor func `rt_glob_addr`, both emitted in `finishModule`
  **gated on `s.midGc`** (so the DEFAULT route emits neither). `rt_glob`'s word 0 is the Mid collector's
  region pointer, replacing the Zig global; the two seats `rt_midgc_region`/`rt_midgc_set_region` are
  **DELETED from `rt.zig`** (`rg` empty) and their BRIDGES row REMOVED. Reserved slots: 8..11 knobs (U5a),
  12 tail-scratch (U4a), 16..8207 freelist heads (U3). Corrections: the accessor is reached by `RawCallRaw`
  (`Il.Sym` verbatim) — NOT `RawCall` (which requires `s.defuns` membership + the lean `:val` ABI); the symbol
  is `rt_glob_addr` (`callW` doesn't mangle, and `.`/`-` are illegal qbe identifier bytes); the constants live
  in `Mid.RtGc` (layout-census's parse contract forbids `RtLayout`; `Mid.Rt` would cycle). Oracles:
  corpus **159/159 byte-identical**, qbe-check **292/0** (all `run_midgc` rows through the re-point), TestMain
  **123/123**, `osier-numbers.sh` exit 0.
- **SEED DRIFT UNDER STAGE 6 (MEASURED, not a defect):** editing any `Mid/*.elm` moves the selfhost seed — after
  U1a `tools/qbe-bootstrap.sh --status` reports `abi DRIFTED` / `exact STALE`. `osier-numbers.sh` step 2c is
  **REPORT-ONLY** and the repo's own rule says "the seed WILL drift as sources change, and that is acceptable".
  Re-freeze is DELIBERATE and lands at U6's flip (corpus + seed together). No stage-6 unit before U6 must re-freeze.

**GOAL (owner direction, 2026-10-12).** Remove Zig from the repository. The runtime — the collector,
the values/allocating seats, the C-ABI surface the generated code links against, the driver, and the
host/effect loop — is written **in Mid** and lowered to QBE by Osier's own backend. Payoff: `rt.o`
disappears and the toolchain collapses to **Osier + qbe + cc**; the runtime becomes backend-neutral
(the same Mid IR serves Phase 5's Lua), and there is one implementation rather than two.

**THE MEASURED SPLIT (2026-10-12) — what "retire Zig" actually is:**

| | lines |
|---|---|
| Mid runtime today (`Mid/Rt.elm` + `Mid/RtPrims.elm`) | **2,779** |
| `tools/qbe/rt.zig` — the C-ABI surface the generated code calls | 1,444 |
| `vendor/osier-rt/src/gc/{heap,collect,types,roots,scan}.zig` | 3,089 |
| `vendor/osier-rt/src/rt/{execplan,prims,values,streams,state,symbols,tables,varray}.zig` | 3,145 |
| `src/effectloop.zig` | 1,375 |

So a substantial runtime already IS Mid (the prims, post-flip), and the collector is the natural wedge.

**EXPRESSIBILITY — VERIFIED by reading the artifact, not assumed:**
- `RawCallRaw` lowers to `Il.Sym seat.sym` with **no whitelist** (`Lower.elm:1878-1905`), so Mid can
  name **any** C symbol, libc included; `RawCall` refuses non-`Rt.*` symbols and points at `rawCallRaw`.
- Present: `RawByteLoad`/`RawByteStore`, `RawAllocRaw`, `RawVecLoad/Store/Addr`, `RawPayload(32)`,
  `RawTagOf`/`RawTagIs`/`RawMkValue`, the scalar/float word ops, `RawCall` to `Rt.*` defuns.
- **MISSING: a word load/store at a computed address.** `RawVecLoad/Store` are GC *Value* arrays,
  `RawPayload` reads a *Value's* payload, `RawByteLoad/Store` are byte-level. A mark-sweep lives on
  8-byte header/page/freelist access, so this node is the first step.

**THE THREE REAL HARD PARTS (not the headers):**
1. the node gap above — small, and Phase 3 produced the exact recipe for adding a node;
2. **`rt.zig` IS the ABI, not a helper** — pooled frames + precise roots, `apply`/`apply_tail`/`bounce`,
   the prim fallback, and the driver `main(c_argc, c_argv)`. Every symbol there is a contract with
   `Mid.Qbe.Lower`'s emission; moving it into Mid changes what the compiled code links against;
3. **the heap (~3.1k lines)** — pages, allocators, triggers, nursery/promotion — Mid-reachable only if
   OS memory comes through libc (`mmap` via `RawCallRaw`) and the **layout lives in exactly one place**
   (the repo has already paid for "the mechanism is right but the thing that reads it is wrong").

**MEASURED PERF WARNING, not a projection.** The last time hot runtime code moved into the Mid route
the suite went **1273 → 3333 ms**; the lean-ABI work recovered −49% and the residual +38% was
attributed to record per-prim-call cost — which **E has just addressed** (CONFIRM). So the route penalty
may now be gone, but it is **unmeasured**, and a collector's mark/sweep inner loops are precisely what
must not be 38% slower. Re-measure the route penalty before committing.

**PROPOSED STAGING** (to be refined by the plan pass):
1. add `RawWordLoad`/`RawWordStore` (+ the established node recipe);
2. put the **heap layout in one Mid module** (constants + accessors) and make Zig read the same
   definition, never a second copy;
3. Phase 4 — the collector in Mid, differentially against the Zig collector (`zig build gate` is now
   step 6 of `osier-numbers.sh`, ahead of this work);
4. then the allocating seats / values helpers; then `rt.zig`'s ABI; then the host/effect loop — or
   defer that last one to Phase 5's Lua host shim.

**OPEN QUESTIONS for the plan pass:** whether `main`/the entry can be a Mid defun (and what it links
to); where the safepoint trigger lives once the collector is Mid; whether the effect loop is in scope
now or belongs to Phase 5; the `.ssa`-growth consequence (the runtime stops being a shared `rt.o` and
becomes per-program injected Mid defuns — re-check the ≤2× guard); and the oracle set for the final
swap (route differential + `zig build gate` + the §1.3 suite rule).

*The plan pass is `handoff-osier-zigretire-plan`; this section is the orchestrator's framing and is
superseded by that plan where they differ.*

### Phase 5 — the Lua backend ("Osier without a compiler")  ⏭

Prims lower to Lua functions emitted **into** the `.lua` (one implementation, not two — the drift
failure this repo has already paid for); values lower to native Lua values; **GC = Lua's own** (the
GC module is unreachable — reachability prunes it because Lua programs' `PrimApp` sites never
`GRef` it, so the Lua backend can error if it is ever reached); host = a small emitted Lua shim
over `io`/`os` implementing the same Task stepping through the same `host_apply` seam.
`A`/`B`/`D`/`F`/`E` transfer as Mid-level passes; `A`'s *emission* becomes trivial on Lua and `A`'s
*lesson* (no per-call staging, no name dispatch, no per-literal allocation) becomes a day-one
constraint. The Mid runtime is precisely what makes this one implementation rather than two.

### Phase 6 — node-lane retirement  ⏭

Move the build loop onto the native/seed lane: `qbe-bootstrap.sh` already rebuilds the compiler from
the committed seed with `qbe` + `cc` alone (`compiler.js` is elm-built and today the oracles drive it
via `node run.js`). The enabler is the **native driver** — a `main` that takes argv, reads its inputs
and compiles them — which is also what makes **`.mid` files** possible (§2.5): the Elm blob
(`Mid/RtSource.elm`) exists only because the elm/node lane cannot read files. Landing the driver
retires node from the *runtime*; elm/node then survive only as the seed's bootstrap. Phase 7 (GADTs)
is blocked behind this, because `elm 0.19.2` must type-check the sources today.

### Phase 7 — GADT-indexed AST (`Exp mode`)  ⏭

*Note (2026-10-12): the owner's direction is **rank-2 types + first-class modules + modular implicits**,
which REPLACES Elm's module system (nominal, non-first-class, rank-1, no signatures/functors). Decision
recorded as `osier-module-system-decision`: **do not build Elm module-system compatibility** — no import
cycles, no `.elmi` interfaces, no package/version resolution, no Platform/effect layer. That direction
also sets the `Exp mode` design's context, where a join key on expressions (Gap E) is the shape the end
state wants anyway.*

### Phase 8 — corpus / paper  ⏭

`docs/research/osier-paper.md` + `build/` (`.tex`, `.pdf`, submission variants) + `submission/`.
The paper's reproducible chain is `tools/osier-numbers.sh`, which prints every number it cites.

---

## 4. Superseded decisions and refuted predictions (do not re-apply)

- **"No per-step freezing"** (user ruling 2026-10-10, recorded on
  `handoff-osier-midruntime-result`) declared **no re-freeze epochs** and made the corpus `.ssa`
  step **report-only**. **Superseded by measurement**: the freeze is *cheap* — seed 7–8 s, corpus
  9.5 s — and only the `--verify` fixed point is expensive (~742 s). The tree already reflects the
  reversal: in `tools/osier-numbers.sh` the corpus step is **gating** (`fail=1` on mismatch) and
  only the seed-status line is report-only. Keep it that way.
- **"The flip will reach parity with A"** (its step-6 oracle) — **refuted**: 3333 ms vs 1273.
- **"`rt_string` interning pays on the suite"** — **UNDECIDED** (no suite sites); its payoff is the
  string-heavy selfhost compiler, to be judged on churn counters, not the suite.
- **"S1 keeps no seed cost because `Mid/*` is seed-free"** — **refuted**: the selfhost manifest is
  67 sources in 1 group and *includes* `Mid/FromAst`, `Mid/Module`, `Mid/Qbe/Types`,
  `Mid/QbeModule`. Every `Mid/*` edit is seed-bearing now.
- **"Refinement re-checks produce duplicate `Range`s"** — **refuted**: the R-RESULT-DISCHARGE
  retry discards the failed attempt's whole state (`orElse` re-runs from the original state), so
  exactly one copy per range survives. The real duplicate source is `Frontend/Lift.elm`'s synthetic
  nodes.
- **"`valMark`/`dead-slot clearing`/loop passes/small-int immediates are worth doing"** — dead
  (`valMark` unused), measured NULL and reverted (dead-slot clearing), unprofitable (numloop is
  already 90% generated code), and structurally impossible without a word-sized `Value` ABI.
  Do not revisit without new measurement.
- **"Cloning `fib` at Int is what makes the suite's `q_Rt_*` calls disappear"** — **refuted as a
  claim about the suite**, MEASURED 2026-10-11 (`00cc7da`): the specialiser engages in only 3 of the
  12 suite programs, and its 7 clones there are 90-line bodies differing from their originals by
  **exactly one data label** — instruction-identical. The pre-stated mono axis (`mono_int`,
  `mono_float`) is therefore BLIND to this pass and cannot show a win in either direction. The
  mechanism is real on the shape it targets (`tools/bench/monoarith.elm`: fallback calls 4 → 1,
  frame 16 → 10), and the win is still **−0.2%** — the cost is the BOXED ABI, not the fallback calls.
  Do not re-run the mono axis on the suite expecting a signal, and do not quote the early ±0.8%
  probe: its fixture's whole workload is ~500 operations.
- **"Canonical field order = the TYPE TABLE order"** — **refuted by measurement** (2026-10-11, planner
  pass `handoff-osier-phase3-ea-plan`): rows are insertion-ordered per literal (`Infer.elm:800-809`)
  and nothing in `Type/*` sorts, so each literal keeps its textual order; MEASURED, `{b=2,a=1} ==
  {a=1,b=2}` prints `false` at `00cc7da` (Elm: `true`). Order must be DERIVED by sorting. Corollary
  refuted with it: **"a per-site deny-to-assoc fallback is enough"** — unsound (host `@p` chains read
  at closed sites; a closed-site vector reaching an open-row site; non-Var record subexpressions in
  the target programs). Do not re-apply either.
- **"No new Mid node" (as a rule)** — **wrong as a rule**: it was a scope observation (E's lowering
  maps onto existing raw/vector nodes), and treating it as a prohibition wrongly blocked the
  static-names-array design that Phase 3 now uses. A new node is an ordinary cost decision (Audit
  enumeration + the seed-bearing `Mid/*` files), not a ban.

---

## 5. Open gaps, outstanding verification, risks

- **`tools/qbe-bootstrap.sh --verify` (~742 s fixed point) has NEVER been re-run** since the seed
  moved. `--freeze` + the stubbed node-free build are green; the fixed point (the native compiler
  re-emitting itself byte-identically) is the untested half.
- **`tools/qbe/qbe-selfhost.sh` is unusable under the 8 GB cap** (32768 MB default; it has peaked
  ~20 GB). Do not run it.
- **Latent hole in `Mid.Rt.allocating`**: `safepointMatch` returns `False`, which skips no
  expression today (a `Match` carries no `Exp`) — but `MLitEq`'s string arm lowers through
  `lowerEqMatch`, materializing the literal with an **allocating** `rt_string` call the walker
  would not see. Unreachable now (zero `Case` in `Mid/RtPrims.elm`); one-line fix when it matters.
- **`QBE_MIDZIG=1` is a dead hatch** — finish deleting it or re-document it.
- **Reviews pending**, GLM credit permitting: a second pair of eyes on `Mid.Rt.allocating`'s
  closure (the walker's completeness) and on step 1's framed-defun cost as the residual's
  unexplained half.
- **QBE compile-time risk from clones**: a previous 10.7 MB selfhost `.ssa` took 25 minutes to
  generate; guard `.ssa` growth ≤2x, emit ≤3x, and cap instantiations per defun if unbounded.
- **`tools/qbe/rt.o` is a shared cache keyed on `vendor/zinc-vm/src`** — a peer editing that tree
  makes a concurrent `qbe-check` racy; a build-failure FAIL in that window is **not** a regression.
  Other agents work on this host; a suite number needs a quiet window and an A/A spread.

---

## 6. Traps this repo has already paid for

- **`elm make` passing is not the tree compiling itself.** A construct elm 0.19.2 accepted was
  rejected by the tree's own front end (`--freeze` exit 2, `unknown name: safepoint`). Run
  `--freeze` early; treat its error as authoritative.
- **An import resolving under `elm make` does not mean the module is in the SELFHOST MANIFEST
  (2026-10-12).** The tree's own front end resolves imported names only against the modules listed
  in `elm-compiler/selfhost/manifest.json`; a seed-bearing module added to the tree but not to the
  manifest reads as `unknown name: gcProgram` (the missing module's export) when `--freeze` compiles
  the manifest. `Mid/RtGc.elm` landed in stage 4 (`9e3bb6e`) and was never added, so `--freeze` died
  for every stage-4 and stage-5 unit while the seed status reported FRESH. When a new module joins
  the selfhost group, add it to the manifest in the same commit.
- **`String.concat` is aliased to `List.concat`** in the tree's own alias table
  (`Lower/Resolve.elm` maps `"String.concat" -> "concat"` -> `Prelude.concat`, the LIST flatten
  `List (List a) -> List a`). `String.concat ["a","b"]` typechecks under elm 0.19.2 (real
  `String.concat : List String -> String`) but the tree's typechecker rejects it with
  `cannot unify List a with String`. Workaround at the use site: `String.join ""` (the two are
  semantically identical). The alias table itself is not yet fixed — it would need a
  `Prelude.stringConcat`.
- **A test row that cannot fail is not a test.** Ask what makes a check FAIL, and check that the
  thing that *reads* the value sees it.
- **`selfhost/NativeMain.elm`'s flag vector is hard-coded** — every new flag goes there too, or the
  native compiler silently emits a different route.
- **Never `find /`** (the NFS mounts hang); never the 807 s `elmvm` selfhost compile.
- **Backticks/apostrophes in an inline shell string are substituted** — write briefs via a
  single-quoted heredoc and keep the authoritative copy in the record. (Learned twice, once from a
  `--implements-->` that the shell read as a redirect.)
- **`tools/qbe-bootstrap.sh --freeze` writes the emit payload straight ONTO the committed seed**, so
  a failed freeze TRUNCATES it — hit twice (51 and 53 bytes against a 12.7 MB seed, restored
  byte-identically from `HEAD`). Emit to a temp path and rename on success; until that lands, treat
  a seed that shrank as a TOOL failure, not as drift.
- **A pre-stated bar can be blind.** Before naming the instruments a decision rule will judge, emit
  both arms and DIFF them: if the change cannot appear in those artifacts, the bar is unfalsifiable
  in the direction that matters. Phase 2's rule was honest, pre-stated, and pointed at the only two
  suite programs that provably cannot see the pass.
- **`elm make` IS NOT A GATE (user ruling 2026-10-11).** Do not narrow a design, avoid a node, or
  write around a construct to keep elm 0.19.2's checker happy. The authoritative compile check is the
  tree's **own** front end (`tools/qbe-bootstrap.sh --freeze` / the gate), which is the stronger one
  anyway (see the `--freeze` trap above). **Honest consequence, not to be papered over:** `compiler.js`
  is elm-built (`build.sh`) and the oracles consume it — `run-elm-gate.sh:681`, `osier-numbers.sh`,
  `primsdiff.sh` and `selfhost-audit` all drive `node run.js` on it. So if `elm make` stops being green
  the **oracles go dark**, and that is the trigger for **Phase 6 (node-lane retirement)** — move the
  loop onto the native/seed lane (`qbe-bootstrap.sh` builds a compiler from the committed seed with
  qbe + cc alone) — never a reason to revert or narrow the change. It is also what unblocks Phase 7:
  an `Exp mode` GADT-indexed AST is unrepresentable while elm 0.19.2 must type-check the sources.
- **A GREEN BATTERY CAN BE GREEN ABOUT THE WRONG INSTRUMENTS (Phase 3, 2026-10-11).** The implementer
  reported "all oracles green" and was telling the truth — qbe-check 270/0, gate 154/0, TestMain
  111/111, consdiff/primsdiff, osier-numbers "all checks pass". Two of the three worst defects in that
  same tree were a **use-after-free** (nursery names array never evacuated) and a **silent wrong-field
  read** (`recAppend` at index `len`, canonical order broken — and the gate's own `insrec.elm` passed
  **by cancellation**: `1+99+5` equalled the expected output while the `.ssa` read the wrong fields).
  Both are precisely the class the battery cannot see: it pins **compile output** and **language
  behaviour**, and it did not run the **runtime's own test suite** (`zig build test` was RED at 36/38
  and was in NO oracle). Ask of every battery: *which instrument would go red if THIS class of bug
  were present?* A probe built to fail-before/pass-after found both in minutes.
- **An attribution hatch that changes EMISSION but not the RUNTIME is not a control arm.** (A)'s
  `QBE_NOCONSARR=1` reproduces the old `.ssa` bytes (148/149) yet cannot RUN — the new scan evacuates a
  cons's `car` only, so the hatched 2-word shape halts or corrupts (`mono_record`: halt at 32 ms alone,
  core dump with `QBE_NOREC=1`). §1.2's byte-for-byte test is a test of the **emit**, which is the right
  question for *attribution* and the wrong one for *using the flag as a measurement arm*. Say which one
  a hatch is for.
- **THE INSTRUMENT PROBLEM — SIX INSTANCES IN ONE ARC (consolidated 2026-10-12).** The single most
  repeated failure here is a **green instrument that cannot see the change it is cited for**. Instances:
  1. **phase 3**: every oracle green while a **use-after-free** and a **wrong-field read** shipped
     (`insrec.elm` passed *by cancellation*; `zig build test` was RED and in no oracle);
  2. **the S5 bar**: pre-stated, honest, and pointed at the two suite programs the pass provably
     cannot affect (its 7 clones differ from their originals by one data label);
  3. **stage 3**: `primsdiff 92/92` cited as the differential for the `Rt.=` fast path — it compares
     numbers/strings/bools/lists/vectors, so **92/92 would pass identically with the fast path
     deleted**;
  4. **unit B**: the fix for two silent wrong answers changes **ZERO corpus artifacts** (150=150
     byte-identical) — the corpus *cannot* see it, because no fixture does arithmetic on a host-built
     record field;
  5. **the census proxy** (mine): five numbers from one question (26% → 58% → 71% → 40% → 50%) as I
     fixed keyword-led operands, operands not cut at the previous operator, then a doc-comment
     confound. The instrument was varying, not the code.
  6. **the seed status** (2026-10-12): the `seed FRESH/DRIFTED` line hashed the manifest INPUTS — a
     proxy that cannot see an emit that FAILS or produces different bytes. It reported FRESH for four
     units while `--freeze` had been impossible since stage 4 (`unknown name: gcProgram` — a missing
     manifest source), so the node-free bootstrap was building a stale compiler. Replaced by the
     exact check (`qbe-bootstrap.sh --status`: emit + cmp against the committed seed).
  **THE RULES THAT FOLLOW.** (a) Ask of every battery: *which instrument would go red if THIS class of
  bug were present?* If none, there is no battery — say so. (b) A regression guard must be
  **fail-before/pass-after**: **a probe that passes before the fix is not a probe for that bug**.
  (c) A guard that lives in `/tmp`, or in one agent's transcript, is not a guard — it must be a
  registered row in a committed suite. (d) A `.ssa` census diff is a **fire-rate** measure, never a
  correctness proof. (e) When a number moves as you refine the instrument, suspect the instrument first.
- **A LOADED HOST FABRICATES A REGRESSION (Phase 3, 2026-10-12).** A first pass measured the record
  programs on a loaded machine and reported `adtmatch` **1.38× SLOWER** — a plausible-looking result
  that would have been recorded as a real regression. Re-run with the load snapshotted per arm, the
  same tree and the same flags gave `adtmatch` **165 vs 164 — dead even**, and cut every other number
  by 30–40% (`mono_record` 248 → 167). **Only WITHIN-SESSION alternated pairs are evidence.** Snapshot
  `loadavg` with every arm; never compare a total against another session's total — the pre-fix suite
  total (933/964, load un-snapshotted) sits *below* the post-fix one (1079/1061) for exactly this
  reason, which would read as a 13% regression that is not established. A regression claim needs the
  same-session control, not a previous day's baseline.
- **A BAR THAT SAYS "beyond the A/A spread" WITHOUT PINNING THE CONTROL'S DOMAIN IS NOT A BAR
  (2026-10-12).** The Zig-retirement decision gate was pre-stated as ">+3% beyond the same-day A/A
  spread". Read **per-program per-session** (the twin actually run), it TRIPS: `adtmatch` +23…+44 over a
  ≤2.6% spread, `mono_float` +10…+15 over ≤1%. Read as **one per-session number** (±10%, §1.3's
  convention), the same data is *inside* the spread and reads NOT REFUTED — which is how the planner
  recorded it. Two honest readings of one pre-stated bar, opposite verdicts, **both computed
  correctly**. A control establishes attributability *within its domain*: name the control, its domain
  and the comparison explicitly, or the bar will be read to taste. (The owner's call — NOT REFUTED with
  the one program beyond *every* reading named as a blocking exception — only worked because the
  measurement was reported per-program rather than pre-aggregated.)

---

## 7. Provenance

Merged from: `handoff-osier-midpasses-plan`, `handoff-osier-midruntime-plan`,
`handoff-osier-midruntime-result`, `handoff-osier-mono-{ctx,plan,result,s1-result,s4-result,s4f-result}`,
`handoff-osier-repr-result`, `handoff-osier-flip-result`, `handoff-osier-midprims-result`,
`handoff-osier-consspike-result`, `handoff-osier-midabi{,-result}`, `handoff-osier-seq-step2`,
`handoff-osier-mono-s5`. Commits cited: `0258326`, `6e6d6b1`, `51a59cb`, `19dd5b3`, `cea1ce6`,
`8f581b8`, `b6e4990`, `2d127d1`, `159198d`, `00cc7da`.
