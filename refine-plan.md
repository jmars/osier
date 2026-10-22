# refinement on branches — the plan

Status: **PLAN, not implemented.** Written 2026-10-18 at `c475008` (after the C-FFI arc, before the
stage-7 effect-loop port). Provenance: two planner rounds —
`/home/jaye/osier-scratch/refine-plan.md` (round 1, superseded on the centrepiece but its measurements
stand) and `/home/jaye/osier-scratch/refine-plan2.md` (round 2, this plan's source); memory nodes
`handoff-refine-plan`, `handoff-refine-plan2-plan`. A killed first attempt at M1 left ~585 lines of
unwired, unverified `Refine/{Pred,Entail}.elm` at `/home/jaye/osier-scratch/refine-m1-wip/`.

## 1. The shape: a branch *context*, not a solver bolted on

Osier already refines TYPES per pattern branch: `Type/Unify.elm`'s `unifyBranch` captures a would-be
rigid binding as a delayed `Equation` on a store, and `dropEqsFrom` discharges it at branch end
(`Type/Infer.elm`'s `refinedTypeEqs`/`refinedVars` survive the branch by design). That is a
hypothetical context Γ with discharge — a sequent-shaped mechanism without the name.

The feature adds a **second kind of assumption** to the same context position: a guard's PREDICATE.
So a branch is typed under

    Γ ∧ pattern-facts(type equations, exists today) ∧ guard-facts(new)

and Mid's `if` is the same thing one constructor down (`checkIf` arms + the `SIf` continuation), which
is where the payoff lives because the runtime's guards are early-return `if`s.

**The one-function rule** (what makes this cheap): the fact extractor and the validity test are the
same function. A guard cannot be both "the hypothesis" and "the obligation", so states like
`if (fd >= 0)` hold no interest; the interesting shape is `if (fd < 0) { return }` followed by a use.

## 2. Three verdicts, and why the third one matters

Every obligation — `a[i]` in bounds, `fd >= 0` before use, non-null before deref, the collector's
accounting — is decided against Γ:

| verdict | action |
|---|---|
| **PROVED** | discharge statically; emit **nothing** (the dropped check is the measurable win) |
| **UNKNOWN** | emit a runtime check: a named `die`-shaped trap (there is no warning channel in this compiler — a die is cheaper than inventing one) |
| **REFUTED** | loud reject, named judgment (J16), naming the obligation and the site |

Round 1 proposed "reject on UNKNOWN, never a runtime check". That is the wrong default: with no
solver yet, everything is UNKNOWN and the feature would reject working code. The triad is what lets
the arc land incrementally — no solver still means contracts.

## 3. The decidable fragment, and why it is in-house

Difference logic over integer terms with constant coefficients: atoms `x - y <= c`, `=`, `!=`, and
per-variable intervals; Γ is a conjunction and an `if` splits it structurally. Out: var×var, div/mod,
pointer ordering, floats. `Refine/Entail.entails : Γ -> List Atom -> Verdict`.

**Z3 is not "deferred", it is unrepresentable**: this compiler bootstraps from a committed `.ssa`
through `qbe`+`cc`, so a compile-time subprocess can never be part of the fixed point. The interface
still allows a different backend later.

Two rules the solver must be pinned to (rows, not prose): **intervals may never refute** (a widening
answer is `Unknown`, not `Refuted`), and a fact about `i` must never prove a fact about `j`.

## 4. Kill semantics on a mutable language

| # | rule |
|---|---|
| K1 | a store to `x` drops every fact mentioning `x`, then re-establishes from the stored term |
| K2 | `&x` passed anywhere drops facts about `x` **and** every binder in `frameAddr`'s provenance set (nothing else produces an address, so this is complete today) |
| K3 | each bind mints a fresh key and kills the old name's facts (Mid keys facts by NAME; Osier by binder id) |
| K4 | **as corrected**: the loop body sees `(Γ ∖ facts about any variable assigned anywhere in the body) ∧ facts(cond)`. Round 1's form ("pre-loop Γ plus cond") is UNSOUND — a back edge re-executes, so `i = 0` is false at iteration 2. The condition is re-established each iteration, which is why the rule still pays |
| K5 | a `call`/`rawcall` kills nothing (only K2 reaches a word binder) |
| K6 | pointer facts are the NULL class only (`p = 0`, `p != 0`), and a `p != 0` fact is dropped at any safepoint where `p` is reloaded from a field (the collector moves objects) |

**Residual unsoundness, stated:** a fact kept across a `call` trusts K5 — a callee writing through a
pointer to a frame variable is caught only when the `&x` is visible. Widening can over-drop, never
over-prove, so its failure mode is UNPROVEN, which is visible.

## 5. The four properties this arc exists to deliver

### P1 — `fd >= 0` before use (the errno class) — **the measured value**

MEASURED: `runtime.mid` has **141** `rawcall` sites, of which **65** bind a result, and of those
**53 are already guarded** (PROVED for free — no runtime check emitted) and **12 are unguarded**.
62 discarded + 14 nested results are honestly out of scope (they are not obligations).

Pair: a binder whose convention-coded result is used without a guard is REFUTED (today it compiles
and silently misbehaves — the C-FFI arc found exactly this class); the guarded twin is accepted with
the check dropped.

### P2 — `a[i]` inside `TArray elem n` — honest: mostly PROSPECTIVE

MEASURED: **0** fixed arrays in `runtime.mid` before the C-FFI arc, **1** now
(`tools/qbe/fixtures/ffim-mem.mid`'s `word[2] fds; … fds[1]`, a gate row). So bounds pays in USER Mid,
not in the runtime. It is still the cheapest slice to build (zero blast radius) and it is what proves
the judgment works.

Pair: `if (i >= 4)` proves `i` in bounds for `word[4]`; `if (i > 4)` leaves it UNKNOWN; an unguarded
`a[i]` is REFUTED. One-character differences, which is the sharpest oracle in the arc.

### P3 — the collector's accounting

`allocated' <= heapBytes` at the recursive call in `Rt.gcAlloc`/`gcAllocGo` (the size-class invariant
a wrong guard silently corrupts). This is where difference logic runs out: the obligation needs
`allocated + step <= heapBytes` with `step = phys*8`, so the invariant must be **named** — the unit
carries a small `runtime.mid` refactor to state it as a defun premise.

### P4 — Phase-7 index refinements: what must not be foreclosed

Facts keyed by binder with a stable identity, a verdict interface that a GADT index obligation can
reuse, and the guard-fact extractor being usable from Osier's `case` arms. Nothing in M1–M5 should
put a Mid-specific assumption into `Refine/*` (the core must import nothing from `Mid.*`, so Osier
reuses it verbatim).

**Explicitly NOT this arc:** the `val` rooting obligation and Mid's containment contracts. Those are
SUBSTRUCTURAL (uniqueness/affinity — a context discipline where Γ splits across premises), not
refinement predicates. Keeping the two apart is the reason to name the context a context.

## 6. Units, in the order that delivers the list

| U | property | files | oracle | risk | cost |
|---|---|---|---|---|---|
| **M1** | the context + the judgment, first client `a[i]` | `Refine/{Pred,Entail}.elm` (new), `Mid/RtLang/Check.elm`, `TestMain.elm`, fixtures, `qbe-check.sh` | P2's pair + the must-not-prove and must-not-refute rows; UNKNOWN = J16 here, **pinned to flip in M2** | low | 2–4 h |
| **M2** | the emitted check: UNKNOWN becomes a named trap, PROVED emits nothing | `Mid/RtLang/Ast.elm` (`EAssert`), `Check.elm` | the same pair, now with the trap visible in the `.ssa` *and* on stderr; PROVED emits no check | med | 2–4 h |
| **M3** | the errno class: a convention-coded result may not be read unguarded | `Ast.elm` (`rawcallConvention`), `Check.elm`, `runtime.mid` (12 sites) | P1's pair; the 53 already-guarded sites must keep compiling with **no** emitted check | med | 3–5 h |
| **O1** | Osier's `if` predicate half (no store change) | `Type/Infer.elm` | a contradiction fixture: each arm sees only its own facts; `refinedVars`/`nodeTypes` unchanged | low | 1–2 h |
| **M4** | loop-body intervals (corrected K4 + widening) | `Check.elm`, `Refine/Entail.elm` | `for k<6` accepted vs `while j<=6` refuted (one character); widening must yield Unknown, never Refuted | med | 3–5 h |
| **M5** | the defun contract (P3, the collector) | `Ast.elm` (`defunPre`), `Check.elm`, `runtime.mid` | the accounting obligation proved at the recursive call; the entry guard is checked against the premise (a two-way check) | high | 4–6 h |
| **O2** | the guarded `case` arm (`when`) — the Shen shape | `Elm/Syntax/Expression.elm`, the parser, `Type/Infer.elm`, `Type/Exhaustive.elm`, `Mid/FromAst.elm` | a guarded arm does NOT cover its pattern (non-exhaustive today) — accepted twin + the fall-through golden | **high** | 3–5 h |

Two notes that decide details rather than scope:

* **O2 is the owner's shape** (`case v of Just n when n > 0 -> …`) and it buys ergonomics, not new
  proof power. Its lowering is NOT free: `Mid.Ir.Match` is a closed set of pattern tests with no
  boolean-expression test, so a guard cannot be another match without a new IR node (out of this
  arc's scope). The plan desugars in `FromAst` to `EIfBlock guard body (Case scrut rest)`, which
  re-matches an already-bound scrutinee — sound because Osier is pure — and therefore duplicates the
  remaining alternatives, so it must refuse loudly above a named bound.
* **Exhaustiveness**: a guarded arm does not cover its pattern (a false guard falls through), so
  `Type/Exhaustive.elm` must drop guarded rows. The row that pins it: `Just n when n > 0 -> … ;
  Nothing -> 0` is accepted today and must be refused.

## 7. Oracle rule for every unit (this is what keeps the arc honest)

Each unit ships a **program that is accepted/rejected for the right reason, shown asymmetric**: one
that compiles and then misbehaves at runtime (or is silently wrong) and that the new judgment rejects
or traps, plus its compliant twin that still compiles — and where a claim is static, the `.ssa` shows
the check present (UNKNOWN) or absent (PROVED). A refinement checker nobody has seen fail is not a
checker.

Fast oracles per unit: `node osier-compiler/test-run.js`, `tools/osier-corpus-ssa.sh`,
`tools/qbe-bootstrap.sh --status` (`… FAILED: err …` is a hard break — it has caught five of them).
The 20-minute `qbe-check.sh` battery belongs to a consolidation pass covering several units, never to
a single unit.

## 8. Open decisions

1. **M2 or O1 as the second unit** — reversible either way, no cost difference.
2. **Is the `when` surface wanted at all** (O2)? It is the owner's requested shape; it buys
   ergonomics and the fall-through chain and no new proof power, at high risk (widening `Case` makes
   every consumer a type error, which is at least loud).
3. **Does `payload(v, k)` ever become a term form?** Today it is out of the fragment; keeping it out
   is what keeps the fragment decidable.
