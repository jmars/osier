# Withe — extensible records × GADTs × locally abstract types

**Withe** is the language; **λρG** is its core calculus (*the declarative calculus of branch-local
row refinement*, `row-gadt-calculus.md`). The name is a *withe* — a flexible twig used for binding,
keeping the botanical lineage from Elm while naming what the language actually does: flexible rows
that extend and bind. (Chosen after checking collisions: Rowan, Linden, Rho and Facet are all taken.)

Working notes for a research paper. Claims are marked **[M]** measured, **[I]** interpretation,
**[P]** projection. Nothing here is a result until it is marked [M].

Provenance: `handoff-rowgadt-ctx` (fx-agent-memory).

---

## 1. Why this is a live question

Three type-system features, no mainstream language has all three first-class:

| Feature | Wants |
|---|---|
| Row polymorphism (Leijen scoped labels) | open, extensible types; unification-based inference; principal types |
| GADTs | local, rigid refinement during pattern matching; gives up principality |
| Locally abstract types (`type a.`) | rigid skolems; blocks unification of the abstracted variable |

**[I]** The conflict is over *what a type variable is*. Row unification wants variables to be
*solvable* — a single global substitution written back into the context. GADT refinement wants
equations to be *local* to a branch and discharged at the branch boundary. Both mechanisms
target the same variable.

### 1.1 The gap is documented, and the strongest evidence is a *restriction*

**[M]** Quotes verified in `handoff-rowgadt-lit` (retrieved in full; URLs there):

- Flix team, ECOOP 2023 (restrictable variants — the dual of extensible records) names the
  connection outright: *"We think it would be interesting future work to explore possible
  connections between restrictable variants and GADTs."* Flix refines a **label-set** index
  under `choose` but carries its record **row** index only through plain extension — refinement
  never flows into the row.
- **OCaml met this exact interaction and restricted it.** Garrigue & Rémy, "Tracing ambiguity
  in GADT type inference" (2012), on their *first* GADT implementation: *"we had to restrict
  the use of object types and polymorphic variants in combination with GADTs, to prevent local
  equations from breaking the invariant that the same row variable may only appear in two
  record types that are equal."* **[I]** That is the paper's thesis stated by its authors, as a
  reason to *stop*: rows and GADT refinement were found incompatible by construction, and the
  fix was to forbid the combination, not to characterise it.
- OutsideIn(X) (2011) — the standard GADT-inference baseline — **cannot state the problem**:
  its type grammar is `τ ::= tv | Int | Bool | [τ] | T τ`; there is no record type, no row
  variable, no presence anywhere. Its constraint solver is first-order equalities only.
- Castagna et al., ICFP 2016 (set-theoretic variants) names the same direction as future work;
  and Castagna & Peyrot, OOPSLA 2025 (the current rows/presence SOTA) declares refinement
  *"mostly orthogonal"* to row polymorphism and brackets it.

**[M]** No published work puts a **row variable under branch-local GADT refinement.** The four
closest, none of them it: OCaml objects/poly-variants + GADTs (combined, but *restricted* to
protect the same-row-variable invariant); Flix's dual-index `Expr [s][r]` (refines `s`, never
`r`); GHC `HasField` on record GADTs (class-triggered unification, nominal records, no rows); and
**CORELINKS** (Lindley & Cheney, TLDI 2012) — the nearest neighbour in one dimension. CORELINKS
types database **insert/update/delete** against `(label × presence × type)` rows, i.e. it *does*
reason about which fields a row must have. But it does so by **quantifying a presence variable**
(abstraction over whether a field is present), the *opposite direction* from our assumption on a
rigid variable, and it has no GADT refinement, no equations, and no rigidity discipline. Its rows
also have **distinct** labels — no scoped duplicates — which is precisely the case where our domain
rule may not be exact (§7.3). So the adjacent cell is explored; the cell we occupy is not.

**[M] Koka** (Leijen, MSFP 2014) uses rows for **effects** and its eliminations **unify** the effect
row variable — never refine it. Cite once as the effect half of the duality; do not claim
"rows + effects" as novel.

