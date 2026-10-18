# PERF-DEBT — the Mid runtime's performance floors (deferred)

Recorded 2026-10-17 at HEAD `42ad241` (stage-6 Path B: B0 frames, B1 apply, B2 tail landed).
This file exists so the debt is not lost when the baseline it is measured against is deleted.

> **Provenance correction** (re-deriving the corpus counts): `42ad241` and `f9d5dd7`
> each claim "126/159 artifacts moved" — the MEASURED count is **125 moved / 34
> unchanged**, every one of the 34 a `compile_error` group (the moved *set* is
> identical across the two commits; only the digits are wrong).

## ⚠ READ THIS FIRST — B4 DESTROYS THE MEASUREMENT BASELINE

Every ratio in this file is measured **against the Zig arm of the same program**,
i.e. the *hatch-OFF* build (`QBE_MIDDRIVER=0`), where the frames / apply / tail are
still the Zig seats in `tools/qbe/rt.zig`.

**B4 (the shrink) deletes those Zig seats.** After B4 there is no hatch-OFF arm, so:

* `frame_perf_gate`, `apply_perf_gate` and `tail_perf_gate` (all ratio gates) lose
  their reference and must be either **re-based on a saved binary** or **disabled**
  — and disabling them silently re-opens the hole that let a **175×** regression
  through every correctness oracle (see below).
* **BEFORE landing B4: build one native binary from the last pre-B4 tree and check
  it into `tools/` (or record its sha256 + how to rebuild it).** It becomes the
  fixed reference the gates compare against.
* **BEFORE landing B4, also run plan.md §1.3's suite rule ON against OFF**
  (`QBE_MIDDRIVER=0` vs default, arms alternated). That is the *only* oracle B3
  ("the full flip") had, and B4 closes the window the same way it closes the ratio
  gates' reference. MEASURED: B3 has **no code left to flip** — every retarget
  (frames B0, apply B1, tail B2) is already `if s.midDriver` and both drivers
  already default MIDDRIVER **on** (`elm-compiler/run.js:309`,
  `selfhost/NativeMain.elm:330` `( False, True )`), so B3's deliverable landed
  inside B0/B1/B2.

### The pre-B4 reference binaries (BUILT — kept)

Below in this file the three ratio gates' Zig arm is referred to as "the Zig arm of the
same program". Those three Zig-arm executables were **built at `cf59488` and saved** so the
gates can be re-based on them after B4 deletes their source:

| fixture | file at build | sha256 | size |
|---|---|---|---|
| frame gate | `tests/elm-fixtures/fib.elm Fib.fib` | `ae86c1681a32e1a72694112ff6a912214ad463a585bcf6aa08e43a751c183dc2` | 3,913,152 |
| apply gate | `tools/qbe/fixtures/applyperf.elm ApplyPerf.main` | `68980e52ec1d9d854f3cf398b509fc50e3be91a9e4cfa74d9be14475b3831f0b` | 3,930,032 |
| tail gate | `tools/qbe/fixtures/mutualtail.elm Mutual.even` | `d86785d56852e8bd1e30d60e06b5f2577c5794247fdc3f207031eafb5cc12ed3` | 3,929,856 |

The built executables currently live at `/home/jaye/osier-scratch/preb4/{fib,applyperf,mutualtail}/`;
**B4 should commit them under `tools/qbe/ref/`** (precedent: `tools/qbe/rt.o` is committed) and
point the three gates at them, or the gates cannot be re-based and must be disabled.

Rebuild command if they are ever lost: `QBE_MIDDRIVER=0 tools/qbe/qbe-mk.sh <src> <entry> <outdir>`
at any tree up to `cf59488` (the Zig seats are still in `tools/qbe/rt.zig` there, and in git
history after B4 — B4 is recoverable, it is not irreversible).

## How the gates work (and why they are ratios)

`frame_perf_gate`, `apply_perf_gate`, `tail_perf_gate` live in `tools/qbe/qbe-check.sh`.
Each builds **the same fixture on both arms**, runs **N alternated pairs**, takes the
**median**, and compares a **RATIO** against a bound. Never an absolute time: this box
is shared and its wall clock varies by >10× with load (`plan.md` §1.3 / the loaded-host
trap — a loaded host once fabricated a fake regression).

