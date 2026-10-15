# Osier — status snapshot

Updated 2026-10-11 (last edit: **phase 3 (E+(A)) implemented, reviewed, blocked, fixed, re-reviewed CLEAN — verdict MIXED; tree UNCOMMITTED**). **This is the short-lived status file. The
durable plan is `plan.md`** (same directory) — oracles, hatches, the decision rule, the phases,
settled/superseded decisions, the coherence bugs and the traps all live there. When this file and
`plan.md` disagree, `plan.md` wins and this file is stale.

Repo `/home/jaye/futaie/osier` · `HEAD = 80f0f2f` (**not pushed**)
Tree: **clean** apart from the by-convention dirty `elm-compiler/.elm-cache/…/registry.dat` and the
untracked-by-design `plan.md`/`todo.md`/`todo-osier.md`. Phase 3 landed as `42abb97` (the epoch),
`a53aa2b` (`zig build gate` wired into `osier-numbers.sh` as step 6), `42fff12` (the `todo-osier.md`
refresh). `plan.md` and `todo.md` are untracked by design — a running agent's `git status` stays
meaningful and no attribution epoch is polluted.

---

## The sequence

```
DONE     0  ZINC/VM retirement; Mid-tier + Mid runtime v1 (the flip)
DONE     1  midabi — the Rt lean ABI          commit 2d127d1   PARTIAL: -49.1%, +38% remains
DONE     2  B / S5 — monomorphisation         S2 159198d, S5 00cc7da — REFUTE but KEPT (mechanism fires, win capped by the boxed ABI)
DONE     3  E + (A) — positional records + cons-as-one-pointer, ONE epoch   commit 42abb97, verdict CONFIRM
              four record programs 2.35×-8× faster, adtmatch NEUTRAL (a load artifact had read as a regression);
              3 review blockers fixed + re-reviewed clean
DONE     3b typespec Unit B (binder-map Int specialization)   commit 80f0f2f — suite 867/865 vs 1024/1027 ms ON/OFF
              (a quiet window, load ~1.3); its review found TWO silent wrong answers in item 3 (host-built records,
              Record.remove chains) now fixed WITH a registered fail-before/pass-after gate guard (gate 157/0)
NEXT     4  a FRESH non-moving mark-sweep collector in Mid
LATER    5  Lua backend ("Osier without a compiler")
WIP      4b retiring Zig — the runtime written in Mid   gate NOT REFUTED, SPLIT (owner 2026-10-12)
              stages 1-2 DONE (64515c6, emit-inert) · stage 3 DONE (e3091bb: the Rt.= symbol byte walk; acceptance
              CLOSED adtmatch 1.443->1.072, but the zero-rt_prim EXIT CONDITION is NOT met — 117 host-only sites remain)
              stages 4 (the collector) next; 5-6 gated on stage 3's exit condition
LATER    6  node-lane retirement          (the elm/node lane the gate still depends on — see plan.md §6)
LATER    7  GADT-indexed AST (`Exp mode`) (blocked until 6: elm 0.19.2 has no GADTs)
LATER    8  corpus / paper
```

## The number that matters right now

**Phase 3 (E+(A)) record programs — RE-RUN 2026-10-12 on a less-loaded host (the first pass was on a
loaded machine and reported a spurious `adtmatch` regression). Arms alternated `default` vs
`QBE_NOREC=1`, `OSIER_BENCH_RUNS=7 OSIER_BENCH_STAT=median`, 2 sessions, load snapshotted per arm
(~8–10 on 32 cores — still not quiet), ms (my own runs):**

| program | E-ON | E-OFF | ratio |
|---|---|---|---|
| recflow | 64 / 62 | 305 / 295 | **4.8× faster** |
| recupd_local | 84 / 80 | 391 / 385 | **4.7× faster** |
| recupd_param | 67 / 60 | 505 / 510 | **8.0× faster** |
| mono_record | 167 / 161 | 441 / 331 | **2.35× faster** |
| **adtmatch** | **165 / 154** | **164 / 155** | **1.00× — NEUTRAL** |
| total (5) | **547 / 517** | 1806 / 1676 | 3.3× faster |

Full suite (12 programs, default) **1079 / 1061 ms**. **Verdict CONFIRM** on the four; **`adtmatch`
UNDECIDED** (1.00× inside the spread — NOT the REFUTE the loaded run suggested).
`mono_record`'s old "pending, not refuting" is resolved **in E's favour** (2.35×).
**`QBE_NOCONSARR=1` is emit-only, not a runtime arm** (it halts/core-dumps — §6).
**Load sensitivity (a new trap): only within-session alternated pairs are evidence** — the loaded run
gave `adtmatch` 222/`mono_record` 248 on the *same tree*; snapshot `loadavg` per arm and never compare
totals across sessions.

