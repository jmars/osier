# Paper plan — Withe / λρG (handoff `rowgadt`, stage `plan`)

Plan for the paper itself: structure, claims, evidence, venue, gaps. Written so that drafting
becomes execution rather than design. Every claim carries its evidence pointer and an
**[M]** measured / **[I]** interpretation / **[P]** projection marker. Pointers verified on the
committed tree (`0207dd2`, branch `main`) on **2026-10-05** by the planning unit itself where
marked ✎; pointers taken from `handoff-rowgadt-meta`'s verified addendum are marked ✎-meta and
must be re-grepped against the paper-frozen commit at drafting time (the `l3ii` lesson: a comment
edit shifted a fixture's error line 20:13 → 24:13; **the byte-identity invariant outranks
comments, and line numbers drift**).

What this unit re-measured itself (✎, 2026-10-05, tree at `0207dd2`):

- `tests/elm-fixtures/run-elm-gate.sh` → **PASS=151 FAIL=0** [M ✎ 2026-10-05, after the exhaustiveness/refutation work].
- `lake build -q` in `lean/` (ELAN_HOME=/var/data/workspace/lean/elan) → **exit 0, zero output** [M ✎].
- `rg -n '^\s*theorem '` → **90 theorems** in the full tree: RowGadt.lean 28, RowGadtEscape.lean 4,
  Update.lean 11 (= **43**, the row-algebra trio) **plus** TypingStore.lean 29 and Preserve.lean 18
  from the typing-judgment arc [M ✎]. Zero `sorry`/`admit`; **3 `axiom`s** -- the explicit
  parameters `Unifies`/`Captures` (Typing.lean:221,229) and `unifies_field_projection`
  (Preserve.lean:213). (This line previously said 43 and "zero axiom"; both were stale.)
- The 19 rowgadt fixtures registered in the gate (`run-elm-gate.sh:557-623`): 10 `compile_clean`,
  9+1 `compile_error` (count: 10 error — see the fixture matrix, §7) [M ✎].
- Code seats re-grepped: `Type/Unify.elm` (`dropEqsFrom:99`, `dischargeType:133`,
  `dischargeRow:166`, `unifyBranch:238`); `Type/Infer.elm` (`insertion rejection:971`,
  `dischargeSetterM:1037`, `restrictField:1124`, `generalizationRigid:1249`,
  `unifyClauseResultM:1640`, `tailReachesHead:1708`, `dropIntroduced:1720`, `rebuildMatches:1740`,
  `findEquation:1773`); `Type/Builtins.elm` (`trustedBodies:340`, runTask entry `:379`);
  `Runtime.elm` (`type Task:19`, `TaskExec a : Task x (Int,String,String):28`, `runTask:178`) [M ✎].

Companion inputs (read in full by this unit): `docs/research/row-gadt.md` (565 lines, the paper
seed), `docs/research/row-gadt-calculus.md` (1281 lines, λρG), `docs/research/withe-related-work.md`
(601 lines, the survey), `lean/*.lean`, and the memory chain `handoff-rowgadt-{ctx,meta,lit3,result}`.

---

## 0. The one thing the drafting units must know before anything else

**`row-gadt-calculus.md` §5.3 and §5.4 are STALE, and §8.2 is stale.** [M — read against the
Lean tree by this unit]

- §5.3 says H1 is "argued, not proved" and "the duplicate-label probe was never built"
  (row-gadt-calculus.md:981-985). **Superseded**: H1 is mechanized *including* the duplicate case —
  `h1_find_commutes` (RowGadt.lean:151), `h1_duplicate_shadow` (:172), `h1_no_shadow` (:183),
  `h1_head_only_vs_full` (:195 — the theorem that CORRECTS the spec: the "for every label m" form
  holds only in the rigid-tail regime), `h1_discharge_head_agrees` (:205) — and the duplicate-label
  probes exist as gate fixtures `rowgadt_dup_rebuild` (clean) / `rowgadt_dup_fewer` (the pinned
  false reject) (`run-elm-gate.sh:617-623`).
- §5.4/§8.2 describe `escapeViaTail` as the direct-shape check with the transitive-alias hole
  (row-gadt-calculus.md:1021-1035, 1160-1171). **Superseded twice over**: (a) the adversarial hunt
  found and fixed two *real* unsound accepts (let-laundering; wildcard sibling leak) — mechanized in
  `lean/RowGadtEscape.lean` (`H2b_no_quantify_refined_tail:97`, `H2b_wildcard_leak_shape:124`);
  (b) the check is now **domain-based** (`dropIntroduced`/`tailReachesHead`/`rebuildMatches`,
  `Type/Infer.elm:1708-1760`), and its exactness boundary is *proved*: `h2b_domain_exactness`
  (RowGadt.lean:410) — exact for fresh labels, coarse for duplicates — with the over-approximation
  itself a theorem (`h2b_overapproximation`, RowGadt.lean:614).
- `row-gadt.md` §7.3 inherits the same stale H2 wording (the "coarse … pre-existing false reject
  via occurs" sentence at row-gadt.md:423-427 describes the *syntactic* check; the domain rule
  fixed exactly that false reject, and `rowgadt_shape_rebuild` is the clean fixture that proves it).

**Consequence for the paper**: the metatheory section is written from the **Lean theorem names**
(§C of the claim table below) as ground truth, with the calculus doc as the rule source and the
two stale passages rewritten. The doc updates are gap item **G6** (doc edits only; no code).

The second thing: **the negative-result theorem (§6 of the calculus doc) and the update theorem
(§7) are pencil-only statements**; the update/insertion half is now mechanized
(`lean/Update.lean`), the λρG⁻ unsoundness theorem is not. Do not conflate their statuses.

---

## 1. Venue and shape

### 1.1 The call

**Primary target: ICFP 2027, research-track full paper.** [I] — and the reasoning is a venue
calibration the whole plan rests on:

- **It is not a POPL paper as the evidence stands.** [I] POPL expects the metatheory to carry the
  paper, and the load-bearing soundness statements — T1 progress, T2 preservation
  (row-gadt-calculus.md §4) — are **argued, not proved, and not mechanized**. The Lean development
  mechanizes the *row algebra* (rewrite/store/escape/update as standalone statements), not the
  typing judgment. A POPL referee reads "no soundness theorem for the calculus" as a reject
  regardless of how good the implementation story is. Closing that gap is a 2–4-week
  pencil-and-mechanization project (gap G9) — not worth distorting the paper's honest frame into
  a proof claim it cannot back.
- **It is more than a workshop or symposium paper.** [I] The content is a calculus, a novel
  mechanized commutation lemma, a measured principality boundary, an adversarial soundness
  result, and a byte-identity implementation study — above the ML Family Workshop / Haskell
  Symposium weight class, and squarely in ICFP's tradition of "type-system design + honest
  implementation experience" papers. ICFP is also the community that knows Leijen scoped labels,
  Elm-family languages, and OCaml's GADT corner — the paper's related work is *their* literature.
- **OOPSLA 2027 Round 2 (April 2027)** is the fallback if the internal review (G10) finds the
  metatheory presentation too thin for ICFP: OOPSLA's two-round revise model tolerates a
  "discipline + mechanical evidence" framing better, and the extra 6 weeks allow G9-lite (a
  pencil T2 proof sketch). [P]

Measured venue facts (retrieved from the CfPs 2026-10-05): [M]

- ICFP 2026: "limit of **25 pages** for a full paper … adhere to the **ACM Small** format";
  double-blind; submission via HotCRP (icfp26.sigplan.org/track/icfp-2026-icfp-papers).
- **ICFP 2027: papers submission deadline Thu 25 Feb 2027** (icfp27.sigplan.org); page limit for
  2027 **not yet posted — verify when the CfP lands** (gap G1). Assume 25 pp ACM Small, excluding
  bibliography, as in 2026.
- POPL 2027 (for reference): 25 pp acmsmall excluding bibliography, deadline 9 Jul 2026 (passed).
- OOPSLA 2027: Round 1 Oct 14 2026, Round 2 Apr 7 2027 (conf.researchr.org track page).
- Haskell Symposium 2026 (for reference): regular paper 25 pp in a single-column format.
- ML Family Workshop 2026: informal, proposal-selected (no proceedings weight).

**Timeline** [P]: gap list (§10) executed Nov 2026 → drafting Dec 2026–Jan 2027 → internal review
(reviewer preset) + revision early Feb 2027 → submit ICFP, 25 Feb 2027. This leaves ~4.7 months
against ~6 weeks of work; slack is deliberate (single author, hobby cadence).