Current bounds: frame **2.5×**, apply **12×**, tail **6×**.

**A gate that cannot fail is not a gate.** Each was proven asymmetric — the bound fails
the pre-fix binary and passes the fixed one. Keep that property when re-basing.

## The debt

### 1. apply — **9.3×** (was 11.6×) — the biggest

Measured on the closure workload (`tools/qbe/fixtures/applyperf.elm`), median of 7
alternated pairs, both arms.

**Named causes** (all per call — this is the hot path for *every* closure call):

1. **frame-enter ×3 per apply call.** `Rt.apply` / `applyGo` / the user's closure body
   each take a frame.
2. **The root push/pop dance.** `env_root` via `rt_root_push_ptr` + `rt_root_pop_to`
   around the allocation in the partial arm.
3. **`applyGo` re-blits `f` four times** to read its fields: each `:val` parameter is a
   40-byte copy under the lean ABI, so reading `payload(f, k)` for four `k` means four
   blits of the same 40 bytes.

**Direction for the fix** (not yet designed in detail): cut the blits (read `f`'s fields
from ONE staged copy rather than four calls), and reduce the frames (a single frame
shared across the apply family, or an in-frame loop like `Rt.bounceGo`). Both are
`Lower`/surface design work, not a loop swap — which is why `copyWords` (fixed for
~17%) only moved 11.6× → 9.3×.

**Leak — FIXED (stage-6 P1a).** The apply family also leaked **~704 B per saturated
closure call**: `Rt.apply`/`Rt.apply-tail` malloc a 32-byte `state` block and never
freed it, and the saturated/over-applied arms of `Rt.applyGo`/`Rt.applyTailGo` malloc
a 640-byte `buf` + 32-byte `disp` per dispatch and never freed either — ~3.5 GB peak
RSS over the 5e6-iter applyperf chain PRE-fix, ~6 MB POST-fix (the same live
default-route bug class as the `.tail` leak, on a hotter path).  Fixed by libc `free`s
after the last use of each block (the `state` after `rt_root_pop`, the `buf`/`disp`
after `Rt.callArity` returns / before the over-applied `recur`).  **The `malloc(640)`
`buf`, the `malloc(32)` `disp`, the boxed-boolean conditions, the four `payload(f, k)`
re-blits and the `mknum`/`payload` round-trips themselves are STILL PENDING** — they
are perf (the next unit will likely delete these buffers entirely), not correctness;
this unit freed them and nothing more.

**P1b Step B — the `payload(f,k)` re-blits FIXED (measured).** The "four re-blits"
were a LOWERING artifact, not a runtime.mid one: `RawPayload`/`RawPayload32`/
`RawTagOf`/`RawTagIs` re-`lowerVal`-ed their Value operand into a fresh slot first —
a full 40-byte Blit — so `Rt.applyGo`'s five `payload(f,k)`/`tagis(f,6)` reads
re-blitted the same 40-byte `f` five times per closure call.  Fixed in
`Lower.elm` (gated on `QBE_MIDDRIVER` so the hatch-OFF attribution window stays
byte-identical): a slot-resident binder (a `:val` param / value `let` / capture /
scrutinee) now reads its field word straight out of its OWN slot.  Ablation
(alternated median-of-7, 3 arms HEAD / +B / +B+A):
mono_int 207.4→201.3 (**-3.0%**), mono_float 184.4→170.0 (**-7.8%**),
mono_record 123.6→120.7 (**-2.4%**); apply-perf gate 4.1x→3.8x.  Corpus: 125 moved /
34 unchanged (the compile_error groups), the same shape as every stage-6 re-freeze.

