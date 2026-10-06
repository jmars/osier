/-
λρG — Stage 2: the store discipline at the JUDGMENT level.

This file turns the stage-1 representation choice (Typing.lean's `caseR` checks
branch bodies under `Δᵢ ++ Δ` and concludes under bare `Δ`) into THEOREMS about
the judgment, and connects them to the row-algebra lemmas already proved in
RowGadt.lean / RowGadtEscape.lean.

CAVEAT, STATED NOT HIDDEN. `Unifies` and `Captures` are `axiom`s in Typing.lean,
so EVERY theorem here about the judgment is CONDITIONAL on those two relations
(and on nothing else). In particular, no closed `HasType` derivation is
constructible that uses a `Unifies`/`Captures` premise; the only fully-closed
derivations are the unifier-free ones (`var`, `ins`, the plain `Result` tier).
Stage 4 replaces the axioms with a SOUND (not complete) relation; nothing here
changes for that replacement.

FINDING (refutation, not weakening). The proposed store-weakening lemma —
  `HasType Γ CEnv Δ R e t → HasType Γ CEnv (Δ' ++ Δ) R e t`
("extra equations available from an enclosing branch do not invalidate a
derivation") — is FALSE as stated. The counterexample is R-UPD-INS: pushing a
fresh ROW equation `ρ ≐ {ℓ : τ | ρ''}` on top of the store refines the open row
`ρ`, so `InsertionRejected` now fires and an insertion `{ x | ℓ ← y }` that was
typeable under the empty store becomes UNtypeable. Adding equations is NOT
monotone for the judgment; the store has one anti-monotone reading (the `ins`
guard) and this is the exact place. See `store_weakening_left_false`.

CONTENTS (all closed; 17 theorems + 2 predicate definitions):
  §1 `store_weakening_left_false` — the proposed left-append weakening is FALSE.
  §2 store lookups under `++` — the positive reading is monotone
     (`tyEqFor`/`rowEqFor` right-append preserves exactly, left-append preserves
     availability), and `InsertionRejected` is monotone both ways with the
     right-append OR-decomposition `insertionRejected_append_right`.
  §3 `result_weakening_right` — R-RESULT right-weakens UNCONDITIONALLY.
  §4 branch scope / no escape — VACUOUS BY CONSTRUCTION (documented, not padded).
  §5 the two escape obligations, restated at the judgment level and wired to the
     RowGadt/RowGadtEscape row algebra.
  §6 `weakening_right_ty`/`weakening_right_br` — the TRUE monotonicity:
     RIGHT-append weakening for the WHOLE judgment, every rule except `ins`
     (whose negative premise is discharged by `hΔ' : ∀ r, ¬ InsertionRejected Δ' r`).
-/

import Typing

open Typing

namespace TypingStore

--------------------------------------------------------------------------------
-- 1. The proposed store-weakening lemma is FALSE (the R-UPD-INS counterexample)
--------------------------------------------------------------------------------

/-- **STORE WEAKENING (left-append) IS FALSE.** The proposed lemma
`HasType Γ CEnv Δ R e t → HasType Γ CEnv (Δ' ++ Δ) R e t` does not hold: a
fresh row equation pushed on top of the store refines the open row `ρ`, flipping
the R-UPD-INS guard and turning an allowed insertion into a rejected one.

Concretely: `{ x | ℓ ← y }` with base row the open `ρ` type-checks under the
empty store, but under `Δ' = [ρ ≐ {ℓ : τ | ρ''}]` the SAME expression is
untypeable because `InsertionRejected Δ' (Row.var ρ)` holds and the `ins` rule's
`¬ InsertionRejected` premise fails. This derivation needs NO unifier (the `ins`
rule has no `Unifies`/`Captures` premise), so the counterexample is fully closed,
not conditional on the axioms. -/
theorem store_weakening_left_false :
    ¬ (∀ (Γ : Ctx) (CEnv : CtorEnv) (Δ Δ' : Store) (R : Rigid) (e : Expr) (t : Ty),
        HasType Γ CEnv Δ R e t → HasType Γ CEnv (Δ' ++ Δ) R e t) := by
  intro hweak
  let ρ : RowVar := ⟨0⟩
  let ρ'' : RowVar := ⟨1⟩
  let ℓ : Label := "ℓ"
  let t_v : Ty := Ty.tcon "Int" []
  let t_f : Ty := Ty.tcon "Str" []
  let s_scrut : Scheme := ⟨[], Ty.record (Row.var ρ)⟩
  let s_val : Scheme := ⟨[], t_v⟩
  let Γ : Ctx := [("x", s_scrut), ("y", s_val)]
  let CEnv : CtorEnv := []
  let R : Rigid := Rigid.empty
  let e : Expr := Expr.var "x"
  let v : Expr := Expr.var "y"
  let Δ' : Store := [Equation.rowEq ρ (Row.field ℓ t_f (Row.var ρ''))]
  -- The two leaves are `var` rule applications: unifier-free, fully closed.
  have hx : HasType Γ CEnv [] R e (Ty.record (Row.var ρ)) :=
    HasType.var Γ CEnv [] R "x" s_scrut (Ty.record (Row.var ρ))
      (by simp [lookupVar, Γ])
      ⟨fun x => x, by simp [s_scrut, substVarTy, substVarRow]⟩
  have hv : HasType Γ CEnv [] R v t_v :=
    HasType.var Γ CEnv [] R "y" s_val t_v
      (by simp [lookupVar, Γ])
      ⟨fun x => x, by simp [s_val, t_v, substVarTy]⟩
  -- Empty store: no tail is refined, so insertion is allowed.
  have hrej_empty : ¬ InsertionRejected [] (Row.var ρ) := by
    intro h
    cases h with
    | up_ins _ _ _ heq => cases heq
  have hderiv : HasType Γ CEnv [] R (Expr.ins e ℓ v) (Ty.record (Row.field ℓ t_v (Row.var ρ))) :=
    HasType.ins Γ CEnv [] R e v ℓ (Row.var ρ) t_v hx hv hrej_empty
  -- Under Δ', the tail ρ IS refined, so insertion is rejected.
  have hins_Δ' : InsertionRejected Δ' (Row.var ρ) :=
    InsertionRejected.up_ins (Row.var ρ) ρ (Row.field ℓ t_f (Row.var ρ'')) rfl rfl
  -- No `ins` derivation exists under Δ': the only constructor concluding
  -- `Expr.ins` carries the premise `¬ InsertionRejected Δ' (Row.var ρ)`.
  have hnot : ¬ HasType Γ CEnv Δ' R (Expr.ins e ℓ v) (Ty.record (Row.field ℓ t_v (Row.var ρ))) := by
    intro h
    cases h with
    | ins _ _ _ _ _ _ _ _ _ _ _ hrej' => exact hrej' hins_Δ'
  have hbad := hweak Γ CEnv [] Δ' R (Expr.ins e ℓ v) (Ty.record (Row.field ℓ t_v (Row.var ρ))) hderiv
  have hbad' : HasType Γ CEnv Δ' R (Expr.ins e ℓ v) (Ty.record (Row.field ℓ t_v (Row.var ρ))) := by
    simpa using hbad
  exact hnot hbad'

--------------------------------------------------------------------------------
-- 2. Store lookups under append (the positive reading is monotone)
--------------------------------------------------------------------------------

/-- RIGHT-append preserves an existing lookup exactly: an equation already in Δ
survives `Δ ++ Δ'` with the same body (Δ is scanned first, so no shadowing).
This is the fact the discharge rules (R-APP-DISCH / R-SEL-DISCH / R-UPD-DISCH,
and R-RESULT's tiers) need for the monotone direction. -/
theorem tyEqFor_append_right (Δ Δ' : Store) (a : TyVar) (τ : Ty) :
    tyEqFor Δ a = some τ -> tyEqFor (Δ ++ Δ') a = some τ := by
  induction Δ generalizing τ with
  | nil => intro h; cases h
  | cons e Δ ih =>
      intro h
      cases e with
      | tyEq b τ₀ =>
          by_cases hba : b = a
          · subst b
            have hτ : τ₀ = τ := by simpa [tyEqFor, List.find?_cons] using h
            simp [tyEqFor, hτ]
          · have hΔ : tyEqFor Δ a = some τ := by simpa [tyEqFor, List.find?_cons, hba] using h
            simpa [tyEqFor, List.find?_cons, hba] using ih τ hΔ
      | rowEq ρ r =>
          have hΔ : tyEqFor Δ a = some τ := by simpa [tyEqFor, List.find?_cons] using h
          simpa [tyEqFor, List.find?_cons] using ih τ hΔ

theorem rowEqFor_append_right (Δ Δ' : Store) (ρ : RowVar) (r : Row) :
    rowEqFor Δ ρ = some r -> rowEqFor (Δ ++ Δ') ρ = some r := by
  induction Δ generalizing r with
  | nil => intro h; cases h
  | cons e Δ ih =>
      intro h
      cases e with
      | rowEq ρ' r₀ =>
          by_cases hρ : ρ' = ρ
          · subst ρ'
            have hr : r₀ = r := by simpa [rowEqFor, List.find?_cons] using h
            simp [rowEqFor, hr]
          · have hΔ : rowEqFor Δ ρ = some r := by simpa [rowEqFor, List.find?_cons, hρ] using h
            simpa [rowEqFor, List.find?_cons, hρ] using ih r hΔ
      | tyEq a τ =>
          have hΔ : rowEqFor Δ ρ = some r := by simpa [rowEqFor, List.find?_cons] using h
          simpa [rowEqFor, List.find?_cons] using ih r hΔ

/-- RIGHT-append preserves a lookup EXACTLY (not merely some-preservation) when
Δ' contributes NO row equation on `ρ`: `rowEqFor (Δ ++ Δ') ρ = rowEqFor Δ ρ`.
`rowEqFor_append_right` above only gives `some r`-preservation; the body-tail
clause of `GeneralizesRespectsRefined` needs the full equality (the `none` case
included), which this provides under the hypothesis that Δ' has no row equation
on the head. -/
theorem rowEqFor_append_right_eq (Δ Δ' : Store) (ρ : RowVar)
    (hΔ' : ∀ ρ', rowEqFor Δ' ρ' = none) :
    rowEqFor (Δ ++ Δ') ρ = rowEqFor Δ ρ := by
  induction Δ generalizing ρ with
  | nil =>
      change rowEqFor Δ' ρ = none
      exact hΔ' ρ
  | cons e Δ ih =>
      cases e with
      | rowEq ρ' r₀ =>
          by_cases hρ : ρ' = ρ
          · subst ρ'
            simp [rowEqFor]
          · simpa [rowEqFor, List.find?_cons, hρ] using (ih ρ)
      | tyEq a τ =>
          simpa [rowEqFor, List.find?_cons] using (ih ρ)

/-- LEFT-append only ADDS equations, never removes: availability is monotone.
It may SHADOW (change the body), but never deletes — which is exactly why
left-append is NOT a weakening for the discharge rules. -/
theorem tyEqFor_append_mono_left (Δ' Δ : Store) (a : TyVar) :
    (∃ τ, tyEqFor Δ a = some τ) -> (∃ τ, tyEqFor (Δ' ++ Δ) a = some τ) := by
  intro h
  induction Δ' generalizing Δ with
  | nil => simpa using h
  | cons e Δ' ih =>
      cases e with
      | tyEq b τ₀ =>
          by_cases hba : b = a
          · subst b
            exact ⟨τ₀, by simp [tyEqFor]⟩
          · rcases ih Δ h with ⟨τ, hτ⟩
            exact ⟨τ, by simpa [tyEqFor, List.find?_cons, hba] using hτ⟩
      | rowEq ρ r =>
          rcases ih Δ h with ⟨τ, hτ⟩
          exact ⟨τ, by simpa [tyEqFor, List.find?_cons] using hτ⟩

theorem rowEqFor_append_mono_left (Δ' Δ : Store) (ρ : RowVar) :
    (∃ r, rowEqFor Δ ρ = some r) -> (∃ r, rowEqFor (Δ' ++ Δ) ρ = some r) := by
  intro h
  induction Δ' generalizing Δ with
  | nil => simpa using h
  | cons e Δ' ih =>
      cases e with
      | rowEq ρ' r₀ =>
          by_cases hρ : ρ' = ρ
          · subst ρ'
            exact ⟨r₀, by simp [rowEqFor]⟩
          · rcases ih Δ h with ⟨r, hr⟩
            exact ⟨r, by simpa [rowEqFor, List.find?_cons, hρ] using hr⟩
      | tyEq a τ =>
          rcases ih Δ h with ⟨r, hr⟩
          exact ⟨r, by simpa [rowEqFor, List.find?_cons] using hr⟩

/-- `InsertionRejected` is monotone in the store in BOTH append directions:
adding equations can only REFINE more tails, never fewer. This is the
anti-monotonicity of the `ins` rule made explicit: more equations -> fewer
allowed insertions. -/
theorem insertionRejected_mono_left (Δ' Δ : Store) (r : Row) :
    InsertionRejected Δ r -> InsertionRejected (Δ' ++ Δ) r := by
  intro h
  cases h with
  | up_ins ρ b htail heq =>
      rcases rowEqFor_append_mono_left Δ' Δ ρ ⟨b, heq⟩ with ⟨b', hb'⟩
      exact InsertionRejected.up_ins r ρ b' htail hb'

theorem insertionRejected_mono_right (Δ Δ' : Store) (r : Row) :
    InsertionRejected Δ r -> InsertionRejected (Δ ++ Δ') r := by
  intro h
  cases h with
  | up_ins ρ b htail heq =>
      exact InsertionRejected.up_ins r ρ b htail (rowEqFor_append_right Δ Δ' ρ b heq)

/-- The precise behavior of the `ins` guard under RIGHT-append: a row is
rejected in `Δ ++ Δ'` iff it is rejected in Δ OR in Δ'. (The `ins` case of the
weakening needs exactly this: `¬ InsertionRejected (Δ ++ Δ') r` follows from
`¬ InsertionRejected Δ r` together with `¬ InsertionRejected Δ' r`.) -/
theorem insertionRejected_append_right (Δ Δ' : Store) (r : Row) :
    InsertionRejected (Δ ++ Δ') r ↔ InsertionRejected Δ r ∨ InsertionRejected Δ' r := by
  constructor
  · induction Δ generalizing r with
    | nil =>
        intro h
        right
        simpa using h
    | cons e Δ ih =>
        intro h
        cases h with
        | up_ins ρ b htail heq =>
            cases e with
            | rowEq ρ' r₀ =>
                by_cases hρ : ρ' = ρ
                · subst ρ'
                  left
                  exact InsertionRejected.up_ins r ρ r₀ htail (by simp [rowEqFor])
                · have heq' : rowEqFor (Δ ++ Δ') ρ = some b := by
                    simpa [rowEqFor, List.find?_cons, hρ] using heq
                  rcases ih r (InsertionRejected.up_ins r ρ b htail heq') with hL | hR
                  · left; exact insertionRejected_mono_left [Equation.rowEq ρ' r₀] Δ r hL
                  · right; exact hR
            | tyEq a τ =>
                have heq' : rowEqFor (Δ ++ Δ') ρ = some b := by
                  simpa [rowEqFor, List.find?_cons] using heq
                rcases ih r (InsertionRejected.up_ins r ρ b htail heq') with hL | hR
                · left; exact insertionRejected_mono_left [Equation.tyEq a τ] Δ r hL
                · right; exact hR
  · intro h
    rcases h with h | h
    · exact insertionRejected_mono_right Δ Δ' r h
    · exact insertionRejected_mono_left Δ Δ' r h

--------------------------------------------------------------------------------
-- 3. R-RESULT is monotone under RIGHT-append (unconditionally)
--------------------------------------------------------------------------------

/-- The branch-result check is monotone in the store's positive reading: a
`Result` derivation under Δ survives `Δ ++ Δ'` UNCONDITIONALLY (no freshness, no
row-equation exclusion) — its only store reads are `tyEqFor`/`rowEqFor`, which
right-append preserves exactly. This is the judgment-level half of why the
discharge rules compose; the `ins` rule is the one exception (Section 2). -/
theorem result_weakening_right (Δ Δ' : Store) (R : Rigid) (t_b t_r : Ty) (v : Verdict) :
    Result Δ R t_b t_r v -> Result (Δ ++ Δ') R t_b t_r v := by
  intro h
  induction h with
  | tier_plain hU => exact Result.tier_plain hU
  | tier_T a τ heq hnotrow hocc hrec =>
      rename_i hrec_ih
      exact Result.tier_T a τ (tyEqFor_append_right Δ Δ' a τ heq) hnotrow hocc hrec_ih
  | tier_R ρ r heq hneed =>
      exact Result.tier_R ρ r (rowEqFor_append_right Δ Δ' ρ r heq) hneed

--------------------------------------------------------------------------------
-- 4. BRANCH SCOPE / NO ESCAPE, at the judgment level
--------------------------------------------------------------------------------

/-
**VACUOUS BY CONSTRUCTION, honestly labelled.** The `caseR` conclusion and the
`HasTypeBranches` recursion are both indexed by BARE `Δ`; the branch's captured
store `Δᵢ` appears only inside the `HasTypeBranches.cons` PREMISES
(`Captures R t_p t_s Δᵢ`, the body under `Δᵢ ++ Δ`, the result check under
`Δᵢ ++ Δ`). There is NO constructor whose conclusion is `HasType … (Δᵢ ++ Δ) …`
while its own store index is `Δ` — so "nothing a branch captures survives it" is
TRUE BY THE SHAPE OF THE RULE, not by a theorem. No lemma is proved here because
there is nothing to prove: a lemma would be a restatement of `rfl`-level index
unfolding.

What would have to change for it to be CONTENT-FUL: a rule whose conclusion is
under `Δᵢ ++ Δ` — i.e. threading the branch's equations OUT into the ambient
store (the unifier-in-rules presentation `case e of {…} ⊳ Δᵢ` that stage 1
deliberately REJECTED in favour of constraint-based capture). Under such a
presentation the no-escape lemma becomes the real theorem `(Δᵢ ++ Δ) ⇒ Δ`
(truncation), i.e. RowGadt's `h2a_truncation` instantiated at `Store` — which is
already proved there as a polymorphic list fact. So the judgment-level discipline
and the row-algebra H2-a lemmas MEET at exactly this point: the judgment makes
H2-a definitional, and RowGadt proves the list fact that would be needed if it
were not.
-/

--------------------------------------------------------------------------------
-- 5. The two escape obligations, restated at the judgment level
--------------------------------------------------------------------------------

/-
`RefinedTailVar` and `GeneralizesRespectsRefined` now live IN Typing.lean (they
moved DOWN a layer so R-LET could reference `GeneralizesRespectsRefined` without
a circular import — this file imports Typing). They are in scope here via
`open Typing`; the theorems below keep their names and statements, now referring
to the single moved definition instead of a local copy.
-/

/-- `Generalizes` (the stage-1 form) quantifies EVERY free variable not in Γ —
so a refined tail that is free in `t` is quantified, which is exactly the
let-laundering hole. The R-LET rule must be strengthened to
`GeneralizesRespectsRefined`. -/
theorem generalizes_quantifies_free_var (Γ : Ctx) (t : Ty) (s : Scheme) (v : Var) :
    Generalizes Γ t s -> fvTy t v -> ¬ fvCtx Γ v -> v ∈ s.quantifiers := by
  intro h hfv hctx
  exact (h.2 v).2 ⟨hfv, hctx⟩

/-- The corrected predicate does exclude refined tails: if ρ is refined in Δ and
`s` generalizes `t` respecting Δ, then ρ is not quantified — the judgment-level
mirror of `H2b_no_quantify_refined_tail`'s conclusion. -/
theorem generalizes_respects_refined_excludes (Δ : Store) (Γ : Ctx) (t : Ty) (s : Scheme)
    (ρ : RowVar) :
    GeneralizesRespectsRefined Δ Γ t s -> RefinedTailVar Δ ρ -> Var.row ρ ∉ s.quantifiers := by
  intro h hρ
  exact h.2.1 ρ hρ

/-- **The new R-LET excludes the let-laundering shape.** With R-LET's BOTH
premises — the unconstrained `Generalizes` (which ALONE would quantify the tail,
see `generalizes_quantifies_free_var`) AND the added `GeneralizesRespectsRefined`
— a refined tail of Δ is NOT in `s.quantifiers`, so the escape check still sees
it. This is the judgment-level mirror of RowGadt's `h2b_let_severs_occurs`,
inverted: there the laundering SEVERS the occurs-link by substituting a fresh
variable; here the respects-refined premise keeps the tail UNquantified so the
link survives generalization. The proof is exactly
`generalizes_respects_refined_excludes` (the `Generalizes` premise is carried so
the "both premises" shape of the corrected rule is explicit, even though it is
the respects-refined premise that does the excluding). -/
theorem letR_excludes_refined_tails (Δ : Store) (Γ : Ctx) (t : Ty) (s : Scheme) (ρ : RowVar) :
    Generalizes Γ t s -> GeneralizesRespectsRefined Δ Γ t s -> RefinedTailVar Δ ρ ->
    Var.row ρ ∉ s.quantifiers := by
  intro _hgen hres hρ
  exact generalizes_respects_refined_excludes Δ Γ t s ρ hres hρ

/-- **The body-tail half, now with its own name.** The mirror of
`generalizes_respects_refined_excludes` for the THIRD conjunct of
`GeneralizesRespectsRefined`: if `s` generalizes `t` respecting Δ and the store
reads `ρ ≐ b` whose body has tail `ρ'`, then `ρ'` is NOT quantified. This is the
half the implementation's `generalizationRigid` comment calls "the crucial one":
the body-tail is where the equation's refined tail actually lives, and it must
survive generalization so the escape check still sees it. (The HEAD half is
`generalizes_respects_refined_excludes`; this is the BODY-TAIL half.) -/
theorem generalizesRespectsRefined_excludes_body_tail (Δ : Store) (Γ : Ctx) (t : Ty) (s : Scheme)
    (ρ : RowVar) (b : Row) (ρ' : RowVar) :
    GeneralizesRespectsRefined Δ Γ t s -> rowEqFor Δ ρ = some b -> tailVar b = some ρ' ->
    Var.row ρ' ∉ s.quantifiers := by
  intro h heq htail
  exact h.2.2 ρ b ρ' heq htail

/-- **The rule-level counterpart for the body-tail channel**, mirroring
`letR_excludes_refined_tails`: consuming R-LET's actual premises (the
unconstrained `Generalizes` AND the added `GeneralizesRespectsRefined`), a
store-read body-tail `ρ'` is NOT in `s.quantifiers`. The `Generalizes` premise is
carried so the "both premises" shape of the corrected rule is explicit, exactly
as in the head-half theorem; it is the respects-refined premise that does the
excluding. -/
theorem letR_excludes_refined_body_tails (Δ : Store) (Γ : Ctx) (t : Ty) (s : Scheme)
    (ρ : RowVar) (b : Row) (ρ' : RowVar) :
    Generalizes Γ t s -> GeneralizesRespectsRefined Δ Γ t s -> rowEqFor Δ ρ = some b ->
    tailVar b = some ρ' -> Var.row ρ' ∉ s.quantifiers := by
  intro _hgen hres heq htail
  exact generalizesRespectsRefined_excludes_body_tail Δ Γ t s ρ b ρ' hres heq htail

--------------------------------------------------------------------------------
-- 6½. The R-VAR θ channel is closed AT THE DEFINITION of `instantiates`
--------------------------------------------------------------------------------

/-
The R-VAR laundering channel was a SECOND, independent hole (FINDING 3): an
unconstrained θ in `instantiates` could rename a free (non-quantified) variable
of `s.body` to a FRESH variable, severing its occurs-link to the store. The fix
made θ the IDENTITY outside `s.quantifiers` (Typing.lean's `instantiates`). The
theorem below states — at the DEFINITION level, NOT about any rule application —
that this identity constraint does its job: a free variable outside the
quantifiers SURVIVES instantiation. It is about the `instantiates` definition
itself; R-VAR (which consumes `instantiates`) inherits the exclusion by reading
this definition, so no separate rule-level statement is needed or wanted.
-/

/- Variable-substitution preserves free occurrences of any variable it FIXES:
if `θ v = v` and `v` is free in `τ` (resp. row `r`), then `v` is free in
`substVarTy θ τ` (resp. `substVarRow θ r`). The identity-outside-quantifiers
constraint of `instantiates` makes `θ v = v` exactly when `v ∉ s.quantifiers`,
which is how the next theorem discharges it. The mutual block mirrors the
`fvTy`/`fvRow`/`fvTyList` recursion (three components: `Ty`, `Row`, `List Ty`)
so the list-element recursion is structural. -/
mutual
  theorem substVarTy_preserves_fv (θ : Var -> Var) (v : Var) (hid : θ v = v) :
      ∀ (τ : Ty), fvTy τ v -> fvTy (substVarTy θ τ) v
    | Ty.tvar a, h =>
        by
          have ha : Var.ty a = v := h
          rw [← ha] at hid
          simpa [substVarTy, fvTy, hid] using h
    | Ty.tcon _ ts, h =>
        by simpa [substVarTy, fvTy] using (substVarTyList_preserves_fv θ v hid ts h)
    | Ty.fn a b, h =>
        by
          simp [substVarTy, fvTy]
          rcases h with ha | hb
          · exact Or.inl (substVarTy_preserves_fv θ v hid a ha)
          · exact Or.inr (substVarTy_preserves_fv θ v hid b hb)
    | Ty.tup ts, h =>
        by simpa [substVarTy, fvTy] using (substVarTyList_preserves_fv θ v hid ts h)
    | Ty.record r, h =>
        by simpa [substVarTy, fvTy] using (substVarRow_preserves_fv θ v hid r h)

  theorem substVarRow_preserves_fv (θ : Var -> Var) (v : Var) (hid : θ v = v) :
      ∀ (r : Row), fvRow r v -> fvRow (substVarRow θ r) v
    | Row.empty, h => by cases h
    | Row.field _ t r, h =>
        by
          simp [substVarRow, fvRow]
          rcases h with ht | hr
          · exact Or.inl (substVarTy_preserves_fv θ v hid t ht)
          · exact Or.inr (substVarRow_preserves_fv θ v hid r hr)
    | Row.var ρ, h =>
        by
          have hρ : Var.row ρ = v := h
          rw [← hρ] at hid
          simpa [substVarRow, fvRow, hid] using h

  theorem substVarTyList_preserves_fv (θ : Var -> Var) (v : Var) (hid : θ v = v) :
      ∀ (ts : List Ty), fvTyList ts v -> fvTyList (ts.map (substVarTy θ)) v
    | [], h => by cases h
    | t :: ts, h =>
        by
          rcases h with ht | hts
          · exact Or.inl (substVarTy_preserves_fv θ v hid t ht)
          · exact Or.inr (substVarTyList_preserves_fv θ v hid ts hts)
end

/-- **The R-VAR θ channel is closed AT THE DEFINITION of `instantiates`.**
If `instantiates s t` (i.e. some θ with `substVarTy θ s.body = t`, IDENTITY
outside `s.quantifiers`) and `v ∉ s.quantifiers` is free in `s.body`, then `v` is
free in `t`: the identity constraint means `θ v = v`, and substitution preserves
free occurrences of a fixed variable. So a free non-quantified variable of the
scheme body is NOT silently renamed to a fresh one — its occurs-link survives,
and the escape check still sees it. This is a statement about the DEFINITION
(`instantiates`), not about R-VAR's rule application; R-VAR inherits it by
consuming exactly this definition as its premise. -/
theorem instantiates_preserves_free_outside_quantifiers (s : Scheme) (t : Ty) (v : Var) :
    instantiates s t -> v ∉ s.quantifiers -> fvTy s.body v -> fvTy t v := by
  intro h hnotin hfv
  rcases h with ⟨θ, hθ, hsub⟩
  have hid : θ v = v := hθ v hnotin
  rw [← hsub]
  exact substVarTy_preserves_fv θ v hid s.body hfv

/-- `InsertionRejected Δ (Row.var ρ)` is exactly `RefinedTailVar Δ ρ`: a bare tail
variable `ρ` is "refined" iff the store carries a row equation on it. This is the
bridge between the `ins` guard's negative premise and the R-LET refinement
exclusion — both name the same store fact, once as a rejection, once as a
refinement. -/
theorem refinedTailVar_iff_insertionRejected (Δ : Store) (ρ : RowVar) :
    InsertionRejected Δ (Row.var ρ) ↔ RefinedTailVar Δ ρ := by
  constructor
  · intro h
    cases h with
    | up_ins ρ' b htail heq =>
        have hρ : ρ' = ρ := by
          simp [tailVar] at htail
          exact htail.symm
        subst ρ'
        exact ⟨b, heq⟩
  · intro h
    rcases h with ⟨b, heq⟩
    exact InsertionRejected.up_ins (Row.var ρ) ρ b rfl heq

/-- `RefinedTailVar` decomposes over right-append: a tail refined in `Δ ++ Δ'` is
refined in Δ OR in Δ' (Δ is scanned first, so Δ' only contributes tails Δ leaves
bare). Derived from `insertionRejected_append_right` via the bridge above. -/
theorem refinedTailVar_append_decompose (Δ Δ' : Store) (ρ : RowVar) :
    RefinedTailVar (Δ ++ Δ') ρ -> RefinedTailVar Δ ρ ∨ RefinedTailVar Δ' ρ := by
  intro h
  have hins : InsertionRejected (Δ ++ Δ') (Row.var ρ) :=
    (refinedTailVar_iff_insertionRejected (Δ ++ Δ') ρ).mpr h
  have hdec := (insertionRejected_append_right Δ Δ' (Row.var ρ)).1 hins
  rcases hdec with hL | hR
  · left; exact (refinedTailVar_iff_insertionRejected Δ ρ).mp hL
  · right; exact (refinedTailVar_iff_insertionRejected Δ' ρ).mp hR

/-- `GeneralizesRespectsRefined` is preserved under RIGHT-append, PROVIDED Δ'
refines no tail (the same `hΔ'` side condition the `ins` case of `weakenTy`
carries). Adding equations to the right can only REFINE new tails — making the
predicate HARDER, not easier — so the exclusion is asked only under a Δ' that
introduces no fresh row equation. This is why R-LET is store-SENSITIVE in the
same way `ins` is, and it is the fact `weakenTy`'s `letR` case needs. -/
theorem generalizesRespectsRefined_append_right (Δ Δ' : Store) (Γ : Ctx) (t : Ty) (s : Scheme)
    (hΔ' : ∀ r, ¬ InsertionRejected Δ' r) :
    GeneralizesRespectsRefined Δ Γ t s -> GeneralizesRespectsRefined (Δ ++ Δ') Γ t s := by
  intro h
  -- Δ' refines no tail, so Δ' carries NO row equation at all (via the bridge).
  have hnoeq : ∀ ρ', rowEqFor Δ' ρ' = none := by
    intro ρ'
    cases h : rowEqFor Δ' ρ' with
    | none => rfl
    | some b =>
        exfalso
        have hnot : ¬ RefinedTailVar Δ' ρ' := by
          intro hR
          exact hΔ' (Row.var ρ') ((refinedTailVar_iff_insertionRejected Δ' ρ').mpr hR)
        exact hnot ⟨b, h⟩
  refine ⟨h.1, ?_, ?_⟩
  · intro ρ hρ
    rcases refinedTailVar_append_decompose Δ Δ' ρ hρ with hL | hR
    · exact h.2.1 ρ hL
    · exfalso
      exact hΔ' (Row.var ρ) ((refinedTailVar_iff_insertionRejected Δ' ρ).mpr hR)
  · intro ρ b ρ' heq htail
    have heq' : rowEqFor Δ ρ = some b := by
      rw [rowEqFor_append_right_eq Δ Δ' ρ hnoeq] at heq
      exact heq
    exact h.2.2 ρ b ρ' heq' htail

/-- The judgment-level counterpart of RowGadt's `refinedTails_of_row_eq`: a row
equation `ρ ≐ {ℓ : t | ρ'}` read from the store makes ρ a refined target (and
`ρ'` its tail — the `(head, tail)` pair the escape obligation must keep rigid). -/
theorem refinedTailVar_of_row_eq (Δ : Store) (ρ : RowVar) (ℓ : Label) (t : Ty) (ρ' : RowVar) :
    rowEqFor Δ ρ = some (Row.field ℓ t (Row.var ρ')) -> RefinedTailVar Δ ρ := by
  intro h
  exact ⟨Row.field ℓ t (Row.var ρ'), h⟩

/-- R-RESULT's Tier-R is the judgment-level seat of `H2b_wildcard_leak_shape`
(proved in RowGadtEscape): when a row equation `ρ ≐ r` is in Δ and `ρ` occurs in
the body OR the result, the branch-result check is FORCED to `escape`. The
row-algebra lemma proves the symmetric `escapesDirect` check fires on exactly
this shape; here the judgment says the same shape is a terminal `escape` verdict. -/
theorem tier_R_forces_escape (Δ : Store) (R : Rigid) (t_b t_r : Ty) (ρ : RowVar) (r : Row) :
    rowEqFor Δ ρ = some r -> fvTy t_r (Var.row ρ) ∨ fvTy t_b (Var.row ρ) ->
    Result Δ R t_b t_r Verdict.escape := by
  intro heq hneed
  exact Result.tier_R ρ r heq hneed

--------------------------------------------------------------------------------
-- 6. The TRUE monotonicity: RIGHT-append weakening for the whole judgment
--------------------------------------------------------------------------------

/-
The naive left-append weakening is FALSE (Section 1). The TRUE monotone form is
RIGHT-append, and it holds for EVERY rule except `ins` — with the `ins` case
discharged by the hypothesis that Δ' refines no row tail (equivalently, Δ' has
no row equations; see `insertionRejected_append_right`). The proof is a mutual
structural recursion over `HasType`/`HasTypeBranches` (Lean's `induction` tactic
rejects mutual inductives, so the recursion is written as a mutual `def` by
pattern matching). Every store read is discharged by Section 2's lemmas: the
positive lookups by `tyEqFor_append_right`/`rowEqFor_append_right`, the `ins`
guard by `insertionRejected_append_right` + `hΔ'`, and the branch-result check
by `result_weakening_right`; the branch store `Δᵢ ++ (Δ ++ Δ')` is obtained from
`(Δᵢ ++ Δ) ++ Δ'` by list associativity. -/
mutual
  theorem weakenTy {Γ : Ctx} {CEnv : CtorEnv} {Δ : Store} {R : Rigid} {e : Expr} {t : Ty}
      (Δ' : Store) (hΔ' : ∀ r, ¬ InsertionRejected Δ' r) :
      HasType Γ CEnv Δ R e t → HasType Γ CEnv (Δ ++ Δ') R e t
    | HasType.var _ _ _ _ x s _ hlook hinst =>
        HasType.var Γ CEnv (Δ ++ Δ') R x s t hlook hinst
    | HasType.typeBinder _ _ _ _ B e' _ hbody =>
        HasType.typeBinder Γ CEnv (Δ ++ Δ') R B e' t (weakenTy Δ' hΔ' hbody)
    | HasType.app _ _ _ _ e₀ e₁ t₁ t₂ t₁' hf ha hU =>
        HasType.app Γ CEnv (Δ ++ Δ') R e₀ e₁ t₁ t₂ t₁'
          (weakenTy Δ' hΔ' hf) (weakenTy Δ' hΔ' ha) hU
    | HasType.appDisch _ _ _ _ e₀ e₁ t₁ t₂ t₁' a τ hf ha heq hnotrow hocc hU =>
        HasType.appDisch Γ CEnv (Δ ++ Δ') R e₀ e₁ t₁ t₂ t₁' a τ
          (weakenTy Δ' hΔ' hf) (weakenTy Δ' hΔ' ha)
          (tyEqFor_append_right Δ Δ' a τ heq) hnotrow hocc hU
    | HasType.sel _ _ _ _ e' ℓ r a β he hU =>
        HasType.sel Γ CEnv (Δ ++ Δ') R e' ℓ r a β (weakenTy Δ' hΔ' he) hU
    | HasType.selDisch _ _ _ _ e' ℓ r ρ ρ'' t' he htail heq =>
        HasType.selDisch Γ CEnv (Δ ++ Δ') R e' ℓ r ρ ρ'' t'
          (weakenTy Δ' hΔ' he) htail
          (rowEqFor_append_right Δ Δ' ρ (Row.field ℓ t' (Row.var ρ'')) heq)
    | HasType.upd _ _ _ _ e' v ℓ r r' t_ℓ t_v he hres hv hU =>
        HasType.upd Γ CEnv (Δ ++ Δ') R e' v ℓ r r' t_ℓ t_v
          (weakenTy Δ' hΔ' he) hres (weakenTy Δ' hΔ' hv) hU
    | HasType.updDisch _ _ _ _ e' v ℓ r ρ ρ'' t' t_v he htail heq hv hU =>
        HasType.updDisch Γ CEnv (Δ ++ Δ') R e' v ℓ r ρ ρ'' t' t_v
          (weakenTy Δ' hΔ' he) htail
          (rowEqFor_append_right Δ Δ' ρ (Row.field ℓ t' (Row.var ρ'')) heq)
          (weakenTy Δ' hΔ' hv) hU
    | HasType.ins _ _ _ _ e' v ℓ r t_v he hv hrej =>
        HasType.ins Γ CEnv (Δ ++ Δ') R e' v ℓ r t_v
          (weakenTy Δ' hΔ' he) (weakenTy Δ' hΔ' hv)
          (by intro hIR
              rcases (insertionRejected_append_right Δ Δ' r).1 hIR with h | h
              · exact hrej h
              · exact hΔ' r h)
    | HasType.caseR _ _ _ _ e_scrut branches t_s t_r hscrut hbranches =>
        HasType.caseR Γ CEnv (Δ ++ Δ') R e_scrut branches t_s t_r
          (weakenTy Δ' hΔ' hscrut) (weakenBr Δ' hΔ' hbranches)
    | HasType.letR _ _ _ _ x e₁ e₂ t₁ t₂ s he₁ hgen hgen' he₂ =>
        HasType.letR Γ CEnv (Δ ++ Δ') R x e₁ e₂ t₁ t₂ s
          (weakenTy Δ' hΔ' he₁) hgen
          (generalizesRespectsRefined_append_right Δ Δ' Γ t₁ s hΔ' hgen')
          (weakenTy Δ' hΔ' he₂)

  theorem weakenBr {Γ : Ctx} {CEnv : CtorEnv} {Δ : Store} {R : Rigid} {t_s t_r : Ty}
      {branches : List (Pattern × Expr)}
      (Δ' : Store) (hΔ' : ∀ r, ¬ InsertionRejected Δ' r) :
      HasTypeBranches Γ CEnv Δ R t_s t_r branches → HasTypeBranches Γ CEnv (Δ ++ Δ') R t_s t_r branches
    | HasTypeBranches.nil _ _ _ _ _ _ =>
        HasTypeBranches.nil Γ CEnv (Δ ++ Δ') R t_s t_r
    | HasTypeBranches.cons _ _ _ _ _ _ t_p t_b binds exts Δᵢ hpat hcap hbody hresult hrest =>
        HasTypeBranches.cons Γ CEnv (Δ ++ Δ') R t_s t_r t_p t_b binds exts Δᵢ hpat hcap
          (by simpa [List.append_assoc] using weakenTy Δ' hΔ' hbody)
          (by simpa [List.append_assoc] using result_weakening_right (Δᵢ ++ Δ) Δ' R t_b t_r Verdict.ok hresult)
          (weakenBr Δ' hΔ' hrest)
end

/-- **THE TRUE STORE MONOTONICITY.** RIGHT-append (`Δ -> Δ ++ Δ'`) is the
monotone direction: a derivation under Δ survives `Δ ++ Δ'` for EVERY rule
except `ins`, whose negative premise is handled by the hypothesis that Δ'
refines no row tail. Contrast Section 1, where LEFT-append is refuted by the
same `ins` rule. -/
theorem weakening_right_ty {Γ : Ctx} {CEnv : CtorEnv} {Δ Δ' : Store} {R : Rigid} {e : Expr} {t : Ty}
    (hΔ' : ∀ r, ¬ InsertionRejected Δ' r) :
    HasType Γ CEnv Δ R e t -> HasType Γ CEnv (Δ ++ Δ') R e t :=
  weakenTy Δ' hΔ'

theorem weakening_right_br {Γ : Ctx} {CEnv : CtorEnv} {Δ Δ' : Store} {R : Rigid} {t_s t_r : Ty}
    {branches : List (Pattern × Expr)}
    (hΔ' : ∀ r, ¬ InsertionRejected Δ' r) :
    HasTypeBranches Γ CEnv Δ R t_s t_r branches -> HasTypeBranches Γ CEnv (Δ ++ Δ') R t_s t_r branches :=
  weakenBr Δ' hΔ'

end TypingStore
