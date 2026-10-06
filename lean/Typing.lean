/-
λρG — Stage 1: the typing judgment skeleton, CONSTRAINT-BASED.

This file mechanizes the DECLARATIVE TYPING JUDGMENT of the calculus
(docs/research/row-gadt-calculus.md §2) as an inductive relation, with
UNIFICATION ABSTRACTED as a parameter of the theory. It is the SKELETON:
terms, the judgment, and the rule set — NO proofs (T1 progress / T2
preservation are deliberately OUT OF SCOPE, as is any unification algorithm).

THE ARCHITECTURE DECISION UNDER TEST. The calculus doc's rules (§2.4-§2.9)
are written AGAINST a unifier: they contain `unify_global(…) ⊳ θ'` and
`unify_branch(…) ⊳ Δᵢ` calls, so unification (which is where GADT inference
bites, and where a COMPLETE unifier is the hard, undecidable-complete part)
lives INSIDE the rules and is dragged into any soundness proof. This file
instead presents the judgment CONSTRAINT-BASED: the rules EMIT CONSTRAINTS
(references to the abstract relation `Unifies`) and CAPTURE equations into
the store Δ, and unification is a SEPARATE, abstract relation. Soundness of
the calculus then needs the unifier to be SOUND (it must not accept
constraints that are actually inconsistent), not COMPLETE — which sidesteps
the hardest part of the metatheory.

WHAT "ABSTRACTED" MEANS HERE. `Unifies : Rigid -> Ty -> Ty -> Prop` and
`Captures : Rigid -> Ty -> Ty -> Store -> Prop` are declared as `axiom`s:
they are the unifier as a PARAMETER of the calculus, with no definition and
no algorithm in this file. The rules reference them and nothing else about
unification. Stage 4 replaces the `axiom`s with a real (SOUND, not
necessarily complete) relation; nothing in the rule set needs to change for
that replacement. The two relations are:

  * `Unifies R t₁ t₂` — the global unification constraint ("wanted"): under
    rigid set R, t₁ and t₂ are unifiable. Used by R-APP, R-SEL, R-UPD,
    R-RESULT (Tier-plain). In the doc this is `unify_global(t₁ ≐ t₂) ⊳ θ'`;
    constraint-based, no θ' is threaded — the types stay as metavariables and
    the constraint records the fact.
  * `Captures R t_p t_s Δᵢ` — the BRANCH unification of R-CASE: unifying the
    pattern type t_p against the scrutinee type t_s under R CAPTURES the
    would-be rigid bindings as the equation store Δᵢ (the doc's
    `unify_branch(t_p ≐ t_s) ⊳ Δᵢ`). Capture never touches θ.

SELF-CONTAINED BY DESIGN. This file does NOT import RowGadt: that file's `Ty`
is the MINIMAL fragment (type variables + records only, for H1/H2), while the
typing judgment needs the FULL type grammar (functions, named types, tuples).
The row-algebra operations needed here (`contains`, `restrict`, `substRow`,
`tailVar`, `equationBody` …) are therefore redeclared at the full `Ty`. This
is the same drift hazard the RowGadt/Update split already carries, flagged
honestly rather than hidden: the two `Ty`s are different objects, and the
label-structural row operations are re-proven later if Stage 3 needs them.
Everything lives in `namespace Typing` so this file can be imported alongside
RowGadt without the name-collision the Lake-library refactor already hit
(Lean 4.34 does NOT auto-namespace modules).

DOC DIVERGENCES (per-rule, also reported to the orchestrator):
  * R-TYPE is formalized as a TERM-level binder `type x̂₁…x̂ₙ. e`; the doc's
    surface has it as a *signature* prefix, but a term binder is the standard
    way to make "binder-rigid" a constructor of the expression judgment.
  * R-RESULT is a verdict-indexed relation (`Result Δ R t_b t_r v`) so the
    TWO-TIER asymmetry is visible IN THE TYPE: Tier-T recurses and can still
    conclude `ok`; Tier-R is terminal and forces `escape`.
  * R-UPD-INS is a REJECTION, so it is a constructor of a rejection predicate
    `InsertionRejected`, not of `HasType` (which concludes typing success).
  * Application is BINARY; the doc's n-ary `e a₁…aₙ` desugars to nesting.
  * The STANDARD (uninteresting) typing rules for `λ`, record literals,
    constructor application, and restriction are OMITTED: those forms are in
    the syntax (§1.5, goal 1) but only the refinement-discipline rules in the
    brief's list are given constructors, so those forms are untypeable in this
    skeleton. Insertion gets BOTH: the allowed rule R-INS and the rejection
    R-UPD-INS.
  * Flex markers (none/number/comparable/appendable, §1.2) are ELIDED; they
    only change R-EXISTS's rigidity guard.
  * "Fresh" variables are existentially quantified in the rule premises, with
    the freshness side condition left to the soundness stage (noted inline).
  * The scheme's `bound` subset B (§1.4) is carried by the `type` term binder,
    not stored in `Scheme`; R-VAR instantiates all quantifiers fresh-flex.
  * Zonking ("zonked once") before discharge is ELIDED: discharge reads the
    equation body's head directly; the alias/zonk step is unification's job,
    which is abstracted away.
-/

namespace Typing

