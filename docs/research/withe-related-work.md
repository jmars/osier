# Withe — related-work survey (the feature-pair map)

Full literature survey for the Withe paper, consolidating passes `handoff-rowgadt-lit` (8 works +
neighbours), `handoff-rowgadt-lit2` (CORELINKS + Koka), and this pass (`handoff-rowgadt-lit3`),
plus a targeted retrieval (2026-10-05, no handoff slug) that read the **full extended text** of
Toohey et al POPL'26 and upgraded its entry (§1 row, §2 quote entry, §3 table row, §4 item 6,
§6 bullet; §2 line numbers below the entry shifted by that insertion),
and a further retrieval (2026-10-06, `handoff-withe-lit`, gap G7) that read the author's PDF of
Chen & Erwig POPL'16 and upgraded its entry (§1 row, §2 quote entry, §3 table row; §5 item 2
resolved; line numbers below the §2 insertion shifted accordingly).
Organised by **which pair of features is combined** — that organisation is itself the paper's
contribution to related work. Claims are marked **[M]** measured (read from the primary source,
URL given) / **[I]** interpretation / **[P]** projection. Second-hand items are flagged
**[SECOND-HAND]**; unretrieved items are listed in §5 with what each would settle.

Working notes; not a bibliography yet. Companion files: `row-gadt.md` (§1.1 positioning, §9 claims),
`row-gadt-calculus.md` (§7 metatheory).

---

## 1. The feature-pair map

Three features: **R** = row polymorphism (extensible records/variants), **G** = GADTs
(branch-local type refinement), **A** = locally abstract types / explicit polymorphism
(`type a.`, rigid vs flexible variables). Cells list the works that combine the pairs.