## Oracles — verified green on the phase-3 tree (my own re-runs where noted)

`qbe-check` **270/0** · gate **PASS=154 FAIL=0** · `zig build test` **38/38** (NEW — it was RED at
36/38 and in NO oracle; the reviewer re-ran it) · corpus **BYTE-IDENTICAL 149/149** (gating) ·
`test-run.js` **111/111** · `primsdiff` **92/92** · consdiff **14/14** · `lake build` exit 0,
**90 theorems / 3 axioms** · seed **18,783,657 B** (was 14,407,846) · hatch
`QBE_NOCONSARR=1 + QBE_NOREC=1` vs the `00cc7da` baseline → **148/149**, `remrec.ssa` the only diff
(flag-independent `Prelude.removeFieldImpl → recToChain`); I reproduced this myself.

## S5/M2 monomorphisation — **COMMITTED `00cc7da`, 2026-10-11 — REFUTE, KEPT**

- **The verdict is a statement about the INSTRUMENT, not about monomorphisation.** Across all twelve
  suite programs the pass engages in only three, and the seven clones it produces are all 90-line
  bodies differing from their originals by **exactly one line** (a shared data label); nine programs
  engage it not at all. The pre-stated bar was honest and blind.
- **The missing instrument now exists**: `tools/bench/monoarith.elm` — the arithmetic ON the
  polymorphic parameter (the suite's mono axis puts it in a closure, where a clone can unbox
  nothing). There the clone is 80 lines vs 154, frame 16 → 10 slots, fallback calls **4 → 1**
  (`<` and both `-` raw; self-calls rewritten), and the mandated protocol gives **47.6 → 47.5 ms,
  −0.2%, A/A spread 0.4 ms** across 15-run medians, alternated arms, 2 sessions. Mechanism real,
  win capped by the **boxed ABI** (identical allocation pattern; `rt_bounce` on every self-call;
  `intParamsOf` can only prove a PARAMETER `Int`, so `+` on two call results stays dynamic).
- **KEPT by owner decision** — no measurable cost, and it is the consumer that will make phase 3/E's
  representation change pay. Honest carried cost: **+1.96% emitted corpus `.ssa`** for no win today.
- The specialiser EXISTS and runs: `elm-compiler/src/Mid/Qbe/Monomorphise.elm` (new), default ON,
  hatched by `QBE_NOMONO=1` through `run.js → Main.elm → Mid.QbeModule → the pass`, with
  `selfhost/NativeMain.elm`'s hard-coded vector updated to **seven** True and
  `Mid/Qbe/Monomorphise.elm` added to `selfhost/manifest.json` (**67 → 68** sources — the
  bootstrap's own front end rejected `String.split` and `<<`, so the pass is written in the subset
  the tree compiles itself with).
- **ORACLE 1 — REFUTE.** `OSIER_BENCH_RUNS=7 OSIER_BENCH_STAT=median`, arms alternated, 2 sessions:
  `mono_int` OFF medians {69,68,67,67} → 67.5, ON {68,69,65,69} → 68.5 (**+1.5%**); `mono_float`
  OFF 78, ON 78 (**0.0%**). A/A spread on the same runs: 65–69 and 77–79 ms. Both < 10% → REFUTE.
  The static counters DO move (2 clones, 4 sites converted) but the emitted **instructions do not**:
  the clone of `fold` at Int is byte-identical to the original apart from one data label, because
  `intParamsOf` yields only `acc` and `fold` never does arithmetic on `acc`.
- **The mechanism IS real on the `fib` shape** (fixture `tools/qbe/fixtures/mono.elm`, rows
  `mono-fired`): the clone loses its `q_Rt_x2e_x3c`/`q_Rt_x2e_x2d` fallbacks (0/0 vs the original's
  1/2), its rt_prim sites drop 4 → 1, its frame block 16 → 10 slots. An early ad-hoc A/B on that
  fixture (−0.8% / +0.8%, two sessions) is **superseded and must not be quoted** — that fixture's
  whole workload is ~500 operations, so it cannot resolve anything; the properly-powered measurement
  on the same shape is the `tools/bench/monoarith.elm` one above.