--------------------------------------------------------------------------------
-- 1. Syntax
--------------------------------------------------------------------------------

/-- A type variable (kind `Ty`, §1.1). Row variables are a SEPARATE sort, which
makes WF-VAR-TAIL (§1.3) true by construction: a row variable can only ever be
a row tail, never a type. Flex markers (§1.2) are ELIDED (see header). -/
structure TyVar where
  id : Nat
  deriving DecidableEq, Inhabited

structure RowVar where
  id : Nat
  deriving DecidableEq, Inhabited

/-- Labels are strings (the surface has no type-level labels, §1.3). -/
abbrev Label := String

/-- Named type constructors and constructor names (§1.3, §1.6). -/
abbrev TName := String

/-- A variable of either kind, for scheme quantifiers (which mix `Ty` and `Row`
variables, §1.4). -/
inductive Var where
  | ty : TyVar -> Var
  | row : RowVar -> Var
  deriving DecidableEq, Inhabited

mutual
  /-- Types (§1.3): type variable, named type `T t₁ … tₙ`, function, tuple,
  record `{ r }`. -/
  inductive Ty where
    | tvar : TyVar -> Ty
    | tcon : TName -> List Ty -> Ty
    | fn : Ty -> Ty -> Ty
    | tup : List Ty -> Ty
    | record : Row -> Ty

  /-- Rows (§1.3): empty tail (closed row), field `ℓ : t | r`, row-tail
  variable. Duplicate labels are legal and retained (scoped labels); the FIRST
  occurrence of a label is the one selection/restriction/update act on. -/
  inductive Row where
    | empty : Row
    | field : Label -> Ty -> Row -> Row
    | var : RowVar -> Row
end

/-- Schemes (§1.4): `∀ x̂₁ … x̂ₙ. t`. The `bound` subset B (the `type`-prefix)
is carried by the `type` term binder (R-TYPE), not stored here — see header. -/
structure Scheme where
  quantifiers : List Var
  body : Ty

/-- The term-variable environment Γ (§2.1): `x : s` with `s` a scheme. -/
abbrev Ctx := List (TName × Scheme)

/-- The constructor environment Σ (§1.6): each constructor name → its scheme
`∀ qⱼ. t₁ -> … -> tₙ -> tᶜ`, where `tᶜ` is the PER-CTOR result type. -/
abbrev CtorEnv := List (TName × Scheme)

/-- Patterns (§1.5). -/
inductive Pattern where
  | var : TName -> Pattern                          -- x
  | wild : Pattern                                 -- _
  | ctor : TName -> List Pattern -> Pattern         -- C p₁ … pₙ
  | tup : List Pattern -> Pattern                  -- (p₁,…,pₙ)
  | rpat : List (Label × Pattern) -> Pattern       -- { ℓⱼ = xⱼ }
  | lit : Nat -> Pattern                           -- literal pattern (Nat tag)
  deriving Inhabited

/-- Expressions (§1.5). Application and abstraction are BINARY/UNARY here; the
doc's n-ary `e a₁ … aₙ` / `λ p₁ … pₙ. e` (n ≥ 1) desugar to nesting. -/
inductive Expr where
  | var : TName -> Expr                               -- x
  | lam : Pattern -> Expr -> Expr                    -- λ p. e
  | app : Expr -> Expr -> Expr                       -- e₀ e₁
  | record : List (Label × Expr) -> Expr             -- { ℓ₁ = e₁, … } (closed)
  | sel : Expr -> Label -> Expr                      -- e.ℓ
  | upd : Expr -> Label -> Expr -> Expr              -- { e | ℓ = v }
  | ins : Expr -> Label -> Expr -> Expr              -- { e | ℓ ← v }
  | restr : Expr -> Label -> Expr                    -- { e − ℓ }
  | ctor : TName -> List Expr -> Expr                 -- C e₁ … eₙ
  | caseOf : Expr -> List (Pattern × Expr) -> Expr   -- case e of { pⱼ ↦ eⱼ }
  | typebind : List Var -> Expr -> Expr              -- type x̂₁ … x̂ₙ. e (R-TYPE)
  | letIn : TName -> Expr -> Expr -> Expr            -- let x = e₁ in e₂
  deriving Inhabited

--------------------------------------------------------------------------------
-- 2. The equation store Δ and the rigid set R (§2.1, §2.2)
--------------------------------------------------------------------------------

/-- An equation `x̂ ≐ t` (§2.1): a captured refinement. `tyEq a τ` is a TYPE
equation (`a : Ty`); `rowEq ρ r` is a ROW equation (`ρ : Row`). -/
inductive Equation where
  | tyEq : TyVar -> Ty -> Equation
  | rowEq : RowVar -> Row -> Equation

/-- The equation store Δ: a most-recent-first list of equations (§2.1). -/
abbrev Store := List Equation

/-- The rigid set R (§2.2): which Ty variables and which Row variables are
rigid (skolems) — never bound by substitution. A variable id is rigid for one
of three reasons (§2.2): signature-bound (`type` prefix, R-TYPE),
constructor-existential (R-EXISTS), or index-lift. -/
structure Rigid where
  ty : TyVar -> Prop
  row : RowVar -> Prop

/-- The empty rigid set. -/
def Rigid.empty : Rigid := ⟨fun _ => False, fun _ => False⟩