**[M] The gap is acknowledged *currently*, not just historically.** octachron (OCaml maintainer),
Jan 2024: *"the interaction of row variables and GADTs is not well specified. Thus it is common to
hit hard to understand behaviour, and nothing is guaranteed beyond the fact that the currently
implemented interaction is safe,"* and *"GADT equations cannot narrow a polymorphic variant
constraint."* His workaround uses **object types as type-level records — one row variable per
field** (`<tag:[`initial]; initial:yes; terminal:no>`), so no single row variable is ever refined.
That is the exact shape of the gap: practitioners route *around* row refinement with per-field rows
— inside one row is where our `Has` witness lives.

**[M] The nearest 2026 neighbour is principality-motivated, not refinement-motivated.**
Omnidirectional inference (O'Brien, Rémy, Scherer 2026) restores principality for fragile features
and lists GADTs as work it *"would be interested in studying"* — over **nominal** records. Cite it
to show the field is active; do not imply it occupies our cell.

### 1.1.1 Insertion is a deliberate trade, not a discovery

**[M]** Rémy 1994 (ΠML′, retrieved in full) types **unrestricted field extension
unconditionally** — `new_a : Π(a:φ;$) → α → Π(a:pre(α);$)` — with no lacks predicate and no
presence check; Gaster & Jones type extension under a *lacks* predicate; CORELINKS types insert by
*quantifying presence*. **So insertion is not untypable in row systems** — our `R-UPD-INS`
rejection exists *only* relative to an **active branch-local equation**. The correct framing is a
**deliberate trade**: soundness under refinement, in exchange for Rémy's unconditioned
expressiveness. Publishing it as a discovery would be wrong.

**[M]** Likewise, record update is *not* nominal-only in prior work: Rémy types update-as-extension,
Gaster & Jones type restrict-then-extend, Links derives remove-then-extend. **Our update's novelty
is being *domain-preserving by construction*** (scoped-label replace) — not being typable at all.

**[I]** This is why the intersection is unexplored, and the answer is *not* "it's hard": the
one system that tried it treated the conflict as unsoundness and legislated around it, and the
dominant GADT-inference framework has no vocabulary for records at all. The contribution is to
show the conflict is an *artefact of eager global solving*, not of the features themselves.

---

## 2. The substrate already exists

`elm-compiler/src/Type/*` in this repo is an Elm-family checker. **[M]** measured by reading the
source and running probes:

- **Rows: present.** HM + Leijen scoped-label rows (`Type/Unify.elm` `unifyRow` / `rewrite`).
- **Locally abstract types: part present.** A prior session added skolem/rigid machinery for
  signature quantifiers: `rigid : Set Int` on `Unify.State` (`Type/Unify.elm:59`),
  `instantiateRigid` (`Type/Env.elm:478`), guards at `unifyVarVar` / `bindVar` /
  `bindRowVar` / `rewrite` / `comparableVar`.
- **Rigid *row* variables: already implemented.** `bindRowVar` (`Type/Unify.elm:~292`) and the
  row-variable case of `rewrite` (`Type/Unify.elm:~388`) constrain a rigid row tail. So
  question 3 of the brief ("can `type a.` extend to `type ρ.`?") is **not open** — it is
  prototyped already. What is untested is rigidity *under refinement*.
- **GADTs: largely absent.** `ctorScheme` (`Type/Env.elm:227`) hardcodes
  `resultType = TCon name generics`. Per-constructor result types exist only as a hardcoded
  table for one ADT (`taskCtorResults`, `Type/Env.elm:276`); the vendored elm-syntax parser
  has no per-ctor result-annotation syntax. `inferPattern` → `resolveCtorType` → `Env.instantiate`
  (**flex**) → `peelCtor` → `unifyM` (`Type/Infer.elm:1107–1152`).

**[M]** Hence the gap is not policy but mechanism: a constructor's result index is unified
*globally* into the substitution. When the scrutinee's index is rigid and the ctor result is
structured, the rigid guard fires. There is no branch-local refinement and no equation discharge.

> **[M] NOTE — §2 describes the STARTING state of the substrate, not its current state.** Every
> absence named above has since been implemented: per-ctor result syntax (§2's hardcoded table is
> gone), branch-local refinement with discharge, rigid constructor existentials, nested-pattern
> refinement (the `**flex**` → `peelCtor` → `unifyM` path above is now branch-mode at the sub-pattern
> level too), position-directed rigidity for GADT index parameters, and compile-time exhaustiveness
> and refutation. **For what the system does NOW, read §10 and §6.** §2 is kept because the paper
> argues *from* this starting point.

---

## 3. The crux example

A type-indexed **row-membership witness** — this is the smallest program that needs all three
features at once.

```
type Has (l : Label) (t : Type) (ρ : Row) where
    Here  : Has l t { l : t | ρ }
    There : ∀ ρ k s. Has l t ρ -> Has l t { k : s | ρ }

select : type l t ρ. Has l t ρ -> { ρ } -> t
select Here  r = r.l
select There h r = select h r

setX : type t ρ. Has "x" t ρ -> t -> { ρ } -> { ρ }
setX Here  v r = r with { x = v }
setX There h v r = <needs a witness for the tail ρ>
```

**[I] Necessity, feature by feature.**

- **Rows:** `{ ρ }` is a row-polymorphic record; `select` must work for every `ρ`.
- **GADTs:** matching `Here` refines the index row `ρ ≐ { l : t | ρ₁ }` (fresh `ρ₁`); that
  equation is what makes `r.l` well-typed. `There` gives a *different* equation, `ρ ≐ { k : s | ρ₂ }`.
- **Locally abstract types:** the two branches impose *conflicting global* substitutions on `ρ`.
  A single global substitution cannot hold both; the only way to type `select` is to make `ρ`
  rigid so each branch's equation stays local to the branch.

**[I]** So the brief's step 3 succeeds: a program exists that requires all three. The premise
holds, and the mechanism it requires is exactly the one the checker lacks.

---

## 4. Key question 5, sharpened (and partly answered)

The brief asks: if `r : { x : Int | ρ }` and a GADT match refines `ρ` to `{ y : String }`, what
does `r with { x = 5 }` mean?

**[M]** Probes `/tmp/rowgadt/P*.elm`, oracle = the output file (`node elm-compiler/run.js`
always exits 0; a type error is written into the artifact as `err <msg>`):

| program | result |
|---|---|
| `{ r \| x : Int }` → select `x` | OK |
| `{ r \| x : Int }` → select `y` (absent) | `err … rigid … cannot be unified with {y:a\| b}` |
| `{ r \| x : Int }` → `{ rec \| x = 5 }` (present) | OK |
| `{ r \| x : Int }` → `{ rec \| y = 2 }` (absent) | `err … record does not have field y` |
| unannotated `g` → `{ rec \| y = 2 }` | `err … does not have field y` |

**[M] Conclusion.** Record update in this checker is **in-place and row-shape-preserving**
(Leijen scoped-label *replace*): `{ rec | x = v }` requires `x` present and replaces it; it
never extends. This is *not* a rigidity effect — the unannotated row behaves identically.

**[I] Consequence for update under refinement.** Under a branch-local refinement
`ρ ≐ { x : t | ρ₁ }`, `r with { x = v }` needs **no discharge**: it cannot change the row's
shape, so the refined row stays unifiable with the original rigid `ρ`. **Update is the safe
operation under row refinement.** Interpreted: update's compatibility falls out of the update
semantics rather than out of the type system.

**[I] Consequence for selection.** Selecting a field *not guaranteed present* is the unsafe
operation, and is precisely what a row-membership witness must justify. The task is therefore
narrower than it looked: the refinement is needed to *grow the readable field set* in a branch,
not to change a row's shape.

**[M] Caveat.** `P1`'s error shows `rewrite` already manufactures the extended row `{ y : a | b }`
before the rigid guard rejects it. Refinement machinery and the rigidity guard are adjacent in
`rewrite`. Any branch-local design must route around that guard *without weakening it* — the
guard is what closed an earlier silent-miscompile hole (`handoff-typeskolem-result`).

---

## 5. The refinement discipline (design)

**[I]** From `handoff-rowgadt-plan`. Representation: a **scoped constraint store with
discharge**, OutsideIn-style but specialised to *row* equations. A row equation `ρ̂ ~ { l : t | ρ' }`
on a rigid `ρ̂` is **delayed, never solved**; it licences `R-SEL`/`R-UPD` to read/replace `l`
*inside the branch*, and is **discarded at branch end**. A rigid row tail may be

1. aliased by a flex variable (already implemented), or
2. locally *known* to have a shape, for discharge inside the branch,
3. **never** bound in the global substitution — unchanged from today's `bindRowVar` guard.

**[I] Escape is two-tier, and that distinction is the paper's point.** A **type** equation
(`a ~ Int`) *does* discharge at the branch result — a branch holding it may return an `Int` at
type `a` — so the canonical GADT evaluator type-checks. A **row** equation (`ρ̂ ~ { l : t | ρ' }`)
does **not**: discharging it at a result would change the row's *domain*, so it errors as an
*escaping row equation*. The rejection is not a limitation to apologise for — it is exactly why
the row case is the interesting one, and it is what keeps the system sound.

*(This corrects an earlier draft of this section, which made escape a blanket rejection. Building
the reference implementation showed that a blanket rejection also refuses the canonical GADT
evaluator; see §6.)*

**[I] Update discharges for free.** `R-UPD` consults the store, discharges `ρ̂ ~ { x : t | ρ' }`
locally, replaces the first `x`, and returns `{ ρ̂ }`. Because update is shape-preserving
(§4, [M]) the refined row's *domain* equals the original's, so the equation is reflexive on
domains and nothing escapes. **Insertion** (`{ r | f <- v }`, which may extend or shadow) must
**not** consult the store — and is the boundary case that makes the conjecture non-vacuous: it
can change the domain, so under refinement it must be rejected.

**[I] The negative result.** The combination is sound *only* under the discharge discipline.
Unrestricted global row refinement is **unsound** — two branches give conflicting equations
(`Here`: `ρ̂ ~ { l : t | ρ₁ }`; `There`: `ρ̂ ~ { k : s | ρ₂ }`) and a global solver silently keeps
whichever fires first. **[M]** In today's checker that failure surfaces as the `RigidVar` error
(probe P4) — the guard is a policy *refusal*, not a semantic distinction.

**[I] Principality boundary.** Retained (fragment P) when no GADT constructor's result mentions
a row variable — this is today's checker, [M] all 1106 corpus signatures check. Broken
(fragment Q) exactly when two branches yield different equations on the same rigid `ρ` **and
the result type mentions it**: `select` has no principal monotype, only a signature that is
*checkable, not inferable*. The hard lemmas: (H1) row-rewrite/equation commutation under
scoped-label swap; (H2) escape.

**[M] Measured confirmation, on three presentations of the same access** (fixture
`rowgadt_l3*`; the boundary falls on the *row-refinement* side, exactly as stated above):

| presentation | signature omitted |
|---|---|
| native row + GADT refinement (`select`) | **rejected** — `infinite type` |
| witness-encoded (GADT record, no native rows) | accepted |
| plain row access, no GADT (`f rec = rec.x`) | accepted |

**[I]** The middle row is the informative one: a witness is a GADT whose index variable is a
constructor *existential*, which (once existentials are rigid, §6) is rigid inside its branch —
so inference proceeds without a signature. The native-row form has to refine a *signature* row
variable, which must be rigid for the branches to agree, so the signature is not optional. That
is why the boundary sits where it does, and it is a sharper statement than "witnesses lack
principal types" (which is the opposite of what was measured, and should not be published).

---

## 6. What building it revealed

**[M]** The reference implementation (Steps 1–3, `handoff-rowgadt-impl-result`) surfaced four
**pre-existing substrate bugs**, each reproducible without any GADT:

1. `ctorScheme` forced `KType` on every ADT generic, so a generic used at a row-tail position
   kind-mismatched. Fixed by making generic creation lazy (kind from first use position).
2. Kind inference by first use position then broke the *other* order — `Has l t ρ` before
   `{ ρ | … }`. Fixed with a row-tail **prescan** (`collectRowTailNames`) binding record-tail
   names to `KRow` before conversion.
3. `unifyGeneral` had no path for a bare `KRow` variable against a `TRecord` — the exact shape a
   GADT constructor's result index produces. Routed to `bindRowVar` in **branch mode only**
   (the global path keeps its historical behaviour).
4. `bindRowVar`'s flex-alias bound a flex row var to the `TRecord` *wrapper* rather than to the
   `TVar`, so a rigid var meeting its own alias `CannotUnify`-ed. Legal programs with two rigid
   row arguments were rejected. Fixed in the identity case.

**[I]** These are the paper's "why the formal model was naive" material: three of the four are
about **kinds**, not about refinement. A calculus that does not make row-variable *kinding*
explicit will not predict where a real implementation breaks.

**[M] Surface-syntax boundaries** (measured, and honest gaps rather than defects):

- **No `type a.` syntax.** Rigidity is *implicit* for signature generics. So the brief's
  feature 3 is a *no-op surface feature* here — the feature is the rigid mechanism itself,
  which now exists.
- **No type-level strings:** `Has "x" t ρ` does not parse; the label comes from the record
  signature instead (`{ ρ | l : t }`).
- **Record literals are closed**, so a closed literal can never witness an open `ρ` — use sites
  must stay abstract. This is a genuine expressiveness boundary, worth stating in the paper.

**[M] The formal model was too naive about escape — found by building it.** The first
implementation of the branch rule only ever *forbade* an equation from reaching the result. That
is sound but wrong: it also rejects the canonical GADT evaluator

```elm
eval : Expr a -> a
eval e = case e of IntLit n -> n   -- err: "escaping row equation ... a (to Int)"
```

The crux `select` never exposed this, because its result type `t` comes from the *record*, not
from the refined variable — so no result-side discharge was ever needed. The fix is to *coerce*
the branch result through a **type** equation (`a ~ Int`) while still rejecting escape for a
**row** equation, whose discharge would move the row's domain. Report noted: pre-fix this program
compiled by binding `a := Int` globally while call sites kept `forall a. Expr a -> a` — unsound,
so relaxing the escape check instead of two-tiering it would restore that hole.

**[M] Type witnesses / heterogeneous containers now work — but the enabler was *existentials*,
not rows.** The paper's motivating ask ("witness GADTs enabling polymorphic arrays") failed for
two independent reasons, and the fixes are instructive:

1. **Constructor-introduced existentials were flexible.** `resolveCtorType` instantiated a
   constructor's scheme with plain `instantiate`, so the `a` bound by `Some : Witness a -> a -> Any`
   was a unification variable; a nested match then bound it *globally* and the sibling branch
   conflicted. Fix: instantiate a pattern's constructor scheme so the variables not determined by
   the scrutinee are **rigid** (skolems) — with an explicit *escaping existential* error. This is
   the "existentials are rigid" rule of every GADT system, and it is worth noting that *reading
   that the helper existed was not evidence that it was called*: it was written and never wired.
2. **Discharge did not reach plain variable uses.** The branch equation `a ~ Int` was consulted
   only at record selection/update and at the branch result, so `String.fromInt x` with `x : a`
   failed. The fix looked like wiring but was not: the discharge re-unified the **un-zonked**
   types, where the rigid variable does not yet appear, so the substitution was a silent no-op.

**[I]** So the row machinery was not the dependency — **existential rigidity was**, and it is the
single change that unlocks both the container feature and a principled witness encoding of rows.

**[M] The effect-interpreter test, and why it is a partial.** The compiler's own effect interpreter
`Runtime.runTask` was a trusted lie whose comment named its precondition: *"kept trusted until the
per-ctor result table can drive a checked interpreter."* That precondition was **met** — the table
was migrated into real per-ctor source annotations, proven behaviour-preserving by two independent
oracles — and it turned out **not to be sufficient**. **[M, CORRECTED]** With refinement in place
**25 of `runTask`'s 30 branches check honestly — not 29.** The original 29/30 figure came from
**fail-fast**: removing `runTask` from `trustedBodies` reports exactly *one* error and stops.
Masking each failure to reveal the next gives **five**: `TaskExec`, `TaskNow`, `TaskQuit`,
`TaskGuiPoll` and `TaskStat` (breakdown in §10). The first-reported holdout is `TaskExec`: its
payload is typed `a`
(the constructor's existential, absent from the result `Task x (Int,String,String)`), so in-branch
`plan : a` is a rigid skolem while the body applies `execPlanPrim : List a -> List b`, requiring
`a ~ List a`. That is a **dynamic cast** — the runtime value *is* a tagged `List`, but the
constructor declares it generically. No amount of refinement types that; the honest fix is a
surface change to the payload (`List a`), not more type theory.

**[I]** This is worth stating exactly as it is, because it is the shape of a good empirical claim:
a documented precondition, a mechanical proof that it was met, and a refutation that it was the
*right* precondition. The remaining gap in the effect story is dynamic typing at the VM boundary,
not the row/GADT machinery.

---

## 7. Metatheory

Drafted from the artefact (`handoff-rowgadt-meta`) — every claim re-measured on the built system,
not from the pre-implementation sketch. Marked **[M]** measured, **[I]** interpretation,
**[P]** projection.

### 7.1 The calculus

**Kinds are explicit** — `k ::= KType | KRow` — and that is the revision the build forced: three of
the four implementation blockers were *kinding* bugs, so a calculus without row kinds cannot
predict where a real implementation breaks. Judgment:

```
G ; D ; R ⊢ e : t      D = equation store (delayed)      R = rigid (skolem) ids
```

A row is `{fields, tail}` with `tail = REmpty | RVar`; duplicate labels are legal and retained,
**first occurrence** is the one select/restrict act on (scoped labels). Kinded substitutions map
row variables only to record values. `Scheme = {quantifiers, body, bound}`.

The surviving rules, in order: **R-VAR** (instantiate fresh, same kind/flex) · **R-TYPE** (a
`type a ρ.` binder marks the named quantifiers rigid for the body; unbound ones stay flexible and
are policed afterwards by the too-general check) · **R-APP/USE** (on rigid failure, consult `D`
for a *type* equation and re-unify one-way — the variable-use discharge) · **R-SEL** · **R-UPD** ·
**R-UPD-INS** (insertion never consults `D`; rejected under refinement) · **R-CASE**
(snapshot `D`, unify pattern-vs-scrutinee in *branch* mode — a would-be rigid bind is **captured**
as an equation and the variable stays unbound — infer body with `D`, restore) · **R-RESULT**
(two-tier, below) · **R-EXISTS** (a constructor scheme instantiates with quantifiers *not free in
the ctor's result* marked rigid — OutsideIn touchables).

### 7.2 The two-tier rule

Name them in the paper as **Tier-T** and **Tier-R**.

- **Tier-T.** At a branch result, a *type* equation (`a ~ Int`) **is** discharged — the body is
  re-checked against `σ[a := τ]` in one pass, never a bind; the equation still dies at branch end.
- **Tier-R.** A *row* equation (`ρ ~ { l : t | ρ' }`) is **never** discharged at a result, because
  that would move the row's **domain** out of the branch. Its rigid failure surfaces as
  *escaping row equation*.

What a rigid row tail **may** do: be aliased *by* a flex row var; be locally known inside its
branch to have a shape, for select/update discharge; unify with itself. What it may **never** do —
in any mode — is be **bound**: to a closed row, to a fielded row, or to another rigid var outside
branch mode. In branch mode a would-be binding is captured, so **the global substitution gains
nothing**.

### 7.3 Soundness: what is argued vs proved

**Preservation** requires a semantic correspondence, and it is measured: records lower to assoc
lists, selection to first-match-from-head — the same first-occurrence discipline `rewrite` uses.
So R-UPD is sound with **no discharge at all** (update is shape-preserving on domains), and R-SEL
is sound precisely because discharge licenses exactly the selections whose label the equation's
head exposes.

- **(H1) rewrite/equation commutation** — **argued, not proved.** The implementation needs only
  the weak form (discharge zonks the stored body *once*), which reduces to: one zonk commutes with
  the outer substitution. **Honest gap:** the duplicate-label-under-refinement probe was never
  built. The corpus has shadowing fixtures, but none *under a refinement*. Say this in the paper.
- **(H2) escape** — two obligations, not one: *store truncation* (proved by construction: restore
  truncates everything pushed after the snapshot, so nesting is safe) and *tail aliasing* (a
  refinement's **flexible** tail can alias its **rigid** head and "succeed", which unification
  alone cannot see).

  **[M] The tail-aliasing gap was real and exploitable.** An adversarial hunt found **two programs
  the checker accepted that are unsound**:
  1. **Let-laundering** — `case (h, xs) of (Here, HCons _ rest) -> let ys = rest in ys`.
     `let`-generalization *quantifies* the flex tail variable, so the use re-instantiates a fresh
     variable with no link to the tail; a check keyed on "the tail occurs in the body" sees nothing,
     and the fresh variable then legal-aliases the rigid head.
  2. **Wildcard sibling leak** — `(Here, HCons _ rest) -> rest ; _ -> xs`. The refining branch
     returns the tail into the **shared** flex case-result variable while the wildcard branch
     returns the full row; unification aliases `tail := ρ` (a *legal* flex-alias), zonking the tail
     away before the clause-level check. The check had been written in **one orientation only**.

  The first fix (the let-generalization rigid set including refined tails) stands; the second was
  **superseded**: the syntactic check was replaced by a **domain-based rule** — *drop* (tail
  identified with head) rejects; *rebuild* (`t` unifies with the equation body **and** `head ∉ t`)
  accepts; anything else rejects. Both are pinned by `rowgadt_escape_launder` /
  `rowgadt_escape_wildcard`, and both obligations are now **proved** in Lean
  (`H2b_no_quantify_refined_tail`, `H2b_wildcard_leak_shape`).

  **[M] H2 is now sound, and its residual coarseness is the DUPLICATE case — not rebuilds.** The
  domain rule *accepts* the legitimate full-row rebuild (`HCons x rest` at `HList ρ`;
  `rowgadt_shape_rebuild` compiles clean), so that false reject is gone — `h2b_overapproximation`
  proves it was the *old* syntactic predicate that fired on it. What remains is that the rule is
  **exact for fresh labels and coarse for duplicates** (`h2b_domain_exactness`): a rebuild with
  **fewer** duplicate occurrences is still rejected (`rowgadt_dup_fewer`) — a **false reject**,
  never a soundness hole. The asymmetry is still the useful part: H2 errs safe, and the
  counterexamples bound sharply what it is *missing*.

  **[I] This vindicates running the hunt before the proof.** H2 would otherwise have been a theorem
  about a mechanism that did not actually enforce it. The empirical claim is now much stronger than
  "no counterexample found": *two real unsound accepts were found, fixed, and pinned.*

**The negative result.** Unrestricted global row refinement is **unsound**: solving a branch's
`ρ ~ { l : t | ρ₁ }` globally makes a sibling branch's conflicting equation either fail spuriously
or silently overwrite, and the exported scheme becomes a lie. **[M]** its shape is visible in the
pre-fix behaviour (a single-branch classic case bound `a := Int` globally while call sites kept
`forall a. Expr a -> a` — silent wrong code). So the discipline is **necessary** for the row case
and **sufficient** for every program in the corpus and fixtures — sufficiency over *all* programs
is **not** proved. **No general soundness theorem exists for this calculus.** The paper must
present it as a *discipline with mechanical evidence*, not a proof.

### 7.4 The principality boundary, and the inversion

**[M]** Restated from the L3 table: principality is retained (fragment **P**) when every
refinement's target is either branch-scoped existentially (the witness case) or discharged inside
the branch; it breaks (fragment **Q**) exactly when a **signature** variable must be refined
differently in two sibling branches *and* the result mentions it. In Q there is no principal
monotype — the signature is *checkable, not inferable*.

**[I] The inversion is the real result:** the *encoded* presentation (witness/HList) sits on the
**P** side, while its *native* translation (row refinement) sits on the **Q** side. The encoding
does not merely model rows — **it moves the principality boundary**, buying inference at the cost
of expressible operations (no encoded update, no domain restriction, and the absent-field negative
cannot even be *stated* in it). The earlier guess had the two sides swapped and must not be
published.

> **[M] Unchanged by the later rigidity work.** Position-directed rigidity (§10) does **not** move
> this boundary: `rowgadt_l3ii` does not flip, because its `select` is **unsignatured** and a
> signature-directed rule cannot reach an unsignatured definition. The measured consequence is that
> the bare **HList `hget`** stops needing the binder; `select`/`eval`'s bare forms already compiled
> clean. So the P/Q line stands where it was — a signature is still required exactly where two
> sibling branches need different equations on a signature variable and the result mentions it.

---

## 8. Open questions

1. ~~Does nested refinement need transitive closure?~~ **Refuted [M]** — the recursive-tail case is
   direct unification of flexible tails; no composition needed.
2. H1 in full: does the scoped-label swap commute with head-exposure under a *duplicate label*?
   The probe was never built — this is the concrete missing piece.
3. Does the dual hold for restrictable variants (answers the Flix hook)? The encoding makes it a
   polarity flip, so this should now be cheap.
4. Does shape-preserving update generalise beyond first-occurrence semantics?

## 9. Claims not to publish

Superseded wording that the measurements contradict — listed so they don't creep back in:

- escape as a **blanket rejection** (it is two-tier; the blanket version refuses the canonical
  evaluator);
- "**witnesses lack principal types**" (the measurement is the **opposite** — see §7.4);
- the pre-binder P-probe error strings as *current* behaviour (option B changed them to
  "annotation is too general"; cite the binder'd fixtures for rigid-row facts);
- "the surface has **no closed empty row**" (`{}` exists and works — §6);
- "**OCaml forbade** the combination" unqualified (the defensible version is the *idiom with
  empirical failure modes* account, §1.1);
- the old `rowgadt_escape` error string (the fixture was reshaped to the tail-escape wording);
- "one missing combinator" / "a wiring job" / "derivable only by composition" — three diagnoses of
  mine that the code refuted. Each is recorded where it was refuted, not here.

**Added after the CORELINKS/Koka check** (`handoff-rowgadt-lit2`):

- "**presence polymorphism is new**" — CORELINKS (TLDI 2012) and Castagna & Peyrot (OOPSLA 2025)
  both refute this.
- "no prior work says **which row operations are safe**" — needs the qualifier **"under
  refinement"**. CORELINKS does answer the coarse version (type insert/update by quantifying a
  presence variable); what is absent is the refinement-relative answer.
- "**rows and GADTs are never combined**" (unqualified) — the OCaml bullet above already covers why
  this is wrong.
- Any claim that our rows have **distinct** labels: they don't — scoped-label duplicates are legal
  and are the source of H1. CORELINKS's rows *are* distinct, so the contrast is the reverse.

**Added after the full survey** (`handoff-rowgadt-lit3`; all [M] against retrieved primary text):

- "**Insertion is untypable in row systems**", or any hint that R-UPD-INS's rejection is a
  *discovery*. Rémy 1994 types unrestricted extension **unconditionally**; Gaster & Jones under a
  *lacks* predicate; CORELINKS by quantifying presence. Ours exists **only relative to an active
  branch-local equation** — frame it as a deliberate trade.
- "**Record update is nominal-only in prior work**" — Rémy types update-as-extension, Gaster & Jones
  restrict-then-extend, Links derives remove-then-extend. Our novelty is *domain-preserving by
  construction*, not being typable at all.
- "**Wand's concatenation is the only prior loss of principality in records**" — Wand 1989 loses it
  for concatenation and compensates with *finite complete sets of types*. Same casualty, different
  trigger; do not conflate.
- "**No one has considered record operations under local assumptions**" — OutsideIn(X)'s implication
  constraints and HMG(X) are *generic* local-assumption frameworks. The accurate claim: no
  published **instantiation** of either targets a row/record theory.
- "**GADT inference frameworks cannot state the problem**" *without naming the framework* —
  OutsideIn(X) cannot (its grammar lacks rows); HMG(X) *could in principle* (it is parameterised
  over X) but never instantiates X with rows. Say *"has not been instantiated"*, not *"cannot"*.
- "**The 2025–26 state of the art ignores principality**" — omnidirectional inference (2026) is
  precisely about restoring it for fragile features. Cite it; do not imply the field is standing
  still.
- Using **Rémy's System Π\* presence variables** to claim he "almost had" refinement — Π\*'s flags
  are **quantified** (∀), not assumed by a branch. Presence polymorphism is *abstraction*, the
  opposite direction from our refinement.

**Added after the exhaustiveness/refutation and position-directed-rigidity work (2026-10-05):**

- "**Withe has no exhaustiveness or refutation checking**" — **FALSE** (commit 36b93d0). Both exist
  and work. Any earlier text saying otherwise is superseded.
- "**Refutation is unconditional**" — false. It fires only where the scrutinee index is **concrete or
  binder-rigid**; a bare flexible index must not be concretised (that bug accepted a partial
  function). State the condition.
- "**A `case` omitting an arm is a runtime failure**" — no longer; a missing *possible* arm is a
  **compile-time** error.
- "**Position-directed rigidity removes the need for the `type a.` binder**" — **overstated**. The
  measured delta is narrow: the bare HList `hget` was the one shape where the binder was genuinely
  forced; bare `select`/`eval` already compiled clean, and `rowgadt_l3ii` does **not** flip because
  its `select` is *unsignatured*. The gain is structural (it closes a bug class), and it does **not**
  move §7.4's principality boundary.
- "**Nested constructor patterns are rejected**" — false since the branch-mode `peelCtor` change.

---

## 10. Status

**Brief's immediate next steps**

- [x] **1. Literature** — `handoff-rowgadt-lit`. Gap documented; no prior work puts a row variable
      under branch-local GADT refinement, and the closest evidence is OCaml's *idiom with empirical
      failure modes* (§1.1).
- [x] **2. Typing rules** — `handoff-rowgadt-plan`, restated against the artefact in §7.
- [x] **3. A program requiring all three** — §3, the `Has`/`select`/`setX` witness. Premise holds.
- [~] **4. Write-up** — §1–§9 drafted here; §7 is the metatheory. The dual / restrictable-variants
      separation (novelty objection 3) is still open.

**Plan's implementation steps**

- [x] **1–3.** Per-ctor result syntax; the equation store; branch-local refinement (capture/restore).
- [x] **4a. Migration** — `taskCtorResults` is **deleted** (0 references); `Runtime.elm`'s
      constructors carry their true results in source (`TaskExec a : Task x (Int, String, String)`).
      Proven by **two independent oracles**: the inferred `Runtime.Task*` ctor schemes are
      byte-identical before/after (30/30) *and* the full 149-artifact corpus batch is
      byte-identical to the pre-migration baseline.
- [x] **4b. `runTask`: clean NEGATIVE.** `runTask` **stays trusted** — and now for a *measured*
      reason rather than the old guess. **[M, CORRECTED — the original "29 of 30" was
      fail-fast]** **25 of its 30 branches check honestly, not 29.** Removing `runTask` from
      `trustedBodies` reports exactly *one* error (`TaskExec`, `Runtime.elm:222:29`) and **stops**;
      masking each failure to reveal the next gives **five**:
      * `TaskExec` — the existential cast `a ~ List a` (payload typed `a`, absent from the result);
      * `TaskNow` — `Ok 0` is a number literal that hits `FlexConflict` (`number` vs rigid `a`)
        **before** the rigid-var discharge can fire;
      * `TaskQuit` and `TaskGuiPoll` — un-annotated nullary ctors (`Ok ()` vs the abstract index
        `a`); **these two are the ones the `taskCtorResults` docstring deliberately left
        generalized — design, not defect**;
      * `TaskStat` — the result is a **closed record**, and `dischargeType` refuses *any* `TRecord`
        body: the Tier-R over-approximation biting a legitimate type equation.
      The old comment's stated condition ("until the per-ctor result table can drive a checked
      interpreter") was met and turned out **not to be sufficient**. The honest fix for the cast is
      a surface change to the payload (`List a`), not more type theory. Comment updated at
      `Builtins.elm:365-379`.
- [ ] **5.** P/Q principality fixtures and the H1/H2 lemma probes. `rowgadt_l3{i,ii,iii}` covers the
      measured principality table; the **duplicate-label H1 probe is the concrete gap**.

**Out-of-plan work** (not in the original plan; all [M] verified)

- **Result-side discharge** — the two-tier rule (§7.2). The blanket-rejection predecessor refused
  the canonical evaluator, which is what forced the split.
- **The `type a.` surface (option B)** — bound ⇒ rigid; unbound ⇒ flexible + too-general police.
- **Rigid constructor existentials** — witness GADTs and heterogeneous containers (`rowgadt_het`).
- **The witness-encoded HList**, including the recursive case (`rowgadt_hget`) — plan risk R1
  **refuted**: no equation composition is needed.
- **Nested-pattern refinement** — `peelCtor` now routes ctor sub-pattern unification through branch
  mode inside a case branch, so a pattern nesting one constructor inside another (the external FSM
  source's actual shape) uses branch-local refinement. Lambda/let/function-argument patterns keep the
  global path. (`rowgadt_fsm_nested`.)
- **Compile-time exhaustiveness AND refutation** — `Type/Exhaustive.elm`. A `case` omitting a
  *possible* arm is now a compile error; an arm *impossible* under the branch equations is refuted
  and not required. Refutation fires only where the scrutinee index is **concrete or binder-rigid**;
  a bare flexible index must never be concretised to refute a sibling — doing so accepted a partial
  function (fixed; `refutbare`). GADT-ness is classified **per-file**, so a cross-module GADT index
  degrades to the old flexible behaviour (safe). (`adtgaps`, `refutpos`, `refutneg`.)
- **Position-directed rigidity** — a variable at a **GADT index parameter** position is rigid in a
  signature whether or not the surface binds it (`Env.collectGadtNames` / `gadtIndexVars` →
  `Scheme.bound`); plain type constructors and locals keep flexible variables, so inference is
  unaffected. Measured delta, honestly: narrow — the bare **HList `hget`** was the one shape where
  the binder was genuinely forced, and it now checks (`rowgadt_hget_bare`); the bare `select`/`eval`
  forms already compiled clean before (per-branch `liftRefinedIndicesM`), and `rowgadt_l3ii` does
  **not** flip (its `select` is *unsignatured*, which a signature-directed rule cannot reach), so
  §7.4's principality boundary does not move. The gain is structural: it closes the recurring
  "should-be-rigid variable treated as solvable" bug class systematically rather than per-case.
- Gate `PASS=151`; 25 `rowgadt_*` fixtures (13 `compile_clean`, 25 `compile_error` entries); all pre-existing corpus artifacts byte-identical (149 = 149).

