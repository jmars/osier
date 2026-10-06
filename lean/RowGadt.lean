/-
λρG — the declarative calculus of branch-local row refinement.
Mechanized fragment: H1 (rewrite/equation commutation) and H2 (escape).

This file mechanizes the two "hard lemmas" of the row-GADT calculus
(docs/research/row-gadt-calculus.md §5.3 and §5.4) as STANDALONE statements
about the row rewriting relation, the equation store, and the row domain.
T1 (progress) and T2 (preservation) are deliberately OUT OF SCOPE — they
depend on the whole calculus (typing judgment + operational semantics) and
are not attempted here.

STATUS / HONESTY. Every `theorem` in this file is closed with the local `lean`
binary (no `sorry`). Statements that are *obligations on the whole checker*
(and therefore need the typing judgment / let-generalization / unification
machinery) are stated as `def`s (propositions) and marked [STATEMENT, NOT
PROVED]. Nothing is weakened to make it close: where the spec over-claims,
the finding is stated as a theorem with a counterexample.

H2 WAS REVISED mid-task (steering rowgadt-12, ids 351/352): the pre-fix
framing "escapeViaTail checks only the direct shape and a transitively-aliased
tail is not caught" is WRONG. An adversarial hunt (unit rowgadt-10) found two
real unsound accepts — LET-LAUNDERING (generalizeLet/generalizeBinds
quantifying the refined tail, so a use re-instantiates a fresh var with no
link to the tail) and WILDCARD SIBLING LEAK (a shared flex case-result var
aliasing tail := head). Both are fixed (generalizationRigid; symmetric
escapeViaTail) and pinned by fixtures. H2-b is therefore mechanized here as a
DOMAIN rule — a branch result is legitimate iff the body row's domain equals
the expected row's domain under the branch equations — plus the two
counterexamples as the test of the statement's strength.
-/

--------------------------------------------------------------------------------
-- 1. Syntax
--------------------------------------------------------------------------------

/-- A type variable (kind `Ty`). Row variables are a SEPARATE sort, which makes
the WF-VAR-TAIL well-formedness condition (§1.3) true by construction: a row
variable can only ever appear as a row tail, never as a type. -/
structure TyVar where
  id : Nat
  deriving DecidableEq, Inhabited

structure RowVar where
  id : Nat
  deriving DecidableEq, Inhabited

/-- Labels are strings (the surface has no type-level labels, §1.3). -/
abbrev Label := String

mutual
  /-- Types. Minimal but faithful for H1/H2: type variables and records
  (`{ r }`). Functions / named types / tuples are orthogonal to the two lemmas
  and omitted. -/
  inductive Ty where
    | tvar : TyVar -> Ty
    | record : Row -> Ty

  /-- Rows: empty tail, a field, or a row-tail variable. Duplicate labels are
  legal and retained (scoped labels, §1.3); the FIRST occurrence of a label is
  the one selection/restriction act on. -/
  inductive Row where
    | empty : Row
    | field : Label -> Ty -> Row -> Row
    | var   : RowVar -> Row
end

--------------------------------------------------------------------------------
-- 2. Scoped-label substitution
--------------------------------------------------------------------------------

mutual
  /-- Type-level substitution of a row variable `v` by a row `s`, homomorphic
  over types (only the record arm can mention a row variable). -/
  def substTy (v : RowVar) (s : Row) : Ty -> Ty
    | Ty.tvar a => Ty.tvar a
    | Ty.record r => Ty.record (substRow v s r)

  /-- Row substitution: `v := s` replaces the tail variable `v` by the row `s`
  (the standard scoped-label substitution — `s`'s fields are prepended, `s`'s
  tail replaces `v`). -/
  def substRow (v : RowVar) (s : Row) : Row -> Row
    | Row.empty => Row.empty
    | Row.field l t r => Row.field l (substTy v s t) (substRow v s r)
    | Row.var ρ => if ρ = v then s else Row.var ρ
end