/-- Add a Ty variable to R. -/
def Rigid.addTy (R : Rigid) (a : TyVar) : Rigid :=
  ⟨fun b => R.ty b ∨ b = a, R.row⟩

/-- Add a Row variable to R. -/
def Rigid.addRow (R : Rigid) (ρ : RowVar) : Rigid :=
  ⟨R.ty, fun b => R.row b ∨ b = ρ⟩

/-- Pointwise union of rigid sets. -/
def Rigid.union (R S : Rigid) : Rigid :=
  ⟨fun a => R.ty a ∨ S.ty a, fun ρ => R.row ρ ∨ S.row ρ⟩

/-- The rigid set induced by a list of quantifiers (the `type`-prefix B of
R-TYPE, or the non-determined existentials of R-EXISTS). -/
def rigidOfVars (B : List Var) : Rigid :=
  ⟨fun a => Var.ty a ∈ B, fun ρ => Var.row ρ ∈ B⟩

--------------------------------------------------------------------------------
-- 3. Unification, ABSTRACTED (the parameter of the theory)
--------------------------------------------------------------------------------

/-- **Global unification (the "wanted" constraint).** `Unifies R t₁ t₂` holds
iff, under the rigid set R, t₁ and t₂ are unifiable (the doc's
`unify_global(t₁ ≐ t₂) ⊳ θ'`). In the constraint-based presentation no θ' is
threaded — the constraint just records that the two types are identified.

THIS IS A PARAMETER, not a definition: Stage 4 gives it a real (SOUND, not
necessarily COMPLETE) relation. The typing rules below reference it and
nothing else about unification. -/
axiom Unifies : Rigid -> Ty -> Ty -> Prop

/-- **Branch unification (capture).** `Captures R t_p t_s Δᵢ` holds iff
unifying the pattern type t_p against the scrutinee type t_s under rigid set R
CAPTURES the would-be rigid bindings as the equation store Δᵢ (the doc's
`unify_branch(t_p ≐ t_s) ⊳ Δᵢ`). Capture never touches θ — the global
substitution is unchanged by any branch-local capture (§2.3). Also a
PARAMETER, defined in Stage 4 alongside `Unifies`. -/
axiom Captures : Rigid -> Ty -> Ty -> Store -> Prop

--------------------------------------------------------------------------------
-- 4. Substitution (for instantiation and discharge)
--------------------------------------------------------------------------------

mutual
  /-- Type-variable substitution `t[a := τ]` (capture-avoiding at the
  metavariable level: the `τ` here is a bare type, no binder model). Used by the
  Tier-T discharge of R-RESULT and R-APP-DISCH. -/
  def substTyVar (a : TyVar) (τ : Ty) : Ty -> Ty
    | Ty.tvar b => if b = a then τ else Ty.tvar b
    | Ty.tcon n ts => Ty.tcon n (ts.map (substTyVar a τ))
    | Ty.fn s t => Ty.fn (substTyVar a τ s) (substTyVar a τ t)
    | Ty.tup ts => Ty.tup (ts.map (substTyVar a τ))
    | Ty.record r => Ty.record (substTyVarRow a τ r)

  def substTyVarRow (a : TyVar) (τ : Ty) : Row -> Row
    | Row.empty => Row.empty
    | Row.field ℓ t r => Row.field ℓ (substTyVar a τ t) (substTyVarRow a τ r)
    | Row.var ρ => Row.var ρ
end

mutual
  /-- Row-variable substitution `ρ := r` (the standard scoped-label substitution
  of §1.4: `r`'s fields are prepended, `r`'s tail replaces `ρ`). Used by
  R-UPD-DISCH's discharged result. -/
  def substRowVar (ρ : RowVar) (s : Row) : Ty -> Ty
    | Ty.tvar a => Ty.tvar a
    | Ty.tcon n ts => Ty.tcon n (ts.map (substRowVar ρ s))
    | Ty.fn a b => Ty.fn (substRowVar ρ s a) (substRowVar ρ s b)
    | Ty.tup ts => Ty.tup (ts.map (substRowVar ρ s))
    | Ty.record r => Ty.record (substRowVarRow ρ s r)

  def substRowVarRow (ρ : RowVar) (s : Row) : Row -> Row
    | Row.empty => Row.empty
    | Row.field ℓ t r => Row.field ℓ (substRowVar ρ s t) (substRowVarRow ρ s r)
    | Row.var ρ' => if ρ' = ρ then s else Row.var ρ'
end

mutual
  /-- Variable-substitution `θ : Var -> Var` (scheme instantiation: each
  quantifier is replaced by a fresh variable). Sort-respecting by convention: a
  well-formed `θ` maps `Var.ty` to `Var.ty` and `Var.row` to `Var.row`; the
  fallback arm (returning the variable unchanged) is unreachable for such a θ. -/
  def substVarTy (θ : Var -> Var) : Ty -> Ty
    | Ty.tvar a => match θ (Var.ty a) with
        | Var.ty a' => Ty.tvar a'
        | Var.row _ => Ty.tvar a
    | Ty.tcon n ts => Ty.tcon n (ts.map (substVarTy θ))
    | Ty.fn a b => Ty.fn (substVarTy θ a) (substVarTy θ b)
    | Ty.tup ts => Ty.tup (ts.map (substVarTy θ))
    | Ty.record r => Ty.record (substVarRow θ r)

  def substVarRow (θ : Var -> Var) : Row -> Row
    | Row.empty => Row.empty
    | Row.field ℓ t r => Row.field ℓ (substVarTy θ t) (substVarRow θ r)
    | Row.var ρ => match θ (Var.row ρ) with
        | Var.row ρ' => Row.var ρ'
        | Var.ty _ => Row.var ρ
