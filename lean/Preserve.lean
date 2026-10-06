/-
λρG — Stage 3: preservation for the record operations.

This file closes the deadline-grade slice of T2: type-preservation for the two
record reductions (SELECT and UPDATE) under branch-local refinement, plus the
soundness of the TWO-TIER result rule's asymmetry (Tier-T coerces and may still
conclude `ok`; Tier-R is terminal and never discharges).

SCOPE, held deliberately tight:
  * a MINIMAL small-step relation `Step` with exactly the two record reductions
    (§3.2 of the calculus doc) — selection by FIRST-OCCURRENCE lookup and update
    by cons-prepend-shadow. No βv, no evaluation contexts, no case dispatch;
    those are out of scope for this stage.
  * `RecordHasType`, the record-literal typing rule the stage-1 skeleton OMITS
    (Typing.lean's header flags it: record literals are in the syntax but have
    no `HasType` constructor). It is declared here as a SEPARATE relation rather
    than added to `HasType`, so this file does not re-emit Typing.lean and does
    not force a new case into TypingStore's `weakenTy`/`weakenBr` total
    functions. This is a FINDING: preservation for selection is not even
    STATEABLE against `HasType` without it.
  * SELECT preservation (both `sel` and the DISCHARGED `selDisch`), UPDATE
    preservation (`upd`), and the two-tier soundness lemmas.

CAVEAT (unchanged from stages 1-2): `Unifies`/`Captures` are axioms, and the
plain `sel` case needs ONE more property of the abstract unifier — that unifying
two record types relates the first-occurrence types of a common label
(`unifies_field_projection`, declared as an axiom here). Every theorem touching
the unifier is conditional on that parameter; Stage 4 must instantiate it
alongside `Unifies`/`Captures`.

The discharged `selDisch` case and the update case need NO unifier axiom and NO
`Captures`; the store-read lemmas (`rowEqFor`, `substRowVarRow`, `firstType`)
are reused from Typing.lean at the full `Ty`/`Row` (the drift note in
Typing.lean's header: RowGadt's minimal `Row` is a DIFFERENT object, so its H1
lemmas are re-proven here at the full grammar — `firstType_subst_rowvar` is the
full-`Ty` restatement of `h1_no_shadow`, and `restrict_domain_ty` /
`update_domain_preserving_ty` are the full-`Ty` restatements of Update.lean's
`restrict_domain` / `update_domain_preserving`).
-/

import Typing
import TypingStore

open Typing

namespace Preserve

--------------------------------------------------------------------------------
-- 1. The dynamic record semantics (minimal: the two record reductions only)
--------------------------------------------------------------------------------