**P1b Step A — the arena (scratch without malloc) TRIED and MEASURED A WASH.**
A bump allocator in the globals block (word 14 bump pointer, 4096 words of .bss,
libc-malloc fallback) replacing the per-call `malloc(32)`/`malloc(640)`/`malloc(32)`
triple, via two rawAbi word helpers `Rt.applyScratch`/`Rt.applyScratchFree`.
Ablation delta (Step B vs B+A): mono_int **+0.7%**, mono_float **-1.7%** (slower),
mono_record **+1.6%** — all inside the same-day A/A spread (**UNDECIDED**, reverted).
WHY: the mid-c surface's ONLY word-level conditional is the `?:` ternary, which
boxes the condition into a `Value` (`mkbool` + slot store + reload) — the helper's
two ternaries cost as much as the glibc tcache malloc/free they replace (P1a's leak
fix already made those frees cheap by tcache reuse).  The arena only wins if the
bump can be expressed as a RAW-WORD conditional, which the surface does not have.
**The real remaining lever is mechanism (ii): drop the 640-byte `buf` staging
buffer entirely** (emit a `rt_callN` variant that blits from the two ranges
`(caps, napp)` + `(args, nargs)`), which removes the 2 `Rt.copyWords` calls AND
their 2 per-call `malloc(8)` counter cells — not just the allocation.

**P1d — the apply family's boxed CONDITIONS + the 640-byte `buf` FIXED
(endpoints measured; the per-step split is NOT — see below).** Two steps:

* **Step A (conditions).** `Rt.applyGo`/`Rt.applyTailGo` test six conditions
  that each `mkbool`-boxed a 0/1 word into a Value before branching.  The P1c
  word-conditional `if` (which applies in ANY defun, `:val` included) lets
  them drop the boxing without making the loops rawAbi: `tagis(f, 6) == 0`,
  `rem == nargs` and `rem > nargs` are now bare word compares (direct `jnz`);
  `napp > 0 && env == 0` is NESTED into two word `if`s (the surface's `&&` is
  val-only); the `payload(mkbool(envlen > napp) ? … : …)`/`capslen > 0` idiom
  drops its `mkbool` wrapper — the same word-cond `?:` shape `Rt.frameBlock`
  already used.
* **Step B (the staging copy, mechanism (ii)).** The saturated/over-applied
  arms built `buf = [captures(napp) ++ args(rem)]` and handed it to
  `Rt.callArity`/`rt_callN`, whose callee blits its params from ONE contiguous
  array — a `malloc(640)` + `malloc(32)` disp + two `Rt.copyWords` loops (and
  their two `malloc(8)` counter cells) per closure call.  Now a new bridge
  `rt_call2r(code, caps, napp, args, nargs)` (emitted in `Lower.elm`, gated on
  `s.midDriver` so the hatch-OFF window stays byte-identical) computes the
  callee's param pointers with branchless selects — param i is
  `(i < napp) ? caps + i*40 : args + (i-napp)*40` — and passes the free-variable
  captures `caps + napp*40` as the callee's env; the arms call it directly with
  no staging buffer at all.  `Rt.callArity` is now **dead but NOT pruned** — the
  defun still exists (`runtime.mid:4060`) and is still EMITTED into every program
  (`q_Rt_x2ecallArity` at `tools/bootstrap/compiler.ssa:816024`,
  `partyapply.ssa:2442`, `mutualtail.ssa:3838`), with zero call sites: `Rt.*`
  defuns are emitted unconditionally (no GRef pruning).  The P1d commit message
  says "pruned"; that half is wrong (P1d review should-fix 1).

**Net: apply-perf 3.6× → 1.6×** (bound 12×), leak-apply still bounded (6160 kB).
The residual 1.6× is the per-call framing + the root push/pop + frame-enter ×3 —
the next levers.

**THE PER-STEP SPLIT IS NOT ESTABLISHED — do not quote one.** The endpoints are
MEASURED (3.6× before the unit, at `c502dfb`; 1.6× after, at `b4fac81`).  The
attribution *between* Step A and Step B is not: the host was at loadavg ~20 with a
24–28% same-day A/A spread, the two steps landed together, and the ablative arms
were **cancelled rather than measured** (the commit message and
`handoff-perf-a4-result` both say so).  An earlier revision of this section quoted
"3.26× → 2.91× → 1.6×"; those intermediate digits are withdrawn — a −6.7% delta
inside a 24–28% spread is noise, and a record must not carry attribution its own
handoff disclaims (P1d review should-fix 2).

### 2. tail — **2.5×** (2.88× manual)

Measured on `mutual-tail` at 1e6 hops (constant stack, `md-mutual-tail`).