### 1.2 Shape and page budget

25 pp ACM Small (acmart), excluding bibliography; double-blind (write §6 and the artifact note
without repo URLs; self-reference as "the artifact"). Budget [P]:

| § | content | pp |
|---|---|---|
| 1 | Introduction (tension, crux, gap, contributions) | 3.0 |
| 2 | λρG: syntax, kinds, judgment, rules | 4.5 |
| 3 | The two-tier rule and the operation-level answer | 3.0 |
| 4 | Metatheory: mechanized, argued, refuted | 3.0 |
| 5 | The principality boundary | 1.5 |
| 6 | Implementation and measured correspondence | 3.5 |
| 7 | Related work (feature-pair map) | 2.5 |
| 8 | Limitations and future work | 1.0 |
| 9 | Conclusion | 0.25 |
| — | figures/tables beyond inline (F1, F3, F5, F6, T1) | ~2.25 |
| | **total** | **~25** |

**Over-budget cuts, in order** [P]: (1) the encoding subsection (§5.2 — keep one paragraph); (2)
the trusted-body decomposition table (T2 — keep the runTask instance prose); (3) related-work
§7 compress to 2 pp; (4) the operational-semantics figure (state the first-occurrence
correspondence in prose). Never cut: §3's counterexample pair, §4's honesty paragraph, §8.

### 1.3 The workshop version (if the gap list does not close, or as a first outing)

ML Family Workshop or Haskell Symposium, 10–12 pp: keep §1, §3, §6 (the motivation, the rule, the
implementation); compress the calculus to 1.5 pp (judgment + the two-tier rule only); one
paragraph each for metatheory and principality; related work 1 pp. Cut entirely: the Lean theorem
inventory, the encoding, the [U]/[S] correspondence list. The fixture matrix (T1) stays — it is the
evidence spine and it is small. [P]

---

## 2. Title and abstract

### 2.1 Title

**Primary**: *Rows under Refinement: Branch-Local GADT Equations for Extensible Records*

Alternates (decide at drafting; the primary names the phenomenon, which survives double-blind
better than a language name): (a) *Which Record Operations Survive a GADT Refinement?* — the
question form, good for the operation-level contribution; (b) *Withe: Extensible Records under
Branch-Local GADT Refinement* — leads with the language; use only if §1 leans on the artifact
story early.

### 2.2 Abstract (draft; every claim evidence-checked — see §5)

> Extensible records with row polymorphism and GADTs with local type refinement are each well
> understood; no published type system refines a *row variable* by a branch-local GADT equation,
> and the one widely used language that ships both documents the interaction as "not well
> specified" and restricted its first GADT implementation to protect a row-variable invariant. We
> present λρG, a calculus of branch-local row refinement: a scoped equation store *captures*
> rather than solves the equations a pattern match puts on rigid variables, and a two-tier rule
> discharges *type* equations at branch results but never *row* equations, whose discharge would
> move a row's domain out of the branch. The discipline yields an operation-level answer to which
> record operations remain typable under an active refinement: selection is licensed exactly by
> the heads of the branch's equations; update is sound by construction, because scoped-label update
> is domain-preserving; insertion, the shape-changing dual, is rejected. We report a reference
> implementation in an Elm-family checker — the pre-existing corpus compiles byte-identically and
> 151 regression checks pass — an adversarial hunt that found two unsound accepts in the escape
> check (both fixed and pinned by regression fixtures), a measured principality boundary with a
> counterintuitive inversion, and 90 machine-checked Lean theorems covering the row-rewrite
> commutation under duplicate labels, the escape domain rule, the update theorem, and
> record-operation preservation. We do not
> prove general soundness: progress and preservation are argued, and the mechanization targets the
> row algebra rather than the typing judgment. The compiler's own effect interpreter, typed
> honestly branch by branch, bounds the residue to one dynamic cast at the VM boundary — a
> representation problem, not a refinement one.

(~250 words.) Claims vs evidence: every sentence of this abstract appears with its pointer in
§5's table (C1–C5, C6–C9, C15–C18, C20). The "not well specified" quote is octachron, Jan 2024
(withe-related-work.md:267-269); the restriction is Garrigue & Rémy 2012
(withe-related-work.md:246-248) — both verbatim-verified in the survey.

---

## 3. Contributions (5; one sentence each; evidence pointer attached)

1. **The discipline for an unoccupied cell.** λρG is the first designed account of what happens
   when a *row variable* sits under a *branch-local GADT equation*: a scoped equation store that
   snapshots, captures rigid bindings as equations, and truncates on branch exit, plus a two-tier
   result rule — Tier-T discharges type equations, Tier-R never discharges row equations because
   that would move a row's *domain* out of the branch.
   *Evidence*: the rule set (row-gadt-calculus.md §2, seats ✎ `Type/Unify.elm:238-241` `unifyBranch`,
   `:99-101` `dropEqsFrom`, `:133-147` `dischargeType`); fixtures `rowgadt_select`, `rowgadt_eval`
   (clean) vs `rowgadt_escape`, `rowgadt_evalbad` (err) — gate `run-elm-gate.sh:557-623` ✎; the
   survey's empty-cell verdict (withe-related-work.md §3).

2. **The operation-level answer, with the positive row result mechanized.** Under an active
   refinement, selection is licensed exactly by the heads of the branch's equations; update is
   sound *by construction* (scoped-label update is domain-preserving, so the branch result is
   well-typed at the abstract row with no discharge); insertion is the shape-changing dual and is
   rejected — a deliberate position on Rémy's extension dial, not a discovery.
   *Evidence*: `rowgadt_absentfield` (err) / `rowgadt_setx` (clean) / insertion rejection ✎
   `Type/Infer.elm:971`; the update/insertion theorems `update_domain_preserving`,
   `update_reflexive_domain`, `update_accepted_at_rho`, `insertion_rejected_under_refinement`
   (`lean/Update.lean:153,167,180,236` ✎); the trade framing (withe-related-work.md §2
   "Remy 1994 — the must-retrieve answer", :329-379).

3. **A measured principality boundary with an inversion.** Principality is retained when every
   refinement's target is a branch-scoped existential (the witness encoding *infers*, no
   signature needed) and lost exactly when two sibling branches refine the same *signature* row
   variable whose result mentions it (the native form is checkable, not inferable) — the
   encoding does not merely model rows, it *moves the boundary*.
   *Evidence*: the L3 table — `rowgadt_l3i` (witness, clean), `rowgadt_l3ii` (native, err
   "infinite type"), `rowgadt_l3iii` (plain row, clean), plus `rowgadt_hget` (clean; the binder
   form) — all gate-registered ✎ (`run-elm-gate.sh:592-601`); boundary statement
   (row-gadt.md §7.4, :442-455).

4. **Mechanized metatheory, validated by an adversarial hunt.** 90 machine-checked
   Lean theorems (`lake build` clean, no `sorry` ✎) cover the row-rewrite commutation under
   duplicate labels — including the theorem that *corrects the spec* (`h1_head_only_vs_full`: the
   commutation holds only in the rigid-tail regime) — the escape domain rule (exact for fresh
   labels, coarse for duplicates: `h2b_domain_exactness`), and both escape counterexamples; and
   the hunt found two real unsound accepts in the implemented check (let-laundering through
   let-generalization; a wildcard sibling leak), fixed them, and pinned them by regression
   fixtures.
   *Evidence*: `lean/RowGadt.lean:151,172,183,195,205,410,614` ✎, `lean/RowGadtEscape.lean:97,124` ✎,
   `lean/Update.lean:153-255` ✎; fixtures `rowgadt_escape_launder`, `rowgadt_escape_wildcard`,
   `rowgadt_shape_rebuild`, `rowgadt_dup_rebuild`, `rowgadt_dup_fewer` ✎
   (`run-elm-gate.sh:616-623`).

5. **A working reference implementation, measured against itself.** The discipline is implemented
   inside an Elm-family checker; the pre-existing corpus compiles byte-identically after the
   change (the non-regression invariant), the gate passes 151/151, and applying the machinery to
   the compiler's own effect interpreter retires all but one of its 30 branches' type lies — the
   residue is a dynamic cast at the VM boundary, which the trusted-body comment now states
   precisely, together with a decomposition of the remaining trusted bodies by *kind of lie*.
   *Evidence*: gate PASS=151 FAIL=0 (re-run ✎ 2026-10-05); corpus byte-identity measured across
   every step against the committed manifest (149 groups; orchestrator-verified, and **G2 is now done** — the baseline lives in `tools/withe-corpus-baseline.sha256` and the chain in `tools/withe-numbers.sh`)
   re-run, G2); `Runtime.elm:28` ✎ (source-level per-ctor result annotations);
   `Type/Builtins.elm:365-379` ✎ (the trusted comment). The 29/30 branch count is
   implementer-reported and NOT independently re-measured — G5.

