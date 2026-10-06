/-
λρG — the two H2 escape obligations, CLOSED.

Companion to `lean/RowGadt.lean`, which mechanizes H1 + the H2-a/H2-b domain
content and STATES (but does not prove) the two escape obligations that close
H2. This file PROVES both. It `import RowGadt` and reuses that file's syntax
(§1), occurrence/substitution algebra (§7) and `escapesDirect` (§9) — the
verbatim copies that previously lived here are GONE, so each definition exists
exactly once.

The rigid set here is `RowVar -> Bool` (a decidable membership test), which is
what the implementation's `generalizationRigid` actually is
(`scopeFreeVars ++ refinedTargets ++ refinedTails heads+tails` — a `List Int`,
membership decidable).

OBLIGATION 1 (let-laundering): `H2b_no_quantify_refined_tail`. An adversarial
hunt proved that a statement of H2 constraining ONLY the branch-result
unification is TOO WEAK to rule out let-laundering: the leak happens in the
let-binding form FIRST — generalizeLet/generalizeBinds quantify the refined
tail away (severing the occurs-link) so a use re-instantiates a fresh variable
and the result-unify check can no longer see the tail. The fix
(`generalizationRigid`, Type/Infer.elm:1249) adds `refinedTargets` and every
refined tail's head+tail to the let-generalization rigid set R. Here we
FORMALIZE let-generalization (`generalizeLet` quantifies exactly the non-rigid
variables) and PROVE a refined tail (and head) is never quantified: its
occurrence in any body type survives generalization, so the escape check still
sees it and the laundering the counterexample (`let ys = rest in ys`) exploits
is impossible.

OBLIGATION 2 (wildcard sibling leak): `H2b_wildcard_leak_shape`. A refining
branch returns the tail into a SHARED flexible case-result variable while a
sibling wildcard/head branch returns the full row; unifying the two aliases
tail := head (a legal flex-alias), zonking the tail away before any
clause-level check can see it. The fix made the escape check SYMMETRIC
(`escapesDirect` tests both orientations). We PROVE the symmetric check fires
on exactly this shape — the second orientation (head in body ∧ tail in result),
which the pre-fix single-orientation check did not test — so the leak is ruled
out.
-/

import RowGadt

--------------------------------------------------------------------------------
-- 1. Let-generalization and OBLIGATION 1 (the let-laundering escape)
--------------------------------------------------------------------------------

/-- Let-generalization, the fixed rule (Type/Infer.elm:1249 `generalizationRigid`):
quantify exactly the variables NOT in the rigid set R — each rigid variable is
left in place, each non-rigid variable is replaced by a fresh variable. -/
def generalizeLet (R : RowVar -> Bool) (fresh : RowVar -> RowVar) : Ty -> Ty :=
  substAliasTy (fun v => if R v then Row.var v else Row.var (fresh v))

/-- The rigid set covers every refined head and tail (the content of
`generalizationRigid`'s refinedTails heads+tails). -/
def rigidCoversRefinedTails (R : RowVar -> Bool) (refinedTails : List (RowVar × RowVar)) : Prop :=
  ∀ hd tl, (hd, tl) ∈ refinedTails -> R hd = true ∧ R tl = true

/-- A rigid variable survives generalization: its occurrence in a body type is
preserved (it is never quantified away). -/
theorem generalizeLet_rigid_preserves (R : RowVar -> Bool) (fresh : RowVar -> RowVar)
    (v : RowVar) (hv : R v = true) (t : Ty) (hocc : occursInTy v t) :
    occursInTy v (generalizeLet R fresh t) := by
  let θ : RowVar -> Row := fun w => if R w then Row.var w else Row.var (fresh w)
  have hθ : θ v = Row.var v := by simp [θ, hv]
  exact occursInTy_stable θ v t hθ hocc

/-- A non-rigid variable IS quantified away: its occurrence is severed — the
exact link the laundering counterexample exploits — provided the fresh image is
genuinely fresh (never `v`). This is the converse that makes the rule exact:
quantification = exactly the non-rigid variables. -/
theorem generalizeLet_nonrigid_severs (R : RowVar -> Bool) (fresh : RowVar -> RowVar)
    (v : RowVar) (hv : R v = false) (hfresh : ∀ w, fresh w ≠ v) (t : Ty) :
    ¬ occursInTy v (generalizeLet R fresh t) := by
  let θ : RowVar -> Row := fun w => if R w then Row.var w else Row.var (fresh w)
  show ¬ occursInTy v (substAliasTy θ t)
  apply occursInTy_not_intro θ v t
  intro w
  cases hRw : R w
  · simp [θ, occursInRow, hRw]
    intro hvw
    exact hfresh w hvw.symm
  · have hvw_ne : v ≠ w := by
      intro hvw
      subst v
      rw [hRw] at hv
      exact Bool.noConfusion hv
    simp [θ, occursInRow, hRw]
    exact hvw_ne

/-- **`H2b_no_quantify_refined_tail` — the let-laundering escape obligation,
PROVED.** If the rigid set R covers every refined head+tail (what
`generalizationRigid` implements), then under the formalized let-generalization
rule a refined tail (resp. head) is NEVER quantified: its occurrence in any
body type survives generalization, so the escape check still sees the tail and
the laundering the counterexample (`let ys = rest in ys`) exploited is
impossible. -/
theorem H2b_no_quantify_refined_tail (R : RowVar -> Bool) (fresh : RowVar -> RowVar)
    (refinedTails : List (RowVar × RowVar))
    (hR : rigidCoversRefinedTails R refinedTails)
    (hd tl : RowVar) (hpair : (hd, tl) ∈ refinedTails) :
    (∀ t, occursInTy tl t -> occursInTy tl (generalizeLet R fresh t))
      ∧ (∀ t, occursInTy hd t -> occursInTy hd (generalizeLet R fresh t)) := by
  have htail : R tl = true := (hR hd tl hpair).2
  have hhead : R hd = true := (hR hd tl hpair).1
  constructor
  · intro t hocc
    exact generalizeLet_rigid_preserves R fresh tl htail t hocc
  · intro t hocc
    exact generalizeLet_rigid_preserves R fresh hd hhead t hocc

--------------------------------------------------------------------------------
-- 2. The wildcard sibling leak and OBLIGATION 2
--------------------------------------------------------------------------------

/-- **`H2b_wildcard_leak_shape` — the wildcard-sibling-leak escape obligation,
PROVED.** The refining branch returns the tail `ρ'` (so `ρ'` occurs in the
shared result `t_r`) while a sibling wildcard/head branch returns the full row
`ρ` (so `ρ` occurs in the body `t_b`). The SYMMETRIC check fires on exactly
this shape: it is the second disjunct of `escapesDirect` (head in body ∧ tail
in result), the orientation the pre-fix single-orientation check did not test.
Hence the leak is ruled out at the clause level, before the flex-alias can zonk
the tail away. (The soundness companion `h2b_wildcard_collapses` is proved in
RowGadt.lean §9b.) -/
theorem H2b_wildcard_leak_shape (ρ ρ' : RowVar) (t_b t_r : Ty)
    (h : occursInTy ρ t_b ∧ occursInTy ρ' t_r) :
    escapesDirect [(ρ, ρ')] t_b t_r := by
  exact ⟨ρ, ρ', by simp, Or.inr h⟩