end

/-- Instantiation of a scheme to a type (`⟦s⟧`, §2.4): there is a variable
substitution θ under which `s.body` equals `t`, IDENTITY OUTSIDE the quantifiers
— only quantified variables may be renamed, so a free (non-quantified) variable
of `s.body` is NOT silently substituted to a fresh one (which would sever its
occurs-link: the R-VAR laundering channel). Freshness of the θ-images (they must
be NEW flex variables, free nowhere in scope) is still a side condition for the
soundness stage and is NOT modeled here. -/
def instantiates (s : Scheme) (t : Ty) : Prop :=
  ∃ θ : Var -> Var, (∀ v, v ∉ s.quantifiers -> θ v = v) ∧ substVarTy θ s.body = t

/-- Peel a ctor scheme body `t₁ -> … -> tₙ -> tᶜ` into (argument types, result
type); `none` if the body is not an arrow. -/
def peelArrow : Ty -> Option (List Ty × Ty)
  | Ty.fn a b => match peelArrow b with
      | some (args, res) => some (a :: args, res)
      | none => some ([a], b)
  | _ => none

--------------------------------------------------------------------------------
-- 5. Free variables and the row algebra (label-structural)
--------------------------------------------------------------------------------

mutual
  /-- `v` occurs free in type `t` (over the unified `Var` sort). The list cases
  recurse through an explicit list helper (`fvTyList`) because the `∃ t ∈ ts`
  / `List.any` forms defeat structural termination (the element `t` is bound by
  a higher-order/∃ position, not a direct subterm). -/
  def fvTy : Ty -> Var -> Prop
    | Ty.tvar a, v => Var.ty a = v
    | Ty.tcon _ ts, v => fvTyList ts v
    | Ty.fn a b, v => fvTy a v ∨ fvTy b v
    | Ty.tup ts, v => fvTyList ts v
    | Ty.record r, v => fvRow r v

  /-- `v` occurs free in row `r` (in a field type, or as the tail). -/
  def fvRow : Row -> Var -> Prop
    | Row.empty, _ => False
    | Row.field _ t r, v => fvTy t v ∨ fvRow r v
    | Row.var ρ, v => Var.row ρ = v

  /-- `v` occurs free in some element of `ts` (structural list helper for the
  `tcon`/`tup` cases of `fvTy`). -/
  def fvTyList : List Ty -> Var -> Prop
    | [], _ => False
    | t :: ts, v => fvTy t v ∨ fvTyList ts v
end

/-- `v` is free in the environment Γ (in the body of some scheme). -/
def fvCtx (Γ : Ctx) (v : Var) : Prop :=
  ∃ x s, (x, s) ∈ Γ ∧ fvTy s.body v

/-- `ℓ` occurs anywhere in row `r` (membership in `dom₀(r)`, the
first-occurrence label set, §1.3 — a duplicate adds no new label). -/
def contains : Label -> Row -> Prop
  | _, Row.empty => False
  | m, Row.field l _ r => m = l ∨ contains m r
  | _, Row.var _ => False