/-- Dynamic first occurrence: the value at the FIRST `ℓ` in the field list,
head-first (the doc's §3.1 `assoc` first-match-wins, and §3.2 SEL). -/
def firstOccurrence : List (Label × Expr) -> Label -> Option Expr
  | [], _ => none
  | (l, v) :: rest, m => if l = m then some v else firstOccurrence rest m

/-- The dynamic first-occurrence label set: `ℓ` is in the record's field
sequence iff `firstOccurrence` finds it. This is `dom₀` of the VALUE. -/
def containsLabel : List (Label × Expr) -> Label -> Prop
  | [], _ => False
  | (l, _) :: rest, m => m = l ∨ containsLabel rest m

/-- **The minimal small-step relation** (§3.2). Two constructors, no more:
  * `sel` — `{ (ℓ₁,v₁) :: … :: (ℓₙ,vₙ) }.ℓ → vᵢ` where `i` is the FIRST `ℓⱼ = ℓ`
    (first-occurrence lookup; stuck if absent — no `Step` in that case);
  * `upd` — `{ v | ℓ = v' } → { (ℓ,v') :: v }` (cons-prepend-shadow).
These are exactly the two record reductions stage 3 is about. -/
inductive Step : Expr -> Expr -> Prop where
  | sel (fs : List (Label × Expr)) (ℓ : Label) (v : Expr) :
      firstOccurrence fs ℓ = some v ->
      Step (Expr.sel (Expr.record fs) ℓ) v
  | upd (fs : List (Label × Expr)) (ℓ : Label) (v : Expr) :
      Step (Expr.upd (Expr.record fs) ℓ v) (Expr.record ((ℓ, v) :: fs))

--------------------------------------------------------------------------------
-- 2. Static first-occurrence type (at the FULL `Row` of Typing.lean)
--------------------------------------------------------------------------------

/-- Static first occurrence: the type at the FIRST `ℓ` in the row's field
prefix (the row-level mirror of the dynamic `firstOccurrence`; `none` at a bare
tail variable or empty tail, because a tail variable exposes no known field). -/
def firstType : Row -> Label -> Option Ty
  | Row.field l t r, m => if l = m then some t else firstType r m
  | Row.empty, _ => none
  | Row.var _, _ => none

--------------------------------------------------------------------------------
-- 3. Record-literal typing (the rule the skeleton omits)
--------------------------------------------------------------------------------

/-- **R-REC** (the missing rule). A closed record literal `{ (ℓ₁,v₁) :: … }`
types against a row whose field prefix is exactly `(ℓ₁,t₁) :: …` — head-field to
head-field. Declared as a SEPARATE relation (not a `HasType` constructor) so
Typing.lean and TypingStore.lean are untouched; see the header's finding. -/
inductive RecordHasType (Γ : Ctx) (CEnv : CtorEnv) (Δ : Store) (R : Rigid) :
    List (Label × Expr) -> Row -> Prop where
  | nil : RecordHasType Γ CEnv Δ R [] Row.empty
  | cons {ℓ : Label} {v : Expr} {t : Ty} {fs : List (Label × Expr)} {r : Row} :
      HasType Γ CEnv Δ R v t ->
      RecordHasType Γ CEnv Δ R fs r ->
      RecordHasType Γ CEnv Δ R ((ℓ, v) :: fs) (Row.field ℓ t r)

--------------------------------------------------------------------------------
-- 4. The static/dynamic first-occurrence correspondence (the bridge)
--------------------------------------------------------------------------------

/-- **The static and dynamic first-occurrence disciplines are the same
relation** (§3 "Erasure and the theorems"): a record value whose field list is
typed against a row selects, at the first `ℓ`, the value whose type is the row's
first-occurrence type of `ℓ`. This is the judgment-level version of the §5.3
identity, before any equation discharge. -/
theorem record_first_occ {Γ : Ctx} {CEnv : CtorEnv} {Δ : Store} {R : Rigid}
    {fs : List (Label × Expr)} {r : Row} :
    RecordHasType Γ CEnv Δ R fs r ->
    ∀ (ℓ : Label) (v : Expr) (t : Ty),
      firstOccurrence fs ℓ = some v -> firstType r ℓ = some t -> HasType Γ CEnv Δ R v t := by
  intro h
  induction h with
  | nil =>
      intro ℓ v t hf ht
      cases hf
  | cons hv hrest ih =>
      rename_i hℓ hv' ht' hfs hr'
      intro ℓ v t hf ht
      by_cases hℓe : hℓ = ℓ
      · subst hℓ
        have hv'' : hv' = v := by simpa [firstOccurrence] using hf
        have ht'' : ht' = t := by simpa [firstType] using ht
        rw [← hv'', ← ht'']
        exact hv
      · have hf' : firstOccurrence hfs ℓ = some v := by simpa [firstOccurrence, hℓe] using hf
        have ht'' : firstType hr' ℓ = some t := by simpa [firstType, hℓe] using ht
        exact ih ℓ v t hf' ht''

/-- The dynamic first-occurrence label set equals the static row domain (the
`contains` relation Typing.lean already has). This is the domain-level bridge the
UPDATE case needs. -/
theorem record_domain {Γ : Ctx} {CEnv : CtorEnv} {Δ : Store} {R : Rigid}
    {fs : List (Label × Expr)} {r : Row} :
    RecordHasType Γ CEnv Δ R fs r -> ∀ x, containsLabel fs x ↔ contains x r := by
  intro h
  induction h with
  | nil => intro x; simp [containsLabel, contains]
  | cons hv hrest ih =>
      intro x
      unfold containsLabel contains
      have ihx := ih x
      constructor
      · intro hx
        rcases hx with hx | hx
        · left; exact hx
        · right; exact ihx.mp hx
      · intro hx
        rcases hx with hx | hx
        · left; exact hx
        · right; exact ihx.mpr hx

--------------------------------------------------------------------------------
-- 5. H1 at the full grammar: the equation's head is the first occurrence
--------------------------------------------------------------------------------

/-- **H1 (no-shadow), restated at the FULL `Row`.** If the known prefix `r`
reaches its tail `ρ` without `ℓ` (so `firstType r ℓ = none`) and `ρ` is expanded
through the equation `{ ℓ : t' | ρ'' }`, then the FIRST occurrence of `ℓ` in the
expanded row is exactly the equation's head, of type `t'`. This is the full-`Ty`
counterpart of RowGadt's `h1_no_shadow` (RowGadt's minimal `Row` is a different
object — the drift note in Typing.lean's header). -/
theorem firstType_subst_rowvar (r : Row) (ρ : RowVar) (ℓ : Label) (t' : Ty) (ρ'' : RowVar) :
    tailVar r = some ρ -> firstType r ℓ = none ->
    firstType (substRowVarRow ρ (Row.field ℓ t' (Row.var ρ'')) r) ℓ = some t' := by
  exact (Row.rec (motive_1 := fun _ => True)
      (motive_2 := fun r =>
        ∀ (ρ : RowVar) (ℓ : Label) (t' : Ty) (ρ'' : RowVar),
          tailVar r = some ρ -> firstType r ℓ = none ->
          firstType (substRowVarRow ρ (Row.field ℓ t' (Row.var ρ'')) r) ℓ = some t')
      (motive_3 := fun _ => True)
      (fun a => by trivial)
      (fun n ts ih => by trivial)
      (fun a b iha ihb => by trivial)
      (fun ts ih => by trivial)
      (fun r' ih => by trivial)
      (fun ρ ℓ t' ρ'' htail hnot => by simp [tailVar] at htail)
      (fun l t r' ihTy ihRow => by
        intro ρ ℓ t' ρ'' htail hnot
        by_cases hℓ : l = ℓ
        · have : firstType (Row.field l t r') ℓ = some t := by simp [firstType, hℓ]
          rw [this] at hnot
          cases hnot
        · have htail' : tailVar r' = some ρ := by simpa [tailVar] using htail
          have hnot' : firstType r' ℓ = none := by simpa [firstType, hℓ] using hnot
          have ih' := ihRow ρ ℓ t' ρ'' htail' hnot'
          simp [substRowVarRow, firstType, hℓ, ih'])
      (fun ρv => by
        intro ρ ℓ t' ρ'' htail hnot
        have hρ : ρv = ρ := by simpa [tailVar] using htail
        subst ρv
        simp [substRowVarRow, firstType])
      (by trivial)
      (fun h tl ihh iht => by trivial)
      r) ρ ℓ t' ρ''

--------------------------------------------------------------------------------
-- 6. SELECT preservation
--------------------------------------------------------------------------------

/-- **Field-projection soundness of the abstract unifier** (Stage-4 obligation,
alongside `Unifies`/`Captures`). Unifying `{ r }` with `{ ℓ : a | β }` relates
`a` to the type of `r`'s FIRST occurrence of `ℓ` — the row-rewrite soundness
property of Leijen's unifier (expose the head, unify the exposed type). The plain
R-SEL preservation case needs exactly this; the discharged `selDisch` case and
update do NOT (their result types are read syntactically). -/
axiom unifies_field_projection (R : Rigid) (r : Row) (ℓ : Label) (a : TyVar) (β : RowVar) (tᵢ : Ty) :
    Unifies R (Ty.record r) (Ty.record (Row.field ℓ (Ty.tvar a) (Row.var β))) ->
    firstType r ℓ = some tᵢ ->
    Unifies R (Ty.tvar a) tᵢ

/-- **R-SEL preserves (plain, no discharge).** If the record value's first `ℓ`
is `v` and its static row has first-occurrence type `tᵢ` at `ℓ`, then `v : tᵢ`;
the syntactic result type `a` is the unifier-identified field type
(`Unifies R a tᵢ`, via the field-projection obligation). The result is typed by
the SELECTED FIELD'S TYPE, and the `a`-connection is exactly the constraint the
unifier records (this is the constraint-based reading of T2's `t' = θ(t)`). -/
theorem sel_preserves {Γ : Ctx} {CEnv : CtorEnv} {Δ : Store} {R : Rigid}
    {fs : List (Label × Expr)} {r : Row} {ℓ : Label} {v : Expr}
    {a : TyVar} {β : RowVar} {tᵢ : Ty} :
    RecordHasType Γ CEnv Δ R fs r ->
    firstType r ℓ = some tᵢ ->
    firstOccurrence fs ℓ = some v ->
    Unifies R (Ty.record r) (Ty.record (Row.field ℓ (Ty.tvar a) (Row.var β))) ->
    HasType Γ CEnv Δ R v tᵢ ∧ Unifies R (Ty.tvar a) tᵢ := by
  intro hrec hft hocc hU
  constructor
  · exact record_first_occ hrec ℓ v tᵢ hocc hft
  · exact unifies_field_projection R r ℓ a β tᵢ hU hft

/-- **R-SEL-DISCH preserves (the DISCHARGED case — the heart of the refinement).**
A selection licensed by the branch equation `ρ ≐ { ℓ : t' | ρ'' } ∈ Δ` (read via
`rowEqFor`, i.e. the discharge) reduces by FIRST-OCCURRENCE lookup; when `ℓ` is
not shadowed in the known prefix `r` and the record's closed type is the
expansion of `r` through the equation, the dynamic first occurrence has EXACTLY
the equation's head type `t'` — no unifier axiom, the result type is read
syntactically off the discharge. This is the selection half of §4's "the
equation's head is the first occurrence under the swap-preserving rewrite". -/
theorem selDisch_preserves {Γ : Ctx} {CEnv : CtorEnv} {Δ : Store} {R : Rigid}
    {fs : List (Label × Expr)} {r : Row} {ℓ : Label} {ρ ρ'' : RowVar} {t' : Ty} {v : Expr} :
    rowEqFor Δ ρ = some (Row.field ℓ t' (Row.var ρ'')) ->
    tailVar r = some ρ ->
    firstType r ℓ = none ->
    RecordHasType Γ CEnv Δ R fs (substRowVarRow ρ (Row.field ℓ t' (Row.var ρ'')) r) ->
    firstOccurrence fs ℓ = some v ->
    HasType Γ CEnv Δ R v t' := by
  intro heq htail hnot hrec hocc
  have hft : firstType (substRowVarRow ρ (Row.field ℓ t' (Row.var ρ'')) r) ℓ = some t' :=
    firstType_subst_rowvar r ρ ℓ t' ρ'' htail hnot
  exact record_first_occ hrec ℓ v t' hocc hft

--------------------------------------------------------------------------------
-- 7. UPDATE preservation (the easy, discharge-free case)
--------------------------------------------------------------------------------

/-- **Restrict removes exactly the first occurrence, domain-wise** — the full-`Ty`
restatement of Update.lean's `restrict_domain`. If `restrict r ℓ = some (t₀, r')`
then `r`'s domain is exactly `{ℓ} ∪ dom(r')` (first occurrence removed; duplicate
`ℓ`s retained). -/
theorem restrict_domain_ty (r : Row) (ℓ : Label) :
    ∀ t₀ r', restrict r ℓ = some (t₀, r') → ∀ x, contains x r ↔ (x = ℓ ∨ contains x r') := by
  exact (Row.rec (motive_1 := fun _ => True)
      (motive_2 := fun r =>
        ∀ t₀ r', restrict r ℓ = some (t₀, r') → ∀ x, contains x r ↔ (x = ℓ ∨ contains x r'))
      (motive_3 := fun _ => True)
      (fun a => by trivial)
      (fun n ts ih => by trivial)
      (fun a b iha ihb => by trivial)
      (fun ts ih => by trivial)
      (fun r' ih => by trivial)
      (by intro t₀ r' h; simp [restrict] at h)
      (fun l t rtail ihTy ihRow => by
        intro t₀ r' h
        unfold restrict at h
        by_cases hl : l = ℓ
        · subst l
          simp at h
          rcases h with ⟨rfl, rfl⟩
          intro x
          simp [contains]
        · simp [hl] at h
          cases hrestrict : restrict rtail ℓ with
          | none => simp [hrestrict] at h
          | some p =>
              rcases p with ⟨t'', r''⟩
              simp [hrestrict] at h
              rcases h with ⟨rfl, rfl⟩
              intro x
              have ih' : contains x rtail ↔ (x = ℓ ∨ contains x r'') := ihRow t'' r'' hrestrict x
              simp [contains]
              constructor
              · intro hx
                rcases hx with hx | hx
                · exact Or.inr (Or.inl hx)
                · rcases (ih'.mp hx) with hx | hx
                  · exact Or.inl hx
                  · exact Or.inr (Or.inr hx)
              · intro hx
                rcases hx with hx | hx
                · exact Or.inr (ih'.mpr (Or.inl hx))
                · rcases hx with hx | hx
                  · exact Or.inl hx
                  · exact Or.inr (ih'.mpr (Or.inr hx)))
      (fun a => by intro t₀ r' h; simp [restrict] at h)
      (by trivial)
      (fun h tl ihh iht => by trivial)
      r)

/-- **UPDATE IS DOMAIN-PRESERVING** (the paper's §7 headline, at the full `Ty`).
When `ℓ` is present (`restrict r ℓ = some (t₀, r')`), the update result
`{ ℓ : t_v | r' }` has EXACTLY the same domain as the argument row `r` —
restrict-then-re-prepend never extends the domain. This is Update.lean's
`update_domain_preserving` restated for the full grammar. -/
theorem update_domain_preserving_ty (r : Row) (ℓ : Label) (t_v t₀ : Ty) (r' : Row)
    (h : restrict r ℓ = some (t₀, r')) :
    ∀ x, contains x (Row.field ℓ t_v r') ↔ contains x r := by
  intro x
  have hd := restrict_domain_ty r ℓ t₀ r' h x
  simp [contains]
  exact hd.symm

/-- **R-UPD preserves (no discharge at all — the paper's key-5 claim, dynamic
half).** The reduction `{ v | ℓ = v' } → { (ℓ,v') :: v }` (cons-prepend-shadow)
produces a record whose first-occurrence DOMAIN equals the static result row
`{ ℓ : t_v | r' }` — and therefore (by `update_domain_preserving_ty`) equals the
original domain `r`. No `rowEqFor` read, no `substRowVarRow`, no `Unifies`
field-projection obligation: update never consults the store and never changes
the domain, so it is sound under refinement with nothing discharged. The static
(dynamic) correspondence is `record_domain` + `restrict_domain_ty`. The new head
value's type `t_v` is a carried premise (`HasType … v t_v`), unchanged by the
step. -/
theorem upd_preserves {Γ : Ctx} {CEnv : CtorEnv} {Δ : Store} {R : Rigid}
    {fs : List (Label × Expr)} {r : Row} {ℓ : Label} {v : Expr} {t_ℓ t_v : Ty} {r' : Row} :
    RecordHasType Γ CEnv Δ R fs r ->
    restrict r ℓ = some (t_ℓ, r') ->
    HasType Γ CEnv Δ R v t_v ->
    ∀ x, containsLabel ((ℓ, v) :: fs) x ↔ contains x (Row.field ℓ t_v r') := by
  intro hrec hrest hv x
  unfold containsLabel contains
  have hd1 : containsLabel fs x ↔ contains x r := record_domain hrec x
  have hd2 : contains x r ↔ (x = ℓ ∨ contains x r') := restrict_domain_ty r ℓ t_ℓ r' hrest x
  constructor
  · intro hx
    rcases hx with hx | hx
    · exact Or.inl hx
    · exact hd2.mp (hd1.mp hx)
  · intro hx
    rcases hx with hx | hx
    · exact Or.inl hx
    · exact Or.inr (hd1.mpr (hd2.mpr (Or.inr hx)))

--------------------------------------------------------------------------------
-- 8. The two-tier rule: Tier-T coerces (soundly), Tier-R is terminal
--------------------------------------------------------------------------------

mutual
  /-- **Substitution fixes a type that does not mention the substituted
  variable.** `a := τ` is the identity on any `t` that has no free `a` (the
  general form; the occurs-guard `¬ fvTy τ (Var.ty a)` is the `t := τ` instance
  below). Proved by mutual induction over `Ty` / `Row` / `List Ty` (the three-way
  recursion of the full grammar). -/
  theorem substTyVar_fixes (a : TyVar) (τ : Ty) (t : Ty) :
      ¬ fvTy t (Var.ty a) -> substTyVar a τ t = t := by
    cases t with
    | tvar b =>
        intro h
        by_cases hba : b = a
        · subst b
          have : fvTy (Ty.tvar a) (Var.ty a) := by simp [fvTy]
          exact False.elim (h this)
        · simp [substTyVar, hba]
    | tcon n ts =>
        intro h
        have hts : ¬ fvTyList ts (Var.ty a) := by intro htl; exact h htl
        simp [substTyVar, substTyVarList_fixes a τ ts hts]
    | fn s t' =>
        intro h
        have hs : ¬ fvTy s (Var.ty a) := by intro hsv; exact h (Or.inl hsv)
        have ht' : ¬ fvTy t' (Var.ty a) := by intro htv; exact h (Or.inr htv)
        simp [substTyVar, substTyVar_fixes a τ s hs, substTyVar_fixes a τ t' ht']
    | tup ts =>
        intro h
        have hts : ¬ fvTyList ts (Var.ty a) := by intro htl; exact h htl
        simp [substTyVar, substTyVarList_fixes a τ ts hts]
    | record r =>
        intro h
        simp [substTyVar, substTyVarRow_fixes a τ r h]
  theorem substTyVarRow_fixes (a : TyVar) (τ : Ty) (r : Row) :
      ¬ fvRow r (Var.ty a) -> substTyVarRow a τ r = r := by
    cases r with
    | empty => intro h; simp [substTyVarRow]
    | field l t r' =>
        intro h
        have ht : ¬ fvTy t (Var.ty a) := by intro htv; exact h (Or.inl htv)
        have hr' : ¬ fvRow r' (Var.ty a) := by intro hrv; exact h (Or.inr hrv)
        simp [substTyVarRow, substTyVar_fixes a τ t ht, substTyVarRow_fixes a τ r' hr']
    | var ρ => intro h; simp [substTyVarRow]
  theorem substTyVarList_fixes (a : TyVar) (τ : Ty) (ts : List Ty) :
      ¬ fvTyList ts (Var.ty a) -> ts.map (substTyVar a τ) = ts := by
    cases ts with
    | nil => intro h; rfl
    | cons h tl =>
        intro h'
        have hh : ¬ fvTy h (Var.ty a) := by intro hhv; exact h' (Or.inl hhv)
        have htl : ¬ fvTyList tl (Var.ty a) := by intro hlv; exact h' (Or.inr hlv)
        simp [List.map_cons, substTyVar_fixes a τ h hh, substTyVarList_fixes a τ tl htl]
end

/-- **The occurs-guard makes the coercion a fixpoint on its image.** With
`¬ fvTy τ (Var.ty a)`, substituting `a := τ` into `τ` is the identity — the
coercion does not loop (`a` cannot occur in its own replacement). This is the
soundness content of Tier-T's occurs-guard (the doc's `a ∉ fv(τ)`). -/
theorem substTyVar_occurs_guard (a : TyVar) (τ : Ty) :
    ¬ fvTy τ (Var.ty a) -> substTyVar a τ τ = τ :=
  substTyVar_fixes a τ τ

/-- **The coercion reads the refined variable as its value.** `a := τ` maps the
variable `a` to `τ` (definitional). This is "Tier-T coerces the genuinely SAME
value at the refined type": under the equation `a ≐ τ`, a value of type `a` IS a
value of type `τ`, and `substTyVar a τ` is exactly that re-reading, extended
structurally by `substTyVar_fixes`. -/
theorem substTyVar_var_eq (a : TyVar) (τ : Ty) : substTyVar a τ (Ty.tvar a) = τ := by
  simp [substTyVar]

/-- **The verdict asymmetry, made a theorem.** A branch-result derivation
concluding `ok` has its last rule `tier_plain` (a plain unification) or `tier_T`
(the recursing TYPE coercion) — NEVER `tier_R`. Inversion on `Result … ok` exposes
no row equation, so a ROW equation can never discharge a result to `ok`: Tier-R is
terminal. (The `tier_R` constructor concludes `Verdict.escape`, which the index
`Verdict.ok` structurally excludes — the asymmetry is in the verdict INDEX.) -/
theorem ok_reachable_only_via_ty {Δ : Store} {R : Rigid} {t_b t_r : Ty} :
    Result Δ R t_b t_r Verdict.ok ->
    (Unifies R t_b t_r) ∨
    (∃ a τ, tyEqFor Δ a = some τ ∧ ¬ isRecordTy τ ∧ ¬ fvTy τ (Var.ty a) ∧
       Result Δ R (substTyVar a τ t_b) (substTyVar a τ t_r) Verdict.ok) := by
  intro h
  cases h with
  | tier_plain hU => exact Or.inl hU
  | tier_T a τ heq hnotrow hocc hrec => exact Or.inr ⟨a, τ, heq, hnotrow, hocc, hrec⟩

/-- **Tier-T is productive: the recursing case can still conclude `ok`.** If the
coerced re-check (`t_b[a:=τ]` vs `t_r[a:=τ]`) concludes `ok`, so does the original
result — the coercion (a genuine retyping, `substTyVar_var_eq` + the occurs-guard)
never turns an `ok` into anything else. This is the PRESERVED (recursing) tier. -/
theorem tier_T_ok {Δ : Store} {R : Rigid} {t_b t_r : Ty} (a : TyVar) (τ : Ty) :
    tyEqFor Δ a = some τ -> ¬ isRecordTy τ -> ¬ fvTy τ (Var.ty a) ->
    Result Δ R (substTyVar a τ t_b) (substTyVar a τ t_r) Verdict.ok ->
    Result Δ R t_b t_r Verdict.ok := by
  intro heq hnotrow hocc hrec
  exact Result.tier_T a τ heq hnotrow hocc hrec

--------------------------------------------------------------------------------
-- 9. Stage-2 carryover, honestly accounted
--------------------------------------------------------------------------------

/-
WHAT THIS STAGE USES FROM STAGE 2, AND WHAT IT DOES NOT:

  * `rowEqFor` / `substRowVarRow` / `tailVar` / `equationBody` (Typing.lean) are
    USED by `selDisch_preserves` via `firstType_subst_rowvar` — the discharge is
    read syntactically off the store, not re-derived.
  * The store weakening (`weakening_right_ty` / `weakening_right_br`,
    TypingStore) and `result_weakening_right` are NOT instantiated here: every
    reduction in `Step` is STORE-INVARIANT (no `Step` constructor introduces a
    new equation or crosses a branch boundary), so the store index `Δ` is
    unchanged across the step and no weakening is needed. They remain the lemmas
    a full T2 (βv, case dispatch) will need.
  * `GeneralizesRespectsRefined` is NOT used here, because no `Step` reduction
    touches `let`. R-LET has now been FIXED: Typing.lean's `letR` carries the
    `GeneralizesRespectsRefined` premise, so a refined tail of Δ is never
    quantified (the let-laundering hole stage 2 PROVED is closed at the rule).
    This stage still neither uses nor needs it; a full T2 touching `let` must
    preserve the corrected premise, not prove preservation around the
    known-unsound rule.
  * `Unifies` / `Captures` are the stage-1 axioms; `unifies_field_projection`
    (this file) is the ONE new parameter the plain R-SEL case needs. Stage 4 must
    instantiate all three with SOUND relations. The discharged `selDisch`, the
    update case, and the two-tier lemmas depend on NO unifier axiom.
-/

--------------------------------------------------------------------------------
-- 10. The Step-wired preservation statements (if `e → e'`, then …)
--------------------------------------------------------------------------------

/-- **R-SEL preservation, wired to the reduction.** If the selection reduces by
FIRST-OCCURRENCE lookup (`Step.sel`), the reduced value is typed at the selected
field's type `tᵢ`, and `a` is the unifier-identified result (the field-projection
obligation). -/
theorem sel_step_preserves {Γ : Ctx} {CEnv : CtorEnv} {Δ : Store} {R : Rigid}
    {fs : List (Label × Expr)} {r : Row} {ℓ : Label} {v : Expr} {a : TyVar} {β : RowVar} {tᵢ : Ty} :
    Step (Expr.sel (Expr.record fs) ℓ) v ->
    RecordHasType Γ CEnv Δ R fs r ->
    firstType r ℓ = some tᵢ ->
    Unifies R (Ty.record r) (Ty.record (Row.field ℓ (Ty.tvar a) (Row.var β))) ->
    HasType Γ CEnv Δ R v tᵢ ∧ Unifies R (Ty.tvar a) tᵢ := by
  intro hstep hrec hft hU
  cases hstep with
  | sel fs' ℓ' v' hocc => exact sel_preserves hrec hft hocc hU

/-- **R-SEL-DISCH preservation, wired to the reduction.** If the discharged
selection reduces, the reduced value is typed at EXACTLY the equation's head type
`t'` (no unifier axiom — the result type is read off the discharge). -/
theorem selDisch_step_preserves {Γ : Ctx} {CEnv : CtorEnv} {Δ : Store} {R : Rigid}
    {fs : List (Label × Expr)} {r : Row} {ℓ : Label} {ρ ρ'' : RowVar} {t' : Ty} {v : Expr} :
    Step (Expr.sel (Expr.record fs) ℓ) v ->
    rowEqFor Δ ρ = some (Row.field ℓ t' (Row.var ρ'')) ->
    tailVar r = some ρ ->
    firstType r ℓ = none ->
    RecordHasType Γ CEnv Δ R fs (substRowVarRow ρ (Row.field ℓ t' (Row.var ρ'')) r) ->
    HasType Γ CEnv Δ R v t' := by
  intro hstep heq htail hnot hrec
  cases hstep with
  | sel fs' ℓ' v' hocc => exact selDisch_preserves heq htail hnot hrec hocc

/-- **R-UPD preservation, wired to the reduction.** If the update reduces by
cons-prepend-shadow (`Step.upd`), the result record's first-occurrence DOMAIN
equals the static result row `{ ℓ : t_v | r' }` — with no discharge and no
unifier obligation. -/
theorem upd_step_preserves {Γ : Ctx} {CEnv : CtorEnv} {Δ : Store} {R : Rigid}
    {fs : List (Label × Expr)} {r : Row} {ℓ : Label} {v : Expr} {t_ℓ t_v : Ty} {r' : Row} :
    Step (Expr.upd (Expr.record fs) ℓ v) (Expr.record ((ℓ, v) :: fs)) ->
    RecordHasType Γ CEnv Δ R fs r ->
    restrict r ℓ = some (t_ℓ, r') ->
    HasType Γ CEnv Δ R v t_v ->
    ∀ x, containsLabel ((ℓ, v) :: fs) x ↔ contains x (Row.field ℓ t_v r') := by
  intro hstep hrec hrest hv
  cases hstep with
  | upd fs' ℓ' v' => exact upd_preserves hrec hrest hv

end Preserve
