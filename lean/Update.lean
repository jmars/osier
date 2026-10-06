/-
The UPDATE THEOREM (paper §7) — mechanized.

This file proves the positive row result of the paper: under a branch-local
refinement `ρ ≐ { ℓ : t | ρ' }`, record UPDATE `{ r | ℓ = v }` survives the
refinement because it is DOMAIN-PRESERVING — update is restrict-then-re-prepend
of the EXISTING first occurrence, so the result row's domain equals the
argument row's domain, which makes the branch equation *reflexive on domains*
and therefore dischargeable FOR FREE (well-typed at the abstract `ρ` with no
Tier-R discharge and no binding of `ρ`). The DUAL is stated and proved too:
INSERTION is the shape-changing operation (its domain is `{ℓ} ∪ dom(r)`, so a
fresh label strictly extends the domain) — and this is exactly why the two-tier
result rule exists and why insertion may never consult the store under
refinement (R-UPD-INS rejects it).

This file `import RowGadt` and reuses its syntax (§1), `contains` (§3),
`substTy`/`substRow`/`equationBody` (§2) and `H2b_domain_rule` (§8) — the
verbatim copies that previously lived here are GONE, so each definition exists
exactly once. Nothing is weakened or renamed.
-/

import RowGadt

--------------------------------------------------------------------------------
-- 1. Restrict, update, insert (the three record operations of §2.4 / §3.2)
--------------------------------------------------------------------------------

/-- `restrict r ℓ` removes the FIRST occurrence of `ℓ`, returning its type and
the remainder row; `none` when `ℓ` is absent. This is `restrictField`
(Type/Infer.elm:1124-1138) — the first-occurrence removal of R-UPD. -/
def restrict : Row -> Label -> Option (Ty × Row)
  | Row.field l t r, m =>
      if l = m then some (t, r) else
        match restrict r m with
        | none => none
        | some (t', r') => some (t', Row.field l t r')
  | Row.empty, _ => none
  | Row.var _, _ => none

/-- UPDATE: restrict-then-re-prepend of the EXISTING first occurrence — remove
the first `ℓ`, then prepend `ℓ : t`. `none` exactly when `ℓ` is absent (update
REQUIRES presence; it never extends). This is R-UPD's
`{ ℓ : θ'(t_v) | restrict(r, ℓ) }`. -/
def updateRow (r : Row) (ℓ : Label) (t : Ty) : Option Row :=
  (restrict r ℓ).map fun p => Row.field ℓ t p.2

/-- INSERTION: unconditional prepend (no presence requirement, no removal) —
the shape-changing dual of update. This is R-UPD-INS's `{ ℓ ← v }` /
`InsertionValue`, which prepends WITHOUT requiring presence. -/
def insertRow (r : Row) (ℓ : Label) (t : Ty) : Row :=
  Row.field ℓ t r

--------------------------------------------------------------------------------
-- 2. UPDATE — the positive row result (§7)
--------------------------------------------------------------------------------

