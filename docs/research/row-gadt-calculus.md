# λρG: the declarative calculus of branch-local row refinement

A formal, mechanization-ready specification of the calculus implemented by
`elm-compiler/src/Type/*` in this repository — Leijen scoped-label
extensible records × GADT refinement × locally abstract types, connected by a
branch-local equation store with two-tier discharge.

This document is **self-contained**: syntax, well-formedness, declarative
typing rules, a small-step operational semantics, the theorem statements with
all hypotheses, the novel commutation lemma, the escape obligations, and the
negative result. Provenance discipline: every claim about the implementation
is marked **[M]** measured (with a `file:line` citation verified against the
current tree), **[I]** interpretation, or **[P]** projection. Claims about the
*calculus defined here* are definitions and need no marker; a proof-assistant
formalization should take this document as the spec, not the implementation
(§8 lists every place the two differ).

The companion paper draft is `docs/research/row-gadt.md` (§7 of that draft is
the prose sketch this document formalizes and corrects). The judgment is
written for the implementation surface, which has a few quirks noted inline:
record literals are closed [M: `Type/Infer.elm:735-743` builds
`TRecord {fields, tail = REmpty}`], record labels are surface strings (there
are no type-level strings), and the update base must be a local variable
[M: `Type/Infer.elm:795-806`].

---

## 1. Syntax

### 1.1 Kinds

```
k  ::=  Ty | Row
```

Every type variable carries a kind: `Ty` variables range over value types;
`Row` variables range over *row tails* and may only stand in the tail position
of a row. [M: `Type/Representation.elm:52-54` `type Kind = KType | KRow`; the
`KRow` doc comment: "they only ever appear as the `RVar` tail of a `Row`".]

Kinds are *not* decorative. Three of the four implementation blockers in the
build were kinding defects (a `KType`-forced generic hitting a row-tail
position, a first-use kind inference that mis-kinded depending on source
order, and a missing unification path for `KRow`-vs-record) [M:
`docs/research/row-gadt.md` §6; `handoff-rowgadt-impl-result` Steps 3, 7]. A
calculus without explicit row kinds cannot predict where a real
implementation breaks — that is a finding of this project, not a stylistic
choice.

### 1.2 Variables

A variable identity is a triple `x = (id, k, φ)` of a globally unique id, a
kind, and a **flex marker**:

```
φ  ::=  none | number | comparable | appendable
```

[M: `Type/Representation.elm:60-76` `Flex` and `VarId`; ids are unique across
kinds (fresh counter shared, `Type/Unify.elm:66-71`)]. Flex markers
participate in unification (a `number` variable unifies with `Int`/`Float`;
conflicting markers fail) but are orthogonal to refinement; we keep them in
the syntax because they change one rule (R-EXISTS: a flex-marked quantifier is
never rigidified) and dropping them would misstate the implemented system
[M: `Type/Env.elm:744-766`, the `q.flex == FNone` guard at `:760`].

Notation: `a, b, c` range over `Ty` variables, `ρ, σ, τ` (and `β`) over `Row`
variables, `x̂` (read "x-hat") over a variable of either kind. `x̂ : k`
abbreviates `kind(x̂) = k`.

### 1.3 Types and rows

```
t  ::=  x̂:Ty                                   type variable
     |  T t₁ … tₙ                               named type (n ≥ 0)
     |  t₁ -> t₂                                function
     |  (t₁, …, tₙ)                             tuple (n ≥ 0; () is the unit)
     |  { r }                                   record (r a row)

r  ::=  ε                                       empty tail (closed row)
     |  ℓ : t | r                               field ℓ : t, then r
     |  ρ                                       row-tail variable (ρ : Row)
```

`ℓ` ranges over label *strings* (the surface has no type-level labels). A row
is a finite field list in source order plus a tail; **duplicate labels are
legal and retained**, and the **first occurrence** of a label in field order
is the one that selection, restriction, and update act on (Leijen's scoped
labels) [M: `Type/Representation.elm:96-99`: "Duplicate labels are legal
and retained (scoped labels); the FIRST occurrence of a label is the one
`select`/`restrict` act on"].

Well-formedness of types and rows, `t ok` / `r ok`:

- **WF-VAR-TAIL.** A `Row` variable may occur **only** as a row tail: `ρ`
  cannot occur as a type argument of `T`, as a function domain/codomain, or
  as a field type. Dually a `Ty` variable may not occur as a row tail. [M:
  enforced by construction — `RowTail = REmpty | RVar VarId` where the `RVar`
  case is created only with `KRow` variables (`Type/Representation.elm:108-110`);
  a `KRow` variable in a type position reaches `bindVar`, which rejects with
  `CannotUnify` (`Type/Unify.elm:472-473`).]
- **WF-TCON.** `T t₁ … tₙ ok` requires `n` = the arity of `T` and `tᵢ ok`.
- **WF-ROW-DUP.** `ℓ : t | r ok` requires `t ok` and `r ok`. Duplicates in `r`
  are permitted — this is a definitional choice, and it is load-bearing for
  the H1 lemma (§5.3), which exists *because* duplicates are representable.

The **head** of a row is its first field; the **tail** is everything after it
(including the tail variable). `dom(r)` is the label sequence of `r`
*with duplicates*; `dom₀(r)` is its first-occurrence set.

### 1.4 Schemes and substitution

```
s  ::=  ∀ x̂₁ … x̂ₙ. t                            scheme (n ≥ 0, x̂ᵢ distinct)
```

A scheme carries a *bound subset* `B ⊆ {x̂₁ … x̂ₙ}` (the variables named by the
locally-abstract-type prefix; §2 R-TYPE) — in the implementation a `Scheme`
is a record `{quantifiers, body, bound}` [M: `Type/Env.elm:70-74`]. Write
`∀ B; x̂₁ … x̂ₙ. t` when the split matters.

**Substitutions are kinded and id-keyed.** `θ : Subst` is a finite partial map
from variable *ids* to types, with the side condition:

- **WF-SUBST-KIND.** For every `θ(x̂) = t`: if `x̂ : Row` then `t = { r }` for
  some row `r`; if `x̂ : Ty` then `t` is a type whose free row-tail variables
  are unaffected (a `Ty` variable never maps to a bare row). [M: the unifier
  routes every `KRow` binding through `bindRowVar`, whose success path is
  `addSubst state a (TRecord row)` (`Type/Unify.elm:595-596`) — row variables
  are only ever mapped to `TRecord` values; `Type/Representation.elm:113-114`:
  "Row variables are only ever mapped to `TRecord` values (the unifier
  enforces this)".]¹
- **WF-SUBST-SKOLEM-FREE.** θ maps no rigid variable (rigidity is a property
  of the inference state, §2.2, not solved away by substitution).

`θ` acts homomorphically on types, and on rows it acts on field types and
tail: `θ(ℓ : t | r) = ℓ : θ(t) | θ(r)`, `θ(ε) = ε`, `θ(ρ) = θ(ρ)` (a `Row`
binding's image is a whole record type `{ r }`, whose fields are *prepended*
and whose tail replaces `ρ`'s occurrence — the standard scoped-label
substitution [M: `Type/Representation.elm:249-…` `zonkRow` implements exactly
this: outer fields ++ substituted-tail fields]).

`t[x̂ := t']` (capture-avoiding) is the special case used by the discharge
rules; `fv(t)` is the set of free variables of either kind.

¹ The doc comment reads "enforces this"; the enforcement is the code cited.

### 1.5 Expressions and patterns

```
e  ::=  x                                       variable
     |  λ p₁ … pₙ . e                           abstraction (n ≥ 1)
     |  e a₁ … aₙ                               application (n ≥ 1)
     |  { ℓ₁ = e₁, … , ℓₙ = eₙ }                record literal (closed!)
     |  e.ℓ                                     selection
     |  { e | ℓ₁ = v₁, … , ℓₙ = vₙ }            update (e a local variable)
     |  { e | ℓ₁ ← v₁, … }                      insertion (ℓ may be absent)
     |  { e − ℓ }                               restriction (Record.remove)
     |  C p₁ … pₙ                               constructor application
     |  case e of { pⱼ ↦ eⱼ }ⱼ                  case (j ≥ 1)

p  ::=  x  |  _  |  C p₁ … pₙ  |  (p₁,…,pₙ)  |  { ℓⱼ = xⱼ }ⱼ  |  literal patterns
```

[M on the surface: literals closed `Type/Infer.elm:735-743`; update base must
be a local variable `Type/Infer.elm:795-806`; insertion is the
`InsertionValue` setter arm `Type/Infer.elm:957-994`; restriction is
`Record.remove`, recognized as a magic two-argument literal application,
`Type/Infer.elm:897-926`; record *literals* have no open-tail form in the
surface — an open record can only be *named* by a signature, never
constructed.]

### 1.6 Constructor declarations

```
data T x̂₁ … x̂ₘ where
  C : t₁ -> … -> tₙ -> tᶜ
```

Each constructor carries its own **annotated result type** `tᶜ`, which may
mention the ADT's parameters and *fresh per-constructor existentials*
(quantified variables occurring only in argument types). When no annotation
is given, `tᶜ = T x̂₁ … x̂ₘ` (all parameters in order). The constructor's
scheme is `∀ x̂'₁ … x̂'ₖ. t₁ -> … -> tₙ -> tᶜ` over its free variables
(arguments' and result's), with the ADT parameters shared per declaration
[M: `Type/Env.elm:251-302` `ctorScheme` converts the result annotation in the
same context as the arguments so both generics and existentials resolve; the
unannotated default is `TCon name generics` at `:283-290`; generalization by
`generalize (foldr TFun resultType argTypes)` at `:292`].

**Well-formedness of a GADT declaration** additionally requires: every
annotated result is kind-correct with respect to the ADT's parameter kinds,
where a parameter is `Row` iff it stands at a row-tail position in any of the
type's constructor annotations [M: `Type/Env.elm:474-543`
`collectFileTypeKinds`; `Type/Env.elm:244-249` `ctorScheme`'s prescan binds
row-tail names `KRow` before conversion]. Kinds are otherwise inferred from
first use position [M: `Type/Env.elm:1218-1223` `convert`'s `GenericType` arm
starts `KType`, overridden by the prescans] — the declarative spec *states*
the kind as part of the declaration and treats the prescan as an
implementation detail of surface-syntax elaboration (§8.6).