/-- The body of a row equation `ρ ≐ { ℓ : t | ρ' }`: the head field `ℓ : t`
prepended to the tail variable `ρ'`. -/
def equationBody (ℓ : Label) (t : Ty) (ρ' : RowVar) : Row :=
  Row.field ℓ t (Row.var ρ')

--------------------------------------------------------------------------------
-- 3. The row domain (what the escape shrinks)
--------------------------------------------------------------------------------

/-- `contains ℓ r` — does label `ℓ` occur anywhere in the row `r` (any
occurrence)? This is membership in `dom₀(r)`, the first-occurrence label SET
(§1.3): with scoped labels a duplicate does not add a label, so "occurs
anywhere" is exactly "is in the domain". -/
def contains : Label -> Row -> Prop
  | _, Row.empty => False
  | m, Row.field l _ r => m = l ∨ contains m r
  | _, Row.var _ => False

--------------------------------------------------------------------------------
-- 4. The rewrite (first-occurrence search) and the head-only discharge
--------------------------------------------------------------------------------

/-- Outcome of a first-occurrence search (§5.2): the exposed field, the open
tail variable reached, or a closed absent. -/
inductive Trace where
  | found : Ty -> Row -> Trace
  | openTail : RowVar -> Trace
  | closedAbsent : Trace

/-- The structural rewrite: expose the FIRST occurrence of `m` (§5.2 row-head
/ row-swap). Reaching the empty tail or a bare tail variable does not expose
anything — whether that is then an instantiation (flex), a rigid failure, or a
discharge of a stored equation is a separate, stateful concern. -/
def find : Row -> Label -> Trace
  | Row.field l t r, m => if l = m then Trace.found t r else find r m
  | Row.empty, _ => Trace.closedAbsent
  | Row.var ρ, _ => Trace.openTail ρ

/-- The implementation's head-only discharge (`dischargeRow`,
Type/Unify.elm:166-188): read the equation body's HEAD field only; never
recurse into the body's tail. -/
def dischargeHead (m : Label) : Row -> Option (Ty × Row)
  | Row.field l t r => if l = m then some (t, r) else none
  | Row.empty => none
  | Row.var _ => none

--------------------------------------------------------------------------------
-- 5. H1 — rewrite/equation commutation (§5.3)
--------------------------------------------------------------------------------

/-- The commutation map: applying the scoped-label substitution `ρ := s` to a
first-occurrence search. A field found BEFORE `ρ` has the substitution passed
through; reaching `ρ` continues the search inside the substituted body `s`
(whose head is exactly what the discharge reads). -/
def mapSubst (ρ : RowVar) (s : Row) (m : Label) : Trace -> Trace
  | Trace.found t r => Trace.found (substTy ρ s t) (substRow ρ s r)
  | Trace.openTail ρ' => if ρ' = ρ then find s m else Trace.openTail ρ'
  | Trace.closedAbsent => Trace.closedAbsent

/-- **H1-a** (the true, unconditional form). The first-occurrence search
commutes with scoped-label substitution: `find (r[ρ := s]) m` equals `find r m`
with the substitution mapped through, and at the position of `ρ` the search
continues into the substituted body `s`. This is the load-bearing content of
§5.3's "discharge-then-rewrite = rewrite-then-discharge". -/
theorem h1_find_commutes (r : Row) (ρ : RowVar) (s : Row) (m : Label) :
    find (substRow ρ s r) m = mapSubst ρ s m (find r m) := by
  refine Row.rec (motive_1 := fun _ => True)
      (motive_2 := fun r => find (substRow ρ s r) m = mapSubst ρ s m (find r m))
      (fun a => by trivial)
      (fun a ih => by trivial)
      (by simp [find, substRow, mapSubst])
      (fun l t r' ihTy ihRow => by
        by_cases h : l = m
        · simp [find, substRow, mapSubst, h]
        · simp [find, substRow, mapSubst, h, ihRow])
      (fun a => by
        by_cases h : a = ρ
        · simp [find, substRow, mapSubst, h]
        · simp [find, substRow, mapSubst, h])
      r

/-- **H1-b** (the duplicate-label case, the novel half). A duplicate `ℓ`
occurring BEFORE the equation's position shadows the equation's `ℓ : t`: both
routes — head-exposure of `r` and eq-swap on `r[ρ := …]` — expose the EARLIER
occurrence's type `t₀`, never the equation's `t`. -/
theorem h1_duplicate_shadow (ℓ : Label) (t t₀ : Ty) (r₀ : Row) (ρ ρ' : RowVar) :
    find (substRow ρ (equationBody ℓ t ρ') (Row.field ℓ t₀ r₀)) ℓ
      = Trace.found (substTy ρ (equationBody ℓ t ρ') t₀)
                    (substRow ρ (equationBody ℓ t ρ') r₀) := by
  simp [find, substRow]

/-- **H1-c** (no shadow ⇒ the equation's type is exposed). If `r` reaches the
equation's head variable `ρ` without finding `ℓ`, the substituted-in `ℓ : t`
IS the first occurrence and the exposed type is the equation's stored type
`t`. Together with `h1_duplicate_shadow` this pins the selection to exactly the
equation's occurrence when it is unshadowed. -/
theorem h1_no_shadow (ℓ : Label) (t : Ty) (r : Row) (ρ ρ' : RowVar)
    (hreaches : find r ℓ = Trace.openTail ρ) :
    find (substRow ρ (equationBody ℓ t ρ') r) ℓ = Trace.found t (Row.var ρ') := by
  rw [h1_find_commutes r ρ (equationBody ℓ t ρ') ℓ, hreaches]
  simp [mapSubst, equationBody, find]

/-- **H1, the honest refinement of the spec.** §5.3's H1-a reads "for every
label `m`". That biconditional is true only in the rigid-tail regime. With a
FLEX equation tail `ρ'`, the full (substituted) search `find` recurses INTO the
equation's tail, while the implementation's head-only `dischargeHead` stops at
the head. This is the precise sense in which the implementation is the *weak*
form (§5.3: "the implementation needs only the weak form"). -/
theorem h1_head_only_vs_full (ℓ m : Label) (t : Ty) (ρ' : RowVar) (hm : m ≠ ℓ) :
    find (Row.field ℓ t (Row.var ρ')) m = Trace.openTail ρ'
      ∧ dischargeHead m (Row.field ℓ t (Row.var ρ')) = none := by
  have hℓm : ℓ ≠ m := fun h => hm h.symm
  constructor
  · simp [find, hℓm]
  · simp [dischargeHead, hℓm]

/-- The head-only discharge AGREES with the full search exactly when the head
label matches: both expose the equation's stored type and remainder. -/
theorem h1_discharge_head_agrees (ℓ : Label) (t : Ty) (ρ' : RowVar) :
    dischargeHead ℓ (equationBody ℓ t ρ') = some (t, Row.var ρ')
      ∧ find (equationBody ℓ t ρ') ℓ = Trace.found t (Row.var ρ') := by
  constructor <;> simp [dischargeHead, find, equationBody]

--------------------------------------------------------------------------------
-- 6. The equation store and H2-a (store truncation, §5.4)
--------------------------------------------------------------------------------

/-- A row equation: the (rigid) head variable and its body row (§2.1). -/
structure RowEq where
  head : RowVar
  body : Row

/-- The equation store: a most-recent-first list of equations (§2.1). -/
abbrev Store := List RowEq

/-- The tail variable of a row, if any. -/
def tailVar : Row -> Option RowVar
  | Row.empty => none
  | Row.field _ _ r => tailVar r
  | Row.var ρ => some ρ

/-- The tail-pair set of a store (§2.1): for each row equation, its
`(head, tail)` pair — the implementation's `refinedTails`. -/
def refinedTails (Δ : Store) : List (RowVar × RowVar) :=
  Δ.filterMap fun e =>
    match tailVar e.body with
    | some tl => some (e.head, tl)
    | none => none

/-- A row equation `ρ ≐ { ℓ : t | ρ' }` contributes exactly the pair `(ρ, ρ')`
to the tail-pair set. -/
theorem refinedTails_of_row_eq (ρ : RowVar) (ℓ : Label) (t : Ty) (ρ' : RowVar) :
    refinedTails [⟨ρ, equationBody ℓ t ρ'⟩] = [(ρ, ρ')] := by
  simp [refinedTails, tailVar, equationBody]

/-- **H2-a** (store truncation). A branch pushes its captured equations on top
of the snapshot and truncates on exit. The pushed prefix is dropped wholesale:
nothing pushed inside the branch survives. This is the general list fact behind
`dropEqsFrom` (Type/Unify.elm:96-101). -/
theorem h2a_truncation (snapshot pushed : List α) :
    (pushed ++ snapshot).drop pushed.length = snapshot := by
  exact List.drop_left (l₁ := pushed) (l₂ := snapshot)

/-- The faithful statement: the store at branch exit equals the store at branch
entry (the snapshot), no matter what equations the branch captured. -/
theorem h2a_no_survival (entry captured : Store) :
    (captured ++ entry).drop captured.length = entry :=
  h2a_truncation entry captured

/-- `a` is a suffix of `b`. -/
def IsSuffix (suffix list : List α) : Prop := ∃ pref, pref ++ suffix = list

/-- The snapshot is a suffix of the branch store (it is the entry prefix that
survives the truncation). -/
theorem h2a_snapshot_is_suffix (entry pushed : List α) :
    IsSuffix entry (pushed ++ entry) :=
  ⟨pushed, rfl⟩

/-- Nesting safety (§2.6): an inner branch's entry store is itself a suffix of
the outer branch store, so truncating the outer also discards the inner's
equations. -/
theorem h2a_inner_snapshot_suffix (entry innerPushed outerPushed : List α) :
    IsSuffix entry (outerPushed ++ innerPushed ++ entry) :=
  ⟨outerPushed ++ innerPushed, by simp [List.append_assoc]⟩

--------------------------------------------------------------------------------
-- 7. Aliasing and occurrence (the mechanism of H2-b)
--------------------------------------------------------------------------------

mutual
  /-- A row variable occurs in a type (through a record's row). -/
  def occursInTy : RowVar -> Ty -> Prop
    | _, Ty.tvar _ => False
    | ρ, Ty.record r => occursInRow ρ r

  /-- A row variable occurs in a row (as the tail, or in a field type). -/
  def occursInRow : RowVar -> Row -> Prop
    | _, Row.empty => False
    | ρ, Row.field _ t r => occursInTy ρ t ∨ occursInRow ρ r
    | ρ, Row.var ρ' => ρ = ρ'
end

mutual
  /-- Aliasing substitution: each row variable is replaced by its alias row
  (the image of `θ`). This is one step of zonk. -/
  def substAliasTy (θ : RowVar -> Row) : Ty -> Ty
    | Ty.tvar a => Ty.tvar a
    | Ty.record r => Ty.record (substAliasRow θ r)

  def substAliasRow (θ : RowVar -> Row) : Row -> Row
    | Row.empty => Row.empty
    | Row.field l t r => Row.field l (substAliasTy θ t) (substAliasRow θ r)
    | Row.var ρ => θ ρ
end

mutual
  /-- Substituting by the identity alias is the identity (needed for the
  rigid-preserves-occurs lemma: a non-generalizable tail is left in place). -/
  theorem substAliasTy_id (t : Ty) : substAliasTy (fun v => Row.var v) t = t :=
    match t with
    | Ty.tvar a => rfl
    | Ty.record r => by simp [substAliasTy, substAliasRow_id r]
  theorem substAliasRow_id (r : Row) : substAliasRow (fun v => Row.var v) r = r :=
    match r with
    | Row.empty => rfl
    | Row.var ρ => rfl
    | Row.field l t r' => by simp [substAliasRow, substAliasTy_id t, substAliasRow_id r']
end

/- NOTE: the reflexive-transitive closure of the one-step alias relation is NOT
modeled here: the adversarial hunt (rowgadt-10) showed the two real escape
holes were let-generalization (a fresh var, not an alias in the substitution)
and the single-orientation occurs check — NOT a transitive alias chain. The
one-step flex-alias `θ ρ' = var ρ` (the legal flex-alias) is what
`h2b_alias_identifies` and `h2b_direct_collapses` reason about. -/

mutual
  /-- Occurrence is monotone under aliasing substitution: if `ρ'` occurs in `t`
  and `ρ` occurs in the alias `θ ρ'`, then `ρ` occurs in the substituted type.
  (This is the mechanism by which a flex tail aliasing a rigid head "moves" the
  head into the body's type.) -/
  theorem occursInTy_mono (θ : RowVar -> Row) (ρ ρ' : RowVar) (t : Ty)
      (hocc : occursInTy ρ' t) (halias : occursInRow ρ (θ ρ')) :
      occursInTy ρ (substAliasTy θ t) :=
    match t with
    | Ty.tvar a => nomatch hocc
    | Ty.record r => by
        simp [substAliasTy, occursInTy]
        exact occursInRow_mono θ ρ ρ' r hocc halias

  theorem occursInRow_mono (θ : RowVar -> Row) (ρ ρ' : RowVar) (r : Row)
      (hocc : occursInRow ρ' r) (halias : occursInRow ρ (θ ρ')) :
      occursInRow ρ (substAliasRow θ r) :=
    match r with
    | Row.empty => nomatch hocc
    | Row.var ρ'' => by
        simp only [substAliasRow, occursInRow] at hocc ⊢
        subst ρ''
        exact halias
    | Row.field l t r' => by
        simp only [substAliasRow, occursInRow] at hocc ⊢
        rcases hocc with hty | hrw
        · left; exact occursInTy_mono θ ρ ρ' t hty halias
        · right; exact occursInRow_mono θ ρ ρ' r' hrw halias
end

mutual
  /-- No-introduction: if no alias image `θ v` contains `ρ`, then `ρ` does not
  occur in the substituted type/row. (The dual of monotonicity: substitution
  cannot manufacture an occurrence that no alias image provides.) -/
  theorem occursInTy_not_intro (θ : RowVar -> Row) (ρ : RowVar) (t : Ty)
      (hθ : ∀ v, ¬ occursInRow ρ (θ v)) :
      ¬ occursInTy ρ (substAliasTy θ t) :=
    match t with
    | Ty.tvar a => by simp [substAliasTy, occursInTy]
    | Ty.record r => by
        simp [substAliasTy, occursInTy]
        exact occursInRow_not_intro θ ρ r hθ

  theorem occursInRow_not_intro (θ : RowVar -> Row) (ρ : RowVar) (r : Row)
      (hθ : ∀ v, ¬ occursInRow ρ (θ v)) :
      ¬ occursInRow ρ (substAliasRow θ r) :=
    match r with
    | Row.empty => by simp [substAliasRow, occursInRow]
    | Row.var ρ' => by
        simp [substAliasRow]
        exact hθ ρ'
    | Row.field l t r' => by
        simp [substAliasRow, occursInRow]
        constructor
        · exact occursInTy_not_intro θ ρ t hθ
        · exact occursInRow_not_intro θ ρ r' hθ
end

/-- Occurrence is stable under substitution that fixes `ρ` (the head is rigid —
never itself substituted). -/
theorem occursInTy_stable (θ : RowVar -> Row) (ρ : RowVar) (t : Ty)
    (hθ : θ ρ = Row.var ρ) (hocc : occursInTy ρ t) :
    occursInTy ρ (substAliasTy θ t) :=
  occursInTy_mono θ ρ ρ t hocc (by simp [occursInRow, hθ])

--------------------------------------------------------------------------------
-- 8. H2-b (escape), as a DOMAIN rule (§5.4, revised per steering)
--------------------------------------------------------------------------------

/-- **H2-b (proper sub-domain).** The head row `{ ℓ : t | ρ' }` contains `ℓ`;
the tail `ρ'` does not. So the tail's domain is a PROPER sub-domain of the
head's — returning the tail where the head is expected shrinks the domain by
`ℓ`. This is the domain form of "the tail is a proper sub-row of the head". -/
theorem h2b_proper_subdomain (ℓ : Label) (t : Ty) (ρ' : RowVar) :
    contains ℓ (equationBody ℓ t ρ') ∧ ¬ contains ℓ (Row.var ρ') := by
  constructor
  · simp [contains, equationBody]
  · simp [contains]

/-- **The exactness boundary (steering id 352, point 4).** Prepending a field
`ℓ : t` to a row `r` changes the domain EXACTLY when `ℓ` was not already
present: `dom₀(ℓ : t | r) = dom₀(r)` iff `ℓ ∈ dom₀(r)`. So the domain rule
distinguishes a head from its tail exactly for FRESH labels, and is COARSE for
duplicate labels — the rule cannot tell a head from a tail by domain alone when
the equation's label was already in the tail. (This is the cited boundary with
CORELINKS's distinct-label rows; it is a real limit of a domain-based H2, not a
failure.) -/
theorem h2b_domain_exactness (ℓ : Label) (t : Ty) (r : Row) :
    (∀ x, contains x (Row.field ℓ t r) ↔ contains x r) ↔ contains ℓ r := by
  constructor
  · intro h
    exact (h ℓ).mp (by simp [contains])
  · intro hℓ x
    constructor
    · intro hx
      simp [contains] at hx
      rcases hx with hx | hx
      · rw [hx]; exact hℓ
      · exact hx
    · intro hx
      exact Or.inr hx

/-- **H2-b (the escape is a domain shrink).** Under the equation
`ρ ≐ { ℓ : t | ρ' }`, the expected row mentions the head `ρ` (domain has `ℓ`)
while the body row mentions only the tail `ρ'` (domain lacks `ℓ`): the domains
differ, so the branch result is illegitimate. The converse orientation (head in
body, tail expected) is symmetric — a domain GROWTH, equally an escape. -/
theorem h2b_domain_shrink (ℓ : Label) (t : Ty) (_ρ ρ' : RowVar) :
    ¬ (∀ x, contains x (Row.var ρ') ↔ contains x (equationBody ℓ t ρ')) := by
  intro h
  -- h says tail-domain = head-domain; but ℓ is in the head and not the tail.
  have hℓ_in_head : contains ℓ (equationBody ℓ t ρ') := by simp [contains, equationBody]
  have hℓ_not_tail : ¬ contains ℓ (Row.var ρ') := by simp [contains]
  exact hℓ_not_tail ((h ℓ).mpr hℓ_in_head)

/-- **H2-b — the domain rule (row-level content).** A branch result is
legitimate iff the body row's domain equals the expected row's domain UNDER the
branch equation `ρ ≐ s` — here "under" means the expected row's tail `ρ` is
expanded through the equation body `s` (the scoped-label substitution, which is
exactly what the discharge does). This is the target the in-flight domain-based
fix implements (steering id 352); the full "legitimate" predicate over the
typing judgment is out of scope, but its row-level content is stated and proved
below. -/
def H2b_domain_rule (ρ : RowVar) (s : Row) (t_b t_r : Ty) : Prop :=
  match t_b, t_r with
  | Ty.record r_b, Ty.record r_r => ∀ x, contains x r_b ↔ contains x (substRow ρ s r_r)
  | _, _ => False

/-- **The domain rule ACCEPTS the full-row rebuild** (the legitimate case the
syntactic occurs check wrongly rejects): the body returns the full row
`{ ℓ : x | ρ' }` (head field + tail) while the expected is the head `ρ`; under
the equation `ρ ≐ { ℓ : t | ρ' }` the expected domain is `{ℓ}`, which equals
the body's domain — so the domain rule accepts. (Note the field type `x` may
differ from the equation's `t`; the domain rule is about labels, not types.) -/
theorem h2b_domain_accepts_rebuild (ℓ : Label) (t x : Ty) (ρ ρ' : RowVar) :
    H2b_domain_rule ρ (equationBody ℓ t ρ')
      (Ty.record (Row.field ℓ x (Row.var ρ')))
      (Ty.record (Row.var ρ)) := by
  intro y
  simp [substRow, contains, equationBody]

/-- **The domain rule REJECTS the tail-return** (the escape): the body returns
only the tail `ρ'` (domain lacks `ℓ`) while the expected is the head `ρ` (domain
has `ℓ` under the equation) — a domain shrink. -/
theorem h2b_domain_rejects_tail (ℓ : Label) (t : Ty) (ρ ρ' : RowVar) :
    ¬ H2b_domain_rule ρ (equationBody ℓ t ρ')
      (Ty.record (Row.var ρ'))
      (Ty.record (Row.var ρ)) := by
  intro h
  have hℓ_expanded : contains ℓ (substRow ρ (equationBody ℓ t ρ') (Row.var ρ)) := by
    simp [substRow, contains, equationBody]
  have hℓ : contains ℓ (Row.var ρ') ↔ contains ℓ (substRow ρ (equationBody ℓ t ρ') (Row.var ρ)) :=
    h ℓ
  have hℓ_not_tail : ¬ contains ℓ (Row.var ρ') := by simp [contains]
  exact hℓ_not_tail (hℓ.mpr hℓ_expanded)

--------------------------------------------------------------------------------
-- 9. H2-b, the two counterexamples (the test of the statement's strength)
--------------------------------------------------------------------------------

/-- The implementation's check, post-fix (Type/Infer.elm:1682-1700): a refined
`(head, tail)` pair with the head occurring in one of (result, body) and the
tail in the other, in EITHER orientation (the fix made it symmetric). -/
def escapesDirect (refinedTails : List (RowVar × RowVar)) (t_b t_r : Ty) : Prop :=
  ∃ hd tl, (hd, tl) ∈ refinedTails ∧
    ((occursInTy hd t_r ∧ occursInTy tl t_b) ∨ (occursInTy hd t_b ∧ occursInTy tl t_r))

/-- **Soundness of the symmetric check.** When it fires on `(ρ, ρ')` in EITHER
orientation and the tail `ρ'` aliases the head `ρ` (the flex-alias the check
exists to prevent), the head then occurs in BOTH the (substituted) body type
and the result type: the tail/head identification is a real one, not a false
positive. (`θ ρ = var ρ` records the head is rigid.) -/
theorem h2b_direct_collapses (θ : RowVar -> Row) (ρ ρ' : RowVar) (t_b t_r : Ty)
    (hθtail : θ ρ' = Row.var ρ) (hθhead : θ ρ = Row.var ρ)
    (hdir : (occursInTy ρ t_r ∧ occursInTy ρ' t_b) ∨ (occursInTy ρ t_b ∧ occursInTy ρ' t_r)) :
    occursInTy ρ (substAliasTy θ t_b) ∧ occursInTy ρ (substAliasTy θ t_r) := by
  rcases hdir with h | h
  · constructor
    · exact occursInTy_mono θ ρ ρ' t_b h.2 (by simp [occursInRow, hθtail])
    · exact occursInTy_stable θ ρ t_r hθhead h.1
  · constructor
    · exact occursInTy_stable θ ρ t_b hθhead h.1
    · exact occursInTy_mono θ ρ ρ' t_r h.2 (by simp [occursInRow, hθtail])

/-- **The alias identifies head and tail.** If `θ` aliases the tail `ρ'` to the
head `ρ`, then applying `θ` to the equation body `{ ℓ : t | ρ' }` yields a row
whose tail is `ρ` itself: the head occurs in its own (aliased) body — the
cyclic equation the alias silently asserts. -/
theorem h2b_alias_identifies (ℓ : Label) (t : Ty) (ρ ρ' : RowVar) (θ : RowVar -> Row)
    (hθ : θ ρ' = Row.var ρ) :
    occursInRow ρ (substAliasRow θ (equationBody ℓ t ρ')) := by
  simp [equationBody, substAliasRow, occursInRow, hθ]

--------------------------------------------------------------------------------
-- 9a. The let-laundering counterexample (steering id 351, point 2a)
--------------------------------------------------------------------------------

/-- Model of let-generalization restricted to the one variable that matters:
if the refined tail `ρ'` is GENERALIZABLE, a `let` quantifies it away by
substituting a FRESH variable `fresh` (the implementation's
`generalizeLet`/`generalizeBinds`; the pre-fix behavior). -/
def generalizeTy (ρ' fresh : RowVar) : Ty -> Ty :=
  substAliasTy (fun v => if v = ρ' then Row.var fresh else Row.var v)

/-- **The laundering severs the occurs-link.** If the tail `ρ'` is generalizable
and generalized to a FRESH variable (`fresh ≠ ρ'`), the body's type no longer
mentions `ρ'`. The escape check (which looks for the tail `ρ'` in the body —
`occursInTy ρ' (zonk t_b)`) therefore cannot see the escape: the link between
the returned value and the refined tail is severed, exactly as the
let-laundering counterexample (`let ys = rest in ys`) exploits. -/
theorem h2b_let_severs_occurs (ρ' fresh : RowVar) (hne : fresh ≠ ρ') (t : Ty) :
    ¬ occursInTy ρ' (generalizeTy ρ' fresh t) := by
  let θ : RowVar -> Row := fun v => if v = ρ' then Row.var fresh else Row.var v
  show ¬ occursInTy ρ' (substAliasTy θ t)
  apply occursInTy_not_intro θ ρ' t
  intro v
  by_cases h : v = ρ'
  · subst v
    simp [θ, occursInRow]
    intro hv
    exact hne hv.symm
  · simp [θ, occursInRow, h]
    intro hv
    exact h hv.symm

/-- **The fix (generalizationRigid).** If the refined tail `ρ'` is instead made
NON-generalizable (rigid — the fix at Type/Infer.elm:1249 adds refined tails'
heads+tails to the let-generalization rigid set), generalizing leaves `ρ'` in
place, and the occurs-link is preserved: the escape check can still see the
tail in the body. -/
theorem h2b_rigid_preserves_occurs (ρ' : RowVar) (t : Ty) (hocc : occursInTy ρ' t) :
    occursInTy ρ' (substAliasTy (fun v => Row.var v) t) := by
  rw [substAliasTy_id t]
  exact hocc

/-- **The strength finding (steering id 351, point 2a).** A statement of H2 that
constrains ONLY the branch-result unification (i.e. `escapesDirect`) is TOO
WEAK to rule out let-laundering: laundering happens BEFORE the result unify, in
the let-binding form. The laundering needs a separate obligation — a refined
tail must never be quantified by a let (generalizationRigid) — which is about
the whole binding form, not the result unify. This definition states that
obligation; it is [STATEMENT, NOT PROVED] at this level because "never
quantified" is a property of the let-generalization rule, not of the row
rewrite relation or the store. (The obligation is PROVED in
`lean/RowGadtEscape.lean` as the theorem `H2b_no_quantify_refined_tail`.) -/
def H2b_no_quantify_refined_tail_stmt (R : RowVar -> Prop) (refinedTails : List (RowVar × RowVar)) : Prop :=
  ∀ hd tl, (hd, tl) ∈ refinedTails -> R hd ∧ R tl
  -- i.e. every refined head+tail is rigid (non-generalizable). The
  -- implementation's generalizationRigid = scopeFreeVars ++ refinedTargets
  -- ++ refinedTails heads+tails is exactly this set R.

--------------------------------------------------------------------------------
-- 9b. The wildcard sibling leak (steering id 351, point 2b)
--------------------------------------------------------------------------------

/-- The wildcard leak is the OTHER orientation of the alias: the refining
branch returns the tail (`ρ'` in the body) into a SHARED flex case-result var,
a sibling wildcard/head branch returns the full row (`ρ`), and unifying the two
aliases `ρ' := ρ` (a legal flex-alias), zonking the tail away before any
clause-level check can see it. `escapesDirect` (the symmetric predicate) is the
obligation that rules this out; the pre-fix check tested only ONE orientation.
The orientation fact is already proved in `h2b_direct_collapses` (either
disjunct collapses the head into both sides). Here we record the concrete shape
as a proposition. (The obligation is PROVED in
`lean/RowGadtEscape.lean` as the theorem `H2b_wildcard_leak_shape`.) -/
def H2b_wildcard_leak_shape_stmt (ρ ρ' : RowVar) (t_b t_r : Ty) : Prop :=
  occursInTy ρ t_b ∧ occursInTy ρ' t_r
  -- a wildcard/head branch returns the full row ρ (t_b) while the refining
  -- branch's tail ρ' sits in the shared result (t_r); the OTHER orientation
  -- from the direct head-in-result/tail-in-body shape.

/-- The wildcard-leak orientation collapses under the alias too (the symmetric
half of `h2b_direct_collapses`, stated standalone for the report). -/
theorem h2b_wildcard_collapses (θ : RowVar -> Row) (ρ ρ' : RowVar) (t_b t_r : Ty)
    (hθtail : θ ρ' = Row.var ρ) (hθhead : θ ρ = Row.var ρ)
    (h : occursInTy ρ t_b ∧ occursInTy ρ' t_r) :
    occursInTy ρ (substAliasTy θ t_b) ∧ occursInTy ρ (substAliasTy θ t_r) := by
  constructor
  · exact occursInTy_stable θ ρ t_b hθhead h.1
  · exact occursInTy_mono θ ρ ρ' t_r h.2 (by simp [occursInRow, hθtail])

--------------------------------------------------------------------------------
-- 10. The over-approximation (steering id 351, point 3)
--------------------------------------------------------------------------------

/-- **H2 is sound-but-incomplete (proved concretely).** The implementation's
syntactic `escapesDirect` is COARSER than the domain rule: on the legitimate
full-row rebuild (`{ ℓ : x | ρ' }` returned at the head `ρ`) it FIRES — the tail
`ρ'` occurs in the body and the head `ρ` in the result — and therefore wrongly
rejects, while the domain rule ACCEPTS (the domain is preserved). This is a
COMPLETENESS limitation (false reject), not a soundness hole. -/
theorem h2b_overapproximation (ℓ : Label) (t x : Ty) (ρ ρ' : RowVar) :
    escapesDirect [(ρ, ρ')] (Ty.record (Row.field ℓ x (Row.var ρ'))) (Ty.record (Row.var ρ))
      ∧ H2b_domain_rule ρ (equationBody ℓ t ρ') (Ty.record (Row.field ℓ x (Row.var ρ'))) (Ty.record (Row.var ρ)) := by
  constructor
  · refine ⟨ρ, ρ', by simp, Or.inl ⟨?_, ?_⟩⟩
    · simp [occursInTy, occursInRow]
    · simp [occursInTy, occursInRow]
  · intro y
    simp [substRow, contains, equationBody]