**Named causes:**
1. A **per-call `malloc(80)`** for the `Ret` in `Rt.tail-known` (the rawAbi `Agg "ret"`
   convention inherited from B1's `Rt.apply-tail`).
2. The **17-arm linear if-chain** on arity in the dispatch — Zig uses a jump table.
3. `bounceGo`'s per-hop **mknum + blit** (the `:val`-shaped staging).

**Direction:** a jump-table-shaped dispatch, and avoiding the per-call `malloc(80)`
(the `Ret` could be staged in the frame or the globals scratch — but mind the
single-`.tail`-in-flight invariant, which is *stated* at `Rt.tail-known`).

**Leak — FIXED (see the commit that added the `free` in Lower's Agg-ret `@ret`
block).** The per-call `malloc(80)` `Ret` was also a **leak**: nothing freed it
(the Lower Agg-ret `@ret` block blit it out and dropped the pointer), while the
Zig seat is heap-free (`Ret` returned by-value through sret) — ~80 MB leaked per
1e6-hop chain, unbounded growth over a program run.  Fixed by a `free` in the
shared Agg-ret `@ret` block **after** the `Blit`: the blit copies the 80 bytes
out first, and libc `free` is not a GC alloc (no safepoint, no move), so the
no-collect invariant holds.  One site covers all three `malloc(80)` arms
(`Rt.apply-tail` ×2, `Rt.tail-known`).  The residual is one libc call per tail;
eliminating the intermediate buffer entirely remains open for B4.

### 3. frames — **1.6× → 1.4× (P1c) → 0.97× (P1e)** — the floor (lowest priority)

The residual after `frameZero` became a raw-word loop. Causes: the
`frameBlock`/`enter`/`leave` **boxed-boolean condition machinery** (`mkbool` builds a
Value per condition) and the word loop's per-slot counter round-trip.

**P1c — the boxed-boolean CONDITIONS FIXED (measured).** A surface `if`/`?:`/
block-if condition may now be `:word` OR `:val`: a bare word 0/1 (`i == 0`)
lowers to a direct `jnz` on the word — no `mkbool` box, no frame slot, no
reload — while the old boxed spelling keeps today's lowering byte-for-byte
(the compatibility seat).  A word-VALUED join (`(a==b) ? 1 : 0`) as a
condition is a LOUD J1 reject (it has no bare word test; box it or
restructure), never a silent box-and-misread.  The frame path
(`Rt.frameZero`, `Rt.frameBlock`, `Rt.frame-leave` — plus `Rt.copyWordsGo`,
which the apply family drives) converted to the word form: frameBlock went
4 boxed conds → 4 `jnz` (107 → 67 instructions, 0 `storew 3`), frameZero 1 →
1 (50 → 39).  The frame-perf gate fell **1.6× → 1.4×** (fib's ~77 ns/call
floor is the boxed-cond removal; the residual is the freelist malloc and the
word-zero loop).  The apply-perf gate moved 3.8× → 3.6× (copyWordsGo's cond).
The corpus moved 125/159 (the same 34 `compile_error` groups); the hatch-OFF
window (`QBE_MIDDRIVER=0` vs `f55bf1b^`) holds byte-identical 159/159.

**P1e — the frame-zero LOOP replaced by ONE bulk `memset` (measured).** The
per-slot loop (`Rt.frameZero`, 5 `wstore`s + counter `wload`/`wstore` + compare +
`jmps` per 40-byte slot) is now a single `rawcall memset(base, 0, 40*nslots)` in
`Rt.frame-enter` — the exact `@memset(hdr.slots[0..nslots], zeroValue())` Zig emits
(`rt.zig:281`).  Byte-equivalent: a Value is 5 words and the loop wrote five zero
WORDS per slot (40 zero bytes).  Zero-BEFORE-root is preserved — the memset is
emitted before `rt_root_push_value_array` (pinned).  `Rt.frameZero` is deleted;
header word 4 (the slots pointer) was the loop's counter and is now never written,
because the Mid frame path never reads it (`rt_root_push_value_array` takes
base+live).  Frame-perf gate: **1.4× → 0.97×** (median of 7 alternated pairs,
fib(28)=317811 on both arms, load 0.61) — the Mid frame path is now at parity
with, slightly faster than, the Zig arm.  Suite rule under load 5–13 (the box was
busy; session-2 A/A spread median 18.3%): total **1.08×** (ON 731 ms / OFF 676 ms),
down from the 2.22× aggregate and the ~1.25–1.33× pre-P1e floor.

**P1e item 2 (kill the `payload(mknum(..))` value selects in `Rt.frameBlock` /
`Rt.frame-leave`) — NOT DONE, and the brief's mechanism is WRONG.**  A rawAbi WORD
defun has NO word-join: `Lower.lowerTailWordBranches` rejects a tail `If` whose two
branches both return a word (`Lower.elm:1843`, no phi), and a word-valued `?:`/`if`
in a value slot is a loud `wordProducerMessage`.  The `mknum`-to-slot-then-`payload`
round-trip IS the word-join-via-memory idiom — the minimal expressible form.  To
remove it needs either a word-phi in Lower or a branchless select; both are bigger
than this unit's minimal mandate and risk the frame invariants (zero-before-root,
the freelist bound).  Deferred.

**re-freeze + full battery deferred to the consolidation pass** (the corpus
baseline and the bootstrap seed are STALE at the P1e commit — do not trust
`tools/bootstrap/compiler.ssa` or the corpus freeze against a post-P1e tree until
the consolidation pass re-runs them).

## THE ANTI-PATTERN THAT CAUSED ALL OF THIS (check this first, always)

**A `:val` LOOP IS A BLIT-AND-BOXING FACTORY.** Every `recur` of a `:val` defun copies
40 bytes per argument, and every `mknum(...)` allocates a Value. On a hot path this is
catastrophic — it is what made the frames **175×** slower than Zig (`frameZero` boxed a
number *per byte*, `nslots*40` allocations per call), and it is why `copyWords` was slow.

**Word loops must be rawAbi WORD defuns.** `lowerTailWord` now has the two arms that
make that expressible (a word-valued `If` join, and the self-tail `App` → `jmp @body`);
the nested-`If` case was silently miscompiled until a `TailShape` was threaded through.

## Methodology traps already paid for (do not repeat)

* **Correctness gates cannot see a perf regression.** A 175× runtime regression passed
  the corpus (checks BYTES), the churn rows (check OUTPUT) and TestMain (checks
  STRUCTURE). Only a clock sees speed — hence the ratio gates.
* **A residual the same size as the scan step is measuring the scan.** Before
  attributing a cost, confirm the probe's own overhead is small.
* **Measure USER time, or a ratio.** Wall clock on this box is load-dominated; `real ≈
  user` was the tell that the tier-2 parser regression was CPU (36 s → 0.80 s), while a
  loaded host fakes wall-clock deltas.
* **Check `/tmp` before believing a gate.** It is a shared 63 G tmpfs that repeatedly
  nears full and fabricates "failed to emit" errors. Use
  `TMPDIR=/home/jaye/osier-scratch` and re-run.

## THE ARC'S OWN SCOREBOARD (MEASURED, suite, arms alternated)

| commit | lever | suite total | apply gate | frame gate |
|---|---|---|---|---|
| `249b09a` | baseline (recorded) | **2.22×** | 9.3× | 1.6× |
| `7748887` | P1a — apply family's ~704 B/closure-call **leak** | 1.74× | 4.1× | 1.6× |
| `53be0c1` | P1b — 5 per-call re-blits of the same 40-byte `f` | 1.67× | 3.8× | 1.6× |
| `dcc15aa` | P1c — word-conditional `if`; frame path converted | 1.33× | 3.6× | **1.4×** |
| `b4fac81` | P1d — apply conditions + the two-range `rt_call2r` bridge | 1.25× (UNDECIDED that session) | **1.6×** | 1.4× |
| `af64afa` | P1e — the frame zeroing loop replaced by ONE `memset` | — | 1.6× | **0.97×** |
| `11a5f80` | consolidation (re-freeze + the stale-pin fix) | **1.06×** (load 8) | — | 0.97× |

Final per-programme ratios (load 8, A/A median spread 4-6%): adtmatch 1.19,
deepnontail 1.32, listbuild 1.10, localrec 1.14, mono_float 1.03, mono_int 1.18,
mono_record 1.00, nestagg 1.03, numloop 1.07, recflow 0.96, **recupd_local 0.86,
recupd_param 0.83** — the Mid route is now FASTER than the Zig arm on two
programmes and inside the spread on most of the rest.  The route penalty that
plan.md's R5 guard called a 3% ceiling is, at the end, 6% of the suite with two
programmes ahead.

**Ordering lesson (MEASURED): fix the CORRECTNESS leaks first.** P1a was one
commit of `free`s and it bought the single largest step (2.22× → 1.74×, and the
apply gate 9.3× → 4.1×) — the per-call `malloc` arena growth had been inflating
the Mid arm, not just leaking.  Two units then spent more for less.

## THE AGGREGATE — the per-op gates UNDERSTATE it (MEASURED 2026-10-17, `cf59488`)

The three ratio gates each measure **one retargeted family** and report 1.6× / 9.3× /
1.6×. plan.md §1.3's suite rule — the instrument the plan designates for a *route*
verdict — says the whole stage-6 migration (Path A + Path B) costs **2.2× on the
representative suite, and up to 4.2× on a single program**. Read that against the plan's
R5 guard ("selfhost wall regression ≤3%"): the guard is violated by two orders of
magnitude, so by §1.3 this route is **REFUTED on clocks** — and the owner's decision to
land it anyway is a *deliberate accepted debt*, not a measurement error.

Instrument: `tools/osier-bench.sh`, `OSIER_BENCH_RUNS=7 OSIER_BENCH_STAT=median`,
12 suite programs, arms **alternated**, 2 sessions + 2 same-day A/A arms.
`QBE_MIDDRIVER=1` (Mid route) vs `QBE_MIDDRIVER=0` (Zig route). Per-program medians:

| program | ON ms | OFF ms | ratio |
|---|---|---|---|
| adtmatch | 134 | 74 | 1.82 |
| deepnontail | 66 | 59 | 1.13 |
| listbuild | 47 | 33 | 1.42 |
| localrec | 12 | 12 | 0.96 |
| mono_float | 316 | 82 | 3.83 |
| mono_int | 298 | 71 | 4.20 |
| mono_record | 188 | 58 | 3.24 |
| nestagg | 220 | 156 | 1.41 |
| numloop | 14 | 14 | 1.04 |
| recflow | 67 | 34 | 1.94 |
| recupd_local | 114 | 64 | 1.78 |
| recupd_param | 78 | 44 | 1.79 |
| **TOTAL** | **1554** | **702** | **2.22** |

Same-day A/A spread (max−min)/median: **median 5.0% / max 18.3%** (session 1) and
**1.3% / 15.9%** (session 2) — i.e. every ratio above 1.4 is outside the spread, and the
big ones are 10–20× outside it. Cross-checked by hand: `mono_int` built both arms,
median of 7 raw runs, **313 ms vs 80 ms (3.9×)** — not a bench artifact.

**Why the per-op gates understate it:** each gate's fixture is dominated by the family it
retargets, but a *program* pays the three families **together** plus the Mid driver on
every entry. fib (1.6×) is a direct-call recursion that barely touches apply or tail;
mono_int (4.2×) is closure/record-heavy and pays all three. **A per-family gate cannot see
the sum — that is what the suite is for, and the plan said so.**

Route penalty vs the plan's pre-arc projection (§3 phase-3 note: "numloop ~0%, mono_int
~+3%, localrec ≤0%, nestagg +5…10%, listbuild +2…13%, mono_float +10…28%, adtmatch
+26…45%"): the measured `mono_float` **+286%** and `mono_int` **+320%** are an order of
magnitude past the projection. That projection was a PROJECTION; this table is MEASURED.

## Recommended order when this is picked up

1. **Save the pre-B4 Zig-arm binary** — DONE, see "The pre-B4 reference binaries".
2. **Run the §1.3 suite rule ON vs OFF** — DONE, see "THE AGGREGATE" (2.22×).
3. **apply (9.3×)** — the biggest absolute cost and the hottest path; it compounds into
   every closure and tail call.
4. **tail (2.5×)** — the jump table and the `malloc(80)`.
5. **frames (1.6×)** — the boxed-boolean conds — **DONE (P1c)**: the frame
   path's boxed-boolean conditions are the word form now, 1.6× → 1.4×; and the
   word-zero loop — **DONE (P1e)**: one bulk `memset`, 1.4× → 0.97×.  The only
   remaining frame-path item is the `payload(mknum(..))` value select (needs a
   word-join Lower does not have) — deferred, see the P1e note above.