/-- **Update requires the label present** (the measured fact: `{ rec | x = 5 }`
requires `x` present and never extends). `restrict` succeeds exactly when the
label is in the domain. -/
theorem restrict_succeeds_iff_contains (r : Row) (ℓ : Label) :
    (∃ t₀ r', restrict r ℓ = some (t₀, r')) ↔ contains ℓ r := by
  refine Row.rec (motive_1 := fun _ => True)
      (motive_2 := fun r => (∃ t₀ r', restrict r ℓ = some (t₀, r')) ↔ contains ℓ r)
      (fun _a => by trivial)
      (fun _a _ih => by trivial)
      (by simp [restrict, contains])
      (fun l t r _ihTy ihRow => by
        by_cases h : l = ℓ
        · simp [restrict, contains, h]
        · have hl' : ℓ ≠ l := fun h2 => h h2.symm
          simp [restrict, contains, h, hl']
          cases hrestrict : restrict r ℓ with
          | none =>
              change (∃ t₀ r', none = some (t₀, r')) ↔ contains ℓ r
              constructor
              · intro h
                rcases h with ⟨t₀, r', h⟩
                cases h
              · intro hc
                rcases ihRow.mpr hc with ⟨t₀, r', h⟩
                simp [hrestrict] at h
          | some p =>
              rcases p with ⟨t', r''⟩
              change (∃ t₀ r', some (t', Row.field l t r'') = some (t₀, r')) ↔ contains ℓ r
              constructor
              · intro _h
                exact ihRow.mp ⟨t', r'', hrestrict⟩
              · intro _hc
                exact ⟨t', Row.field l t r'', rfl⟩)
      (fun _a => by simp [restrict, contains])
      r

/-- **Restrict removes exactly the first occurrence, domain-wise.** If
`restrict r ℓ = some (_, r')`, then `r`'s domain is exactly `{ℓ} ∪ dom(r')` —
i.e. removing the first `ℓ` changes the domain by at most `ℓ` (and, because
duplicates are retained, it removes `ℓ` from the *first-occurrence* position
without changing membership of any other label). -/
theorem restrict_domain (r : Row) (ℓ : Label) :
    ∀ t₀ r', restrict r ℓ = some (t₀, r') → ∀ x, contains x r ↔ (x = ℓ ∨ contains x r') := by
  refine Row.rec (motive_1 := fun _ => True)
      (motive_2 := fun r => ∀ t₀ r', restrict r ℓ = some (t₀, r') → ∀ x, contains x r ↔ (x = ℓ ∨ contains x r'))
      (fun _a => by trivial)
      (fun _a _ih => by trivial)
      (by intro t₀ r' h; simp [restrict] at h)
      (fun l t r _ihTy ihRow => by
        intro t₀ r' h
        unfold restrict at h
        by_cases hl : l = ℓ
        · subst l
          simp at h
          rcases h with ⟨rfl, rfl⟩
          intro x
          simp [contains]
        · simp [hl] at h
          cases hrestrict : restrict r ℓ with
          | none => simp [hrestrict] at h
          | some p =>
              rcases p with ⟨t'', r''⟩
              simp [hrestrict] at h
              rcases h with ⟨rfl, rfl⟩
              intro x
              have ih' : contains x r ↔ (x = ℓ ∨ contains x r'') := ihRow t'' r'' hrestrict x
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
      (fun _a => by intro t₀ r' h; simp [restrict] at h)
      r

/-- **Update is restrict-then-re-prepend.** `updateRow` unfolds to re-prepending
`ℓ : t` onto the remainder of the first-occurrence removal. -/
theorem updateRow_eq (r : Row) (ℓ : Label) (t t₀ : Ty) (r' : Row)
    (h : restrict r ℓ = some (t₀, r')) :
    updateRow r ℓ t = some (Row.field ℓ t r') := by
  simp [updateRow, h]

/-- **UPDATE IS DOMAIN-PRESERVING** (the headline of §7). When the label is
present (`restrict r ℓ = some (t₀, r')`), the update result `{ ℓ : t | r' }`
has EXACTLY the same domain as the argument row `r` — including the
duplicate-label case (a shadowed second `ℓ` survives in `r'`, so the domain is
unchanged; re-prepending `ℓ` restores exactly the original domain). Update
therefore never extends the domain. -/
theorem update_domain_preserving (r : Row) (ℓ : Label) (t t₀ : Ty) (r' : Row)
    (h : restrict r ℓ = some (t₀, r')) :
    ∀ x, contains x (Row.field ℓ t r') ↔ contains x r := by
  intro x
  have hd := restrict_domain r ℓ t₀ r' h x
  simp [contains]
  exact hd.symm

/-- **The branch equation is reflexive on domains** (§7's
`dom({ℓ:t_v|ρ'}) = dom({ℓ:t|ρ'}) = dom(ρ)` under the equation). The update's
discharged result `{ ℓ : t_v | ρ' }` and the abstract row `ρ` (expanded through
its equation `ρ ≐ { ℓ : t | ρ' }`) have the same domain — the property that
makes the update dischargeable for free, because the row equation is consistent
BOTH ways (no domain change, so nothing needs to escape the branch). -/
theorem update_reflexive_domain (ℓ : Label) (t t_v : Ty) (ρ ρ' : RowVar) :
    ∀ x, contains x (Row.field ℓ t_v (Row.var ρ'))
         ↔ contains x (substRow ρ (equationBody ℓ t ρ') (Row.var ρ)) := by
  intro x
  simp [substRow, equationBody, contains]

/-- **Update is well-typed AT `ρ` without binding it** (§7, "no discharge needed
and no equation consumed"). The domain rule (the RESULT-side check of §2.7)
ACCEPTS the update: the body row is the concrete `{ ℓ : t_v | ρ' }` — which
mentions only the equation's TAIL `ρ'`, never the rigid head `ρ` — and its
domain equals the expected `ρ`'s domain under the equation. No Tier-R discharge
and no binding of `ρ` is needed. (This is `h2b_domain_accepts_rebuild` from
RowGadt.lean with the new-value type `t_v` as the rebuilt field's type.) -/
theorem update_accepted_at_rho (ℓ : Label) (t t_v : Ty) (ρ ρ' : RowVar) :
    H2b_domain_rule ρ (equationBody ℓ t ρ')
      (Ty.record (Row.field ℓ t_v (Row.var ρ')))
      (Ty.record (Row.var ρ)) := by
  simp [H2b_domain_rule]
  exact update_reflexive_domain ℓ t t_v ρ ρ'

--------------------------------------------------------------------------------
-- 3. INSERTION — the shape-changing dual (§2.4 R-UPD-INS, §7's boundary case)
--------------------------------------------------------------------------------

/-- **Insertion's domain is `{ℓ} ∪ dom(r)`.** Prepend adds exactly `ℓ` to the
domain (and a duplicate `ℓ` is absorbed by the set). -/
theorem insertion_domain (r : Row) (ℓ : Label) (t : Ty) :
    ∀ x, contains x (insertRow r ℓ t) ↔ (x = ℓ ∨ contains x r) := by
  intro x
  simp [insertRow, contains]

/-- **The exactness boundary: insertion is domain-preserving IFF the label is
already present.** Prepending `ℓ : t` changes the domain exactly when `ℓ` was
not already there — so insertion preserves the domain only in the shadow case,
and strictly EXTENDS it for a fresh label. This is the precise dual of update's
unconditional domain preservation. (Mirrors `h2b_domain_exactness` of
RowGadt.lean, applied to `insertRow`.) -/
theorem insertion_domain_exactness (r : Row) (ℓ : Label) (t : Ty) :
    (∀ x, contains x (insertRow r ℓ t) ↔ contains x r) ↔ contains ℓ r := by
  constructor
  · intro h
    have hℓ : contains ℓ (insertRow r ℓ t) := by simp [insertRow, contains]
    exact (h ℓ).mp hℓ
  · intro hℓ x
    constructor
    · intro hx
      simp [insertRow, contains] at hx
      rcases hx with hx | hx
      · rw [hx]; exact hℓ
      · exact hx
    · intro hx
      exact Or.inr hx

/-- **A fresh label makes insertion strictly extend the domain** — the witness
that insertion is NOT domain-preserving in general, unlike update. -/
theorem insertion_fresh_extends (r : Row) (ℓ : Label) (t : Ty)
    (h : ¬ contains ℓ r) :
    ¬ (∀ x, contains x (insertRow r ℓ t) ↔ contains x r) := by
  intro hdom
  have hℓ : contains ℓ (insertRow r ℓ t) := by simp [insertRow, contains]
  exact h ((hdom ℓ).mp hℓ)

/-- **Insertion under refinement is REJECTED — the dual of
`update_accepted_at_rho`.** Inserting a FRESH label `k ≠ ℓ` into the abstract
row `ρ` (body `{ k : s | ρ }`, no discharge — insertion never consults the
store) produces a domain `{k}` that differs from the expected `ρ`'s domain
`{ℓ}` (under `ρ ≐ { ℓ : t | ρ' }`), so the domain rule rejects it. This is
exactly why the two-tier result rule exists: a domain-changing operation may
not discharge at a result, and the store is never consulted to make it pass. -/
theorem insertion_rejected_under_refinement (k ℓ : Label) (hk : k ≠ ℓ) (s t : Ty) (ρ ρ' : RowVar) :
    ¬ H2b_domain_rule ρ (equationBody ℓ t ρ')
      (Ty.record (insertRow (Row.var ρ) k s))
      (Ty.record (Row.var ρ)) := by
  intro h
  simp [H2b_domain_rule] at h
  have hk_body : contains k (insertRow (Row.var ρ) k s) := by simp [insertRow, contains]
  have hk_expected : ¬ contains k (substRow ρ (equationBody ℓ t ρ') (Row.var ρ)) := by
    simp [substRow, equationBody, contains]
    exact hk
  exact hk_expected ((h k).mp hk_body)

/-- **The coarse boundary, stated honestly.** A SHADOWING insertion (same label
`ℓ`) is domain-preserving, so the domain rule ACCEPTS it — it cannot tell a
shadowing insertion from an update by domain alone. The implementation's
R-UPD-INS is therefore STRICTER than the domain rule: it rejects ALL insertion
under refinement (any label, on a refined tail), not just the domain-changing
ones. This is the same "exact for fresh labels, coarse for duplicates" boundary
already proved for the escape rule in RowGadt.lean (`h2b_domain_exactness`). -/
theorem insertion_shadow_domain_unchanged (ℓ : Label) (s t : Ty) (ρ ρ' : RowVar) :
    H2b_domain_rule ρ (equationBody ℓ t ρ')
      (Ty.record (insertRow (Row.var ρ) ℓ s))
      (Ty.record (Row.var ρ)) := by
  simp [H2b_domain_rule, insertRow, substRow, equationBody, contains]