None of these rests on an item of the do-not-publish list (row-gadt.md §9, :469-520 +
withe-related-work.md §6, :627-667; merged in Appendix A below). Contribution 3 states the
*measured inversion*, explicitly reversing the banned guess ("witnesses lack principal types").
Contribution 2's insertion clause is worded as a trade, per the ban.

---

## 4. Section-by-section outline

### §1 Introduction (3 pp)

**Argues**: the three features target *the same variable* with conflicting treatments (rows want
variables solvable into a global substitution; GADT refinement wants equations local to a branch);
the conflict is documented (the one system that met it legislated around it); the contribution is
the first designed account, and the paper is honest about what is proved.

Contents:
- The tension in one paragraph (row-gadt.md §1, :15-29 — "what a type variable *is*").
- **Figure 1** — the crux program: `Has`/`select`/`setX` (row-gadt.md §3, :130-160; live fixture
  `tests/elm-fixtures/rowgadt_select.elm`, `rowgadt_setx.elm`). Necessity walk-through: `Here`
  and `There` impose *conflicting global* row substitutions on ρ; only a rigid ρ plus branch-local
  capture types `select`.
- The gap, with the maintainer record: octachron Jan 2024 "not well specified … nothing is
  guaranteed beyond the fact that the currently implemented interaction is safe" and his
  per-field-object workaround — which *is* a manual membership-witness encoding, i.e. the idiom
  practitioners already reach for (withe-related-work.md:263-300, :441-446); Garrigue & Rémy 2012
  on the first implementation's restriction (:243-245); issue #5724 (poly-variant patterns block
  refinement, :289-292).
- **Second motivating example** — the heterogeneous container (`rowgadt_het`: witness GADT +
  existential wrapper + a two-element list at different witness types, folded to String) — the
  feature the *existential-rigidity* rule unlocks.
- **Third, the payoff example** — the compiler's own effect interpreter: 30 `Task` constructors
  now carrying honest per-ctor result types in source (`Runtime.elm:17-52` ✎); the branch-checking
  result (G5 number); the residue as a representation problem.
- "Why has nobody done it" — compressed to one paragraph: rows and GADTs were adopted by disjoint
  language populations; the one system with all three had secondary rows where the cheap
  workaround costs almost nothing, while here rows are the primary record mechanism so the same
  restriction removes the core feature; three of four implementation blockers were *kinding*
  defects, which both literatures hand-wave. (Memory's six-reason answer, `handoff-rowgadt-result`;
  the honest counter-explanation — "maybe it is not worth much" — is answered in §9 objection O3,
  not hidden in §1.)
- Contributions list (§3 above) and the honest scope sentence: *a discipline with mechanical
  evidence, not a soundness theorem* (this sentence must survive every revision).

Artifact: row-gadt.md §1-§3; withe-related-work.md §3.

### §2 A calculus of branch-local row refinement (4.5 pp)

**Argues**: λρG is a real calculus (not a post-hoc rationalization), and *explicit row kinds are
load-bearing* — the finding the build forced.

Contents:
- **Figure 2** — syntax: kinds `Ty | Row`, variables as `(id, kind, flex)`, types/rows, schemes
  with a bound subset, the judgment `Γ; Δ; R ⊢ e : t` (row-gadt-calculus.md §1-2.2).
- Why kinds are not decorative: three of four build blockers were kinding defects
  (row-gadt-calculus.md:41-48; row-gadt.md §6) — this paragraph is the paper's "why the formal
  model was naive" material and doubles as the §6 setup.
- **Figure 3** — the rule list: R-VAR, R-TYPE (+ the too-general police), R-APP (+ use-discharge),
  R-SEL(-DISCH), R-UPD(-DISCH), R-UPD-INS (rejection), R-RESTR, R-LET, R-CASE
  (snapshot/capture/restore + `refinedTargets`/`refinedTails`), R-RESULT (two-tier), R-EXISTS.
  Source: row-gadt-calculus.md §2.3-2.9, with seats ✎-meta (re-verify at drafting).
- Unification's two modes and the rigid-row-tail inventory ("may be aliased-by-flex, may be
  locally known, may unify with itself; may NEVER be bound — in any mode") — the single most
  quotable paragraph of the design (row-gadt-calculus.md:320-336).
- R-EXISTS as OutsideIn's touchables, row-aware; the flex-marker guard that keeps the prelude
  green (row-gadt-calculus.md §2.8).
- One paragraph: the implementation's two-pass declaration-directed *retry* is an artifact for
  corpus byte-identity; **the declarative calculus has only the declaration-directed rule**
  (row-gadt-calculus.md:706-714, §8.1). State it here so §6 can be honest without a digression.

Artifact: row-gadt-calculus.md §1-§2; code seats listed in the meta node's verified addendum.

### §3 The two-tier rule and the operation-level answer (3 pp)

**Argues**: the *shape* of the rule is the contribution — what may discharge at a branch result
and what may not, and the operation inventory that follows.

Contents:
- Tier-T / Tier-R, named (terminology from the meta node): a type equation discharges via a
  one-way coercion at the re-check (the canonical evaluator types: `rowgadt_eval` clean); a row
  equation never does, because discharge would move the row's **domain** out of the branch
  (`rowgadt_escape`, `rowgadt_hget_escape` err).
- **Figure 4** — the branch-result decision procedure, in order (the six steps of
  row-gadt-calculus.md §2.7:606-629), updated to the *domain-based* rule of the current
  implementation: DROP (tail identified with head) → REJECT; REBUILD (unifies with the equation
  body, head not free in it) → ACCEPT; CHANGE → REJECT (seats ✎ `Type/Infer.elm:1640-1760`).