| Work | Pairs combined | Mechanism | What it omits about the third feature |
|---|---|---|---|
| **Remy 1994** (RR-1431/MS-CIS-90-73; MIT Press TAOOP ch.) **[M this pass]** | R (+presence flags) | Sorted equational theory; record extension of a free algebra; `pre(t)`/`abs` field types; `new_a : Π(a:φ;$) → α → Π(a:pre(α);$)` types **unrestricted extension** always | **No G, no A-seat**: no equations at branches, no rigid variables; GADTs did not exist yet. Strictness of extension is a *parameter* of the primitive's type, not a discipline |
| **Wand 1989** (LICS; concatenation) **[M this pass]** | R (concatenation!) | Records as partial functions over finite label set; concatenation typed by a **disjunction of equations**; **no principal types** — finite complete sets instead; kind `Extension` with only extension vars + `empty` | **No G** (1989); no `A` beyond ordinary ML polymorphism. Concatenation costs principality — the first measured instance of that trade |
| **Gaster & Jones 1996** (NOTTCS-TR-96-3) **[M this pass]** | R (+variants) | Qualified types over rows; **lacks predicates `r\l`** on every extension/update; ops: select, restrict, extend, update, rename, first-class labels | **No G**; extension is **strict** (requires `r\l`) — Remy's *unrestricted* variant is deliberately given up for simple inference + compilation |
| **Ohori 1995** (TOPLAS) **[M this pass]** | R | **Kind restrictions instead of row variables**: "instead of using row variables, we base our development on … placing restrictions on possible instantiations of type variables"; kinded quantification `∀t::k.τ`; `modify(e1,l,e2)` polymorphic update | **No G**; explicitly *not* a row-variable system, so there is no row variable to refine — the seat itself is absent |
| **Leijen 2005** (TFP, scoped labels) **[M, lit]** | R (+HM, MLF, qualified) | New type equality `~=` with `eq-swap` for **distinct** labels → duplicate labels legal and retained; row-unification with termination side-condition; sound+complete | **No G, no refinement, no local equations anywhere** — the paper predates the GADT-inference era; omission is total (no future-work sentence exists) |
| **CORELINKS** (Lindley & Cheney TLDI'12) **[M, lit2]** | R + presence polymorphism (+effects) | `(label × presence × type)` rows with **distinct** labels; presence **variables** `θ`; insert/update/delete typed by quantifying over presence in the *needed row*: "presence … is unconstrained as we can infer nothing about it solely from an insert or update operation" | **No G**: no equations on rows, no rigid row variables, no branch-local store. Its branch rule *flips a presence flag* on a variant's default branch — nearest published neighbour in one dimension, different mechanism |
| **Koka** (Leijen MSFP'14) **[M, lit2]** | R for **effects** | Effect rows with **duplicate labels** (from Leijen'05); eliminations **unify** the effect row variable (`catch` unifies `μ` with `(exn|μ′)`), never refine | **No G, no A**: pure HM rules; no type equalities, no existentials, no `type a.` binder, no skolems; paper never mentions GADTs |
| **Castagna & Peyrot OOPSLA'25** **[M, lit]** | R + presence + set-theoretic types | Semantic subtyping + tallying; field-type variables over `t ⊔ ⊥` give presence polymorphism ("first to allow presence polymorphism over optional fields"); **explicit** polymorphism | **No G**: "type cases, guards, or type narrowing … seem mostly orthogonal to the introduction of row polymorphism" — refinement explicitly bracketed |
| **Paszke & Xie TyDe'23** (infix-extensible records) **[M this pass]** | R (records for tabular data) | Row-polymorphic record calculus with infix extension; equality constraints over types, rows, labels | **No G**: zero GADT/refinement/equation-at-branch mentions (grep-measured on the retrieved PDF) |
| **Spanò 2024** (arXiv 2406.11750) **[M this pass]** | R + overloading | Reversible conversion records ↔ overloading constraints | **No G**: zero GADT/refinement mentions (grep-measured) |
| **Toohey, Chen, Jamalzadeh & Xie POPL'26** (extensible data types + classes; full extended text read 2026-10-05) **[M, lit + retrieval]** | R + ad-hoc polymorphism | Row types + **dictionary-passing elaboration** of type classes; `All` constraints (a property across all fields), `ind` (**fold over rows**), `Split`, `Lift`, **row commutativity annotations** + a commutativity hierarchy; row theory **parameterised** (validity check / commutativity predicate / constraint solver, per Morris & McKinna) — i.e. a plug-in door; target `F⊗⊕ω`; **proofs mechanized in Lean 4** | **No G, and no refinement**: zero occurrences of `GADT`/`GADTs`/`refine`/`refinement`/`branch` in the full 38-page extended text (grep-measured). But the omission is *specifically* refinement — `All` + `ind` already deliver **generic operations across any row**, so structural dispatch over rows is theirs, not ours |
| **Hubers et al 2025** (extensible recursive functions) **[M, lit]** | R (variants) | Row-typed histomorphisms; results vary with inputs via row constraints on return types | **No G**: zero GADT mentions |
| **Kennedy & Russo MSFP'05** (GADTs meet OO) **[M, lit]** | G + OO | GADT ctor as subclass refining the class type parameter; equational constraints as method pre-conditions | **Rows entirely**: no row variable, no record extension, no presence; refinement vocabulary is nominal class-parameter instantiation |
| **OutsideIn(X)** (JFP'11) **[M, lit]** | G + classes/families (+local let) | Implication constraints `∃ᾱ.(Qgiven ~> Cwanted)`; **touchable vs untouchable** variables; outside-in solving | **Cannot state the problem**: type grammar `τ ::= tv \| Int \| Bool \| [τ] \| T τ` — no record type, no row variable, no presence. X is first-order equalities only |
| **Stratified inference** (Pottier & Régis-Gianas POPL'06) **[M this pass — was SECOND-HAND]** | G | Two-pass: **shape inference** (rigid info propagated through annotations) then constraint solving; rigid `ᾱβ̄` vs flexible `γ̄` convention; annotations' meaning can depend on equation set E | **Rows never appear as types**: "row" occurs only as English ("error …", table rows); equations are first-order tree equalities; no record/presence machinery |
| **Wobbly types** (PJS+Vytiniotis+Weirich+Washburn ICFP'06) **[M this pass — was SECOND-HAND]** | G | **Rigid vs wobbly** annotation modifiers in the environment; lexically scoped type variables; unification with per-annotation rigidity; "exploit programmer-supplied type annotations to make the type inference task almost embarrassingly easy" | **Rows absent**: `σ ::= ∀a.τ`, monotypes "entirely conventional"; "row" does not occur in the paper (grep-measured); no records as types |
| **Simonet & Pottier 2007** (HMG(X), TOPLAS) **[M this pass — was SECOND-HAND]** | G (generic framework) | Constraint-based HM(X) extended with guarded ADTs; every branch typechecked "under different assumptions about the type variables in scope"; tractable-constraint restriction; soundness proved | **Rows not instantiateable**: types are `→` + algebraic data constructors `ε(τ̄)`; the only Rémy cite is ML-ART (objects), not the record theory; no row/presence instantiation of X is given |
| **Ambivalent types** (Garrigue & Rémy APLAS'13) **[M, lit]** | G + A | `ν(a).M` introduces rigid var → quantified flexible at scope exit (the formal `type a.`); ambivalent types `ψ_α` = set of raw types sharing one flexible label; **scoped equations**: `a ~ int` may not leak out of branch | **No R**: source types `τ ::= α \| a \| τ→τ \| eq(τ,τ) \| int` — the grammar cannot state `ρ = {l:t\|ρ′}`. Their 2012 abstract records the OCaml restriction of rows+GADTs (see §2) |
| **Chen & Erwig POPL'16** ("Chore", choice types) **[M this pass — was SECOND-HAND]** | G | Branch refinements represented by **choice types** `D⟨φ̄⟩` (dimension-name-synchronised alternatives); typing separated from **reconciliation**, which replaces choices by *type index variables*; "Principality comes at the price of having choice types in the type language" | **No row seat at all**: grammar `τ ::= α \| τ→τ \| T τ`, `φ ::= τ \| D⟨φ̄⟩ \| φ→φ \| T φ` — no record type, no row variable, no presence; "record"/"field"/"label" never occur, "row" only inside "arrow" (grep-measured) |
| **OCaml** (`type a.` + GADTs + objects/poly-variants) **[M, lit + this pass]** | G + A + R-as-idiom | Locally abstract types are rigid inside, flexible at exit; GADT match adds equations to non-local abstract types too; **but**: GADT invariance on object type parameters; poly-variant patterns block refinement entirely | **The combination is an undocumented idiom with failure modes**, not a discipline: "the interaction of row variables and GADTs is not well specified" (octachron 2024, §2); no published account of which record operations are safe under an active equation |
| **Garrigue & Rémy 1999** (semi-explicit polymorphism) **[M this pass]** | A | Polytypes `[σ]` with **label variables ε**; unification distinguishes user-provided from guessed polytypes; `#point` = `⟨x:int;y:int;ρ⟩` "contains a **hidden row variable that is polymorphic**" | **No G** (1999); but the mechanism that *protects* a row variable from unification (label-quantified polytypes) existed in the same authors' toolbox — the seat for `type ρ.`-style protection predates GADT inference |
| **Leijen HMF 2008 / HML 2009** **[M this pass]** | A (first-class/higher-rank) | Conservative extension of HM with first-class polymorphism; regular System F types | **No R, no G**: zero row/record occurrences in HMF (grep-measured); GADTs untouched |
| **Scherer-line: Omnidirectional inference** (O'Brien, Rémy, Scherer, arXiv 2511.10343, v2 2026) **[M this pass]** | A + principality-restoration | **Suspended match constraints**: solving may proceed in any order, suspending until information arrives; applied to record-label overloading and semi-explicit polymorphism; "more expressive than OCaml's current typechecker" | **G = explicit future work**: "our omnidirectional recipe could provide a declarative specification: one capable of being principal and complete for GADTs, and we would be interested in studying this application." **Rows**: only as discussion of SML's structural-record overloading; the formalization uses **nominal records** `rcd T τ̄` — no row variables |
| **Frank** (Lindley et al JFP) **[SECOND-HAND, lit2's Links/CORELINKS context]** | effects + (row-typed) | Effect polymorphism without mentioning effect variables in source; do-blocks | **No G**; records/effects machinery without refinement |
| **Eff / Links** **[SECOND-HAND]** | effects + rows | Effect rows; Links' full language adds subtyping via upcasts; record update **derived** (remove+extend or CPS+upcast), per CORELINKS aside | **No G** in any of them |

**The empty cell.** No work above — and §3 documents the search — puts a **row variable under a
branch-local GADT equation**. The nearest occupants of adjacent cells, in decreasing proximity:

1. **OCaml** — has all three features in one compiler; the combination *works as an idiom* but is
   "not well specified" (octachron 2024 [M]) and was *restricted* in its first implementation
   (Garrigue & Rémy 2012 [M]); refinement of a poly-variant row is impossible in a match, and
   object row variables must be kept "far away from GADT equations" [M, lit].
2. **CORELINKS** — asks the adjacent question (what must an operation know about which fields are
   present?) and answers by **quantifying presence**; no equations, no rigidity, no branch-local
   anything [M, lit2].
3. **Flix restrictable variants** — refines a *label-set* index `s` under `choose` while the record
   row index `r` is only ever extended; "interesting future work to explore possible connections
   between restrictable variants and GADTs" [M, lit].
4. **GHC `HasField` on record GADTs** — class-triggered unification; nominal records; no row
   variables [M, lit].
5. **Omnidirectional inference (2025-26)** — restores principality for fragile features and names
   GADTs as the application they'd like to study; nominal records only [M, this pass].

---

## 2. Quote bank (verbatim, with URLs)

Load-bearing sentences only; each was read in the retrieved full text unless marked
[SECOND-HAND]. Glyph normalisations (`’`→`'`, ligatures) noted where applied; no wording invented.

### The rows literature on GADTs — the omission sentences

- **Leijen 2005**, *Extensible records with scoped labels*, TFP'05.
  https://www.microsoft.com/en-us/research/wp-content/uploads/2016/02/scopedlabels.pdf
  The paper contains **no occurrence of "GADT", "refinement", or any future-work sentence about
  type indices** [M — grep-measured on the retrieved PDF, lit pass]. The omission is total, which
  is itself the positioning datum. Closest formal statement of scope:
  > "We only define a new notion of equality between (mono) types and present an extended
  > unification algorithm. This is all completely independent of a particular set of type rules."

- **Remy 1994**, *Type inference for records in a natural extension of ML* (UPenn MS-CIS-90-73
  copy = RR-1431).
  https://repository.upenn.edu/bitstreams/82820b99-74b8-4a44-bd03-0de4b3a91030/download
  No GADT/refinement sentences exist (the paper predates them); the load-bearing content is the
  **operation set** (§2-Remy below). On what the solution does **not** give:
  > "But we do not provide an and construction." (sec 3.1, on record concatenation)

  and on the deliberate flexibility of strictness:
  > "asserting that new_a has the principal type [with `abs` in place of `pre(α)` in the argument]
  > will make the extension of a record with a new field possible only if the field was previously
  > undefined. This slight change gives exactly the strong restriction that appears in both
  > attempts to solve Wand's system [JM88, OB88]."

  and on the known weakness:
  > "This is really a weakness, for the program #(choice car truck).name;; … may actually be
  > useful. We will give a partial solution to this problem, and suggest a full but expensive
  > one." (sec 3.2)

- **Wand 1989**, *Type inference for record concatenation and multiple inheritance*, LICS'89.
  https://www.cs.tufts.edu/comp/150FP/archive/mitch-wand/types-simple-objects.pdf
  > "We show that this calculus does not have principal types, but does have finite complete sets
  > of types." (abstract)

  > "In this system it is impossible to assign a principal type to the concatenation operator."
  > (sec on Dealing with Concatenation)

  > "It is not possible to state a typing rule for concatenation as an equation in this style,
  > since concatenation has no principal type, but it is possible to express a sound typing rule
  > for concatenation using a disjunction of equations." (ibid.)

- **Gaster & Jones 1996**, *A Polymorphic Type System for Extensible Records and Variants*.
  http://web.cecs.pdx.edu/~mpj/pubs/96-3.pdf
  > "The type system is an application of qualified types, extended to deal with a general concept
  > of rows. Positive information about the fields in a given row is captured in the type language
  > using row extension, while negative information is reflected by the use of predicates."
  > (intro; hyphenation normalised from the PDF's "lan-guage")

  Operation types, verbatim from §3 (their layout, my transcription of the row syntax):
  > "Extension: to add a field l to an existing record: `(l =|) :: (r\l) ⇒ α → Rec r → Rec {|l:α|r|}`"

  > "Update/replace: to update the value in a particular field, possibly with a value of a
  > different type: `(l :=|) :: (r\l) ⇒ α → Rec {|l:β|r|} → Rec {|l:α|r|}`"

  > "Again, it is convenient to introduce abbreviations … `(l1=e1,...,ln=en | r)` …"
  On what update desugars to:
  > `(l := x | r) = (l = x | r − l)` (their equation 2 region)

- **Ohori 1995**, *A Polymorphic Record Calculus and its Compilation*, TOPLAS 17(6).
  https://www.cs.tufts.edu/comp/150FP/archive/atsushi-ohori/record-calc.pdf
  > "Here, instead of using row variables, we base our development on the idea presented in Ohori
  > and Buneman [1988] of placing restrictions on possible instantiations of type variables. We
  > formalize this idea as a kind system of types and refine the ordinary type quantification to
  > kinded quantification of the form ∀t::k.τ where type variable t is constrained to range only
  > over the set of types denoted by a kind k." (intro)

  > "In addition to labeled-field access, kinded abstraction can also be used to represent
  > polymorphic record modification (update) operations modify(e1,l,e2), which creates a new
  > record …" (intro)

- **CORELINKS** (Lindley & Cheney, TLDI'12) — full quote bank in `handoff-rowgadt-lit2`;
  https://homepages.inf.ed.ac.uk/slindley/papers/corelinks.pdf
  > "Unlike most other row type systems, but like Remy's PiML' [22], the type of a label is
  > independent of whether or not it is present. We make essential use of this feature in typing
  > the database update operations."

  > "The presence information is, on the other hand, unconstrained as we can infer nothing about
  > it solely from an insert or update operation."

  > "Dually, the CASE rule refines the type of the value being matched so that in the type of the
  > variable bound by the default branch, the non-matched label is absent."

  > "The basis for our row type system is Remy's PiML' [22]."

- **Koka** (Leijen, MSFP'14) — full quote bank in `handoff-rowgadt-lit2`;
  https://arxiv.org/abs/1406.2061
  > "Our effect rows differ in an important way from the usual approaches in that effect labels
  > can be duplicated … This was first described by Leijen [17] where this was used to enable
  > scoped labels in record types."

  > "the [row variable] will unify with a type of the form (exn | μ′) giving action the effect
  > (exn | exn | μ′) where exn occurs duplicated" — **unification**, not refinement [M].

- **Castagna & Peyrot OOPSLA'25** — https://arxiv.org/abs/2404.00338 [M, lit]
  > "any type system for a dynamic language needs to account for features like pattern matching,
  > type cases, guards, or type narrowing. At first sight, these features seem mostly orthogonal to
  > the introduction of row polymorphism."

  > "To our knowledge, our work is the first to allow presence polymorphism over optional
  > fields."

- **Castagna, Petrucciani, Nguyen ICFP'16** — https://www.irif.fr/~gc/papers/icfp16.pdf [M, lit]
  > "we want to explore the addition of intersection types to OCaml (or Haskell) in order to allow
  > the programmer to define refinement types and check how such an integration blends with
  > existing features, notably GADTs."

- **Flix / Madsen, Starup, Lutze ECOOP'23** —
  https://drops.dagstuhl.de/storage/00lipics/lipics-vol263-ecoop2023/LIPIcs.ECOOP.2023.17/LIPIcs.ECOOP.2023.17.pdf
  [M, lit]
  > "We think it would be interesting future work to explore possible connections between
  > restrictable variants and GADTs."

### The GADT literature on rows — the omission sentences

- **OutsideIn(X)** 2011 — https://lirias.kuleuven.be/retrieve/237824 [M, lit]
  > "An implication constraint is of the form ∃ᾱ.(Q ~> C) where we call the ᾱ variables the
  > touchables of the constraint. These are the variables that we are allowed to unify when
  > solving the implication constraint."

  The word "row" appears only in the operational sense (bullet lists); the type grammar has no
  record type, no row variable, no presence [M — grep-measured, lit].

- **Stratified inference** (Pottier & Régis-Gianas POPL'06).
  https://cambium.inria.fr/~fpottier/publis/pottier-regis-gianas-popl06.pdf **[M this pass]**
  On the mechanism:
  > "A key mechanism is the introduction, at case constructs, of type equations into the typing
  > context. For instance, in the first branch of eval, the variable t, which has type term α, is
  > known to match the pattern Lit i, which, according to the declaration of Lit, has type
  > term int. As a result, the equation α = int must hold within that branch."

  On the price of stratification (a principality-relevant honest gap):
  > "When one writes (x : α), the shape inference systems Wob and Ibis behave exactly as if one
  > had written (x : int). Some valuable information is discarded: perhaps the programmer really
  > intended to tell the system that x is being used at type α, not int. This behavior makes the
  > meaning of a type annotation dependent upon E. As a result, moving a type annotation into or
  > out of a case construct can change its meaning! Yet, it is not entirely clear how to avoid
  > this shortcoming." (§8, discussion)

  **No "row" as a type anywhere**; equations are between first-order trees [M — grep-measured].

- **Wobbly types** (Peyton Jones, Vytiniotis, Weirich, Washburn ICFP'06).
  https://www.cs.tufts.edu/~nr/cs257/archive/simon-peyton-jones/gadt-icfp.pdf **[M this pass]**
  > "Our main technical innovation is wobbly types, which express in a declarative way the
  > uncertainty caused by the incremental nature of typical type-inference algorithms." (abstract)

  > "The language of types is also entirely conventional, stratified into polytypes σ and
  > quantifier-free monotypes τ." (§4)

  > "Types of constructors are always closed and rigid." (§4, on the environment modifiers)

  **Zero "row" occurrences** [M — grep-measured]; no records as types.

- **Simonet & Pottier 2007**, *A constraint-based approach to guarded algebraic data types*,
  TOPLAS 29(1). http://www.normalesup.org/~simonet/publis/simonet-pottier-hmg-toplas.pdf
  **[M this pass — was flagged SECOND-HAND]**
  > "Guarded algebraic data types … have the distinguishing feature that, when typechecking a
  > function defined by cases, every branch may be checked under different assumptions about the
  > type variables in scope." (abstract region)

  > "To the best of our knowledge, this is the first generic and comprehensive account of type
  > inference in the presence of guarded algebraic data types." (intro region, RR version)

  No row/presence instantiation of X; types are arrows + algebraic data constructors
  `ε(τ̄)` [M — read]. The only Rémy citation is ML-ART 1994 (objects) [M — reference list read].

- **Chen & Erwig**, *Principal type inference for GADTs*, POPL'16.
  https://web.engr.oregonstate.edu/~erwig/papers/TypeInfForGADTs_POPL16b.pdf
  **[M this pass — was SECOND-HAND]** (author's version, retrieved 2026-10-06 from Erwig's
  publications page; ACM DL remains CAPTCHA-blocked). Glyph normalisations: PDF-extraction
  hyphenations joined ("sys-tematically"→"systematically"), arrows/brackets render as `→`/`⟨⟩`,
  the bar over `φ` in Fig. 2 is lost by extraction; no wording invented.
  On the mechanism:
  > "Our method is based on the idea to represent type refinements in pattern-matching branches
  > by choice types, which facilitate a separation of the typing and reconciliation phases and
  > thus support case expressions." (abstract)

  > "Here D gives a name to control the variation between two types. All variations under the
  > same name are synchronized in the sense that the same decision should be made about
  > choosing variants." (§1)

  The type grammar (Fig. 2): `Monotypes τ ::= α | τ → τ | T τ`; `Variational types φ ::= τ |
  D⟨φ̄⟩ | φ → φ | T φ`; `Type schemas σ ::= φ | ∀α.φ`.

  **It cannot express a row refinement**: the grammar has no record type, no row variable, no
  presence; "record", "field", "label" never occur, and "row" occurs only as a substring of
  "arrow" (grep-measured on the retrieved PDF). Refinement is carried entirely by ordinary GADT
  type-constructor parameters — reconciliation's replacement targets must live inside them:
  > "The overall idea is to systematically replace choices by type variables. However, such type
  > variables must at least appear inside of GADT type constructors, which in turn must be used
  > as function arguments." (§3.4)

  And the principality price, stated by the authors:
  > "Principality comes at the price of having choice types in the type language. If we want to
  > get rid of choice types, we lose principality during reconciliation that converts variational
  > types to plain types." (§5)

  Whether the choice mechanism would transfer to a grammar *extended* with rows is undiscussed
  in the paper [I].

- **Ambivalent types** (Garrigue & Rémy APLAS'13) —
  http://gallium.inria.fr/~remy/gadts/Garrigue-Remy:gadts@aplas2013.pdf [M, lit]
  > "a rigid variable, treated in a special way in OCaml as it can be refined by GADT pattern
  > matching."

  > "Surprisingly, GADTs may not play well with other features of the language: in our first
  > implementation of GADT in OCaml [1], we had to restrict the use of object types and
  > polymorphic variants in combination with GADTs, to prevent local equations from breaking the
  > invariant that the same row variable may only appear in two record types that are equal."
  (their 2012 3-page abstract, *Tracing ambiguity in GADT type inference*,
  http://gallium.inria.fr/~remy/gadts/Garrigue-Remy:gadts@abs2012.pdf [M, lit])

- **Kennedy & Russo MSFP'05** —
  https://www.microsoft.com/en-us/research/wp-content/uploads/2016/02/gadtoop.pdf [M, lit]
  > "adding the constraint where T=Pair<C,D> to the signature of TupleEq would allow us to
  > restrict its callers" — equational constraints as method pre-conditions; **rows never appear**
  [M, lit].

- **GHC `HasField`** on record GADTs —
  https://downloads.haskell.org/ghc/latest/docs/users_guide/exts/hasfield.html [M, lit]
  > "the solver will reduce the constraint HasField unGadt (Gadt t) b by unifying t ~ [v] and
  > b ~ Maybe v for some fresh metavariable v, rather as if we had an instance."

### OCaml on the combination — the maintainer record [M, this pass + lit]

- **octachron** (OCaml maintainer), discuss.ocaml.org, thread 13718, Jan 3 2024.
  https://discuss.ocaml.org/t/unable-to-refute-impossible-gadt-pattern-with-polymorphic-variants/13718
  > "First, as a general remark, the interaction of row variables and GADTs is not well specified.
  > Thus it is common to hit hard to understand behaviour, and nothing is guaranteed beyond the
  > fact that the currently implemented interaction is safe."

  > "The issue is that GADTs work by adding equations, and those equations interact poorly with
  > polymorphic variant constraints. In particular, GADT equations cannot narrow a polymorphic
  > variant constraint."

  The workaround he sketches uses **object types as type-level records** — each *field* of the
  object gets its own row variable (`<tag:[`initial]; initial:yes; terminal:no> as 'a`), so no
  single row variable is ever refined. That is the exact shape of the gap: OCaml practitioners
  route *around* row refinement by per-field rows, exactly what our `Has` witness does *inside*
  one row [I].

- **gasche** (OCaml maintainer), same thread, Dec 27 2023:
  > "Matching on a GADT adds type equalities to the typing environment. Those equalities can be
  > used in the right-hand-side of the pattern, and also 'to the right' of the pattern where they
  > were introduced. You are right that this is a left-to-right bias in the type-checker, but note
  > that this is not related to type inference per se (guessing types), it is part of the typing
  > rules that even a fully-explicit version of OCaml would respect."

- **ocaml/ocaml issue #5724** [M, lit]:
  > "This is a documented limitation of GADTs: types cannot be refined if a pattern-matching
  > contains polymorphic variant. This comes from the fact polymorphic variant pattern-matching
  > typing is specified in the absence of type propagation and GADT type refinement requires type
  > propagation."

- **octachron**, thread 14042 [M, lit]:
  > "GADTs are incompatible with object subtyping: they are always invariant with respect to their
  > type parameters."

  > "the brittleness of the last point is the reason why using object type is often better than
  > polymorphic variant for this use case, since object types makes it easier to not introduce
  > long-lived row type variable that will clash later with a GADT equation."

- **The OCaml manual** (`type a.`, GADTs) [M, lit]:
  > "GADT pattern-matching may also add type equations to non-local abstract types. The behaviour
  > is the same as with local abstract types."

  > "Namely, builtin types (those defined by the compiler itself, such as int or array), and
  > abstract types defined by the local module, are non-instantiable, and as such cause a type
  > error rather than introduce an equation."

  UNRETRIEVED: a manual section documenting the objects/poly-variants+GADT restriction — no such
  section found in lit or this pass.

### Remy 1994 — the must-retrieve answer (the R-UPD-INS trade)

**[M] Primary source retrieved this pass** (UPenn bitstream = MS-CIS-90-73, Oct 1990, the
preprint of the 1994 MIT Press chapter; content matches the abstract both CORELINKS and Koka
cite). Two typing systems in the paper:

- **System Π** (finite labels, §1): record types as `Π(field₁, …, fieldₙ)` over the *whole* label
  universe, `field ::= pre(τ) | abs`; primitives
  `null : Π(abs,…,abs)`, `extract_a : Π(γ,…,pre(a),…,γₙ) → a`,
  `new_a : Π(γ,…,γᵢ,…,γₙ) → a → Π(γ,…,pre(a),…,γₙ)`.
- **System Π′** (denumerable labels, §2): the same primitives over the record extension of a
  sorted free algebra; §3.3's **System Π\*** adds presence *variables*: `abs(α)` with α quantified,
  giving every field a distinct flag variable — this is the presence polymorphism CORELINKS
  inherits ("like Remy's PiML'" [M, CORELINKS]).

**The question the retrieval had to decide: does PiML′ support UNRESTRICTED field extension /
is insertion always typable? — YES. [M]**

The abstract says it outright:
> "All operations on records introduced by Wand in [Wan87] are supported, in particular the
> **unrestricted extension of a field**, and other operations such as renaming of fields are
> added."

The body defines the two extension kinds:
> "To distinguish between the two kinds of extensions of a record with a new field, we will say
> that the extension is **strict** when the new field could not be previously defined and
> **unrestricted** otherwise." (§1)

and demonstrates both directions with the running example [M]:
> `let driver = {person with vehicle = car};;` — field previously undefined
> `let truck-driver = {driver with vehicle = truck};;` — "As above, the operation is not a
> physical replacement of the vehicle field by a new value. We do not wish any constraint
> between the types of the old and the new values of the vehicle field."

i.e. Remy's `with` is **shadowing-style insertion**: it never requires the field present (that
would be strict), and it imposes **no constraint between old and new field types**. The
primitive `new_a`'s scheme `Π(a:φ;$) → α → Π(a:pre(α);$)` types extension **unconditionally** —
there is no lacks predicate, no presence constraint, nothing to check. (Contrast Gaster & Jones'
`(l =|) :: (r\l) ⇒ …`, which makes the same operation *strict* by fiat [M, this pass].)

Remy explicitly notes strictness is a **dial, not a discovery** [M]:
> "asserting that new_a has the principal type [with `abs` in place of `pre(α)` in the argument]
> will make the extension of a record with a new field possible only if the field was previously
> undefined. This slight change gives exactly the strong restriction that appears in both
> attempts to solve Wand's system [JM88, OB88]. Weakening the type of this primitive may be
> interesting in some cases, because the restricted construction may be easier to implement, and
> more efficient."

**And record concatenation (`and`) is NOT provided** [M]:
> "But we do not provide an and construction." (§3.1)

— so Remy types unrestricted *single-field extension* but not concatenation; Wand 1989 types
concatenation at the cost of principality ("does not have principal types, but … finite complete
sets of types" [M]).

**What this settles for the paper (the R-UPD-INS framing):**

- **Our R-UPD-INS rejection is a DELIBERATE TRADE, not a discovery. [I, now grounded [M]]**
  Unconstrained insertion is typable in the rows-only world — Remy's Π/Π′ types it always,
  Gaster & Jones type it under a lacks predicate, CORELINKS types it by quantifying presence
  over the needed row. Our rule rejects insertion *only when a branch-local equation is active
  on the base's row tail* (`row-gadt-calculus.md` R-UPD-INS: "insertion … never consults the
  store … rejected outright"). The trade is: soundness of refinement (an insertion can change
  the domain, letting a domain change escape the branch) vs the expressiveness Remy gives for
  free. Section 1.1 and §7 of the calculus must state this as "we give up Remy's unrestricted
  extension **under an active equation**, to keep refinement sound", and must NOT present
  "insertion is rejected" as a novel boundary — the boundary exists only relative to refinement.
- **The deeper symmetry [I]: Remy's own system already shows principality forcing his hand.**
  His stated weakness is `#choice car truck` failing on a `Pre`/`Abs` collision — merging
  records with different field sets breaks under ML generic polymorphism, and his remedy is
  presence *variables* (System Π\*), i.e. more quantification, never equation-scoping. The
  rows-only literature answers every "what may this field be?" question with **quantify**
  (presence flags, lacks predicates, kind restrictions) — there is no branch-local assumption
  anywhere in the lineage, which is exactly why our cell stayed empty.

### Two-tier update lineage [M, this pass — fills the lit gap on "how do others type update?"]

The three published treatments of record update, all rows-only, all different from ours:

1. **Remy Π/Π′**: `{r with a = x} = new_a r x` — extension is unrestricted; update is just
   extension (shadowing; "no constraint between the types of the old and the new values").
2. **Gaster & Jones**: `(l :=|) :: (r\l) ⇒ α → Rec {|l:β|r|} → Rec {|l:α|r|}`, defined as
   `(l = x | r − l)` — restrict-then-extend under a lacks predicate; update is polymorphic in
   the new type α. Their rows have **no duplicates** (an invariant), so restrict+extend is exact.
3. **CORELINKS/Links**: record update is a **derived** operation ("The full version of Links also
   includes an operation to remove labels from a record, which allows one to define a record
   update operation that does not require the label to be absent"), or CPS + upcast [M, lit2].

Our R-UPD differs from all three in the *direction that matters under refinement*: it is
**domain-preserving by construction** (scoped-label first-occurrence replace, §4 of
`row-gadt.md` [M]), so under an active equation `ρ̂ ~ {l:t|ρ′}` it discharges **without touching
the domain** — no lacks predicate, no presence variable, no quantifier. That is the positive row
result, and it is now positioned against three named alternatives rather than a vacuum.

### 2025-26 additions [M, this pass]

- **O'Brien, Rémy & Scherer, *Omnidirectional type inference for ML: principality any way***
  (arXiv 2511.10343, v2 May 2026). https://arxiv.org/abs/2511.10343
  > "We present omnidirectionality as a general framework for inference in the presence of
  > fragile features. While this paper instantiates our framework for two concrete features in
  > OCaml [static overloading of record labels and datatype constructors; semi-explicit
  > first-class polymorphism] …" (abstract region)

  > "We believe that our omnidirectional recipe could provide a declarative specification: one
  > capable of being principal and complete for GADTs, and we would be interested in studying
  > this application." (§7, related work on OutsideIn)

  On records/rows:
  > "SML employs row variables to support overloaded fields for structural records, while GHC
  > uses qualified types to allow overloading of nominal record fields" (§Discussion)

  but their own formalization uses **nominal records** `rcd T τ̄` — no row variables in the
  calculus [M]. **Threat assessment: none to the headline; one to a lazy sentence.** It does not
  refine anything (it *restores principality* by reordering constraint solving); but if §1.1
  says "GADT inference frameworks cannot accommodate records", this paper shows people are
  actively building the neighbouring infrastructure (suspended constraints that could host row
  equations). Cite as: the 2026 frontier knows principality is the casualty and is rebuilding
  inference around it — without rows.

- **Fan, Xu & Xie, *Practical Type Inference with Levels*** (PLDI'25).
  https://sec-r.github.io/papers/pldi25level.pdf
  > "Other advanced datatype features (e.g. GADTs) would require further extensions (§8)."

  Levels implement touchability/untouchability in GHC and OCaml; GADTs explicitly deferred.
  Useful to us as: the *implementation* vocabulary (levels) for what our calculus calls R
  (rigid ids) and OutsideIn calls touchables — cite when discussing the discharge discipline's
  implementability.

- **Practitioner demand, 2023-24 [M]:** the discuss.ocaml.org threads (13718 FSM modelling,
  11573 constrained locally abstract types) show users *currently* hitting the row×GADT
  boundary and receiving workarounds ("the fix is simply to swap the order of the arguments to
  the constructor" — zbaylin's accidental discovery of the left-to-right equation bias; octachron's
  object-type encoding). This is the "undocumented idiom with empirical failure modes" account of
  `row-gadt.md` §1.1, now with fresh primary evidence and URLs.

- **Toohey, Chen, Jamalzadeh & Xie, *Extensible Data Types with Ad-Hoc Polymorphism (Extended)***
  (POPL'26; Proc. ACM Program. Lang. 10, POPL, Article 20, Jan 2026; 38pp extended version).
  https://xnning.github.io/papers/popl26extensible-appendix.pdf
  **[M — full extended PDF retrieved 2026-10-05]**. Retrieval note: the ACM DL landing page
  (`https://dl.acm.org/doi/10.1145/3776662`) is CAPTCHA-blocked; the author's extended version is
  the retrieved artifact, so any wording quoted here is the *extended* text. This is the nearest
  neighbour to the **rows + type-classes** cell, and it is the paper that must be cited *against*
  any future claim of that cell:
  > "This paper proposes a novel language design that combines extensible data types, implemented
  > through row types and row polymorphism, with ad-hoc polymorphism, implemented through type
  > classes. … We formalize our design in a source calculus λ⇒ρ, which elaborates into a target
  > calculus F⊗⊕ω. We prove that the target calculus is type-safe and that the elaboration is
  > sound, thus establishing the soundness of λ⇒ρ. All proofs are mechanized in the Lean 4 proof
  > assistant." (abstract; the elision is one B2T2-evaluation sentence)

  Contribution bullets, verbatim: a design "which allows us to express type class constraints
  over polymorphic rows (§2)"; "a new form of `All` constraints, where a specific property holds
  across all fields"; "`ind`, a new language construct for folding over rows"; "row commutativity
  annotations, allowing for strict row ordering when necessary"; "`Lift`, a type-level mapping of
  rows"; "a novel unlifting constraint, `Split`, which is useful for splitting rows based on
  their type information".

  On the row theory being a **parameter** — the plug-in door a row theory of ours could use:
  > "we leave the details of which labels can appear together in a row abstract for now, as
  > different row theories exist [Morris and McKinna 2019]"

  > "we rely on the row theory to specify: (1) a validity check for labels within a row (e.g.
  > row in Fig. 2); (2) a predicate which can restrict reordering for commutative rows (e.g.
  > comm in Fig. 4); and (3) a constraint solver (e.g. qalE in Fig. 3), allowing for varied
  > interpretations of row constraints."

  **Grep measurement on the retrieved 38-page full text: `GADT` 0, `GADTs` 0, `refine` 0,
  `refinement` 0, `branch` 0.** The omission is *specifically refinement* — and note what is
  **not** omitted. `All` + `ind` already give generic operations across an unknown row:
  > "we would prefer a general `eq` function that can compare fields within any given record
  > type." (§2.1 region, on `Eq` under row polymorphism)

  So **type-level structural dispatch over rows is theirs, not ours**; our delta against them is
  narrow and must be stated as such — *resolution of a row constraint under a branch-local
  GADT equation*. Smaller point in our favour: their Table 2 (B2T2) marks `orderBy` as requiring
  **existential types**, which their formalism does not have.

---

## 3. The verdict on the headline claim

**Claim under test (row-gadt.md §1.1):** *"No published work puts a row variable under
branch-local GADT refinement."*

**VERDICT: SAFE, with one qualifier that §1.1 already (correctly) carries. [I]**

**How this pass checked.** Beyond re-verifying the lit/lit2 corpora, this pass: (a) retrieved the
five previously second-hand or unretrieved primary sources (Remy 1994, Wand 1989, Gaster & Jones
1996, Ohori 1995, Pottier & Régis-Gianas 2006, wobbly types 2006, Simonet & Pottier 2007,
Garrigue & Rémy 1999) and grep-measured each for rows-under-equations; (b) ran the brief's C-cell
query terms and variants ("GADT row polymorphism", "extensible records refinement GADT", "row
variable refinement", "polymorphic variants GADTs", "records GADT refinement", "structural
records type refinement", "extensible records type equality refinement", "record update row
variable rigid skolem", "presence polymorphism 2025", "row types GADTs combination"); (c)
checked every 2024-2026 hit that any search surfaced (omnidirectional inference, levels, Paszke &
Xie TyDe'23, Spanò 2024, Toohey POPL'26, haskellforall's Wand mechanization, osa1's presence
post, the two discuss.ocaml.org threads).

**What would break it, and why nothing found does:**

| Candidate | Why it does not break the claim |
|---|---|
| OCaml (objects/poly-variants + GADTs) | Combination exists but refinement of the row is **impossible in a poly-variant match** (issue #5724) and object rows must be kept "far away from GADT equations" (octachron); the first implementation **restricted** it (Garrigue & Rémy 2012). Idiom, not discipline [M] |
| CORELINKS | No equations on rows; presence is quantified, not assumed; the branch rule flips a presence flag on a **variant**, and the row variable R is never equated [M] |
| Flix restrictable variants | Refines the label-set index `s`; the record row index `r` is only extended, never equated; GADTs named as future work [M] |
| GHC HasField/record GADTs | Nominal records; class-triggered unification; no row variables [M] |
| Omnidirectional inference 2026 | Restores principality by reordering; nominal records `rcd T τ̄`; GADTs explicitly "would be interested in studying" [M] |
| Toohey et al POPL'26 (rows + type classes) | `All` / `ind` / `Split` / `Lift` constraints over polymorphic rows, dictionary-passing elaboration, Lean 4 mechanized — but **no equations on rows**: zero `GADT`/`refine`/`refinement`/`branch` occurrences in the full 38pp text [M — 2026-10-05] |
| **Chen & Erwig POPL'16** (choice types) | Branch refinement via choice types over GADT type-constructor parameters only; type grammar has no record/row/presence construct; "row" never occurs as a word, "record"/"field"/"label" never occur (grep-measured) [M — 2026-10-06] |
| Koka; Frank; Eff; Links | Effect rows unified, never refined; no GADTs [M] |
| Castagna line (2016, 2025) | Subtyping/tallying; refinement declared "mostly orthogonal"; GADTs named as future work [M] |
| Wand/Gaster/Ohori/Remy | Rows only; no GADTs, no branch-local anything; several predate GADTs entirely [M] |
| HMF/HML; Garrigue & Rémy 1999 | Explicit polymorphism; HMF has no rows; G&R 1999 *protects* a row variable with a label-quantified polytype but has no equations [M] |

**The qualifier (already in §1.1, keep it):** the claim is about **published type systems with a
designed discipline**. OCaml ships the raw combination as an idiom whose boundary is discovered
empirically; the claim must never be worded "rows and GADTs have never been combined" (the
result node's own correction, and §9 already lists it). The safe wording, which §1.1 now
approaches and this pass confirms against the full landscape:

> No published type system refines a **row variable** by a **branch-local GADT equation**, and no
> published system therefore says which record operations remain typable when such an equation is
> active. The adjacent cells are occupied — presence *quantification* (Remy, CORELINKS,
> Castagna & Peyrot), presence *subtyping* (tallying), label-set *refinement* (Flix, on the
> variant side), class-triggered *nominal* record unification (GHC) — but the refinement-side
> answer for extensible records is absent, and the one system that met the interaction
> legislated around it.

**Negative results worth recording [M]:** (a) no paper titled or abstracted around "row
refinement under GADTs" was found by any query; (b) the Haskell row-polymorphism ecosystem
(CTRex, HList-based records, Thoralf) encodes rows as type-level lists + classes — library
encodings with no inference-discipline claims, not competitors; (c) the strongest *formal*
neighbour, Simonet & Pottier's HMG(X), is a parameterised framework whose instances in the paper
never instantiate X with a record/row theory — the parameterisation is exactly the door nobody
walked through [I].

---

## 4. The feature-pair contributions our paper makes against this map

**[I]** Reading the map as a referee will:

1. **The empty cell is real and load-bearing** (§3). The paper's first contribution is the
   *discipline* for that cell: scoped equation store + two-tier discharge
   (`row-gadt-calculus.md` §3-4), with measured evidence.
2. **Remy 1994 is the reference point for the trade, not a threat.** Our insertion rejection
   must be presented as: Remy's unrestricted `new` is the expressiveness maximum; Gaster & Jones
   dial it to strict; CORELINKS quantify it; we restrict it *conditionally* — only under an
   active branch equation — and give the first account of **why** (domain escape breaks
   refinement soundness). Three published positions on the same dial, none of them conditional
   on an equation [I, grounded M].
3. **Update is the positive result precisely because everyone else's update is not
   domain-preserving by construction.** Remy's is shadowing-extension (domain may grow), G&J's is
   restrict+extend under lacks, Links' is remove+extend. Ours is first-occurrence replace on
   scoped labels — domain-preserving *semantically*, which is what makes the discharge free.
   That contrast (§2 above) should be in the calculus doc's §7 positioning paragraph.
4. **The OCaml maintainer record is the strongest single piece of prior-art evidence**: the
   combination is "not well specified" (2024, current), "hard to understand behaviour" is the
   documented experience, and the recommended workaround restructures types to avoid refining
   any row. We do the opposite: we characterise the safe fragment. The discuss threads are the
   user-demand datapoints.
5. **Timing/novelty context**: omnidirectional inference (2026) shows the community treating
   GADT principality as *the* open inference problem and rebuilding constraint solving around
   it — with nominal records. Our paper lands in that conversation with the row-side answer.
6. **The rows+classes cell is now occupied — cite it, do not enter it.** Toohey et al POPL'26
   mechanizes exactly the rows + type-classes combination (dictionary passing, target `F⊗⊕ω`,
   Lean 4) and, by grep measurement on the full text, contains **no refinement anywhere**. Two
   consequences. (a) No claim of ours may ever be "rows + type classes" as such — that cell is
   taken, by a paper with our own method (Lean mechanization) and our own row theory's ancestor
   (Leijen's first-class labels). (b) The refinement *interaction* is thereby sharpened into the
   delta: the neighbour supplies the row-constraint machinery (`All`, `ind`, `Split`, a
   pluggable constraint solver over a **parameterised row theory**) and conspicuously stops at
   the branch. Positioning, should the class-over-rows extension ever be published: *resolution
   of constraints under branch-local row refinement* — and their parameterised row theory is the
   door to framing our discipline **as a row theory of theirs** rather than a rival calculus.
   [I, grounded M]

---

## 5. UNRETRIEVED list

Per item: what it is, what was tried, and what it would settle.

1. **Remy 1994, the MIT Press TAOOP chapter as printed (pp 67-95).** — RESOLVED this pass via the
   UPenn MS-CIS-90-73 preprint (the RR-1431 content; same abstract, same systems Π/Π′/Π\*).
   Remaining doubt is editorial only (page numbers of the MIT Press printing for citation
   formatting); **no technical question remains open** — the unrestricted-extension question is
   answered [M]. If exact chapter pagination is needed for the bibliography, fetch the printed
   chapter via a library; settles nothing else.
2. **Chen & Erwig, *Principal type inference for GADTs* (POPL'16).** — RESOLVED this pass
   (2026-10-06): retrieved the **author's version** from Erwig's publications page
   (https://web.engr.oregonstate.edu/~erwig/papers/TypeInfForGADTs_POPL16b.pdf, found via
   `abstracts.html` on the same site). ACM DL remains CAPTCHA-blocked (not retried); arXiv /
   CiteSeerX / Semantic Scholar were not needed — the author page was the first route that
   worked. What it settled: choice types **cannot express a row refinement** — the type grammar
   is `τ ::= α | τ→τ | T τ` plus choices, with no record/row/presence construct; "record",
   "field", "label" never occur and "row" occurs only inside "arrow" (grep-measured). Entry
   added (§1 G-row, §2, §3 table); the [SECOND-HAND] markers are upgraded there. No residual
   doubt: the earlier snippets ("interact with other types …") were about choice-vs-union-type
   expressiveness in their §9 related work, not about rows.
3. **Simonet & Pottier's RR-5462 full version (2005)** — superseded by the TOPLAS version
   retrieved this pass; nothing further needed.
4. **A manual section documenting OCaml's objects/poly-variants+GADT restriction** — searched
   in lit and this pass; does not appear to exist (the restriction is documented only in
   Garrigue & Rémy 2012 + the issue tracker). What it would settle: whether OCaml's restriction
   is *currently* official policy or just historical; affects only how §1.1 words the OCaml
   bullet ("restricted in the first implementation" is the defensible wording either way).
5. **octachron's discuss.ocaml.org t/14042 post body** — fetched in the earlier pass (quotes
   recorded in `handoff-rowgadt-result`); this pass did not re-fetch. The recorded quotes are
   marked [M] from that pass; if the paper quotes them, re-verify the URL renders before
   camera-ready (discuss.ocaml.org sometimes rate-limits).
6. **Frank (Lindley, Morris, Cheney JFP) full text** — treated second-hand via CORELINKS and
   Koka. What it would settle: whether Frank's effect rows interact with any equation mechanism
   (they don't, per the CORELINKS lineage's design; risk low). Not worth a retrieval pass unless
   the paper makes a claim about Frank specifically.

---

## 6. Claims not to publish (additions for `row-gadt.md` §9)

Building on §9's existing list (which already bans "presence polymorphism is new", the
unqualified "no prior work says which row operations are safe", and the unqualified
"rows and GADTs are never combined"):

- **"Insertion is untypable in row systems" / any implication that R-UPD-INS's rejection is a
  discovery.** Remy 1994 types unrestricted extension **unconditionally** [M]; Gaster & Jones
  type it under a lacks predicate [M]; CORELINKS types insert by quantifying presence [M]. Our
  rejection exists *only* relative to an active branch-local equation. The correct framing is a
  deliberate trade: soundness under refinement vs Remy's expressiveness.
- **"Record update is nominal-only in prior work"** — no: Remy types update-as-extension, G&J
  type restrict+extend, Links derives remove+extend [M]. Our update's novelty is being
  *domain-preserving by construction* (scoped-label replace), not being typable at all.
- **"Wand's concatenation is the only prior loss of principality in records"** — careful: Wand
  1989 loses principality for concatenation and compensates with finite complete sets [M]; our
  fragment Q loses it for refinement-with-mentioning-result. Same casualty, different trigger;
  do not conflate the two when citing the principality boundary.
- **"No one has considered record operations under local assumptions"** — OutsideIn(X)'s
  implication constraints and Simonet & Pottier's HMG(X) are *generic* local-assumption
  frameworks; the accurate statement is that **no published instantiation of either targets a
  row/record theory** [M — verified this pass against both papers' type grammars].
- **"GADT inference frameworks cannot state the problem" without naming the framework.**
  OutsideIn(X) cannot (its grammar lacks rows [M]); HMG(X) *could in principle* — it is
  parameterised over X — but never instantiates X with rows in the paper [M]. Say "has not
  been instantiated", not "cannot".
- **"The 2025-26 state of the art ignores principality"** — omnidirectional inference (2026)
  is precisely about restoring principality for fragile features (with nominal records, GADTs
  as future work) [M]. Cite it; don't imply the field is standing still.
- **Any use of Remy's System Π\* presence variables to claim Remy "almost had" refinement.**
  Π\*'s flag variables are quantified (∀), not assumed-by-branch [M]; presence polymorphism is
  abstraction, the opposite direction from our refinement (lit2's verdict, now grounded in the
  primary text).
- **"Rows + type classes" as a novelty claim.** Occupied: Toohey, Chen, Jamalzadeh & Xie (POPL'26)
  mechanize rows + type classes with dictionary-passing elaboration and a parameterised row
  theory (`All`, `ind`, `Split`, `Lift`, commutativity annotations), all proofs in Lean 4 [M —
  retrieved 2026-10-05]. The claimable delta is exactly the refinement interaction — constraints
  *resolved under a branch-local equation* — and nothing broader. Corollary, same source: do not
  present "generic / type-level structural dispatch over rows" as a consequence of the
  refinement discipline; `All` + `ind` already provide generic operations across any row, so
  that capability is prior art [M].