/-- The tail variable of a row, if any (§2.1's `tails(Δ)` head/tail pairs). -/
def tailVar : Row -> Option RowVar
  | Row.empty => none
  | Row.field _ _ r => tailVar r
  | Row.var ρ => some ρ

/-- The body of a row equation `ρ ≐ { ℓ : t | ρ' }`: the head field `ℓ : t`
prepended to the tail variable `ρ'`. -/
def equationBody (ℓ : Label) (t : Ty) (ρ' : RowVar) : Row :=
  Row.field ℓ t (Row.var ρ')

/-- `restrict r ℓ` removes the FIRST occurrence of `ℓ`, returning its type and
the remainder row; `none` when absent (R-UPD / R-RESTR, §2.4). -/
def restrict : Row -> Label -> Option (Ty × Row)
  | Row.field l t r, m =>
      if l = m then some (t, r) else
        match restrict r m with
        | none => none
        | some (t', r') => some (t', Row.field l t r')
  | Row.empty, _ => none
  | Row.var _, _ => none

/-- Build a CLOSED row (empty tail) from a field-type list, left-to-right
(R-REC's record-literal result, §1.5: literals are closed). -/
def rowOfFields : List (Label × Ty) -> Row
  | [] => Row.empty
  | (l, t) :: rest => Row.field l t (rowOfFields rest)

--------------------------------------------------------------------------------
-- 6. Store lookup (discharge reads an equation; no unification here)
--------------------------------------------------------------------------------

/-- The first TYPE equation `a ≐ τ` on `a` in the store, if any (§2.7 Tier-T /
§2.4 R-APP-DISCH read this). -/
def tyEqFor (Δ : Store) (a : TyVar) : Option Ty :=
  match Δ.find? (fun e => match e with
    | Equation.tyEq a' _ => a' = a
    | Equation.rowEq _ _ => false) with
  | some (Equation.tyEq _ τ) => some τ
  | _ => none

/-- The first ROW equation `ρ ≐ r` on `ρ` in the store, if any (§2.4 R-SEL-DISCH /
R-UPD-DISCH read this). -/
def rowEqFor (Δ : Store) (ρ : RowVar) : Option Row :=
  match Δ.find? (fun e => match e with
    | Equation.rowEq ρ' _ => ρ' = ρ
    | Equation.tyEq _ _ => false) with
  | some (Equation.rowEq _ r) => some r
  | _ => none

/-- A row variable is REFINED in the store Δ iff Δ carries a (first) row equation
on it — the judgment-level notion that RowGadtEscape's `rigidCoversRefinedTails`
and the implementation's `refinedTails` describe at the row-algebra level. (Moved
here from TypingStore.lean so R-LET's soundness predicate, which lives in this
file, can reference it without a circular import.) -/
def RefinedTailVar (Δ : Store) (ρ : RowVar) : Prop :=
  ∃ b, rowEqFor Δ ρ = some b

/-- Is `t` a record type (i.e. does it carry row structure)? Tier-T discharges
only NON-record bodies (§2.7: `dischargeType` returns the first equation whose
body is not a `TRecord`). -/
def isRecordTy : Ty -> Prop
  | Ty.record _ => True
  | _ => False

/-- Is the row's tail refined in Δ (has an equation on it)? R-UPD-INS rejects
exactly this (§2.4). -/
def refinedTail (Δ : Store) (r : Row) : Prop :=
  ∃ ρ, tailVar r = some ρ ∧ ∃ b, rowEqFor Δ ρ = some b

--------------------------------------------------------------------------------
-- 7. Lookup and constructor existentials
--------------------------------------------------------------------------------

/-- Term-variable lookup in Γ. -/
def lookupVar (Γ : Ctx) (x : TName) : Option Scheme :=
  (Γ.find? (fun e => e.1 = x)).map (fun e => e.2)

/-- Constructor lookup in the constructor environment (named `CEnv`, not `Σ`,
because Lean reserves `Σ` for Sigma-type notation). -/
def lookupCtor (CEnv : CtorEnv) (C : TName) : Option Scheme :=
  (CEnv.find? (fun e => e.1 = C)).map (fun e => e.2)

/-- The constructor existentials of R-EXISTS (§2.10): exactly the quantifiers
NOT free in the ctor result type tC, mapped through the instantiation θ and made
RIGID. The determined quantifiers (free in tC) are NOT in this set — they stay
flexible. (The flex-marker guard of §1.2 is elided: every non-determined
quantifier is rigidified.) -/
def extsOf (s : Scheme) (θ : Var -> Var) (tC : Ty) : Rigid :=
  ⟨ fun a => ∃ q ∈ s.quantifiers, ¬ fvTy tC q ∧ Var.ty a = θ q,
    fun ρ => ∃ q ∈ s.quantifiers, ¬ fvTy tC q ∧ Var.row ρ = θ q ⟩

--------------------------------------------------------------------------------
-- 8. R-RESULT (the branch-result check, two tiers, §2.7)
--------------------------------------------------------------------------------

/-- The verdict of the branch-result check: `ok` (the body's type is a
legitimate result) or `escape` (an equation is needed but may not leave the
branch). -/
inductive Verdict where
  | ok : Verdict
  | escape : Verdict

/-- **R-RESULT**, verdict-indexed so the TWO-TIER asymmetry is VISIBLE IN THE
TYPE of the relation:

  * `tier_plain` — plain global unification (doc §2.7 step 2);
  * `tier_T` — a TYPE equation `a ≐ τ` (τ NOT a record) DISCHARGES: the body and
    result are re-checked under `a := τ` (one-way substitution, never a bind),
    and the recursion may still conclude `ok`. This is the COERCING tier.
  * `tier_R` — a ROW equation `ρ ≐ r` NEVER discharges: if `ρ` is needed (occurs
    in the body or the result), the verdict is forced to `escape`. This is the
    REJECTING tier.

The asymmetry is exactly that `tier_T` recurses (productive, may conclude `ok`)
while `tier_R` is terminal (always `escape`). -/
inductive Result (Δ : Store) (R : Rigid) : Ty -> Ty -> Verdict -> Prop where
  | tier_plain {t_b t_r : Ty} (h : Unifies R t_b t_r) :
      Result Δ R t_b t_r Verdict.ok
  | tier_T {t_b t_r : Ty} {v : Verdict} (a : TyVar) (τ : Ty)
      (heq : tyEqFor Δ a = some τ)
      (hnotrow : ¬ isRecordTy τ)
      (hocc : ¬ fvTy τ (Var.ty a))
      (hrec : Result Δ R (substTyVar a τ t_b) (substTyVar a τ t_r) v) :
      Result Δ R t_b t_r v
  | tier_R {t_b t_r : Ty} (ρ : RowVar) (r : Row)
      (heq : rowEqFor Δ ρ = some r)
      (hneed : fvTy t_r (Var.row ρ) ∨ fvTy t_b (Var.row ρ)) :
      Result Δ R t_b t_r Verdict.escape

--------------------------------------------------------------------------------
-- 9. R-UPD-INS (the explicit rejection, §2.4)
--------------------------------------------------------------------------------

/-- **R-UPD-INS** — the explicit rejection. Insertion `{ e | ℓ ← v }` never
consults the store; when the base row's tail is refined in Δ the form is
REJECTED outright. As a rejection it is NOT a `HasType` constructor; it is named
here so the rejection is an object of the calculus, visible alongside R-INS's
`¬ InsertionRejected` premise (the asymmetry with R-UPD, which HAS a discharge
constructor). -/
inductive InsertionRejected (Δ : Store) : Row -> Prop where
  | up_ins (r : Row) (ρ : RowVar) (b : Row) :
      tailVar r = some ρ ->
      rowEqFor Δ ρ = some b ->
      InsertionRejected Δ r

--------------------------------------------------------------------------------
-- 10. R-LET generalization (§2.9)
--------------------------------------------------------------------------------

/-- `s` generalizes `t` with respect to Γ: it quantifies exactly the free
variables of `t` that are NOT free in Γ. (The appendable-flex exclusion of §2.9
is elided.) -/
def Generalizes (Γ : Ctx) (t : Ty) (s : Scheme) : Prop :=
  s.body = t ∧ ∀ v, (v ∈ s.quantifiers) ↔ (fvTy t v ∧ ¬ fvCtx Γ v)

/-- **R-LET's generalization, RESTRICTED so neither a refined row head nor an
equation's body-tail is ever quantified.**
This is the judgment-level restatement of `H2b_no_quantify_refined_tail` (proved
in RowGadtEscape): the row-algebra lemma says a rigid variable survives
`generalizeLet`; here the judgment says the scheme quantifiers must EXCLUDE
(a) the store's refined row HEADs — `RefinedTailVar Δ ρ`, i.e. `ρ` is the
SUBJECT of a row equation (`rowEqFor Δ ρ` is defined), which the implementation's
`generalizationRigid` comment calls the "harmless" half (heads are already
skolems in its `scopeFreeVars`) — AND (b) each equation's BODY-TAIL `ρ'`
(`rowEqFor Δ ρ = some b` with `tailVar b = some ρ'`), the half the
implementation's comment calls "the crucial one". The two conjuncts together
cover the (head, tail) PAIR the implementation rigidifies.

The unconstrained `Generalizes` (above) does NOT satisfy this: it quantifies
every free variable not in Γ (see `generalizes_quantifies_free_var` in
TypingStore.lean), so the skeleton's ORIGINAL R-LET rule is UNSOUND for the
escape obligation. This predicate is the corrected premise: `Generalizes Γ t s`
PLUS the exclusion of every refined head of Δ PLUS the exclusion of every
equation body-tail of Δ from the quantifiers. It is defined IN THIS FILE
(rather than TypingStore.lean) because R-LET references it and TypingStore.lean
imports this file — the predicate had to move DOWN a layer to avoid a circular
import. `Generalizes` itself is left UNCHANGED, so the correspondence with the
implementation's let-laundering bug remains visible: the unconstrained rule is
the unsound one, and this is the added premise that fixes it. -/
def GeneralizesRespectsRefined (Δ : Store) (Γ : Ctx) (t : Ty) (s : Scheme) : Prop :=
  Generalizes Γ t s ∧
    (∀ ρ, RefinedTailVar Δ ρ -> Var.row ρ ∉ s.quantifiers) ∧
    (∀ ρ b ρ', rowEqFor Δ ρ = some b -> tailVar b = some ρ' -> Var.row ρ' ∉ s.quantifiers)

--------------------------------------------------------------------------------
-- 11. Pattern typing (with R-EXISTS, §2.10)
--------------------------------------------------------------------------------

mutual
  /-- Pattern typing (§2.6): `Γ ⊢ p : t ⊳ binds, exts` — the pattern `p` has type
  `t`, binds the term variables `binds`, and rigidifies the constructor
  existentials `exts` (R-EXISTS). R-CASE adds `exts` to R for the branch body. -/
  inductive HasTypePat (Γ : Ctx) (CEnv : CtorEnv) : Pattern -> Ty -> Ctx -> Rigid -> Prop where
    | pat_var (x : TName) (t : Ty) :
        HasTypePat Γ CEnv (Pattern.var x) t [(x, ⟨[], t⟩)] Rigid.empty
    | pat_wild (t : Ty) :
        HasTypePat Γ CEnv Pattern.wild t [] Rigid.empty
    | pat_ctor (C : TName) (ps : List Pattern) (s : Scheme) (θ : Var -> Var)
        (argTs : List Ty) (tC : Ty) (binds : Ctx) (extsArgs : Rigid) :
        lookupCtor CEnv C = some s ->
        peelArrow s.body = some (argTs, tC) ->
        HasTypePatArgs Γ CEnv ps (argTs.map (substVarTy θ)) binds extsArgs ->
        HasTypePat Γ CEnv (Pattern.ctor C ps) (substVarTy θ tC) binds
          (Rigid.union (extsOf s θ tC) extsArgs)

  /-- Arguments of a constructor pattern, typed pointwise (used by R-EXISTS). -/
  inductive HasTypePatArgs (Γ : Ctx) (CEnv : CtorEnv) : List Pattern -> List Ty -> Ctx -> Rigid -> Prop where
    | nil : HasTypePatArgs Γ CEnv [] [] [] Rigid.empty
    | cons {p : Pattern} {ps : List Pattern} {t : Ty} {ts : List Ty}
        (binds binds' : Ctx) (exts exts' : Rigid) :
        HasTypePat Γ CEnv p t binds exts ->
        HasTypePatArgs Γ CEnv ps ts binds' exts' ->
        HasTypePatArgs Γ CEnv (p :: ps) (t :: ts) (binds ++ binds') (Rigid.union exts exts')
end

--------------------------------------------------------------------------------
-- 12. THE TYPING JUDGMENT and the rule set
--------------------------------------------------------------------------------

/-
The judgment is CONSTRAINT-BASED and all four "context" arguments are
INDICES (not Lean parameters) because they VARY across the rule set: R-CASE
checks the branch body under `Δᵢ ++ Δ` while the conclusion is under `Δ` (the
snapshot/restore discipline); R-TYPE checks the body under `R ∪ rigidOfVars B`;
R-LET checks `e₂` under `(x, s) :: Γ`. Making them indices is precisely how the
store discipline is made explicit in the rule SHAPE (see the header).
-/
mutual
  /-- **THE TYPING JUDGMENT** `Γ ; Δ ; R ⊢ e : t` (§2.1), presented
  constraint-based: the rules EMIT unification constraints (`Unifies`) and read
  / capture equations in the store Δ; unification is the abstract parameter of
  §3. Γ is the term env, `CEnv` the constructor env, Δ the equation store, R the
  rigid set. -/
  inductive HasType : Ctx -> CtorEnv -> Store -> Rigid -> Expr -> Ty -> Prop where
    | var (Γ : Ctx) (CEnv : CtorEnv) (Δ : Store) (R : Rigid) (x : TName) (s : Scheme) (t : Ty) :
        lookupVar Γ x = some s ->
        instantiates s t ->
        HasType Γ CEnv Δ R (Expr.var x) t

    | typeBinder (Γ : Ctx) (CEnv : CtorEnv) (Δ : Store) (R : Rigid) (B : List Var) (e : Expr) (t : Ty) :
        HasType Γ CEnv Δ (Rigid.union R (rigidOfVars B)) e t ->
        HasType Γ CEnv Δ R (Expr.typebind B e) t

    | app (Γ : Ctx) (CEnv : CtorEnv) (Δ : Store) (R : Rigid) (e₀ e₁ : Expr) (t₁ t₂ t₁' : Ty) :
        HasType Γ CEnv Δ R e₀ (Ty.fn t₁ t₂) ->
        HasType Γ CEnv Δ R e₁ t₁' ->
        Unifies R t₁ t₁' ->
        HasType Γ CEnv Δ R (Expr.app e₀ e₁) t₂

    | appDisch (Γ : Ctx) (CEnv : CtorEnv) (Δ : Store) (R : Rigid) (e₀ e₁ : Expr) (t₁ t₂ t₁' : Ty) (a : TyVar) (τ : Ty) :
        HasType Γ CEnv Δ R e₀ (Ty.fn t₁ t₂) ->
        HasType Γ CEnv Δ R e₁ t₁' ->
        tyEqFor Δ a = some τ ->
        ¬ isRecordTy τ ->
        ¬ fvTy τ (Var.ty a) ->
        Unifies R (substTyVar a τ t₁) (substTyVar a τ t₁') ->
        HasType Γ CEnv Δ R (Expr.app e₀ e₁) (substTyVar a τ t₂)

    | sel (Γ : Ctx) (CEnv : CtorEnv) (Δ : Store) (R : Rigid) (e : Expr) (ℓ : Label) (r : Row) (a : TyVar) (β : RowVar) :
        HasType Γ CEnv Δ R e (Ty.record r) ->
        Unifies R (Ty.record r) (Ty.record (Row.field ℓ (Ty.tvar a) (Row.var β))) ->
        HasType Γ CEnv Δ R (Expr.sel e ℓ) (Ty.tvar a)

    | selDisch (Γ : Ctx) (CEnv : CtorEnv) (Δ : Store) (R : Rigid) (e : Expr) (ℓ : Label) (r : Row) (ρ ρ'' : RowVar) (t' : Ty) :
        HasType Γ CEnv Δ R e (Ty.record r) ->
        tailVar r = some ρ ->
        rowEqFor Δ ρ = some (Row.field ℓ t' (Row.var ρ'')) ->
        HasType Γ CEnv Δ R (Expr.sel e ℓ) t'

    | upd (Γ : Ctx) (CEnv : CtorEnv) (Δ : Store) (R : Rigid) (e v : Expr) (ℓ : Label) (r r' : Row) (t_ℓ t_v : Ty) :
        HasType Γ CEnv Δ R e (Ty.record r) ->
        restrict r ℓ = some (t_ℓ, r') ->
        HasType Γ CEnv Δ R v t_v ->
        Unifies R t_v t_ℓ ->
        HasType Γ CEnv Δ R (Expr.upd e ℓ v) (Ty.record (Row.field ℓ t_v r'))

    | updDisch (Γ : Ctx) (CEnv : CtorEnv) (Δ : Store) (R : Rigid) (e v : Expr) (ℓ : Label) (r : Row) (ρ ρ'' : RowVar) (t' t_v : Ty) :
        HasType Γ CEnv Δ R e (Ty.record r) ->
        tailVar r = some ρ ->
        rowEqFor Δ ρ = some (Row.field ℓ t' (Row.var ρ'')) ->
        HasType Γ CEnv Δ R v t_v ->
        Unifies R t_v t' ->
        HasType Γ CEnv Δ R (Expr.upd e ℓ v)
          (Ty.record (substRowVarRow ρ (Row.field ℓ t_v (Row.var ρ'')) r))

    | ins (Γ : Ctx) (CEnv : CtorEnv) (Δ : Store) (R : Rigid) (e v : Expr) (ℓ : Label) (r : Row) (t_v : Ty) :
        HasType Γ CEnv Δ R e (Ty.record r) ->
        HasType Γ CEnv Δ R v t_v ->
        ¬ InsertionRejected Δ r ->
        HasType Γ CEnv Δ R (Expr.ins e ℓ v) (Ty.record (Row.field ℓ t_v r))

    | caseR (Γ : Ctx) (CEnv : CtorEnv) (Δ : Store) (R : Rigid) (e : Expr) (branches : List (Pattern × Expr)) (t_s t_r : Ty) :
        HasType Γ CEnv Δ R e t_s ->
        HasTypeBranches Γ CEnv Δ R t_s t_r branches ->
        HasType Γ CEnv Δ R (Expr.caseOf e branches) t_r

    | letR (Γ : Ctx) (CEnv : CtorEnv) (Δ : Store) (R : Rigid) (x : TName) (e₁ e₂ : Expr) (t₁ t₂ : Ty) (s : Scheme) :
        HasType Γ CEnv Δ R e₁ t₁ ->
        Generalizes Γ t₁ s ->
        GeneralizesRespectsRefined Δ Γ t₁ s ->
        HasType ((x, s) :: Γ) CEnv Δ R e₂ t₂ ->
        HasType Γ CEnv Δ R (Expr.letIn x e₁ e₂) t₂

  /-- **R-CASE's branch list** (§2.6), the SNAPSHOT / CAPTURE / RESTORE discipline
  made explicit in the shape: the list is threaded through the SAME snapshot Δ;
  each branch CAPTURES its equations `Δᵢ` (via `Captures`), checks its body under
  the PUSHED store `Δᵢ ++ Δ` and extended rigid set `R ∪ exts`, runs the
  branch-result check `Result` under `Δᵢ ++ Δ`, and the RECURSION — like the
  `caseR` conclusion — is back under the bare snapshot `Δ`. Nothing the branch
  captured survives into the next branch or the conclusion. -/
  inductive HasTypeBranches : Ctx -> CtorEnv -> Store -> Rigid -> Ty -> Ty -> List (Pattern × Expr) -> Prop where
    | nil (Γ : Ctx) (CEnv : CtorEnv) (Δ : Store) (R : Rigid) (t_s t_r : Ty) :
        HasTypeBranches Γ CEnv Δ R t_s t_r []
    | cons (Γ : Ctx) (CEnv : CtorEnv) (Δ : Store) (R : Rigid) (t_s t_r : Ty)
        {p : Pattern} {e : Expr} {rest : List (Pattern × Expr)}
        (t_p t_b : Ty) (binds : Ctx) (exts : Rigid) (Δᵢ : Store) :
        HasTypePat Γ CEnv p t_p binds exts ->
        Captures R t_p t_s Δᵢ ->
        HasType (Γ ++ binds) CEnv (Δᵢ ++ Δ) (Rigid.union R exts) e t_b ->
        Result (Δᵢ ++ Δ) R t_b t_r Verdict.ok ->
        HasTypeBranches Γ CEnv Δ R t_s t_r rest ->
        HasTypeBranches Γ CEnv Δ R t_s t_r ((p, e) :: rest)
end

--------------------------------------------------------------------------------
-- 13. Sanity checks (demonstrate the non-unifier parts are inhabited)
--------------------------------------------------------------------------------

/-- `pat_var` is directly constructible — pattern typing needs no unifier. -/
example (Γ : Ctx) (CEnv : CtorEnv) (x : TName) (t : Ty) :
    HasTypePat Γ CEnv (Pattern.var x) t [(x, ⟨[], t⟩)] Rigid.empty :=
  HasTypePat.pat_var x t

/-- R-UPD-INS's rejection is constructible from a row equation in the store. -/
example (ρ ρ'' : RowVar) (ℓ : Label) (t : Ty) :
    InsertionRejected [Equation.rowEq ρ (Row.field ℓ t (Row.var ρ''))] (Row.var ρ) :=
  InsertionRejected.up_ins (Row.var ρ) ρ (Row.field ℓ t (Row.var ρ'')) rfl
    (by simp [rowEqFor])

/-- R-RESULT's plain tier is constructible from a `Unifies` hypothesis — the
result check needs only the abstract unifier, nothing else. (The `Unifies`
premise is exactly the unifier-parameter boundary; it is uninhabited until
Stage 4 instantiates the parameter.) -/
example (Δ : Store) (R : Rigid) (t_b t_r : Ty) (h : Unifies R t_b t_r) :
    Result Δ R t_b t_r Verdict.ok :=
  Result.tier_plain h

end Typing