- The operation inventory: selection licensed by equation heads only (`rowgadt_absentfield`:
  a field in no equation's head is an error even inside the branch); update safe *by construction*
  — no discharge, no equation consumed (`rowgadt_setx`); insertion rejected under refinement
  (✎ `Type/Infer.elm:971`).
- **The negative result** (calculus §6): unrestricted global row refinement λρG⁻ is unsound —
  statement + the mechanism measured pre-fix (the single-branch classic case binding `a := Int`
  globally while call sites kept `∀a. Expr a → a`). Marked *stated, not proved* — it is the
  necessity direction; sufficiency is empirical.
- **The insertion trade, positioned**: Rémy's `new_a` types unrestricted extension unconditionally;
  Gaster & Jones dial it strict under a lacks predicate; CORELINKS quantify presence; we restrict
  it *conditionally* — only under an active branch equation — and give the first account of *why*
  (domain escape breaks refinement soundness). Three published positions on one dial, none
  conditional (withe-related-work.md:368-379, §4.2).
- The update lineage contrast: Rémy update = shadowing-extension (domain may grow);
  Gaster & Jones = restrict-then-extend under lacks; Links = derived remove-then-extend; ours =
  first-occurrence scoped-label replace, domain-preserving by construction — which is why
  discharge is free (withe-related-work.md:388-405).

Artifact: row-gadt-calculus.md §2.4-2.7, §6, §7; fixtures; `lean/Update.lean`.

### §4 Metatheory: mechanized, argued, refuted (3 pp)

**Argues**: the paper knows exactly what is proved, what is argued, and what was *refuted by the
proof* — and the proof and the implementation agree on where the boundary sits, in three places.

Contents:
- **H1 — rewrite/equation commutation under duplicate labels** (the genuinely novel formal
  content; no prior system has the setting). The five theorems: `h1_find_commutes`,
  `h1_duplicate_shadow` (a duplicate before the equation shadows it — both routes expose the
  earlier field), `h1_no_shadow`, `h1_head_only_vs_full` (**the spec corrected by the proof**:
  the "for every label" form holds only in the rigid-tail regime), `h1_discharge_head_agrees`
  (✎ RowGadt.lean:151-218).
- **H2 — escape as a domain rule.** H2-a store truncation (by construction; `h2a_truncation`,
  `h2a_no_survival`, `h2a_snapshot_is_suffix` — nesting safe by construction). H2-b the domain
  rule: `h2b_proper_subdomain`, `h2b_domain_rejects_tail`, `h2b_domain_accepts_rebuild`,
  `h2b_domain_exactness` (**exact for fresh labels, coarse for duplicates**), and
  `h2b_overapproximation` (the check is *provably* sound-but-incomplete — the legitimate
  full-row rebuild fires the syntactic check the domain rule accepts) (✎ RowGadt.lean:246-620).
- **The two counterexamples, mechanized**: let-laundering (`h2b_let_severs_occurs` +
  `h2b_rigid_preserves_occurs` + `H2b_no_quantify_refined_tail` — the let-generalization
  predicate that keeps refined tails unquantified) and the wildcard sibling leak
  (`H2b_wildcard_leak_shape` + `h2b_wildcard_collapses`) (✎ RowGadtEscape.lean:60-127).
  The story: H2 as first conceived was the *wrong shape of lemma* — a statement constraining only
  the branch-result unification cannot see the let-form leak — and the hunt found that before the
  theorem enshrined it.
- **The update theorem** (§7 of the calculus, mechanized): `update_domain_preserving`,
  `update_reflexive_domain`, `update_accepted_at_rho` — update well-typed at the abstract row,
  no discharge; the dual `insertion_rejected_under_refinement`,
  `insertion_shadow_domain_unchanged` (✎ Update.lean:142-258).
- **The three-way agreement paragraph** (the section's payoff): the Lean theorem
  (`h2b_domain_exactness`: exact for fresh, coarse for duplicates), the implementation's honest
  exactness note (the rebuild arm accepts exact field-list matches), and the adversarial battery
  (the duplicate probes: `rowgadt_dup_rebuild` clean, `rowgadt_dup_fewer` the pinned false reject)
  agree on both the rule and its boundary. **Note**: the e1–e7 duplicate battery lives in
  `/tmp/rowgadt/dup-hunt/` — volatile; only the two registered fixtures are durable (G3).
- **The honesty paragraph**: T1/T2 stated (calculus §4), marked argued-not-proved; T1 reduces to
  T2's SELECT clause; T2's two row clauses are exactly what H1 + the update theorem carry; no
  general soundness theorem for λρG exists. The mechanization targets the row algebra, not the
  typing judgment — said plainly, once, here.

Artifact: `lean/*.lean` (theorem names + statements, not proofs); row-gadt-calculus.md §4-5.

### §5 The principality boundary (1.5 pp)

**Argues**: the cost of the discipline is real and *located*, and the location is
counterintuitive.

Contents:
- **Figure 6 / Table** — the L3 table, three presentations of the same access:
  witness-encoded, no signature → **accepted** (infers); native-row witness-style, no signature
  → **rejected** ("infinite type"); plain row access, no GADT → **accepted** (infers
  `{ r | x : a } -> a`). All gate-registered ✎ (`run-elm-gate.sh:592-601`).
- Fragment P / fragment Q, stated precisely (row-gadt.md §7.4): principality retained iff every
  refinement's target is (a) branch-scoped existentially or (b) discharged inside the branch;
  broken when a *signature* variable must be refined differently in two sibling branches AND the
  result mentions it. In Q, no principal monotype exists — the signature is *checkable, not
  inferable*, which is exactly the locally-abstract-types dependency.
- **The inversion** [I, grounded M]: the encoded presentation sits on the P side while its native
  translation sits on the Q side — the encoding *moves the principality boundary*, buying
  inference at the cost of expressible operations (no encoded update, no domain restriction, and
  the absent-field negative is not even *stateable* in it). The pre-measurement guess had the two
  sides swapped; the measurement is the result.
- Optional (cut first if over budget): the encoding faithful-for-access / incomplete-for-recursion
  analysis (meta node §C; the `hget` case needs no equation composition — plan risk R1 refuted).

Artifact: fixtures; row-gadt.md §5 (:243-257), §7.4; meta node's principality observation.

### §6 Implementation and measured correspondence (3.5 pp)

**Argues**: the discipline is implemented, the implementation is measured, and the
correspondence to the calculus is *itemized* — including where the implementation approximates
the spec.

Contents:
- The substrate: an Elm-family checker, HM + Leijen scoped-label rows; the change is contained
  to the pattern path + a store; **the byte-identity invariant**: the pre-existing corpus compiles
  byte-identically after every step (149 groups; the gate at PASS=151 FAIL=0 ✎). The invariant is
  the paper's non-regression evidence, and the retry design (plain path primary, retry on failure,
  historical error reported) is what makes it *by construction*.
- The four pre-existing substrate bugs the build surfaced, three of them *kinding* (row-gadt.md
  §6.1-6.4): forced-KType generics; first-use kind inference order-sensitivity (fixed by the
  row-tail prescans ✎-meta `Type/Env.elm` collectFileTypeKinds/collectRowNames); no
  bare-KRow-vs-TRecord unify path; the flex-alias wrapper bug. Message: *a calculus without
  explicit row kinds cannot predict where a real implementation breaks*.
- **The escape check's evolution** — the section's centrepiece, told as three measurements:
  (1) the first check was syntactic (tail-occurrence, one orientation); (2) the adversarial hunt
  found two unsound accepts (**Figure 5** — the counterexample pair, each a 6-line program, with
  its pre-fix behaviour: `escapeBad Here (HCons 1 HNil)` returned `HNil` at `HList {l:Int|{}}`);
  (3) the domain-based rule (✎ `Type/Infer.elm:1708-1760`) accepts the legitimate rebuild
  (`rowgadt_shape_rebuild` clean) and rejects every escape shape — six must-error probes and
  seven must-error fixtures re-verified after the fix (orchestrator-verified; memory `33c2f4bc`).
- The `type a.` surface (option B): bound ⇒ rigid, unbound ⇒ flexible + the too-general police —
  the feature-3 *no-op* point (rigidity is the mechanism; the prefix is its surface).
- The effect interpreter: per-ctor result annotations migrated into source syntax, proven
  behaviour-preserving by two independent oracles (the --schemes dump 30/30 byte-identical; the
  full corpus batch byte-identical); then the honest typing attempt — **the G5 number** of 30
  branches check, the `TaskExec` holdout needs `a ~ List a`, a dynamic cast no HM-style typing can
  express; the honest fix is a surface change to the payload. The three-part empirical claim: a
  documented precondition, a mechanical proof it was met, a refutation that it was the *right*
  precondition (row-gadt.md §6, :327-342).
- The trusted-body decomposition (optional, cut to a paragraph if over budget): remaining trusted
  bodies decompose by *kind of lie* — refinement-blocked (retired), dynamically-typed island
  (retirable at bounded cost), predicate-dispatched comparison, representation-identity
  (Char=String, Int/Float), row-ops over the record representation; only the first two are
  addressable by the type system. **Warning**: this rests on `/tmp` probes (`probeA*`,
  unit rowgadt-11, zero repo edits) — G3/G5 must re-home or the claim is cut to the runTask
  instance.
- The measured correspondence list, compressed from calculus §8 (the [U]/[S] table), *updated to
  the domain rule*: the retry [S]; per-file kinding [U, weakly]; the rebuild arm's duplicate
  coarseness [S, pinned]; surface restrictions [S]; trusted bodies [S]. One sentence each; the
  full list goes to the artifact appendix.

Artifact: row-gadt.md §6; calculus §8; `Type/*.elm` seats; gate + corpus scripts.

### §7 Related work (2.5 pp)

**Argues**: organized by the feature-pair map — the organization itself is the section's
contribution, because it makes the empty cell visible and pre-empts "but X did rows" / "but Y did
GADTs".

Contents (structure = withe-related-work.md §1's table, the 26-work map):
- **Rows-only lineage** (R): Wand 1989 (concatenation costs principality — finite complete sets
  instead; *same casualty as ours, different trigger — do not conflate*); Rémy 1994 (unrestricted
  extension; presence flags as quantification); Gaster & Jones 1996 (strict under lacks); Ohori
  1995 (kinds instead of row variables — cite for the kinding finding); Leijen 2005 (scoped
  labels — the substrate; the eq-swap our H1 commutes with).
- **Presence**: CORELINKS (distinct labels, presence quantified, no equations — the nearest
  neighbour in one dimension, and the contrast case for the duplicate-label coarseness); Castagna
  & Peyrot OOPSLA'25 (refinement "mostly orthogonal" — the live assumption our cell falsifies
  for the product half).
- **GADT-inference lineage** (G): OutsideIn(X) (touchables; *cannot* state the problem — its
  grammar lacks rows, grep-measured); stratified inference (equations at case; the
  annotation-meaning caveat we share); wobbly types; **HMG(X) — the un-walked door**: a
  parameterised local-assumption framework never instantiated with a row/record theory; λρG is
  that instantiation, and the two row-specific obligations (H1 commutation under scoped-label
  duplicates; the domain rule) are what the generic frame does not give for free. (This is the
  strongest positioning sentence available — use it as §7's topic sentence.)
- **The combination cell**: OCaml — the idiom with empirical failure modes (maintainer record;
  issue #5724; the FSM threads as user-demand datapoints); Flix restrictable variants (refines
  the label-set, never the row; GADTs as future work); GHC `HasField` (nominal, class-triggered).
- **Effects rows**: Koka (eliminations unify the effect row, never refine it) — one cite; do not
  claim "rows + effects".
- **The frontier**: omnidirectional inference 2026 (principality-restoration with nominal
  records; GADTs as "would be interested in studying") — the field is active, cite it, land the
  row-side answer next to it.
- The safe headline sentence, verbatim from the survey's verdict (withe-related-work.md:532-538):
  "No published type system refines a row variable by a branch-local GADT equation, and no
  published system therefore says which record operations remain typable when such an equation is
  active…" — with the qualifier that the claim is about *published systems with a designed
  discipline*, never worded as "rows and GADTs have never been combined".

Artifact: withe-related-work.md (quotes verbatim, URLs in the survey; the survey is the
bibliography's source). Do **not** cite Chen & Erwig POPL'16 (unretrieved — survey §5.2).

### §8 Limitations and future work (1 pp)

Drafted bullets in §6 below (the plan's §6 = the paper's §8).

### §9 Conclusion (0.25 pp)

One paragraph: the conflict between rows and GADT refinement is an artifact of eager global
solving, not of the features; the discipline (capture, discharge types never rows, keep domains
branch-local) makes the combination usable and measurable; what remains open is stated, not
hidden.

---

## 5. Claim → evidence table (the spine)

Legend: FIX = gate-registered fixture (`tests/elm-fixtures/rowgadt_*.elm`, registrations at
`run-elm-gate.sh:557-623` ✎); LEAN = theorem in `lean/`; CODE = `elm-compiler/src` seat; DOC =
companion doc with verified pointers; SURVEY = withe-related-work.md. "Thin" = evidence exists but
is volatile (`/tmp`) or reported-not-re-measured — each Thin row names its gap item.

| # | Claim (as the paper will word it) | Evidence | Status |
|---|---|---|---|
| C1 | No published type system refines a row variable by a branch-local GADT equation; none therefore says which record operations remain typable under an active equation | SURVEY §3 (26 works, query list, would-be-breakers table, :492-546); qualifier mandatory | [M] |
| C2 | The one widely used language with all three treats the combination as an idiom with empirical failure modes ("not well specified", 2024); its first GADT implementation restricted objects/poly-variants to protect a row-variable invariant | SURVEY :246-248 (G&R 2012 verbatim), :263-300 (octachron/gasche verbatim), :288-292 (#5724) | [M] |
| C3 | OutsideIn(X) cannot state the problem (grammar lacks rows); HMG(X) could in principle but has never been instantiated with a row/record theory | SURVEY :39, :227-238; "has not been instantiated", never "cannot" unqualified | [M] |
| C4 | Insertion is typable in rows-only systems (Rémy unconditionally; G&J under lacks; CORELINKS by presence quantification); our rejection exists only relative to an active branch equation | SURVEY :313-379 (Rémy verbatim: `new_a`, strict/unrestricted dial) | [M] |
| C5 | Our update is domain-preserving by construction — the property that makes discharge free — unlike Rémy/G&J/Links updates | SURVEY :388-405; FIX `rowgadt_setx`; CODE `Type/Infer.elm:1037-1058` ✎-meta; LEAN `update_domain_preserving` (Update.lean:153 ✎) | [M] |
| C6 | Two branches impose conflicting equations on a rigid ρ; only branch-local capture types `select` | FIX `rowgadt_select` (clean), `rowgadt_l3ii` (err "infinite type"); DOC row-gadt.md §3 | [M] |
| C7 | A type equation discharges at a branch result (the canonical 3-branch evaluator type-checks) | FIX `rowgadt_eval` (clean); CODE `dischargeType` (Unify.elm:133 ✎), tier-1 re-check | [M] |
| C8 | A row equation never discharges at a result; its escape is an error | FIX `rowgadt_escape`, `rowgadt_hget_escape` (err); CODE `unifyClauseResultM` (Infer.elm:1640 ✎) | [M] |
| C9 | Selection is licensed exactly by equation heads; a field in no head is an error even inside the branch | FIX `rowgadt_absentfield` (err); CODE `dischargeRow` (Unify.elm:166 ✎) | [M] |
| C10 | The first (syntactic) escape check accepted two unsound programs; both are fixed and pinned | FIX `rowgadt_escape_launder`, `rowgadt_escape_wildcard`; LEAN `H2b_no_quantify_refined_tail` (RowGadtEscape.lean:97 ✎), `H2b_wildcard_leak_shape` (:124 ✎), `h2b_let_severs_occurs` (RowGadt.lean:533 ✎) | [M] |
| C11 | The escape rule is domain-based: DROP rejected, REBUILD accepted, CHANGE rejected | CODE ✎ Infer.elm:1708-1760; FIX `rowgadt_shape_rebuild` (clean) | [M] |
| C12 | The domain rule is exact for fresh labels and coarse for duplicates — proved, implemented, and probed to agree | LEAN `h2b_domain_exactness` (RowGadt.lean:410 ✎), `h2b_overapproximation` (:614 ✎); FIX `rowgadt_dup_rebuild` (clean), `rowgadt_dup_fewer` (err — the pinned false reject); dup battery e1–e7 in `/tmp/rowgadt/dup-hunt/` | [M] — battery volatile → G3 |
| C13 | H1: first-occurrence search commutes with scoped-label substitution, including under duplicate labels; the "for every label" form holds only in the rigid-tail regime (spec corrected by proof) | LEAN `h1_find_commutes`/`h1_duplicate_shadow`/`h1_no_shadow`/`h1_head_only_vs_full`/`h1_discharge_head_agrees` (RowGadt.lean:151-218 ✎) | [M] |
| C14 | Store truncation is exact and nesting-safe by construction | LEAN `h2a_truncation`/`h2a_no_survival`/`h2a_snapshot_is_suffix`/`h2a_inner_snapshot_suffix` (RowGadt.lean:246-268 ✎); CODE `dropEqsFrom` (Unify.elm:99 ✎) | [M] |
| C15 | Update is well-typed at the abstract row with no discharge; insertion is domain-changing and rejected under refinement | LEAN `update_reflexive_domain`/`update_accepted_at_rho`/`insertion_rejected_under_refinement`/`insertion_shadow_domain_unchanged` (Update.lean:167-258 ✎); FIX `rowgadt_setx`; CODE Infer.elm:971 ✎ | [M] |
| C16 | The pre-existing corpus compiles byte-identically; the gate passes 151/151 | Gate re-run ✎ 2026-10-05 (**PASS=151 FAIL=0**); byte-identity against the COMMITTED manifest `tools/withe-corpus-baseline.sha256` (149 artifacts) via `tools/withe-numbers.sh` | [M] — **G2 DONE**: the baseline and the chain are in-repo |
| C17 | ~~29 of the effect interpreter's 30 branches check honestly~~ **CORRECTED: 25 of 30** — the 29/30 figure was FAIL-FAST (removing `runTask` from `trustedBodies` reports one error and stops). The five that fail: `TaskExec` (existential cast `a ~ List a`), `TaskNow` (`Ok 0` number literal hits FlexConflict before the rigid-var discharge fires), `TaskQuit` + `TaskGuiPoll` (**un-annotated nullary ctors — the two the `taskCtorResults` docstring deliberately left generalized: design, not defect**), `TaskStat` (closed-record result; `dischargeType` refuses any `TRecord` body — the Tier-R over-approximation costing a legitimate type equation) | CODE Runtime.elm:28 ✎ (annotation), Builtins.elm:365-379 ✎ (comment); **G5 DONE — recounted by bisection** | **[M] corrected** |
| C18 | The trusted-body residue decomposes by kind of lie; only refinement-blocked and dynamically-typed lies are type-system-addressable | The typed-VM experiment (probeA/probeA2/probeA_neg + the `compare` retirement error) — **all in /tmp, zero repo edits** | **Thin** → **G3** (re-home probes) or cut to the runTask instance |
| C19 | The principality boundary sits on the native-row side, not the witness side; the encoding moves it | FIX `rowgadt_l3i` (clean) / `l3ii` (err) / `l3iii` (clean) / `rowgadt_hget` (clean); the plain-signature `hget` rejection is a `/tmp` probe (`hlist2.elm`) | [M] for the fixtures; the hlist2 data point → **G3** |
| C20 | No general soundness theorem exists: T1/T2 argued, not proved; the mechanization targets the row algebra, not the typing judgment | Honest absence; LEAN header states the scope (RowGadt.lean:1-27 ✎) | [M-by-absence] |
| C21 | Rank-2/higher-rank is absent (no `TForall` in the type representation); the general handler signature cannot be stated | CODE `Type/Representation.elm` (Type grammar has no quantifier node — ✎-meta; re-verify) | [M] |
| C22 | ~~No exhaustiveness/refutation checking exists~~ **CORRECTED: both exist and work.** `Type/Exhaustive.elm` rejects a missing POSSIBLE arm at COMPILE time, and REFUTES an impossible arm under branch equations (`eval : Expr Int -> Int` matching only `IntLit` compiles clean, `BoolLit` being impossible at `Expr Int`) — i.e. it does what the external OCaml thread could not (`-> .`) | Gate `adtgaps`/`refutpos`/`refutneg`/`refutbare`; commit 36b93d0 + the over-refutation fix | **[M] corrected** — the old absence claim is now FALSE |
| C23 | ADT generic kinds are collected per file (a cross-file bare row parameter kinds as `KType`) | CODE `Type/Env.elm:134-137` ✎-meta (typeKinds pre-pass); unexercised by corpus/fixtures | [M] — state as [U]; see §6 |
| C24 | The implementation checks declarations with a historical first pass and retries declaration-directed only on failure with a case body; the declarative calculus has only the declaration-directed rule | CODE `Type/Infer.elm:2379-2428` ✎-meta; calculus §8.1; the case-under-let spurious reject is a `/tmp` probe (`gNeg_letcase.elm`) | [M] — probe volatile → G3 if the completeness claim is made |
| C25 | Practitioners hit this boundary today (FSM/reducer modelling; the recommended workaround restructures types so no row is refined) | SURVEY :263-300, :441-446 (discuss.ocaml.org threads, fetched JSON; /tmp copies) | [M] — quotes are in the survey (durable); re-verify URLs render at camera-ready (survey §5.5) |
| C26 | Three of the four implementation blockers were kinding defects | Build history (row-gadt.md §6); the fixed code is the residue (prescans; the KRow-KRow alias path) | [M] as history; fine for §6 prose, not a headline |
| C27 | **90** machine-checked Lean theorems (row-algebra trio 43 + TypingStore 29 + Preserve 18); `lake build` clean, no `sorry`, **3 `axiom`s** (the explicit unifier parameters) | Re-measured ✎ 2026-10-05 (build exit 0, zero output); the 43 figure was stale before the typing arc | [M] |

**Rule for the drafting units**: if a claim is not in this table, it does not go in the paper; if
a row is Thin, either close its gap item first or cut the claim to what the durable evidence
carries.

---

## 6. Honest limitations (drafted as bullets — this is the paper's §8)

Paper-gap vs future-work is marked; "paper-gap" = must be fixed or explicitly stated before
submission.

- **No general soundness theorem.** T1 (progress) and T2 (preservation) are stated and *argued*,
  not proved — the mechanization covers the row algebra (rewrite, store, escape, update, plus the typing-judgment
  arc: 90 theorems) but not the operational semantics and not a full typing soundness proof or the operational semantics. T1's new obligation
  reduces to T2's SELECT clause; T2's two row clauses are what H1 and the update theorem carry.
  *(paper-gap — the wording IS the fix; do not let a later draft upgrade "argued" to "proved")*
- **Rank-2 / higher-rank types are absent** — no quantifier node inside `Type`, so the general
  handler signature (a polymorphic continuation) cannot be stated; effect operations with
  polymorphic argument types cannot be declared. Deliberate: orthogonal to the row×GADT claim,
  and landing it would move the evidence baseline under the paper. *(future work;
  annotation-directed checking, not inference)*
- ~~No exhaustiveness or refutation checking~~ — **NOW IMPLEMENTED** (commit 36b93d0). A missing
  POSSIBLE arm is a COMPILE error; an IMPOSSIBLE arm is refuted under the branch equations. This
  **answers** the external thread's wall rather than missing it. Caveats to state: refutation fires
  only where the index is CONCRETE or BINDER-RIGID (a bare flexible index must not be concretised —
  that was the over-refutation bug); GADT-ness is classified per-file, so a hypothetical
  CROSS-MODULE GADT index would degrade to the old flexible behaviour (safe, via the too-general
  police and the refutation guard); and a pre-existing unsignatured-nested false positive remains.
- **The escape check is sound but over-approximate** — *proved*, not hedged
  (`h2b_overapproximation`): the check rejects some legitimate returns. *(paper-gap: state as a
  theorem-backed completeness limitation)*
- **The duplicate-label case is coarse** — *proved* (`h2b_domain_exactness`: exact for fresh
  labels, coarse for duplicates): a rebuild with fewer duplicate occurrences than the equation
  body is a false reject, pinned by `rowgadt_dup_fewer` with a do-not-weaken comment. *(paper-gap:
  state; never "fix" by weakening the check)*
- **Per-file kinding** — ADT generic kinds are collected per file, so a cross-file bare row
  parameter can kind as `KType` (a soundness-relevant approximation, unexercised by the corpus and
  fixtures). *(paper-gap: state as [U]; future work to fix)*
- **The trusted-body residue is a dynamic-representation problem, not a refinement one** — the
  interpreter's holdout is a dynamic cast (`a ~ List a`) at the VM boundary; the remaining
  trusted bodies decompose into kinds of lie of which only two classes are type-system-addressable.
  *(paper-gap: keep this framed as a *finding*; it bounds the effect story honestly)*
- **Fragment Q is checkable, not inferable** — signatureless native row-GADT code with a
  result-mentioning refinement is rejected; the signature is not optional there. *(paper-gap:
  state with the L3 table)*
- **Surface gaps** — no type-level strings; record literals closed (an open row can only be
  *named*); `{ | ρ }` bare-open does not parse; the update base must be a local variable.
  *(paper-gap: one list; all completeness [S])*
- **The two-pass retry is an implementation artifact** — the declarative rule is
  declaration-directed; the retry accepts a subset (e.g. a case under a `let` fails spuriously).
  *(paper-gap: state; soundness-neutral)*
- **Evaluation is self-corpus + designed fixtures** — no comparative user study, no external
  codebase; the adversarial hunt was one pass (two counterexamples; absence of more is evidence,
  not proof). *(paper-gap: say so; future work: the FSM example is the first external datum — G4)*

---

## 7. Figures and tables

REQUIRED (the paper fails without them):

- **F1 — the crux program** (`Has`/`select`/`setX`): from `rowgadt_select.elm`/`rowgadt_setx.elm`
  verbatim. §1.
- **F2 — syntax + kinds + judgment** (`Γ; Δ; R`). §2. Source: calculus §1-2.2.
- **F3 — the typing rules** (the rule list of §2 above; ~1.5 pp, the paper's largest figure).
  Source: calculus §2.3-2.9.
- **F4 — the branch-result decision procedure** (six steps, domain-based: tail-escape pre-check →
  unify → Tier-T → existential → refined-target escape → historical error). §3. Source: calculus
  §2.7 + CODE ✎ Infer.elm:1640-1760.
- **F5 — the counterexample pair** (let-laundering; wildcard sibling leak), each 6 lines, with
  pre-fix behaviour and post-fix error. §6. Source: fixtures `rowgadt_escape_launder`/`_wildcard`.
- **F6 — the L3 principality table** (3 rows: witness / native / plain). §5.
- **T1 — the fixture matrix**: all 19 rowgadt fixtures, expected vs measured (clean or the exact
  error string). The evaluation's spine. Source: `run-elm-gate.sh:557-623` ✎ + fixture files.

OPTIONAL (cut in the order listed if over budget):

- **T2 — the trusted-body decomposition** (kinds of lie). §6. *Depends on G3.*
- **T3 — the Lean theorem inventory** mapped to paper claims (or an artifact appendix). §4.
- **F7 — the λρG⁻ negative-result program** (merge into F1's discussion if space binds). §3.
- **F8 — the feature-pair map** (the 26-work table, compressed to the ~12 load-bearing rows). §7.
- **F9 — the effect-interpreter excerpt** (the `Task` declaration + the `TaskExec` holdout). §6
  or §1.
- **Appendix A — full fixture list with expected/measured outcomes** (artifact-referenced).

---

## 8. The evaluation story

### FIRM now (evidence that survives a referee's spot-check on the committed tree)

- **Gate**: PASS=151 FAIL=0, re-run on the current tree ✎. Includes all 25 `rowgadt_*` fixtures (13 `compile_clean`, 25 `compile_error`).
- **43 Lean theorems**, `lake build` exit 0, zero output, zero `sorry` — re-run ✎. Build command
  is part of the artifact (`lake build` / `lake env lean <file>` from `lean/`; bare `lean` fails
  on the two importing files — the oracle gotcha is documented in memory and must be in the
  artifact README).
- **The counterexamples found-and-fixed**: two unsound accepts, fixed, pinned by gate-registered
  fixtures; the fixes verified against six must-still-error probes and six must-stay-clean
  fixtures (orchestrator-verified, memory `33c2f4bc`); the false reject fixed by the domain rule
  with no soundness regression (verified on the same battery).
- **Proof/implementation/probe agreement** on the escape boundary in three independent places
  (Lean `h2b_domain_exactness`; the rebuild arm's exact-match acceptance; the duplicate probes).
- **The compiler's own effect interpreter carries per-ctor result types in source**
  (`Runtime.elm:17-52` ✎), and `runTask`'s trusted comment states the precise remaining reason
  (`Builtins.elm:365-379` ✎).

### MISSING (and what it costs the paper if not closed)

- **A durable corpus baseline + re-run protocol.** Byte-identity was measured against
  `/tmp/rowgadt-base` (volatile) by the orchestrator at every step; the paper needs one clean
  re-measurement on the paper-frozen commit with the numbers written into the artifact appendix.
  **G2.**
- **An independent re-count of the 29/30 interpreter branches.** Implementer-reported; the
  orchestrator verified the annotations, gate, and corpus but did not recount. Either recount
  (G5) or weaken the claim to "all but one branch". A referee can check this one line against
  the artifact.
- **The volatile probes behind C18 (trusted-body decomposition) and parts of C19/C24.** If §6
  keeps the decomposition claim, `probeA*` and the `compare` retirement error must be re-homed
  as fixtures/examples. **G3.**
- **A second real program.** Everything beyond the crux is either a designed fixture or the
  compiler's own internals. The discuss.ocaml.org FSM/reducer pattern is the motivating
  application practitioners already report — encoding it in Withe (it checks: strong §1 datum;
  it fails: the failure is a datum about which operation it needs) is the single best use of a
  spare week. **G4.**
- **A missing negative result**: there is no adversarial battery against the *domain-based* rule
  specifically (the e1–e7 battery targeted the duplicate arm; the six-probe verification targeted
  the drop/rebuild split). A fresh adversarial pass (tail-reaches-head through two zonk steps)
  would strengthen the "sufficiency is empirical" sentence. **G13, optional.**
- Not missing, and do not add: benchmarks/perf numbers. The retry fires only on the failure
  path; any perf claim would be new, thin, and off-thesis. [I] Omit.

### If there were one more week (priority order)

1. **G4** the FSM example (external motivating datum; answers objection O3 with a program).
2. **G2+G5** the durable re-measurement script + the 29/30 recount (one script, one afternoon,
   makes every number in the paper reproducible from the artifact).
3. **G3** re-home `probeA*`, `hlist2`, `gNeg_letcase`, the dup battery.
4. **G13** the fresh adversarial battery against the domain rule.

---

## 9. What is not proved, and what a referee will attack

Not proved (the complete list — §4/§8 state each):

1. **T1 progress, T2 preservation** — argued only. The mechanization is of the row algebra.
2. **The λρG⁻ unsoundness theorem** (the negative result) — stated with a measured mechanism,
   not proved.
3. **Sufficiency of the discipline over all programs** — empirical (corpus + fixtures + hunt),
   explicitly not a claim.
4. **The typing-judge correspondence** — the implementation approximates the declarative rules
   in the listed [U]/[S] places; the two [U] items are per-file kinding and the (now closed)
   escape approximation's exactness boundary.
5. **H1 in the implementation** — the mechanized H1 is about the row-rewrite relation; the
   implementation's discharge needs only the weak form (one zonk commutes with the outer
   substitution). The full-form vs implementation-weak-form relationship is argued.
6. **No completeness claim** for the retry path (case-under-let fails spuriously — probed, in
   /tmp, G3 if cited).

Referee attacks, strongest first, each with the pre-empted answer:

- **O3 (strongest): "The program class is narrow and the paper is self-referential — the only
  non-toy evidence is your own compiler."** Pre-empt: (a) the OCaml maintainer record and the
  FSM threads are *external* evidence practitioners hit this boundary today, and octachron's
  recommended workaround (one row variable per field) is a manual membership-witness encoding —
  the idiom our calculus formalizes is one practitioners already reach for; (b) the effect
  interpreter is 30 constructors of real code, and the machinery retired its type lies down to
  one dynamic cast; (c) the paper's claim is a *boundary characterization* — which operations
  survive — not "use this language"; (d) build G4, and let the FSM example close the loop. Do
  not hide the objection: state it in §1 and answer it in §6.
- **O1: "No soundness theorem — this is an engineering report."** Pre-empt: the necessity
  direction is a theorem-shaped negative result with a measured mechanism; the *load-bearing*
  obligations of T2's row clauses are exactly what is mechanized (H1 commutation, the domain
  rule, the update theorem); and the adversarial hunt means the H2 statement was validated
  against the implementation *before* being mechanized — the two counterexamples are theorems
  too (`H2b_no_quantify_refined_tail`, `H2b_wildcard_leak_shape`). The honest scope sentence in
  §1 costs one sentence; hiding it costs the paper.
- **O2: "The calculus is a rationalization of the implementation."** Pre-empt: the calculus was
  drafted *from* the measured artefact and the build refuted three of its own earlier claims
  (blanket escape; the composition hypothesis R1; the principality sides) — that history is the
  paper's credibility, told in §4/§6; and the [U]/[S] list is published, not buried.
- **O4: "OutsideIn/stratified/wobbly already solve local equations; you instantiated a known
  frame."** Pre-empt: yes — HMG(X) is the frame and nobody walked through it with rows; the
  row-specific content is *not* free from the frame: scoped-label duplicates (H1's hard case)
  and the domain rule (Tier-R's reason) do not exist in the generic settings. Cite the frame as
  the parent, claim the instantiation + the two row obligations.
- **O5: "Rémy/CORELINKS already answer 'which operations are typable'."** Pre-empt: they answer
  it by *quantifying* (presence flags, lacks predicates) — abstraction, the opposite direction
  from branch-local *assumption*; the refinement-relative answer is absent, and the survey's
  would-be-breakers table is the evidence. Never claim presence polymorphism as new.
- **O6: "Wand already lost principality in records."** Pre-empt: same casualty, different
  trigger (concatenation vs refinement-with-mentioning-result); state the contrast explicitly —
  it is on the banned-conflation list.
- **O7: "Duplicate labels are exotic."** Pre-empt: scoped labels are Leijen's design and Koka's
  effect rows inherit them; the duplicate case is where H1 bites and where the domain rule is
  provably coarse — the hard case is the contribution, and its false reject is *pinned* with a
  do-not-weaken comment.
- **O8: "The evaluation is a self-corpus."** Pre-empt: byte-identity is the *non-regression*
  evidence, not a benchmark claim; the accept/reject evidence is the designed fixture matrix
  (T1); and G4 adds the external program. Say "we do not claim user-facing benefit; we claim a
  characterized boundary".

---

## 10. Before-submission gap list (ordered; this is what the next units execute)

| # | Item | Why | Cost | Type |
|---|---|---|---|---|
| G1 | Verify the ICFP 2027 CfP when it posts: page limit (assume 25pp ACM Small from 2026), deadline (25 Feb 2027), double-blind policy, artifact track dates | Calibrates the budget; the 2027 numbers are not yet posted | 1 h (web check at write time) | check |
| G2 | Durable re-measurement: freeze the corpus baseline *inside the repo* (or tag it), write one script that runs gate + batch + corpus diff + `lake build` and prints every number the paper cites; run on the paper-frozen commit; record outputs in the artifact appendix | C16 is currently measured against a volatile `/tmp` baseline; referees (and artifact evaluation) must be able to reproduce | 0.5–1 day | tooling + measure |
| G3 | Re-home the volatile probes whose claims the paper uses: `probeA/probeA2/probeA_neg` (C18, the typed-representation experiment), `hlist2` (C19, plain-signature rejection), `gNeg_letcase` (C24, retry completeness), the dup battery `e1–e7` (C12) — as registered fixtures or an `examples/` dir. **Do not add framing comments to existing fixtures** (the `l3ii` lesson: a comment shifted the error line and broke byte-identity) | C12/C18/C19/C24 currently rest partly on `/tmp` | 1 day | fixtures |
| G4 | Build the FSM/reducer example (discuss.ocaml.org t/13718 pattern) in Withe, probe-first in `/tmp`, then register as an example: row-typed state + a witness GADT for the transition relation | The strongest answer to O3; the missing external program | 1–2 days | example |
| G5 | Independently re-count the interpreter branches on the committed tree (the 29/30 claim), or weaken the claim to "all branches except `TaskExec`" | C17 is the one number a referee can check against the artifact | 0.5 day | measure |
| G6 | Update the stale metatheory wording in the two docs so the drafting units cannot inherit it: calculus §5.3 (H1 now mechanized incl. duplicates; probes exist), §5.4/§8.2 (H2 is the domain rule; both counterexamples mechanized; `escapeViaTail` superseded by `dropIntroduced`/`rebuildMatches`), row-gadt.md §7.3 (the same). **Doc edits only; no code; no fixture edits** | The paper's metatheory must be written from the current state | 0.5–1 day | docs |
| G7 | Try once more to retrieve Chen & Erwig POPL'16 (choice types) via a non-ACM route; cite only if read, else leave uncited (survey §5.2) | An unread citation is a liability | 1 h | lit |
| G8 | Check whether OCaml's 2012 objects/poly-variants+GADT restriction is still current (manual/issue tracker); if unverifiable, keep "restricted in its first implementation" (the defensible wording, survey §5.4) | One sentence in §1/§7 depends on it | 2–4 h | lit |
| G9 | Decide T1/T2 presentation: (a) argued + the reduction note (ICFP frame — recommended); (b) invest 2–4 weeks in a pencil T2 sketch with the two row clauses carried by H1 + the update theorem (OOPSLA-R2 scale). Do NOT attempt full mechanization pre-submission | The venue calibration depends on this decision | 1 h decision; (b) 2–4 weeks | decision |
| G10 | Drafting (the writing units, in order): §1+§2 (design is settled) → §6 (most material exists) → §3+§4 (from the calculus doc + Lean) → §5 → §7 (from the survey) → §8 → abstract last. Run the reviewer preset on the full draft; then a strategist pass on the contribution list and abstract | The paper itself | 2–3 weeks of units | write |
| G11 | Artifact packaging: repo + the G2 verification script + fixture matrix + `lean/` build instructions (note the bare-`lean` gotcha: `lake build` from `lean/`) + the artifact note (the three Lean files are one Lake project, one definition of the row algebra) | ICFP artifact evaluation; also makes the referee's spot-check trivial | 1 day | packaging |
| G12 | Figures: F1 (verbatim from fixtures), F2/F3 (from the calculus doc), F4 (from the code comments), F5 (counterexamples), F6 (L3 table), T1 (fixture matrix) | The paper's figures are all derivative of existing material | 1–2 days | write |
| G13 | *(optional)* A fresh adversarial battery against the domain-based escape rule (two-step tail-to-head chains through zonk; `dropIntroduced`'s pre/post scoping) | Strengthens the empirical-sufficiency sentence; the hunt found two accepts in the *previous* rule, so this rule deserves its own pass | 0.5 day (pro-coder probe unit) | probe |
| G14 | Line-number refresh pass: re-verify every `file:line` citation in the draft against the paper-frozen commit hash (cite the hash in the artifact note). The ✎-meta seats (from the meta node's addendum) predate the domain fix; the ✎ seats are current as of `0207dd2` | Line drift is a documented failure mode on this project | 0.5 day (fold into G10) | verify |

Execution order: G6 → G2 → G5 → G3 → G4 (probe units first while the tree is stable) → G7/G8 in
parallel → G10 (drafting, with G1/G14 folded in) → G11/G12 → G13 if time.

---

## Appendix A: do-not-publish constraints (hard; both lists merged)

From row-gadt.md §9 (:469-520):

- Escape as a **blanket rejection** (it is two-tier; the blanket version refuses the canonical
  evaluator).
- "**Witnesses lack principal types**" — the measurement is the opposite (§5's inversion).
- The **pre-binder P-probe error strings** as current behaviour (option B changed them; cite the
  binder'd fixtures for rigid-row facts).
- "**The surface has no closed empty row**" — `{}` exists and works.
- "**OCaml forbade** the combination" unqualified — use the idiom-with-failure-modes account.
- The **old `rowgadt_escape` error string** (the fixture was reshaped to the tail-escape wording).
- "**Presence polymorphism is new**" (CORELINKS; Castagna & Peyrot).
- "**No prior work says which row operations are safe**" without "under refinement".
- "**Rows and GADTs are never combined**" unqualified.
- Any claim that our rows have **distinct labels** (scoped duplicates are legal and are H1's source;
  CORELINKS's are distinct — the contrast is the reverse).

From withe-related-work.md §6 (:627-667):

- "**Insertion is untypable in row systems**" / R-UPD-INS as a discovery (Rémy types it
  unconditionally) — the trade framing only.
- "**Record update is nominal-only in prior work**".
- "**Wand's concatenation is the only prior loss of principality in records**" (do not conflate).
- "**No one has considered record operations under local assumptions**" — the accurate form: no
  published *instantiation* of the generic local-assumption frameworks targets a row/record theory.
- "**GADT inference frameworks cannot state the problem**" without naming the framework
  (OutsideIn(X) cannot; HMG(X) has not been instantiated).
- "**The 2025-26 state of the art ignores principality**" (omnidirectional inference exists).
- Using Rémy's Π\* presence variables to claim he "almost had" refinement (they are quantified,
  not assumed — abstraction is the opposite direction).

Also, from the memory chain (not in the doc lists but enforced): the duplicate-fewer false reject
surfaces to the user as `CannotUnify: 'cannot unify a with {x:Int| a}'` — do not repeat the
corrected-in-memory "infinite type via shared-tail side condition" parenthetical.

## Appendix B: source-material map (what feeds which section)

| Paper § | Primary source | Secondary |
|---|---|---|
| §1 | row-gadt.md §1-§3; withe-related-work.md §3, quote bank | fixtures (select/setx/het); Runtime.elm |
| §2 | row-gadt-calculus.md §1-§2 | meta node's rule seats (✎-meta) |
| §3 | row-gadt-calculus.md §2.4-2.7, §6, §7 | lean/Update.lean; SURVEY §2 (Rémy) |
| §4 | lean/*.lean (theorem statements); row-gadt-calculus.md §4-§5 (status paragraphs REWRITTEN per §0) | meta node B |
| §5 | fixtures l3i/l3ii/l3iii/hget; row-gadt.md §5, §7.4 | meta node principality |
| §6 | row-gadt.md §6; calculus §8; memory (hunt, domain fix) | gate + corpus scripts |
| §7 | withe-related-work.md (whole) | quote bank URLs → bibliography |
| §8 | this plan's §6 | calculus §8.4-8.7 |

## Appendix C: verification protocol for the drafting units

1. Every number in the draft must come from the G2 script's output on the paper-frozen commit
   (gate count, corpus diff, Lean build + theorem count). No number from memory or from this plan
   without a re-run — this plan's own ✎ numbers were re-measured 2026-10-05 and will drift.
2. Every `file:line` citation: re-grep at drafting time (G14); cite the commit hash in the
   artifact note.
3. Every fixture citation: confirm the fixture is still registered in the gate and the gate
   still passes; **never edit a fixture's comments** to improve framing (byte-identity outranks
   comments).
4. Every quote: verbatim from the survey's quote bank (the survey programmatically verified 22
   needles; re-verify URLs render before camera-ready, survey §5.5).
5. Every Lean citation: by theorem name (stable across the refactor; the unique-name set was
   verified byte-identical, memory `0bca1da8`), not by file:line alone.
6. The abstract is re-checked against §5's table at every revision; the honest scope sentence
   ("we do not prove general soundness") is the last thing deleted only if T1/T2 actually get
   proved — which, per G9(a), they will not pre-submission.