- **ORACLE 2 — green.** `qbe-check` **270/0** (was 256/0; +14 rows, `mono-*`), gate **PASS=154
  FAIL=0**, `osier-numbers.sh` exit 0 **VERDICT: all checks pass**, TestMain 111/111, lake 90
  theorems / 0 sorry. Attribution: `QBE_NOMONO=1` reproduces `159198d`'s committed corpus baseline
  **149/149 byte-for-byte** (re-run after the corpus freeze against `git show HEAD:`), and the
  corpus `.ssa` grew **+136,107 B (+1.96%)** across 149 artifacts (66 byte-identical — the pass
  decided nothing there). Seed re-frozen: **12,691,624 → 14,407,846 B** (+13.5%, well under the 2×
  guard) — that growth is the COMPILER's own new source in the self-hosted emit, NOT clone
  duplication (the pass's duplication cost is the corpus +1.96% above); ABI marker UNCHANGED,
  `seed status: FRESH`; the stub-PATH node-free bootstrap builds with
  the stubbed `node`/`elm` never invoked (invocation log absent).
- The refusal predicate, deny-by-default, and which fixture fires each clause (all POSITIVE
  programs): **(b) rigid** is TOTAL and pre-derivation — `bound ⊆ quantifiers = freeVars body`, so
  no instantiation can close; `MonoRefuse.hget` (`refused_b=1`). **(c) refined** —
  `MonoRefuse.hgetPlain`'s `box x`, an INFERRED helper (so (b) cannot mask it) applied to a
  `Here`-branch-refined binder (`refused_c=1`). **(a) unclosed** — `MonoRefuse.apply2`'s
  `fold f acc xs`, whose arguments are the enclosing polymorphic defun's own type variables
  (`refused_a=1`). **untyped** — `MonoRefuse.fold`, a literal/application argument. Cap = 16 clones
  per defun (not exercised by any fixture; recorded when hit).
- **Two carried items, both in "Open" and "Next action" below** and not repeated here: the
  `qbe-bootstrap.sh --freeze` truncation footgun (which this unit hit twice) and the still-unrun
  `--verify` half of the seed story.

## Open, unrelated to S5

- **`tools/qbe-bootstrap.sh --verify` (~742 s) has never been re-run** since the seed moved;
  `--freeze` + the stub-PATH build are green. This is the untested half of the seed story.
- **`Mid.Rt.allocating` has a named latent hole** (`safepointMatch` returns `False`; harmless today
  because no `Case`/`MLitEq` string arm reaches an Rt body — one-line fix when it matters).
- **`QBE_MIDZIG=1` is a dead hatch** — finish deleting it or re-document it.
- **S6 (unboxed aggregates) has a stale precondition**: it is gated on approval for
  `vendor/zinc-vm`, which was deleted in P8. The layout descriptor now belongs to the new
  mark-sweep (plan.md §3).
- **Reviews pending** (GLM credit permitting): `Mid.Rt.allocating`'s closure completeness, and
  step 1's framed-defun cost as the residual's unexplained half.

## Next action

1. **Zig retirement is mid-flight** (plan.md §3 Phase 4b): stages 1-2 (`64515c6`) and stage 3 (`e3091bb`)
   committed; **stages 4 (the collector in Mid) is next**, with 5-6 gated on stage 3's exit condition.
   Stage 3's remaining ownable work is the 61-host-prim port (fd/value/intern/str) — it does NOT move
   the acceptance test, which has already closed.
2. **NEW INSTRUMENT: `tools/bench/elm-corpus/`** (`bcd858c`) — the whole published Elm registry
   (2765 packages, 17,359 files, 6.1M lines). Use it before concluding anything about USER code: the
   12-program suite said a prim operand needs an expression type 5 times; real Elm says 50% of operator
   sites. The join-key question in `handoff-osier-typespec-plan` is NOT closed.
2. **The corpus says the dialect is the constraint, not the module system** (`bcd858c`, `f718b59`):
   OK=24/2776 packages, and the top failure classes are the LEXER (`<<`/`>>`/`^`/`|>`/`|.` ≈ 357 files),
   629 `parse failed` (uncharacterized), and missing builtins/modules. Decision recorded as
   `osier-module-system-decision`: do NOT build Elm module-system compatibility (rank-2 + first-class
   modules + modular implicits will replace it); DO fix the operator lexer and grow `core-libs`.
   Separately and independently: 4 real packages hit `cannot unify <T> with {field:a| b}` — our checker
   refusing the extensible-record idiom this project exists for.
3. **`push`?** The three commits are local only. Nothing pushes without the owner's word.
4. Carried, non-blocking: `recUpd`/`recInsert`/`recAppend` primsdiff batches (accepted residual — no
   Zig reference arm; `recGet` IS now fired); `tools/qbe-bootstrap.sh --freeze` writes the emit payload
   ONTO the committed seed, so a mid-freeze failure truncates it (hit twice, 51/53 B — restored from
   `HEAD`); emit-to-temp + atomic rename is the fix. `--verify` (~742 s) still unrun since the seed moved.
