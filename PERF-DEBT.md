# PERF-DEBT — the Mid runtime's performance floors (deferred)

Recorded 2026-10-17 at HEAD `42ad241` (stage-6 Path B: B0 frames, B1 apply, B2 tail landed).
This file exists so the debt is not lost when the baseline it is measured against is deleted.

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

### 3. frames — **1.6×** — the floor (lowest priority)

The residual after `frameZero` became a raw-word loop. Causes: the
`frameBlock`/`enter`/`leave` **boxed-boolean condition machinery** (`mkbool` builds a
Value per condition) and the word loop's per-slot counter round-trip.

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

## Recommended order when this is picked up

1. **Save the pre-B4 Zig-arm binary** (see the top of this file) — everything else
   depends on it.
2. **apply (9.3×)** — the biggest absolute cost and the hottest path; it compounds into
   every closure and tail call.
3. **tail (2.5×)** — the jump table and the `malloc(80)`.
4. **frames (1.6×)** — the boxed-boolean conds; lowest payoff, most invasive.