The canonical GADT used throughout:

```
data Has (l : Label) (t : Ty) (ρ : Row) where
  Here   : Has l t { l : t | ρ' }                        -- ρ' fresh existential
  There  : ∀ ρ₀ k s. Has l t ρ₀ -> Has l t { k : s | ρ₀ }
```

Written on the implementation's surface as
`Here : Has l t { l : t | rho }` / `There : Has l t rho -> Has l t { k : s | rho }`
with `l, t, rho` ADT parameters — i.e. `l` is a phantom `Ty` parameter
standing for a label, and the *label* in the result row is the fresh
existential `k`, not `l` [M: `tests/elm-fixtures/rowgadt_select.elm:8-10`].

---

## 2. The declarative typing rules

### 2.1 The judgment

```
Γ ; Δ ; R ⊢ e : t
```

- `Γ` — the term-variable environment: `x : s` with `s` a scheme.
- `Δ` — the **equation store**: a finite set (implemented as a most-recent-
  first list [M: `Type/Unify.elm:91-95`]) of **equations** `x̂ ≐ t` where
  `x̂` is a variable of either kind and `t` a type of the matching kind
  (`x̂ ≐ { r }` for `x̂ : Row`).
- `R` — the set of **rigid** variable ids (skolems). Rigid variables are
  never bound by substitution; see §2.2.

Two derived notions used by the rules:

- `x̂` is **explained in Δ** if `x̂ ≐ t ∈ Δ`.
- The **tail-pair set** of Δ: `tails(Δ) = { (x̂, ŷ) | x̂ ≐ { ℓ : t | ŷ } ∈ Δ
  for some ℓ, t }` — for each *row* equation, its head variable and its tail
  variable (empty tail ⇒ no pair).

### 2.2 Origin of rigidity (definitional, needed by the rules)

A variable id is rigid in `R` for exactly three reasons, and in each case the
rigidity is **scoped**:

1. **Signature-bound** (locally abstract): the `type x̂₁ … x̂ₙ.` prefix of a
   signature names quantifiers that are rigid while the signature's own body
   is checked [M: `Type/Env.elm:706-728` `instantiatePartial` /
   `freshPartial` marks `q.flex == FNone && memberById q.id bound` rigid;
   called at `Type/Infer.elm:2724`].
2. **Constructor-existential**: a constructor quantifier *not free in the
   constructor's result type* is rigid within the branch that matched it
   (R-EXISTS, §2.10) [M: `Type/Env.elm:744-766`; `Type/Infer.elm:2239-2282`].
3. **Index-lift**: a signature index variable free in the *scrutinee* that
   the branch's pattern result equates to a non-variable type is lifted rigid
   for the branch's duration (the `Witness a` case) [M:
   `Type/Infer.elm:1393-1477` `liftRefinedIndicesM`/`unliftRigidM`; called at
   `Type/Infer.elm:1309`].

Everything else is **flex** (unifiable). `R` is part of the state the rules
thread; branch entry and exit change it (R-CASE, R-EXISTS).

The **global substitution θ** is the persistent component of the state;
equations in Δ are *not* in θ and are never solved into it while their
target is rigid. In the implementation θ and Δ both live in the unifier
state [M: `Type/Unify.elm:66-71`], but the calculus keeps them separate
because the store discipline (snapshot / capture / truncate, §2.8) operates
only on Δ.

### 2.3 Unification (the auxiliary judgment)

Typing uses a *unification* judgment

```
unify_δ(θ, R ; t₁ ≐ t₂) ⊳ θ'   or   ⊳ capture(x̂, t)   or   FAIL(err)
```

where `δ ∈ {global, branch}` selects the behavior on a would-be binding of a
rigid variable [M: `Type/Unify.elm:295-393` `unifyGeneral` threads exactly
this flag; `unify = unifyGeneral False`, `unifyBranch = unifyGeneral True`,
`Type/Unify.elm:276-293`]. Its rules are the standard ones (decompose
`T`/arrows/tuples/records pointwise, occurs check, flex-marker
compatibility, row unification with the scoped-label **rewrite** of §5.2)
plus the rigid discipline:

- **U-RIGID-BIND-T.** `θ ; R ⊢ a ≐ t` with `a` rigid, `a : Ty`:
  in `global` mode FAIL(`RigidVar`); in `branch` mode `capture(a, t)` and
  `a` stays unbound. [M: `Type/Unify.elm:475-485` `bindVar`: the rigid case
  pushes `Equation {target = v, body = t}` in branch mode, errors in global
  mode.]
- **U-RIGID-BIND-R.** `θ ; R ⊢ ρ ≐ { r }` with `ρ` rigid, `ρ : Row`:
  in `global` mode FAIL(`RigidVar`); in `branch` mode `capture(ρ, { r })`.
  [M: `Type/Unify.elm:559-590` `bindRowVar`'s rigid arm — both the
  fielded-row and the bare-tail cases.] **Exception (the alias case):** if
  `r = ρ'` for a *flex* variable `ρ'` (the equation is `ρ ≐ ρ'`, no fields),
  the binding is `θ' = θ[ρ' := { ε | ρ }]` — a flex variable aliased *to* the
  rigid one — in **both** modes, and nothing is captured. [M:
  `Type/Unify.elm:569-590`: the `([], RVar b)` case with flex `b` does
  `addSubst state b (TRecord {fields = [], tail = RVar a})`; the same case
  with rigid `b` captures in branch mode / errors in global mode
  (`:570-571` and `:584-585`).] The dual alias (rigid `ρ` bound *to* flex)
  never arises: the binding direction is always flex-gets-bound.
- **U-RIGID-RIGID.** `θ ; R ⊢ x̂₁ ≐ x̂₂`, distinct, both rigid: FAIL in
  global mode; in branch mode `capture(x̂₁, x̂₂)` [M:
  `Type/Unify.elm:414-423` (`unifyVarVar`'s rigid-rigid case, capture at
  `:419`); also the `KRow`-`KRow` alias routed through `bindRowVar`
  (`Type/Unify.elm:400-411`), whose rigid-rigid case captures in branch
  mode (`:572-573`)].
- **U-RIGID-EXTEND.** The row rewrite (§5.2) reaching a rigid tail it would
  extend: FAIL(`RigidVar`) in global mode; in branch mode `capture(ρ,
  { ℓ : γ | β })` for fresh `γ : Ty`, `β : Row`, and the rewrite *proceeds*,
  handing out the fresh-field view. [M: `Type/Unify.elm:665-687` — the
  `RVar a` + `isRigid` case of `rewrite`.] This is the one branch-mode
  behavior that continues with a *derived fact* rather than failing: the
  equation is captured and the selection site still sees the exposed field
  type.
- **U-IDENT.** `x̂ ≐ { ε | x̂ }` and `x̂ ≐ x̂` are identities, no state change
  [M: `Type/Unify.elm:309` (`rowIsSameVar` check in `unifyGeneral`),
  `:556-557` (same in `bindRowVar`)].

**What a rigid row tail may be, stated once.** [M, the exact code inventory;
this is the target of H2 and of the negative result in §6.]

A rigid `ρ` MAY: (a) be aliased *by* a flex row variable (U-RIGID-BIND-R
alias case — the flex var is bound to `{ ε | ρ }`); (b) be **locally known**
inside a branch to have a shape `{ ℓ : t | ρ' }`, via a captured equation
that licenses R-SEL/R-UPD discharge *within that branch only*; (c) be unified
with itself (U-IDENT).

A rigid `ρ` may NEVER — in any mode — be *bound in θ*: not to a closed row,
not to a fielded row, not to another rigid variable outside branch mode, and
no rewrite may extend it outside branch mode. In branch mode a would-be
binding is captured as an equation, and **θ gains nothing**: the global
substitution is unchanged by any branch-local capture. [M:
`Type/Unify.elm:581-590` (global errors on all non-alias rigid-row binds),
`:687` (rewrite's global `RigidRowE`), `:562-563` comment: "binding it to a
closed, fielded, or extended row specializes the signature's row variable".]

### 2.4 Core structural rules

Notation: `⟦s⟧` = instantiation of scheme `s = ∀ B; x̂₁ … x̂ₙ. t` with **fresh
flex** variables of the same kinds and flex markers substituted for
`x̂₁ … x̂ₙ` [M: `Type/Env.elm:644-659` `instantiate` via `freshQuant` — fresh
vars preserve kind and flex, no rigidity].

```
──────────────────────── R-VAR
Γ(x) = s
─────────────────────────────
Γ ; Δ ; R ⊢ x : ⟦s⟧
```

Δ passes through unchanged — uses of variables never consult the store;
only the discharge rules (R-APP-DISCH, R-SEL-DISCH, R-UPD-DISCH) and the
result rules do.

```
Γ ; Δ ; R ⊢ e₀ : t₀        peel t₀ ≐ t₁ -> t'     (t', fresh result)
Γ ; Δ ; R ⊢ e₁ : t₁'       unify_global(t₁ ≐ t₁') ⊳ θ'
───────────────────────────── R-APP                     (on failure: R-APP-DISCH)
Γ ; Δ' ; R' ⊢ e₀ e₁ : θ'(t')
```

The applied rule of the implementation always *attempts* the global unify
first; when it fails with a rigid failure and the store explains the rigid
variable, the **use-discharge** applies:

```
Γ ; Δ ; R ⊢ e₀ e₁ : t    attempted;   unify_global fails RigidVar(a, t)
a ≐ τ ∈ Δ,  a : Ty,  τ not a row,  a ∉ fv(τ)  (occurs-guard)
──────────────────────────────────── R-APP-DISCH
Γ ; Δ ; R ⊢ e₀ e₁ : θ'[a := τ](t)      (one-way re-check, no binding)
```

The re-unification is on **zonked** sides — the calculus states the
substitution fully applied (the implementation's zonk-before-replaceVar fix;
see §8.3) — and may itself consult the store recursively for a *different*
refined variable (one nested recursion in the implementation) [M:
`Type/Infer.elm:328-376` `unifyUseM`: zonk both sides, on `RigidVar` consult
`dischargeType`, occurs-guard, re-unify with `replaceVar target.id body` on
both sides, recurse once on a rigid failure on a different variable
(`:360-366`); the application-argument site routes through it
(`applyStep`, `Type/Infer.elm:847-853`); list literals, if-branches,
negation and operator applications use it too (`:750`, `:702`, `:655`,
operators through the same application path `:825-853`)]. The equation is
**consumed by nothing**: it stays in Δ and dies at
branch end like every equation.

Side conditions on τ: its free variables must not include the target `a`
(occurs) — otherwise the discharge could identify `a` with a type mentioning
`a` [M: the occurs-guard at `Type/Infer.elm:352-354`].

```
Γ ; Δ ; R ⊢ e : t       fresh a : Ty, β : Row
unify_global(t ≐ { ℓ : a | β }) ⊳ …
   (on rigid failure: R-SEL-DISCH below)
───────────────────────────── R-SEL
Γ ; Δ' ; R' ⊢ e.ℓ : a
```

**R-SEL-DISCH** (the row-discharge rule, the heart of the refinement): the
unification above fails `RigidVar(ρ, _)` where `ρ` is the rigid tail of the
(base's) record type. If `ρ ≐ { ℓ : t' | ρ'' } ∈ Δ` — i.e. some stored row
equation on `ρ`, after one zonk, exposes `ℓ` at its head — the selection is
licensed and returns `t'`, with the site's fresh `a` unified to `t'`; the
store is unchanged:

```
Γ ; Δ ; R ⊢ e : { r | ρ }        ρ rigid
ρ ≐ { ℓ : t' | ρ'' } ∈ Δ  (zonked once; head label is ℓ)
────────────────────────────────────── R-SEL-DISCH
Γ ; Δ ; R ⊢ e.ℓ : t'
```

An equation whose head label is *different* from `ℓ` does not license the
selection [M: `Type/Unify.elm:217-239` `dischargeRow` returns `Nothing` when
`l2 /= l` — "the refinement does not expose `l`"; the reader site is
`Type/Infer.elm:382-407` `unifyMOrDischarge`, called at the `RecordAccess`
site `:759-781`: fresh `a`, fresh `β`, wanted `{ ℓ : a | β }`, and on
success the site's element var is unified to the discharged type]. **The
selectable set inside a refining branch grows exactly by the heads of the
branch's equations** — a field in no equation's head is still an error even
inside the branch [M: the fixture `rowgadt_absentfield` errors `type
variable a is rigid … cannot be unified with {zz:a| b}` — re-measured on the
current tree].

```
Γ ; Δ ; R ⊢ e : { r }              restrict(r, ℓ) = (t_ℓ, r')   (ℓ present, first occurrence)
Γ ; Δ ; R ⊢ v : t_v                unify_global(t_v ≐ t_ℓ) ⊳ θ'
────────────────────────────────────── R-UPD
Γ ; Δ' ; R' ⊢ { e | ℓ = v } : { ℓ : θ'(t_v) | r' }
```

`restrict(r, ℓ)` removes the **first** occurrence of `ℓ` from the field list,
keeping inner duplicates [M: `Type/Infer.elm:1128-1148` `restrictField`].
When `ℓ` is not present in the *known* fields, **R-UPD-DISCH** consults the
store — same shape as R-SEL-DISCH, but the result is the discharged shape
with the new field value prepended:

```
Γ ; Δ ; R ⊢ e : { known | ρ }       ρ rigid, restrict(known, ℓ) fails
ρ ≐ { ℓ : t' | ρ'' } ∈ Δ  (zonked once)
Γ ; Δ ; R ⊢ v : t_v               unify_global(t_v ≐ t') ⊳ θ'
────────────────────────────────────── R-UPD-DISCH
Γ ; Δ ; R ⊢ { e | ℓ = v } : { ℓ : θ'(t_v) | known ++ ρ''-fields }
```

[M: `Type/Infer.elm:1046-1061` `dischargeSetterM`: on a matching equation,
unify the value type against the equation's exposed type and return
`TRecord { fields = ( f, tv ) :: row.fields ++ remainder.fields, tail =
remainder.tail }` — the discharged shape re-prepended.] **Nothing is
bound**: the equation is read, not consumed.

**R-UPD-INS (rejection).** Insertion `{ e | ℓ ← v }` **never** consults the
store. If the (zonked) base's row has a tail variable that the current
branch refines (has an equation in Δ), the form is **rejected outright** —
no discharge, no extension through the equation:

```
Γ ; Δ ; R ⊢ e : { known | ρ }        ρ has an equation in Δ
────────────────────────────────────── R-UPD-INS (REJECT)
escaping-error: "insertion under rigid row refinement"
```

[M: `Type/Infer.elm:964-987` — the `InsertionValue` arm checks
`refinedTailVarM` first and fails with "insertion under rigid row
refinement: cannot insert …"; the store is never consulted on that path.]
Rationale: insertion is the shape-*changing* dual (it may extend the domain
or shadow), so discharging it would let a domain change escape the branch —
this is the boundary case that keeps the update-is-safe claim (§7) non-vacuous.

**R-RESTR.** `{ e − ℓ }` restricts: requires `ℓ` present in the known fields
(first occurrence removed); **no discharge** — the store is not consulted
[M: `Type/Infer.elm:897-926` `inferRecordRemove`: `restrictField` fails to
"record does not have field ℓ"; no store access]. It is a trusted-lie
builtin on the implementation surface (`Record.remove` rewrites to
`Prelude.removeFieldImpl`, whose body is skipped) [M:
`Type/Builtins.elm:69-74`, `:95-98`], but the *rule* the checker enforces at
the rewrite site is the declarative one above.

```
Γ ; Δ ; R ⊢ e : t        t zonks to { r } with restrict(r, ℓ) = (t_ℓ, r')
────────────────────────────────────── R-RESTR
Γ ; Δ ; R ⊢ { e − ℓ } : { r' }
```

### 2.5 R-TYPE (locally abstract types, the binder-rigid rule)

For a declaration `f : type x̂₁ … x̂ₙ. t` with body clauses, each clause is
checked against an **elaborated** scheme in which the named quantifiers are
rigid for the body check:

```
───────────────────────────────────────────── R-TYPE (clause checking)
Γ(f) = ∀ B; qⱼ. t    B = {x̂₁…x̂ₙ}   (the `type`-prefixed names)
instantiatePartial: qⱼ ↦ fresh q̂ⱼ;  q̂ⱼ rigid ⟺ qⱼ ∈ B ∧ flex(qⱼ) = none
Γ ; Δ ; R ∪ {q̂ⱼ | qⱼ ∈ B} ⊢ clauses of f against t[qⱼ := q̂ⱼ]
```

Every *unnamed* quantifier stays **flexible** during the body check — the
body may specialize it — and soundness is restored *after* the body by the
**too-general police**:

```
────────────────────────────────────── R-TYPE-POLICE (annotationNotTooGeneral)
Γ(f) = s_declared        body inferred at fullType (args → result)
s_body  = generalize(zonk(fullType))                  (∀-closure of fv)
skolemize s_declared (ALL none-flex quantifiers rigid), flex-instantiate s_body
unify_global(declared_skolem ≐ body_flex) must SUCCEED
else FAIL: "annotation is too general"
```

[M: `Type/Env.elm:706-728` `instantiatePartial` + `freshPartial`; the body
check calls it at `Type/Infer.elm:2724`; the police is
`annotationNotTooGeneral` at `Type/Infer.elm:2889-2916` — generalizes the
body's zonked full type, `instantiateRigid` the declared scheme
(`Type/Env.elm:674-704`, full skolemization), unifies, error "annotation is
too general: the definition specializes a type variable the annotation
promises to keep general".] The police also runs on the retry path (§2.9)
[M: `Type/Infer.elm:2807`].

A `Ty` variable under `type` may be refined by a branch equation and
discharged at the result (§2.7 Tier-T); a `Row` variable under `type` is the
refinable-but-never-bound tail of §2.3. This rule is what the paper's
feature 3 *is*: the surface prefix exists, and its sole semantic effect is
this rigidity split [M: `/tmp/tc/typea.elm` compiles clean; the option-B
asymmetry measured: select *without* binder → `cannot unify {k:a| b} with
{| a}`; eval without binder → "annotation is too general"].

### 2.6 R-CASE (snapshot, capture, restore)

```
Γ ; Δ ; R ⊢ e : t_s                    (the scrutinee)
For each branch i (pattern pᵢ, body eᵢ):
  Γ ⊢ pᵢ : t_p ⊳ binds_i               (pattern inference; ctor arms via R-EXISTS)
  Δ⁰ = Δ                                (SNAPSHOT the store)
  unify_branch(t_p ≐ t_s) ⊳ Δᵢ          (capture: would-be rigid binds become equations)
  Γ, binds_i ; Δ ∪ Δᵢ ; R ∪ lifted(pᵢ, t_p, t_s) ⊢ eᵢ : t_b
  branch-result check (§2.7) of t_b against t_r
  Δ := Δ⁰                              (TRUNCATE: restore the snapshot)
────────────────────────────────────── R-CASE
Γ ; Δ ; R ⊢ case e of { pᵢ ↦ eᵢ } : t_r
```

The store discipline, stated precisely (this is what "branch-local" means):

- **Snapshot on entry.** Before the branch unify, Δ is identified; the
  branch's equations are pushed *on top of* it.
- **Capture instead of bind.** The pattern-vs-scrutinee unification runs in
  branch mode (§2.3): every would-be rigid binding becomes an equation
  `x̂ ≐ t` in the store, and θ is unchanged. The captured equations are
  visible to the body's discharge rules (R-APP-DISCH, R-SEL-DISCH,
  R-UPD-DISCH) and to the branch-result check — and to nothing else.
- **Truncate on exit.** At branch end the store is restored to the snapshot
  **by truncation**: everything pushed after the snapshot point is dropped,
  however deeply nested the branch [M: `Type/Unify.elm:101-103`
  `dropEqsFrom snapshot state = { state | eqs = snapshot }` — restore is
  assignment of the snapshot prefix; `Type/Infer.elm:1933-1941`
  `snapshotEqsM`/`restoreEqsM`; the sequencing at `Type/Infer.elm:1300-1320`:
  snapshot → lift → `unifyBranchM` → infer body → `unifyResultM` →
  `restoreEqsM` → unlift → restore existentials]. Nesting safety is by
  construction: an inner branch's snapshot is a prefix of the outer store,
  and restore truncates to a prefix.

**The branch remembers, the clause is told.** The equations die at branch
end, but two *memories* survive into the clause — they are the enforcement
seats of the H2 obligations (§5.4):

- `refinedTargets`: every variable a branch of this clause refined (the ids
  of all captured equations' targets) [M: `Type/Infer.elm:154`
  `refinedTargets : List Int`; accumulated in `unifyBranchM`
  `Type/Infer.elm:1963-2011`].
- `refinedTails`: for each captured **row** equation, the pair `(head, tail)`
  = (target id, the tail variable of the zonked body) [M: `Type/Infer.elm:155`,
  `:1968-2011`].

Wildcard and no-constructor branches borrow nothing: a branch with no
captured equation of its own has an empty Δᵢ and its result check is
vacuous [M: the `gNeg_wild`/`gNeg_noeq` probes still err; see §8.1].

### 2.7 R-RESULT (the branch-result check, two tiers)

At the end of each branch, the body type `t_b` is unified with the expected
result type `t_r` (a fresh result variable in the plain case; the declared
result under a signature — §2.9). On **rigid failure** the check is
two-tier:

```
unify_global(t_b ≐ t_r) fails RigidVar(a, t)
a ≐ τ ∈ Δ  with  a : Ty  (a TYPE equation — τ is not a row)
a ∉ fv(τ)  (occurs-guard)
────────────────────────────────────── R-RESULT-Tier-T (discharge)
re-check: unify_global(t_b[a := τ] ≐ t_r[a := τ]) ⊳ θ'  (one-way, both sides)
─ on success: branch result ok; τ's equation still dies at branch end
─ on nested rigid failure on b ≠ a: recurse once (same rule)
─ on any other failure: the historical error
```

**Tier-T discharges; Tier-R never does.** A **row** equation (`ρ ≐ { r }`)
is never discharged at a result — its rigid failure surfaces as the
**escaping-row-equation error**. The asymmetry is the point: discharging a
type equation substitutes a *value* type for an abstract variable (the
standard GADT coercion — a branch knowing `a ≐ Int` may return an `Int` *at*
type `a`), while discharging a row equation would move a row's **domain**
out of the branch — the exported scheme would promise a domain the signature
does not.

The full decision procedure at a branch result, in order [M:
`Type/Infer.elm:1498-1625` `unifyResultM`]:

1. `unify_global(zonk(t_b) ≐ zonk(t_r))` (both sides zonked first).
2. On success, three gates before acceptance: the **tail-escape check**
   (§5.4 H2-b, domain-based) — `dropIntroduced` rejects when THIS result
   unify newly made a refined tail reach its head (the drop; measured
   against the post-pattern and pre-unify baselines) [M: `:1511-1512` calls
   `dropIntroduced` :1842 via `tailReachesHead` :1818; `tailEscapeError`
   :1806]; the flex→rigid alias gate (`refinedTargetAliasedBy` :1709) [M:
   `:1515`]; the branch-end occurs check (`pendingTypeOccurs`) [M: `:1526`].
3. On `RigidVar(a, t)`: if `t` IS the head's refinement **rebuilt**
   (`rebuildMatches` :1879 — `a` a refined-tail head, `a ∉ fv(t)`, `t` a
   fielded row unifying with the equation's zonked body) — ACCEPT without
   binding anything (the domain-preserving rebuild) [M: `:1534-1539`].
4. Else if a usable TYPE equation exists (dischargeType: the first equation
   on `a` whose zonked body is not a `TRecord` [M: `Type/Unify.elm:135-150`])
   — Tier-T discharge as above [M: `Type/Infer.elm:1542-1589`, with the
   occurs-guard at `:1567-1569` and the one-level recursion at `:1580-1589`].
5. Else if `a` is this branch's **constructor existential** (in the
   existentials list, §2.10): reject with the *escaping existential* error
   [M: `:1592-1607`; the fixture `rowgadt_noescape` errors "type variable a
   is rigid … cannot be unified with String" — re-measured].
6. Else if `a` has any equation in the store (`escapesThrough` :1694): reject
   with the **escaping row equation** error ("this branch's refinement of a
   (to t) is needed to type the result, but a branch equation may not escape
   its branch") [M: `:1609-1619`; `escapesThrough` `:1694-1696`].
7. Else: the historical rigid error [M: `:1621-1622`].

The clause-level twin (declaration-directed clauses, §2.9) has the same
shape but replaces steps 3–5 with the refinedTargets check only
[M: `Type/Infer.elm:1733-1816` `unifyClauseResultM`: the tail-escape gates
(`dropIntroduced` on a successful unify; a `RigidVar` on a refined-tail head
→ the tail-escape error), then on `RigidVar(a)` with `a ∈ refinedTargets` →
the escape error; no rebuild arm and no Tier-T discharge at the clause level
— that is the retry's job, branch by branch].

**What Tier-T is not.** The discharge is a *one-way coercion for the
re-check only*: the equation is applied by capture-avoiding substitution to
both sides of the result comparison, never written into θ, and never visible
after the branch [M: `Type/Infer.elm:1644-1691` `replaceVar` — a single-pass
substitution; the doc comment at `:1485-1497` states "one-way coercion,
never a bind"]. A wrong body still fails: the re-check compares the coerced
body against the coerced expected type, so a `String` body under `a ≐ Int`
fails `String ≐ Int` [M: the fixture `rowgadt_evalbad` errors "escaping row
equation: this branch's refinement of a (to String)…" — re-measured; the
re-check unify is what rejects it].

### 2.8 R-EXISTS (rigid constructor existentials)

When a pattern's constructor scheme is instantiated, the quantifiers **not
free in the constructor's result type** are the constructor's *true
existentials*; they are instantiated **rigid** (branch-scoped skolems):

```
C : ∀ qⱼ. t₁ -> … -> tₙ -> tᶜ          determined = fv(tᶜ) ∩ {qⱼ}
instantiate: qⱼ ↦ fresh q̂ⱼ;  q̂ⱼ rigid ⟺ qⱼ ∉ determined ∧ flex(qⱼ) = none
────────────────────────────────────── R-EXISTS
Γ ⊢ C p₁ … pₙ : tᶜ[qⱼ := q̂ⱼ] ⊳ binds      existentials += {q̂ⱼ rigid, scoped to branch}
```

Non-GADT constructors (unannotated result `T x̂₁ … x̂ₘ`) have every
quantifier free in the result, so nothing is rigidified and ordinary ADT
patterns are unaffected. Flex-marked (`number`/`comparable`/`appendable`)
quantifiers are never rigidified — this is what keeps the prelude green (a
`Dict k v` pattern must not skolemize `k`) [M: `Type/Infer.elm:2239-2282`
`resolveCtorType`: `determined = quantifiers free in freeVars (peelResult
scheme.body)`; `Type/Env.elm:744-766` `instantiateExistential` /
`freshExistential` with the `q.flex == FNone && not (memberById q.id
determined)` guard; the existential ids accumulate into `state.existentials`
(`Type/Infer.elm:2282`) and are restored per branch
(`restoreExistentialsM`, `Type/Infer.elm:1480-1482`)]. This is OutsideIn's
touchables discipline, row-aware: the existential may be refined by an
inner match's branch equations and discharged inside, but may not escape
(R-RESULT step 5).

### 2.9 R-LET and the top-level/declaration forms

**R-LET.**

```
Γ ; Δ ; R ⊢ e₁ : t₁          s = ∀ (fv(t₁) − fv(Γ) − appendables). t₁
────────────────────────────────────── R-LET
Γ, x : s ; Δ ; R ⊢ let x = e₁ in e₂ : t₂        (where Γ, x : s ; Δ ; R ⊢ e₂ : t₂)
```

Let-generalization quantifies the free variables of the bound type not
free in the environment, excluding `appendable`-flex variables (they are
resolved at the enclosing declaration's end) [M: `Type/Infer.elm:1197-1246`
`inferLetFunction`/`generalizeLet`: `quantifiers = freeVars t |> filter
(not in rigid(scopeFreeVars)) && v.flex /= FAppendable`; the rigid avoid-set
is `scopeFreeVars` (`:603-613`) = env + locals + top]. Destructuring `let`
patterns generalize their binds the same way (`:1183-1195`,
`generalizeBinds` at `:1222-1232`, with a zonk-first step documented at
`:1214-1220`).

**Top-level declarations.** Unsignatued top-level names start as fresh
monomorphic variables and are generalized per strongly-connected component
after its clauses check [M: `seedOne` at `Type/Infer.elm:2397-2408`
(`monoScheme (TVar v)` for unsignatured), `generalizeScc`/`generalizeUnsig`
(`:2613-2615`, `:2411-2423`), checked in SCC dependency order
(`checkSccs`/`checkScc` `:2589-2612`)]. Signatured names are seeded with
their declared scheme, so recursive occurrences instantiate polymorphically
(polymorphic recursion is available with a signature, monomorphic without)
[M: `seedOne`'s `Env.lookupValue` arm at `:2399-2401`].

**R-TOP-RETRY is NOT a rule of this calculus.** The implementation checks a
declaration's clauses by a historical first pass, then — only when that
fails and the body is directly a `case` — retries declaration-directed
(branch bodies checked against the *declared* result type, each with its
own branch-local discharges). That two-pass retry is an implementation
artifact for corpus byte-identity, described in §8.1; **the declarative
calculus has only the declaration-directed rule**: under a signature, each
clause's body is checked against the declared result type (R-TYPE + R-CASE +
R-RESULT as written above), with no bottom-up join and no retry.

---

## 3. Operational semantics

Types are **erased** at lowering [M: the lowerer runs after inference and
emits untyped VM code; `docs/research/row-gadt.md` §2 and the plan record
"types erased; Lower/* untouched"]. Consequently:

- The dynamic semantics mentions no types; progress and preservation are
  statements about the *erased* behavior of well-typed programs.
- The theorem obligations reduce to: no well-typed closed program reaches a
  *stuck* form that the type system claimed impossible. Because the only
  type-dependent primitives are field selection and case dispatch, and case
  dispatch is now CHECKED for exhaustiveness and refutation (`Type/Exhaustive.elm` — a missing
  POSSIBLE arm is a compile error, an IMPOSSIBLE arm is refuted), so a missing branch is no longer a
  silent runtime failure. The load-bearing obligation remains that **every selection
  licensed by the typing rules finds its label at runtime** (T1's SELECT
  clause, below).

### 3.1 Values and evaluation contexts

```
v  ::=  x  |  λ p. e  |  C v … v  |  { (ℓ₁,v₁) :: … :: (ℓₙ,vₙ) }     (a record VALUE: an assoc list)
E  ::=  [ ]  |  E a  |  v E  |  E.ℓ  |  { E | ℓ = v, … }  |  { E | ℓ ← v, … }
     |  { v | ℓ₁ = v₁, …, ℓᵢ = v, ℓᵢ₊₁ = e, … }   (analogously for insertion)
     |  C v … v E e … e  |  case E of {…}  |  { E − ℓ }
```

A record value is an **association list** of label-value pairs in source
order — this is not a modeling choice: records lower to cons pairs
`((ℓ, v) :: … )` built right-to-left so field `j` sits at the head
[M: `elm-compiler/src/Lower/Expr.elm:1117-1130` and `recordExpr
`:1130-1141`]. Selection lowers to `assoc` + `snd`, and **`assoc` is
first-match-wins from the head** [M: `Lower/Expr.elm:1147-1151`
`recordAccess`; `vendor/osier-rt/src/rt/prims.zig:237-262` `primAssoc` — the
loop breaks on the first `deepEqual` key match]. Update lowers to
**cons-prepend-shadow**: each setter conses a fresh `(ℓ, v)` pair onto the
front of the base record, so the new pair *shadows* any older same-label
pair under first-match [M: `Lower/Expr.elm:1127-1129` comment ("PREPEND-
SHADOW: … assoc's first-match-wins makes it shadow any older same-field
pair") and `recordUpdate`/`setterCode` `:1141-1146`, `:1135-1139`].

So the dynamic semantics of records is exactly Leijen scoped labels: the
**first occurrence** of a label in field order is the one selected and the
one replaced; update never changes the field *sequence* except by
prepending a shadowing pair.

### 3.2 Small-step rules (βv + the record operations)

```
(λ p. e) v  →  e[binds(p, v)]                       (βv; a match failure is stuck)

{ (ℓ₁,v₁) :: … :: (ℓₙ,vₙ) }.ℓ  →  vᵢ                 (SEL: i = MIN{ j | ℓⱼ = ℓ } —
                                                     the FIRST occurrence; if no
                                                     such i, the term is STUCK)

{ v | ℓ = v' }  →  { (ℓ,v') :: v }                   (UPD: cons-prepend-shadow; the
                                                     old first ℓ, if any, is shadowed)

{ v | ℓ ← v' }  →  { (ℓ,v') :: v }                   (INS: same machine action; the
                                                     static rule differs, §2.4)

case Cᵢ v … v of { … ; Cᵢ xⱼ ↦ eⱼ ; … }  →  eⱼ[xⱼ := vⱼ]    (CASE)

{ v − ℓ }  →  remove first ℓ pair from v              (RESTR; stuck if absent)
```

Plus congruence: `e → e'` implies `E[e] → E[e']`.

Stuck forms: a selection whose label is absent, a restriction whose label is
absent, a βv pattern mismatch, and application of a non-function value. The
type system's job (T1) is that closed well-typed programs never reach the
first two.

**Erasure and the theorems.** Since types are erased, the semantic
correspondence the preservation proof needs is purely this: the static
first-occurrence discipline (R-SEL/R-UPD act on the first occurrence of the
label in the row, and `restrict`/`rewrite` preserve field order) coincides
with the dynamic first-occurrence discipline (head-first `assoc`,
prepend-shadow). Both are first-occurrence by construction, and the static
`rewrite`'s swap recursion preserves the order of the skipped fields
(§5.2), so the two disciplines are the *same relation* — this identity is
what H1 makes precise (§5.3).

---

## 4. The theorems

State invariant maintained by all rules: **no equation's target is ever in
θ** (captured targets stay unbound; §2.3) and **Δ's equations mention only
variables live at capture time** (the body of a captured equation is the
type the branch unify wanted to bind, in terms of variables free in the
pattern/scrutinee).

### T1 (Progress)

> **Theorem.** If `∅ ; ∅ ; ∅ ⊢ e : t` (a closed well-typed program) and `e`
> is not a value, then there exists `e'` with `e → e'`, or `e` is a βv
> pattern-mismatch on a refutable pattern — **unless** `e` is a stuck *term*
> the type system excluded: specifically, `e` cannot be of the form
> `E[v.ℓ]` with `ℓ` absent from `v`'s field sequence, nor `E[v − ℓ]` with
> `ℓ` absent.
>
> All hypotheses: standard (the value/evaluation-context grammar of §3.1;
> variables are closed). The SELECT obligation is the paper's point: every
> selection licensed by R-SEL/R-SEL-DISCH must find its label. For a
> selection licensed by R-SEL-DISCH (`ρ ≐ { ℓ : t' | ρ'' } ∈ Δ` at
> typing time), the runtime record is a value of the refined row — its field
> sequence's first occurrence of `ℓ` is exactly the one the equation's head
> named — so SEL steps. For a selection licensed by plain R-SEL, the label
> is in the static row and present by construction.

Status: **argued, not proved** — nothing here introduces a new redex shape;
the genuinely new obligation is the SELECT clause above, and that clause is
*carried by T2* (if preservation holds, an absent-label selection is exactly
a preservation violation at the selection step). The paper must present
progress as a consequence of preservation plus the standard disjointness of
stuck forms, not as an independent result [I; consistent with
`docs/research/row-gadt.md` §7.3, which marks progress "argued"].

### T2 (Preservation)

> **Theorem.** If `Γ ; Δ ; R ⊢ e : t` and `e → e'`, then there exist `t'`,
> `Δ'` such that `Γ ; Δ' ; R ⊢ e' : t'` where:
>
> 1. `t' = θ(t)` for the θ accumulated by the step (ordinary substitution) —
>    and, if the step crosses a **branch boundary** (the branch-result
>    re-check fired), `t' = θ(t[a := τ])` for the discharged Tier-T equation
>    `a ≐ τ` — the *only* ways `t'` differs from `t` are (i) substitution
>    and (ii) Tier-T discharge;
> 2. **Tier-R never discharges**: no `t'` of the form `θ(t)[ρ := { r } ρ-tail
>    rewrite]` — a row equation never changes the result type;
> 3. every equation in `Δ` is preserved **syntactically**: `Δ' ⊇ Δ` with all
>    bodies unchanged (equations mention only variables, and no reduction
>    step substitutes into them);
> 4. (store discipline) if the step is the *last* of a branch body, `Δ'` is
>    the branch-entry snapshot (H2-a).
>
> A full statement needs the usual environment-growth lemmas for application
> (the argument's type enters Γ') and case dispatch (pattern binds enter Γ).

Status: **argued, not proved** [I]. The two row-relevant clauses and why
they hold in the implementation:

- **R-SEL is sound only because discharge licenses exactly the selections
  whose label the equation's head exposes** (`dischargeRow` matches the
  head label; §2.4), and the equation's head is the first occurrence under
  the swap-preserving rewrite (§5.3 H1) — the same first-occurrence as
  `primAssoc`'s [M: `Type/Unify.elm:640-651` head-then-swap; the identity
  of the two disciplines is §3's correspondence].
- **R-UPD is sound with no discharge at all**: update is shape-preserving on
  domains — `{ e | ℓ = v }` requires `ℓ` present and replaces its first
  occurrence, so the result's field sequence is the original's with one
  value changed (dynamically: one shadowing pair prepended). Under a
  refinement `ρ ≐ { ℓ : t | ρ' }` the branch result `{ ℓ : t_v | ρ' }` is
  well-typed **at** `{ ρ }` without binding `ρ` — the domains are equal,
  which is precisely why Tier-R never needs to fire for updates [M: the
  fixture `rowgadt_setx` compiles clean; `dischargeSetterM`'s result shape
  `Type/Infer.elm:1054-1061`; probes P5b/P10 in `docs/research/row-gadt.md`
  §4]. Insertion is the shape-changing dual and is exactly why it is
  rejected under refinement (R-UPD-INS) [M: the insertion rejection
  `Type/Infer.elm:964-987`].

The honest bound: **no general soundness theorem exists for λρG** — T1/T2
are the statements a mechanization should prove or refute; the paper
presents the discipline with mechanical evidence (136 gate checks, corpus
byte-identity), not a proof [I; `docs/research/row-gadt.md` §7.3].

---

## 5. The hard lemmas

### 5.2 The row rewrite (the relation H1 commutes with)

The scoped-label **rewrite** relation, `rewrite(r, ℓ) ⊳ (t, r')` — "expose
`ℓ` at the head of `r`":

```
rewrite(ℓ : t | r, ℓ)      ⊳ (t, r)                    (row-head: first occurrence)
rewrite(ℓ₂ : t | r, ℓ)     ⊳ (t', ℓ₂ : t | r')   if rewrite(r, ℓ) ⊳ (t', r')   (row-swap)
rewrite(ε, ℓ)              ⊳ FAIL(absent)
rewrite(ρ, ℓ)              ⊳ (γ, β)  + θ[ρ := { ℓ : γ | β }]   (row-instantiate; γ,β fresh)
                             — if ρ is flex
rewrite(ρ, ℓ)              ⊳ FAIL(rigid)                    if ρ is rigid, global mode
rewrite(ρ, ℓ)              ⊳ (γ, β)  + equation ρ ≐ { ℓ : γ | β }   (branch mode; §2.3 U-RIGID-EXTEND)
```

Side condition: when rewriting within `unify` of a left row whose tail is
`ρ_L`, reaching a tail variable equal to `ρ_L` is rejected (the
shared-tail/occurs guard — it prevents divergent common-tail unification)
[M: `Type/Unify.elm:629-632`: the `forbidden` parameter and the
`SharedTailE` error at `:660-663`]. [M: the row-head/row-swap cases and the
first-occurrence comment at `:640-651`; row-instantiate for flex at
`:689-701`.]

**Lemma (swap preserves order).** In the `row-swap` recursion, the skipped
fields are prepended back in their original order, so `r'`'s field sequence
is a permutation of `r`'s that moves exactly the first `ℓ` to the front and
preserves the relative order of everything else. Consequently
`dom₀(r') = dom₀(r)` and the *exposed* occurrence is the first `ℓ` of `r`.
[M: the recursion at `Type/Unify.elm:645-651` prepends `(l2, t)` onto
`s2.fields`, i.e. in order. Definitional; provable by induction on the
field list.]

### 5.3 H1 — rewrite/equation commutation (the novel content)

The genuinely new formal content of the calculus — the lemma that does not
exist in any prior system because no prior system puts a row variable under
branch-local refinement:

> **H1 (discharge/rewrite commutation).** Let `ρ` be rigid with
> `ρ ≐ { ℓ : t | ρ' } ∈ Δ` (a branch's row equation), and let `r` be a row
> mentioning `ρ` (possibly after the equation's tail: `r = r₀ ++ ρ` where
> `r₀` may itself contain duplicates of `ℓ` and of other labels). For every
> label `m`, the following commute:
>
> **(a) Discharge-then-rewrite = rewrite-then-discharge.**
> `rewrite(r[ρ := { ℓ : t | ρ' }], m)` succeeds/failed-with-the-same-error iff
> `rewrite(r, m)` consults Δ at `ρ` and discharges — and both yield the same
> exposed type and the same remainder row.
>
> **(b) THE DUPLICATE-LABEL CASE (the hard half).** Suppose `r` contains a
> *second* occurrence of `ℓ` (a duplicate label — legal scoped labels), and
> `m = ℓ`. Then:
> - the **eq-swap** (rewriting under the discharged equation — the swaps of
>   §5.2 applied to `r[ρ := { ℓ : t | ρ' }]`) and
> - the **head-exposure** (rewriting `r` itself, where the first `ℓ` of
>   `r₀` is exposed without ever touching `ρ`)
>
> must agree. Precisely: if `r₀`'s first occurrence of `ℓ` comes before the
> equation's position, head-exposure exposes *that* occurrence and the
> equation is never consulted (its label is shadowed); discharge-then-
> rewrite must therefore expose the same field — the substituted-in `ℓ : t`
> sits *after* `r₀`'s `ℓ` and is not the first occurrence. If `r₀` has no
> `ℓ`, both expose the equation's `ℓ : t`. The **order of the skipped
> fields** must be preserved by both routes (Lemma swap-preserves-order),
> and the two routes' remainder rows differ only by the substitution — not
> by the *order* of any field.
>
> **(c) No-shadow divergence.** Under a duplicate label, one route reading
> the equation and the other not must not produce *different* field types
> for the same selection — i.e. `t_eq` (the equation's type) can only be
> selected when the equation's occurrence is the first `ℓ` in the combined
> row.

**Why this is central.** The implementation's discharge reads the
equation's *head* (`dischargeRow` returns the body's first field, and only
if its label matches) — it does **not** run the full rewrite under the
substituted row. So the implementation needs only the *weak* form of H1:
one zonk of the stored body commutes with the outer substitution, which
holds because the store's bodies are only ever written at capture time in
terms of variables live then, and zonk is a substitution homomorphism
[M: `Type/Unify.elm:217-239` `dischargeRow` zonks the body once and reads
its head; the store's writers are exactly the branch-mode capture sites
§2.3 [M]]. But the **declarative** rule (R-SEL-DISCH as written — "the
equation's head exposes `ℓ`") is only equivalent to the substitution-based
statement under (b): with a duplicate `ℓ` *before* the equation's head,
the equation's `ℓ` is not the first occurrence, so the equation must not
license the selection — and with a duplicate *after*, it must, and the
exposed type must be the equation's.

H1's status: **[M] MECHANIZED, including the duplicate-label case.** The Lean development
(`lean/RowGadt.lean`, part of the `lake build`'d `rowgadt` library) proves:

- `h1_find_commutes` — first-occurrence search commutes with scoped-label substitution: the
  discharge-then-rewrite and rewrite-then-discharge routes agree (H1-a's "one zonk commutes with
  the outer substitution").
- `h1_duplicate_shadow` — **the case that was open**: a duplicate `ℓ` *before* the equation
  shadows it, so both routes expose the **earlier** `t₀` and never the equation's `t`. The
  falsifiable prediction above is therefore *tested and confirmed*, not open.
- `h1_no_shadow` — with no shadowing duplicate, the equation's head is what is selected (the
  positive counterpart).
- `h1_head_only_vs_full` — **[M] a correction to this document's own statement, not a
  confirmation of it**: H1-a read as "for *every* label `m`" holds only in the **rigid-tail**
  regime. With a flex tail the substitution-based search recurses into the tail while the
  implementation's head-only `dischargeRow` stops at the head. The weak form is what the
  implementation needs (and what the paper should state); the strong "for every `m`" form is
  false as originally written here.

The corresponding probes now exist in-repo (they were listed as "never built"):
`tests/elm-fixtures/rowgadt_dup_rebuild.elm` (a full-duplicate rebuild — clean) and
`rowgadt_dup_fewer.elm` (a rebuild with **fewer** duplicate occurrences — errors). The second is a
**known false reject** (incompleteness), not a soundness requirement; see §8.2 item 4.

### 5.4 H2 — escape (two obligations)

The escape property is *two* obligations, not one, and the second is where
the real hole was:

> **H2-a (store truncation).** For every branch, the store at branch exit
> equals the store at branch entry: no equation pushed inside the branch
> survives it. Formally, if `Γ ; Δ⁰ ; R ⊢ case …` derives with branch
> stores `Δ⁰ ∪ Δᵢ`, then after the branch the store is `Δ⁰` — a branch's
> equations are discarded wholesale.
>
> **Status: proved by construction** in the implementation — restore is
> assignment of the snapshot prefix, so truncation is exact and nesting is
> safe (§2.6) [M: `Type/Unify.elm:101-103`; `Type/Infer.elm:1933-1941`].

> **H2-b (no escape of a needed equation).** No equation on a variable free
> in the branch's *result type* may be *needed* to type that result. I.e.
> for a branch with expected result `t_r` and body type `t_b`: there is no
> rigid variable `x̂` with an equation in Δ such that typing `t_b ≐ t_r`
> *requires* solving `x̂`'s equation — unless the equation is a Tier-T type
> equation discharged by R-RESULT-Tier-T (which is not "survival": the
> equation dies, only the *coercion* happened).
>
> **Including tail aliasing:** no equation on a variable free in the result
> survives *under an alias*. Precisely: if `ρ ≐ { ℓ : t | ρ' } ∈ Δ` (head
> `ρ`, tail `ρ'`) and the branch returns a value whose type mentions
> **`ρ'`** (the *tail*) while the expected result mentions **`ρ`** (the
> *head*), the branch is ill-typed — the tail is a **proper sub-row** of the
> head, so returning the tail at the head's type *identifies* them, which
> is exactly the refinement escaping its branch — **and this holds even
> when the identification is routed through an intermediate variable**
> (`ρ'` bound to `ρ''`, or a flex alias chain), not only when `ρ'` appears
> literally.
>
> **The implementation's check is now DOMAIN-BASED — the syntactic check it replaced was
> exploited.** The old check enforced H2-b only on the **direct shape**
> (`head ∈ fv(t_r) ∧ tail ∈ fv(t_b)`, both by occurs-check on zonked types) and a tail aliased
> **through an intermediate variable** was **not caught**. That gap was not theoretical:
> **[M] an adversarial hunt found two programs the checker ACCEPTED that are unsound** —
> (1) *let-laundering*, `(Here, HCons _ rest) -> let ys = rest in ys`, where `let`-generalization
> quantifies the flex tail so the use re-instantiates a fresh variable with no link to it; and
> (2) the *wildcard sibling leak*, `(Here, HCons _ rest) -> rest ; _ -> xs`, where the refining
> branch puts the tail into the **shared** case-result variable and the wildcard puts the full row,
> so unification aliases `tail := ρ` — a *legal* flex-alias — zonking the tail away before any
> clause-level check (the check had been written in **one orientation only**).
> Both are fixed and pinned (`rowgadt_escape_launder`, `rowgadt_escape_wildcard`), and **both are
> mechanized**: `h2b_let_severs_occurs` + `h2b_rigid_preserves_occurs` (let-laundering) and
> `h2b_direct_collapses` (**symmetric** — the second disjunct the old check never tested) +
> `h2b_wildcard_collapses`.
>
> The rule now implemented decides on the **domain**, not on syntactic occurrence: for a refined
> tail `(head, tail)` with equation `head ~ {L|tail}` — **drop** (tail identified with head) →
> reject; **rebuild** (`t` unifies with the equation body **and** `head ∉ t`) → accept; **change**
> (a rigid failure that is not a rebuild) → reject. Both escape obligations are **proved**:
> `H2b_no_quantify_refined_tail` (a refined tail is never quantified, so its occurrence survives
> generalization) and `H2b_wildcard_leak_shape`.
>
> **The remaining gap is the other direction: coarseness, not unsoundness.** `h2b_overapproximation`
> *proves* that the old syntactic predicate fires on a **legitimate** full-row rebuild; the
> domain rule accepts it, and the implementation now does too
> (`tests/elm-fixtures/rowgadt_shape_rebuild.elm` compiles clean). The residue is
> **duplicate-label equations only** — `h2b_domain_exactness` proves the rule is **exact for fresh
> labels and coarse for duplicates**, and the implementation's own note says the same: a body
> rebuilding with **fewer** duplicate occurrences than the equation body is still rejected (a
> **false reject**, never a soundness hole; full-duplicate rebuilds are accepted). See §8.2 item 4.
>
> **Scope note (measured, and load-bearing for honesty):** the
> tail-aliasing check is *result-scoped*. A branch may perform the same
> flex-tail-aliases-rigid-head identification **in its body** without
> triggering anything, provided the result type does not mention the row —
> measured: `rowgadt_select`'s `There` branch does the alias in its body
> (`select r rest` with `rest` the tail-bound payload) and stays clean
> because the result type `t` does not mention `ρ` [M:
> `tests/elm-fixtures/rowgadt_select.elm:19-20`; the meta node's analysis].
> H2-b as stated is exactly result-scoped too (the obligation is about
> typing the *result*), so this is consistent — but the mechanizer must
> not strengthen H2-b to "no aliasing anywhere in the body", which the
> implementation refutes.

Both obligations together are what R-CASE + R-RESULT enforce; neither is
proven in general — H2-a is by-construction, H2-b is enforced on the direct
shape only [M, as cited].

---

## 6. The negative result

> **Theorem (unrestricted global row refinement is unsound).** Let `λρG⁻`
> be the variant of λρG in which branch mode is *replaced* by global mode:
> a branch's would-be capture is solved into θ (a branch refining `ρ ≐
> { ℓ : t | ρ₁ }` binds `ρ := { ℓ : t | ρ₁ }` globally). Then `λρG⁻` types a
> program whose exported scheme is a lie about row domains. Concretely, for
>
> ```
> select : ∀ ρ l t. Has l t ρ -> { ρ } -> t
> select Here r = r.l
> select There h r = select h r
> ```
>
> with `Has` the GADT of §1.6: the `Here` branch captures `ρ ≐ { ℓ : t |
> ρ₁ }` and the `There` branch captures `ρ ≐ { k : s | ρ₂ }`. In `λρG⁻`,
> checking the clauses sequentially solves `ρ := { ℓ : t | ρ₁ }` during the
> first branch; the second branch's equation is then either (a) rejected
> against the already-solved `ρ` (a spurious failure — the *policy* shape
> the rigid guard produces today), or (b) if the guard is removed and the
> solver overwrites, **silently accepted with the wrong scheme**: a caller
> instantiating `ρ := { x : Int }` passes `Here`-shaped data to a function
> whose body was type-checked under `ρ = { ℓ : t | ρ₁ }` — the exported
> scheme `∀ ρ l t. Has l t ρ -> { ρ } -> t` promises nothing about `ℓ`
> being present, but the body's `r.l` was justified by it.
>
> **What it refutes.** The theorem refutes the claim that the features alone
> (rows + GADTs + locally abstract types) compose soundly under the
> *standard* treatment of type-class-free GADT equations — eager global
> solving. It does **not** refute the combination under the store
> discipline: with capture-then-truncate, both equations stay branch-local,
> neither is solved, and the exported scheme is honest — which is the
> necessity direction of the paper's thesis. The discipline is *necessary*
> (this theorem) and *sufficient for every program in the corpus and the
> designed fixtures* (136 gate checks, no unsound accept found) — sufficiency
> over *all* programs is **not** proved [M for the fixture evidence;
> `handoff-rowgadt-meta` B, D].

**Evidence for the mechanism, measured.** The pre-fix behaviour of the
implementation is the theorem's shape in the `Ty` domain: a single-branch
classic case bound `a := Int` globally at the definition while call sites
kept `∀ a. Expr a -> a` — silent wrong code (`evalInt (BoolLit True)` would
typecheck at `Bool` and crash) [M: `handoff-rowgadt-ctx` gA measurement;
`docs/research/row-gadt.md` §6]. The row-domain analogue is today's rigid
guard's *rejection* (the policy refusal) [M: probe P4's `RigidVar` error];
the store discipline converts the refusal into a sound accept
(`rowgadt_select` compiles clean) without ever binding the rigid tail.

---

## 7. The update theorem (the positive row result)

> **Proposition (shape preservation makes update safe).** If `ρ` is rigid
> with `ρ ≐ { ℓ : t | ρ' } ∈ Δ` and `Γ ; Δ ; R ⊢ e : { ρ }`, then
> `Γ ; Δ ; R ⊢ { e | ℓ = v } : { ρ }` — the update is well-typed **at the
> abstract row** with no discharge needed and no equation consumed —
> provided `Γ ; Δ ; R ⊢ v : t`.
>
> Proof idea: update replaces the first occurrence of `ℓ`; the equation
> says the row's head is `ℓ : t | ρ'`; so the result's domain is `ρ`'s
> domain with `ℓ`'s value changed — identical domains, and the type of the
> new value matches the equation's `t`. Formally `dom({ ℓ : t_v | ρ' }) =
> dom({ ℓ : t | ρ' }) = dom(ρ)` under the equation, and neither the
> abstract `ρ` nor the equation needed to be solved.

This is the "update is the safe operation" claim of the paper, now with
all hypotheses on the table [M for the fixture (`rowgadt_setx` compiles
clean; re-measured); the proof idea is [I] and unproved]. Its dual is
R-UPD-INS: insertion can change the domain, so under refinement it is
rejected — the boundary case that makes the proposition non-vacuous
[falsifiable exactly at insertion; M for the rejection].

A note on convention-dependence, for honesty: the argument uses only that
update is domain-preserving, not that it is first-occurrence; under a
last-occurrence semantics the domain is still preserved and the
proposition survives [I; the counterfactual is §8 of the paper draft].

---

## 8. What is idealized (the spec vs the implementation)

The declarative spec above differs from the implementation in the
following places. Each is marked: **[U]** could hide an unsoundness
(a mechanization must prove the implementation's approximation implies
the declarative rule, or exhibit the gap), or **[S]** is soundness-neutral
affecting only completeness or diagnostics.

1. **The two-pass declaration-directed retry — [S].** The implementation
   checks a signatured declaration's clauses bottom-up (fresh result
   variable, branch joins unified at the clause end), and only when that
   fails *and* the body is directly a `case` re-checks it
   declaration-directed [M: `Type/Infer.elm:2718-2830`; the retry is
   `orElse`-wrapped at `:2767`, and on retry failure the
   *historical* error is reported (`:2822`)]. The declarative calculus has only the
   declaration-directed rule (§2.9). Soundness-neutral: the retry accepts a
   *subset* of the declarative language (a GADT case nested under a `let`
   is not retried and fails spuriously [M: `/tmp/rowgadt/gNeg_letcase.elm`
   errs "cannot unify Bool with Int" — measured in the meta node]), and
   every pre-existing diagnostic is unchanged by construction. **But**: the
   retry's *acceptance* condition (plain-fails ∧ body-is-a-case ∧
   sigma-succeeds) is an approximation of "the declarative rule accepts" —
   completeness differs; soundness does not, because the retry still runs
   every rule of §2 (R-CASE, R-RESULT, the police) — it only changes the
   *order* and the *reported error*.
2. **The escape check (H2-b) — [M] RESOLVED, and it DID hide an unsoundness.** This item
   originally read "[U]: `escapeViaTail` checks only `head ∈ fv(result) ∧ tail ∈ fv(body)` on
   zonked types; a tail aliased through an intermediate variable is not caught … **this is the one
   difference that could hide an unsoundness**". That prediction was **correct and is now
   measured**: an adversarial hunt found **two unsound programs the checker accepted**
   (let-laundering and the wildcard sibling leak — §5.4), both since fixed and pinned by fixtures,
   and both mechanized. The syntactic check is superseded by the **domain rule**
   (`dropIntroduced` / `rebuildMatches`), and the two escape obligations are now **proved**
   (`H2b_no_quantify_refined_tail`, `H2b_wildcard_leak_shape`). The remaining difference from the
   declarative rule is **coarseness in the duplicate case** — item 4.
3. **Per-file kinding — [U, weakly].** ADT generic kinds are collected
   *per file* (`collectFileTypeKinds self file.declarations`), so a
   signature in file A referencing a row-parameter ADT declared in file B
   kinded the parameter `KType` in A unless the signature itself spells it
   at a record-tail position [M: `Type/Env.elm:134-137`, the `typeKinds`
   pre-pass is scoped to the file; the cross-file gap is stated in
   `handoff-rowgadt-impl-result` ROWGADT-7]. The declarative spec states
   kinds on the declaration (§1.6), which is the *intended* semantics; the
   per-file prescan is an approximation. A mis-kind could let a row
   variable be treated as a type variable — turning a row equation into a
   type equation that Tier-T would discharge, i.e. a domain change
   escaping its branch. This has not been observed [M: neither occurs in
   the corpus or fixtures], but it is a soundness-relevant approximation.
4. **The duplicate-label case is COARSE — a false reject, not a hole — [M, proved].** The domain
   rule is **exact for fresh labels and coarse for duplicates** (`h2b_domain_exactness`): a body
   that rebuilds with **fewer** duplicate occurrences than the equation body is still rejected.
   The implementation's own note says the same. This is an **incompleteness** —
   `rowgadt_dup_fewer` errors where a more precise rule would accept, while `rowgadt_dup_rebuild`
   (a full-duplicate rebuild) is accepted — and it is **never** a soundness hole: an adversarial
   battery over duplicate shapes (bare tail, let-laundered tail, wildcard sibling leak, wrong
   label, wrong first-occurrence type) found **no unsound accept**. Do **not** "fix" it by
   weakening the check.
5. **Exhaustiveness and refutation — [M] NOW IMPLEMENTED** (`Type/Exhaustive.elm`, commit 36b93d0).
   A `case` omitting a POSSIBLE arm is a COMPILE error (`non-exhaustive case: missing <ctor>`), and
   an arm IMPOSSIBLE under the branch equations is REFUTED and not required. Refutation fires only
   where the scrutinee index is CONCRETE or BINDER-RIGID: a bare FLEXIBLE index must never be
   concretised to refute a sibling (doing so accepted a partial function — fixed). GADT-ness is
   classified PER-FILE, so a cross-module GADT index degrades to the old flexible behaviour (safe).
   *(This item previously read as an absence — [S]; the calculus text above is otherwise unchanged.)*
   (stuck βv on refutable patterns is a documented stuck form, §3.2).
6. **Surface restrictions — [S].** No type-level strings (labels are
   surface strings, so `Has "x" t ρ` is inexpressible); record literals
   are closed (an open row can only be named, never constructed);
   `{ | ρ }` bare-open does not parse; the update base must be a local
   variable. All completeness, not soundness.
7. **Kind elaboration from surface syntax — [S].** The spec states the
   kind of every declaration (§1.6); the implementation *infers* it (row
   prescans + first-use) because the surface has no kind annotations.
   The elaboration rules (`collectRowTailNames` for ctor annotations,
   `collectRowNames` + `collectFileTypeKinds` for signatures) are
   approximations of "the declared kind" that were built precisely
   because first-use inference mis-kinded source-order-dependent
   programs [M: `Type/Env.elm:251-302`, `:474-543`, `:1215-1268`]. A
   mechanization takes the stated kind and treats elaboration as a
   front-end concern.
8. **Trusted bodies — [S].** A fixed list of qualified names
   (`Prelude.removeFieldImpl`, `Runtime.runTask`, 20 total) skip
   inference entirely [M: `Type/Builtins.elm:95-98`, the trusted list at
   `:340-393`; `Type/Infer.elm:2711-2716` skips trusted bodies in
   `inferClause`]. The calculus does not model them (they are escapes,
   not rules); `runTask` is the honest remaining gap (its `TaskExec`
   branch performs a dynamic cast `a ≐ List a` that no type system here
   can express) [M: the trusted comment at `Type/Builtins.elm:365-391`].
9. **Flex markers and the `++` resolution — [S].** The implementation
   carries `number`/`comparable`/`appendable` and resolves `++` sites
   after the body [M: `resolveAppends`/`checkNoResidualAppendable`,
   `Type/Infer.elm:2842-2880`]. The calculus keeps the markers in the
   syntax (§1.2) but omits the `++`-specific machinery; a mechanization
   may drop markers entirely if it also drops R-EXISTS's flex guard and
   the unification compat rules — dropping only the police would be
   unsound.
10. **The zonk-before-replaceVar fix — [S].** The discharge rules as
   written operate on fully substituted (zonked) types; the
   implementation zonks explicitly at the three discharge sites because
   the rigid variable may only appear after resolving the substitution
   [M: `Type/Infer.elm:334`, `:1501` — both sites comment "Zonk
   BOTH sides first (same reason as `unifyUseM`)"]. In the calculus this
   is a non-issue (the rules are stated on semantic types, not
   syntactic representatives); it is listed because the bug it fixed
   was a *silent no-op* discharge — the class of defect that makes a
   mechanized proof of the implementation's discharge nontrivial even
   though the declarative rule is trivially correct.

---

## Appendix A: the fixtures, as the theorem-hypothesis evidence

Every designed positive/negative cited above, re-measured on the current
tree through the batch oracle (the output artifact, never the exit code):

| fixture | expected | measured error / clean |
|---|---|---|
| `rowgadt_select` | clean (R-CASE + R-SEL-DISCH) | clean |
| `rowgadt_setx` | clean (§7) | clean |
| `rowgadt_eval` | clean (Tier-T discharge ×3) | clean |
| `rowgadt_hget` | clean (R-EXISTS + tail unification) | clean |
| `rowgadt_l3i` | clean (witness infers) | clean |
| `rowgadt_l3iii` | clean (plain row infers) | clean |
| `rowgadt_absentfield` | err (no equation's head is `zz`) | `type variable a is rigid … {zz:a\| b}` |
| `rowgadt_escape` | err (H2-b direct: tail at head) | `escaping row equation: … returned only its tail …` |
| `rowgadt_hget_escape` | err (H2-b direct, encoded) | same tail-escape error |
| `rowgadt_hget_badhead` | err (wrong body at index) | `type variable a is rigid … String` |
| `rowgadt_evalbad` | err (Tier-T re-check fails) | `escaping row equation: this branch's refinement of a (to String) …` |
| `rowgadt_noescape` | err (R-EXISTS escape) | `type variable a is rigid … String` |
| `rowgadt_l3ii` | err (no-binder principality loss) | `infinite type: a = {k:a\| b}` |

[M: all thirteen re-compiled through `node elm-compiler/run.js` against the
current tree during the writing of this spec; the gate has since moved to PASS=151
FAIL=0 per the meta node's re-measurement.] The two H1-relevant shadowing
fixtures (`shadow`, `shadowerr`, `shadowtyperr`) are *not* under a
refinement — the duplicate-label-under-refinement probe remains unbuilt
(§5.3).

---

## Appendix B: notation summary

| symbol | meaning |
|---|---|
| `x̂` | a variable of either kind |
| `a, b, c` / `ρ, σ, β` | `Ty` / `Row` variables |
| `θ` | kinded substitution (id-keyed) |
| `Δ` | equation store (set of `x̂ ≐ t`) |
| `R` | rigid (skolem) id set |
| `Γ` | term environment (`x : scheme`) |
| `dom₀(r)` | first-occurrence label set of row `r` |
| `⟦s⟧` | fresh-flex instantiation of scheme `s` |
| `unify_global` / `unify_branch` | the two modes of §2.3 |
| `t[x̂ := t']` | capture-avoiding substitution |
| `fv(t)` | free variables of either kind |
| Tier-T / Tier-R | type / row equations at a branch result (§2.7) |
