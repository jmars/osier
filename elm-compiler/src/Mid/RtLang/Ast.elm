module Mid.RtLang.Ast exposing
    ( AggShape(..)
    , Builtin(..)
    , Block
    , Decl(..)
    , Defun
    , Effect(..)
    , EnumEntry
    , Exp(..)
    , Export
    , ExportSig
    , Field
    , Flag(..)
    , FlagGuard(..)
    , FltBinOp(..)
    , FltCmpOp(..)
    , Header
    , Key
    , Module
    , OTy(..)
    , PTy(..)
    , Param
    , Program
    , Sig(..)
    , SizeTarget(..)
    , Stmt(..)
    , ArrayInit(..)
    , StructInit(..)
    , Sym
    , Term(..)
    , Type(..)
    , WordBinOp(..)
    , WordCmpOp(..)
    , allWordSig
    , builtinClass
    , builtinName
    , fltBinSig
    , fltCmpSig
    , rawcallArity
    , shortSig
    , splitArrow
    , valArity
    , wordBinSig
    , wordClassTy
    , wordCmpSig
    )

{-| Mid.RtLang.Ast — the SURFACE LANGUAGE's AST plus the two tables the
typechecker (tier-2 units T4/T5) will enforce: the builtin
operand/result CLASS table (plan judgment J1) and the `rawcall`
per-symbol ARITY table (plan judgment J3).

This module is the pinned transcription of the tier-2 plan's THE GRAMMAR
observation: every construct below was MEASURED in the existing DSL bodies
(Mid.RtPrims / Mid.RtGc) before being given a surface spelling — nothing in
this file exists for a construct no Rt body uses (no Case, no tagof, no
records-as-syntactic-values: tag dispatch is `tagis` + `mkbool` + `if`, the
exact discipline RtPrims:51-57 records for why Case is forbidden here).

BACKEND-NEUTRAL (the Mid.Rt contract, Rt.elm:17-21): this file imports only
`Dict` — it references no QBE type and no Ir type.  The register classes it
names are the CONTRACT every backend must honour; the measured citations
below point at Mid.Qbe.Lower only to say where the contract was read off.

THE THREE CLASSES.  `Type` is both the surface type annotation (`ty :=
word|float|val`) and the register-class lattice the checker checks against —
the plan's J1 lattice is exactly these three disjoint classes (Lower's
rawWord/rawFloat/value-slot, Lower.elm:192-196).  Deliberately NO fourth
"effect" class: the three store builtins are typed `TVal` because that is
what their (ignored) result slot holds — Lower's comment on RawVecStore
("dest is deliberately IGNORED ... a valid Value; nothing reads it") — and
the DSL's discipline of dead-binding them stays a style fact, enforced (if
at all) by a later unit, not by inventing a class.

FLOAT WORDS ARE NOT LET-BINDABLE on the QBE backend (MEASURED:
Lower's rawFltArg — "A Var never appears — float words are not
let-bindable (recompute; they are pure)").  `TFloat` therefore classifies
EXPRESSIONS only; whether a surface binder may declare `:float` is a T4/T5
decision, and the honest default the grammar leaves open here.

THE INDEX AND TAG ARGUMENTS ARE INT LITERALS.  `payload`/`payload32` carry
the payload-word index and `tagis` the tag as ordinary expression arguments
whose AST form must be `EInt` — that is not a style choice: `RawPayload`'s
`word : Int` and `RawTagIs`'s `tag : Int` are constants inside the lowered
node (Mid.Ir), so the index cannot be a computed value.  The MEASURED uses
need this generality: `payload(v, 0)` is the DSL's `wOf`, `payload(v, 2)` is
the record family's data-pointer read (RtPrims:1083), `payload32(v, 0)` is
`w32Of`, and `payload32(v, 1)` is spelled `len32` — the plan grammar's
`payload(w)` shorthand cannot express the word-2 reads on its own.

-}

import Dict exposing (Dict)


-- ============================ program shape ============================


{-| The class/type lattice: word (raw i64/i32 temps), float (a `d` word,
expression-only — see the header), val (a tagged 40-byte Value), and —
added U1 (midlang-u1) — `TPtr`, the POINTER ANNOTATION (`*S` / `*word` /
`*val`).  A pointer type is a CHECKER-ONLY refinement over `TWord` (the
plan's §1.1: a pointer IS a word — same register class `l`, same rawWord
slots, erased at lowering) that names the LAYOUT the address points at.
It is deliberately NOT a fourth class: it says "layout", never "lifetime,
ownership, or rootedness" — the checker cannot and must not distinguish a
`*S` over malloc'd memory from one over the globals block or a
`value_array` payload, exactly as today's `wload` can read any word.  The
`PTy` pointee family is below; the struct/enum declarations it can name
are the `Decl`s on the module record.

`int` IS NOT A CLASS (B1, plan Q1): it is a second SPELLING of `TWord` —
the parser maps the token `int` to `TWord`, so `int` and `word` are
interchangeable in every position and no int↔word cast exists to get
wrong.  There are no narrow widths (`int8/16/32`, `uint`): no raw node
exists for them (Q1's honest cut, not a silent `word` stand-in).

`TBool` (B1, plan Q2) is a NEW checker-only class over the 0/1 word: the
result of a comparison (`EWordCmp`/`EFltCmp`), a `[bool](w)` cast, or a
`bool` literal, held by a `bool` binder.  It is deliberately
REPRESENTATION-UNAMBIGUOUS — every bool expression lowers to a raw 0/1
word temp (a `RawCmp`, or a constant `Lit`) — which is what makes a bool
BINDER branchable where a `word` binder is not (Check.checkCond; the
`handoff-perf-a3-review` P1c seam: a word binder's representation is the
lowering's, a bool binder's is the class's).  Its ONE implicit coercion is
bool→val, which BOXES to `RawMkValue tagBoolean` — the exact tree the
`true`/`false` sugar used to emit.  bool→word is the identity but is
EXPLICIT only (`[word](b)`, plan Q10).

`TStruct name` (B2, plan Q4) is the struct VALUE class: a `struct S` used by
value (`S s;`, a field `inner : B`, a `p[i]`-style element once B3 lands).
Its REPRESENTATION is one raw WORD — the ADDRESS of the value's storage —
which is what makes the plan's rule "a struct-typed field read IS the
field's ADDRESS (no load: the field is a location)" literally true, and
what makes `s.f` and `p->f` (/`p.f`) the SAME lowering.  See `StructInit`
and `TStruct` notes below for where the storage comes from and what a
copy means.

`TArray elem n` (B3, plan Q5) is the FIXED-SIZE ARRAY type — spelled
`elem[n]` in the source, a TYPE like any other (`surfaceType`), so it
composes: a binder (`word[5] a;`), a struct field (`tab : word[3];`), a
`sizeof` operand (`sizeof(word[5])` = 5), and NESTED for the
multidimensional case.  THE DECLARATOR IS THE TYPE, not C's suffix form:
`word[3][4] a;` declares `a : word[3][4]`, i.e. `TArray (TArray TWord 4) 3`
— three elements of `word[4]` each, ROW-MAJOR and flat (12 contiguous
words).  C's `word a[3][4]` spelling is deliberately NOT the grammar; one
spelling, and it is the one the type table reads.

Its REPRESENTATION is one raw WORD — the ADDRESS of the storage — exactly
like `TStruct`, which is what makes decay-to-pointer free (`*word p = a;`
is a binder cast, `coerce`'s decay row) and what makes the element
arithmetic the only scaling that exists in the language.  The index
contract and the initialiser rules are on `ArrayInit` and `SArrayBind`
below; the val-element obligation is plan §Q11's (raw memory holding
40-byte handles — an unrooted handle across an allocating call is the
hazard the B3 churn fixture makes visible).

-}
type Type
    = TWord
    | TBool
    | TFloat
    | TVal
    | TPtr PTy
    | TStruct String
    | TArray Type Int


{-| The POINTEE of a pointer annotation (`*S` / `*word` / `*val`), the
plan's three pointee families (§1.1):

  * `PStruct name` — `*S`: a pointer to the struct `S`; field access
    `p->f` and struct-scaled indexing `p[i]` (A1/A2, the checker/lowerer
    units this grammar is the seat for).
  * `PWord` — `*word`: a pointer to a word array; `p[i]` (= `wload(p,i)`),
    `p[i] = e` (= `wstore`), `*p` (= `wload(p,0)`).
  * `PVal` — `*val`: a pointer to a value array; `p[i]` (= `vecload`),
    `p[i] = v` (= `vecstore`).

No `&` address-of in v1: every base arrives as a word from
`payload`/`wload`/`malloc`/`rt_glob_addr`, so the view-cast is spelled as
a typed binder (`*S r = payload(v, 0);`), never an operator.  `word`
stays the language's `void*` — the address the runtime computes with —
and `*T` is the typed view taken AT that boundary, the one direction the
source spells (plan J12's unchecked word→*T cast).
-}
type PTy
    = PStruct String
    | PWord
    | PVal


{-| A Rt-defun key, full and verbatim (`"Rt.deepEq"` — the rtDeps spelling;
the plan: "Key is the full 'Rt.name'").
-}
type alias Key =
    String


{-| A C-seat / libc symbol for `rawcall` (`"mmap"`, `"rt_sym_intern"`).
-}
type alias Sym =
    String


type alias Program =
    List Defun


-- ============================ the module header (M2) ============================


{-| THE EXPORT-BLOCK TYPE SYNTAX (M2, plan.md §2.5) — the Osier-side type
an `export` line declares, and the value the TYPED EXTERN TABLE carries.

DELIBERATELY NOT PINNED TO MONOMORPHIC TYPES (the OWNER-STATED forward-
compatibility requirement): a later exported type can be a QUANTIFIER
(`OForall`/`OExists` over a bound variable — the `exists s. { alloc :
Int -> Ref s, ... }` / rank-2 `forall s. ...` scoped-effect shapes), a
TYPE APPLICATION over an abstract name (`OCon "Ref" [ OVar "s" ]`), or an
ARROW whose argument is itself polymorphic (`OArrow (OForall "s" ...) _`).
None of that changes this grammar; M2 parses and CARRIES these forms
(erasure/semantics are Phase-7-adjacent work, not here).

The atoms, matching §2.5's three classes and the Osier names they map to:

  * `OVal`/`OFloat`/`OWord` — the THREE MID-C CLASSES as OPAQUE atoms
    (`val` / `float` / `word`, lowercase — the raw ABI classes; `word` is
    the locally-abstract opaque Word, never unified with Osier Int).
  * `OVar` — a lowercase identifier: a BOUND type variable (`s`, `a`).
    Lowercase is reserved for variables, so `val`/`float`/`word` are the
    ONLY lowercase atoms; any other lowercase identifier is a variable.
  * `OCon name args` — an UPPERCASE type constructor, applied or bare:
    `Val Int`, `Word`, `Ref s`, `Int`.  `OCon "Word" []` is the opaque
    word; `OCon "Val" [...]` the boxed value type.
  * `OArrow` — `->`, right-associative.
  * `OForall`/`OExists` — `forall s. T` / `exists s. T` (CARRIED, not
    checked or erased in M2).

The grammar is a single recursive type expression, so an export line is
`export key : OTYPE` and the FLAT `params -> result` split is DERIVED
(`splitArrow`, below) rather than a second grammar — a rank-2 export that
needs a polymorphic argument stays one type, no grammar change.
-}
type OTy
    = OVal
    | OFloat
    | OWord
    | OVar String
    | OCon String (List OTy)
    | OArrow OTy OTy
    | OForall String OTy
    | OExists String OTy


{-| An export's effect marker.  `Io` is `!io` — the §2.5 impure-export
marker (contract 3).  The marker list is the postfix `!ident` sequence on
an export line; M2 recognises exactly `!io` (here) and the contract-4
taint (`ExportSig.taint`), anything else is a loud parse reject.
-}
type Effect
    = Io


{-| One export line's DECLARED SIGNATURE — the full type expression plus
the markers the grammar attaches to the RESULT position: the `!io` effect
marker (contract 3) and the contract-4 TAINT (`taint = True` says "this
result may not escape an Osier function's return").  Both are CARRIED here
and in the typed extern table; neither is ENFORCED in M2 (that is M4) —
the seat exists, the check does not.
-}
type alias ExportSig =
    { ty : OTy
    , effects : List Effect
    , taint : Bool
    }


{-| One `export key : ty markers` line.  `key` is the defun name verbatim
(the full `Rt.*` key for runtime.mid; a user module's own key later).
-}
type alias Export =
    { key : Key
    , sig : ExportSig
    }


{-| A `.mid` module's OPTIONAL header: the module NAME (`module Rt`) and
the export block (zero or more export lines).  The whole header is
optional — a headerless `.mid` is a module with no name and no exports
(every defun module-private).  `//`-commentable per M0.
-}
type alias Header =
    { name : Maybe String
    , exports : List Export
    }


{-| A whole `.mid` file: the header, the file-scoped `struct`/`enum`
declarations (`decls`), and the defun list (`Program`).
`Parse.parseModule` returns this; the defun list is the same `Program`
every lowerer/checker already consumes (the header and the declarations
are NOT lowered in U1 — they ride beside the program, consumed by the
A1 checker (J11/J14) to build the struct/enum tables and the A2 lowerer to
lay out fields).  v1 has NO cross-module import: these declarations are
FILE-SCOPED to their own `.mid` module — a `*S` in one module cannot name
a struct declared in another (pointers cross a module boundary only as
the opaque `word`/`*word` the plan §2.5 already pins).
-}
type alias Module =
    { header : Header
    , decls : List Decl
    , defuns : List Defun
    }


-- ============================ file-scoped declarations (U1) ============================


{-| A top-level `struct` or `enum` declaration — the file-scoped layout
tables the plan's §1.2/§1.3 define.  U1 PARSES and CARRIES these (they
are the grammar); the A1 checker (J11/J14) turns them into the struct/
enum tables and field-offset layout in `Env`, and the A2 lowerer reads the
SAME table (the plan's one-table property — no second copy to skew).  A
declaration is NOT lowered in U1: it produces no node and no byte; it
only reserves a NAME and its shape for the checker/lowerer to consume.

WHY THIS FORM EXISTS (the measured wall it closes): the runtime's own
layouts are today comment-kept offsets — `RtGc.elm`'s globals comment and
the `gcInit` wstore block spell the region's words 0..12 as bare numbers,
and the two OVERLAPS this code has (the mark stack at region base, the
header at body−2) are silent conventions.  A struct turns one comment
into ONE table the checker derives offsets from, so a pad field forgotten
or a shifted cursor/markTop is a checked layout error, not a magic-number
drift (plan risk R2).  It is a named offset table over raw memory — never
a GC object kind: `value_array` stays the only GC object (the owner's
hard constraint), and a struct value is reached only through a pointer
the program already holds.
-}
type Decl
    = StructDecl { name : String, fields : List Field }
    | EnumDecl { name : String, entries : List EnumEntry }


{-| One struct field: a name and its type, in DECLARATION ORDER (the
layout rule is order-preserving, word-granular — every field a whole
number of 8-byte words; the runtime's own layouts are word-quantized, so
no finer padding exists).  A `_pad` field is an ordinary word field —
nothing special to check — it keeps the layout table honest where a real
layout has a hole (region word 7; globals words 3–7, 14–15).  Field
types are the `Type` grammar: `word`, `val` (40 bytes = 5 words, stored
INLINE — allowed, nothing traces it, the rooting discipline is a stated
contract not a type property), `float` (parsed here; REJECTED by the A1
checker's J11 — Mid.Ir has no raw-memory f64 load node), and the three
pointer families.  Self-reference by value (`next : S`) is the A1 checker's
J11 reject (infinite size); by pointer (`next : *S`) is the only recursion.
-}
type alias Field =
    { name : String
    , ty : Type
    }


{-| One `enum E { ... }` entry: `name = value`.  C-style named word
constants, NOT tagged unions — `enum RootKind { ptr = 0; value = 1; }`
makes `RootKind.ptr` an `EInt` alias legal anywhere a word literal is,
most usefully in the compares the existing tag-dispatch discipline
already uses (`if (mkbool(kind == RootKind.ptr))` — a byte-identical word
compare vs `Con 0`).  Tagged unions + `match` are deliberately REJECTED:
the measured discipline forbids `Case`/`tagof` (Ast.elm's header), and a
tag + max-variant-payload layout would need a new Mid.Ir `Case` node,
violating the keep-IL-unchanged goal.
-}
type alias EnumEntry =
    { name : String
    , value : Int
    }


{- M4 — THE FOUR CONTRACTS OF THE Osier ↔ mid-c INTERFACE, STATED HERE (the
interface the `export` block declares) rather than only in plan.md §2.5.  Each
is marked ENFORCED / STATED-NOT-ENFORCED, honestly:

  1. ROOTING — a `val` argument is a GC reference: it must survive the callee's
     allocations and must not be stashed where the collector cannot see it.
     RUNTIME/ABI contract, NOT a type property (§2.5 SETTLED): the mid-c frame
     machinery (PFrame, the lean ABI's pooled ROOTED block) enforces it; no
     `ExportSig` field carries it because no type check could.  STATED.
  2. IMMUTABILITY — Osier values are immutable; mid-c has `wstore`.  Mutation
     must be reachable ONLY through `word`/raw, never `val`.  ENFORCED by the
     J1 class table: every mutating builtin (`VecStore`/`ByteStore`/
     `WordStore`) takes `word` (raw address) operands, never a `val`, so a
     `val` cannot be mutated — the class checker rejects a `val` in a `word`
     slot.  ENFORCED (by J1), stated here as the interface contract.
  3. EFFECTS — an impure export carries `!io`; Osier's purity discipline must
     not be silently violated.  The marker is PARSED and CARRIED on
     `ExportSig.effects` and in the typed extern table.  NOT ENFORCED on the
     Osier side: the Osier surface has no effect system, so a pure Osier
     function may call an `!io` export — the marker documents impurity, it does
     not gate it (enforcing it is effect-system work, Phase-7-adjacent).
     STATED, marker carried.
  4. EFFECT CONTAINMENT — the result of a Mid import must not reach the
     enclosing Osier function's RETURN (use inside the function is unrestricted;
     the owner's let-bound + self-recursive-lambda case is safe; the check is on
     DATAFLOW into the return, never a syntactic ban).  The `taint` marker is
     PARSED and CARRIED on `ExportSig.taint`.  NOT ENFORCED — M4 chose the
     "state it loudly" arm, not the conservative taint floor: real containment
     is the Phase-7 machinery (existential/rank-2 + phantom region types,
     §2.5 SETTLED), and M4 does not half-build a type system.  STATED, marker
     carried, enforcement deferred.

`!io`/`!taint` are the grammar's postfix `!ident` markers; an unknown marker is
a loud parse reject (M2).
-}



{-| Flatten a type expression's TOP-LEVEL arrow chain into `(params,
result)` — the `key -> (param types, result)` view the typed extern table
gives J2.  A LEADING quantifier scopes the whole rest of the type, so the
arrow chain UNDER it is exactly the param list: `forall s. Ref s -> Int`
flattens to `([Ref s], Int)` — one parameter, quantified over `s`.
Unwrapping it here (rather than at each consumer) is what keeps the
forward-enforced arity check in `Check.checkExports` honest: without these
two cases a quantified export read as arity 0 and the FIRST such export
failed load with a message blaming the defun.  A non-arrow, non-quantified
type (a bare atom) is the only thing that flattens to zero params.
-}
splitArrow : OTy -> ( List OTy, OTy )
splitArrow ty =
    case ty of
        OArrow a b ->
            let
                ( ps, r ) =
                    splitArrow b
            in
            ( a :: ps, r )

        OForall _ b ->
            splitArrow b

        OExists _ b ->
            splitArrow b

        _ ->
            ( [], ty )


{-| The arity-only fallback type: `val -> val -> ... -> val` (n params) —
today's all-`:val` extern seat, spelled as a type so the typed table can
hold exported and unexported keys in one shape.
-}
valArity : Int -> OTy
valArity n =
    if n <= 0 then
        OVal

    else
        OArrow OVal (valArity (n - 1))


{-| THE WORD-CLASS PREDICATE (B6, plan Q7): does a declared type live in a
WORD REGISTER — `word`/`int` (one class, B1), `bool` (the 0/1 word, B1), a
pointer (`*T` — a pointer IS a word, J12), or a struct VALUE (its fields are
flat words, which is what makes a struct parameter passable at all)?

The two EXCLUSIONS are deliberate and each has its own reason:
  * `val` — the 40-byte handle; a `:val` in the signature is what forces the
    value ABI (`:ret`/lean, frame slots, the blit).
  * `float` — a `d` register class in QBE, not a word.  A float parameter in
    a word-ABI defun would need `d` registers and a second register class in
    the signature; no defun in the tree has one, so the rule keeps floats on
    the value side (today's behaviour, MOVED BY NOTHING).
  * an ARRAY (`T[N]`) is word-class by REPRESENTATION (its value IS its base
    address) but a by-value array parameter is still refused by Check (B3's
    J11 reject, unchanged by B6): the flattening question there is the
    element count, not the class.  It is listed as word-class so the CLASS
    rule and the PARAMETER rule stay two separate judgments.
-}
wordClassTy : Type -> Bool
wordClassTy ty =
    case ty of
        TWord ->
            True

        TBool ->
            True

        TPtr _ ->
            True

        TStruct _ ->
            True

        TArray _ _ ->
            True

        TFloat ->
            False

        TVal ->
            False


{-| THE ABI CLASS OF A SIGNATURE (B6, plan Q7) — THE ONE RULE, here in the
backend-neutral vocabulary so the checker (which decides whether a struct
parameter may exist) and the emitter (which decides the register shape) read
the SAME judgment:

> a defun whose parameters AND result are all word-class takes the WORD ABI
> (register parameters, word tail); any `val` (or `float`) in the signature
> keeps the VALUE ABI (frame slots, `:ret`/lean).

MEASURED agreement with the hand-maintained `Mid.Rt.rawAbi` key list: the
nine all-word surface defuns in runtime.mid (frameBlock, frame-enter,
frame-leave, die, halt, cStrEq, main, copyWords, copyWordsGo) are EXACTLY
the all-word signatures AND are all in `rawAbi`; the four remaining `rawAbi`
keys (apply, apply-tail, tail-known, bounce) return an AGGREGATE `val`, so
they classify value-ABI by this rule and are kept word-ABI by the explicit
set's OVERRIDE (Mid.Rt.abiTable merges the two).  That merge is load-bearing,
not a safety net: without it those four keys would move the corpus.
-}
allWordSig : List Type -> Type -> Bool
allWordSig paramTys retTy =
    List.all wordClassTy paramTys && wordClassTy retTy


{-| One surface defun.  `key` is the Rt key the lowered Defun carries;
gated variants (the consArr/rec/eqPtrFast 4-defun variation, MEASURED at
Rt.elm's `program`) share ONE key under mutually exclusive `flags` (J8), so
rtDeps is untouched by the guards.
-}
type alias Defun =
    { key : Key
    , flags : List FlagGuard
    , params : List Param
    , ret : Type
    , body : Block
    }


type alias Param =
    { name : String
    , ty : Type
    }


{-| A compilation switch a defun is gated on.  The three constructors are
the MEASURED set — exactly Rt.elm's `program consArr rec eqPtrFast` switches;
a fourth switch would be a new emission axis and must be added here (and to
Rt.elm) explicitly, never smuggled through a String.
-}
type Flag
    = ConsArr
    | Rec
    | EqPtrFast


{-| `@flag` / `@!flag` in the source text.
-}
type FlagGuard
    = Guard Flag
    | GuardNot Flag


{-| `stmt* term`.  A block has exactly one terminator — the lowering (plan
L3/L4/L5) consumes it as the block's value; Mid has no fall-through and no
join, and the surface keeps that honest by making the terminator explicit.
-}
type alias Block =
    { stmts : List Stmt
    , term : Term
    }


{-| `SBind` is `ty id = exp;` — a NEW binder only (rebinding is a fresh id
that shadows, like the DSL's hand-numbered distinct b's; J5 checks the
declared class).  `SEffect` is `exp;` — its value is discarded; the lowering
(L2) gives it a fresh dead binder, the DSL's `(b 107, rStore ...)` shape.
`SIf` is a mid-block `if`: legal ONLY when at least one branch diverges
(ends in `return`/`recur`) — the L6 else-nesting rule; both-branches-fall-
through is a checker REJECT (J7), never a silent join.
  * `SFieldStore` — `p->f = e;` (U1, midlang-u1): the field STORE, a
    STATEMENT (Mid has no assignment expressions).  Lowers to a
    dead-binder `Let` of `RawWordStore { ptr = p, index = Lit off, value =
    e }` — the EXACT `wstore(p, off, e);` tree (plan §3) — for a word/
    pointer field, `RawVecStore` for a `val` field.  The field offset is
    the A1 checker's derived value, carried here as the field NAME.
  * `SIndexStore` — `p[i] = e;` (U1): the index STORE.  The matching
    `RawWordStore`/`RawVecStore` node with the computed index `i` — the
    `wstore(p, i, e)`/`vecstore(p, i, e)` shape.
  * `SStructBind` — `S s;` / `S s = { f = e; .. };` / `S s = other;`
    (B2): the struct-VALUE binder.  These three are the three ways a
    struct's storage comes into being, and `StructInit` below says what
    each lowers to.  It is a STATEMENT of its own (not an `SBind` with a
    `TStruct` type) because the ALLOCATION is the point: a struct binder
    is a fresh storage location, never a rename.
  * `SArrayBind` — `word[N] a;` / `word[N] a = { e, .. };` (B3): the
    FIXED-SIZE ARRAY binder.  Like `SStructBind` it is a statement of its
    own because the ALLOCATION is the point (an array binder is fresh
    storage, never a rename), and its two initialisers are `ArrayInit`'s.
  * `SVarStore` — `s = other;` (B2): aggregate ASSIGNMENT — the
    field-wise COPY into storage that already exists (plan Q4: "assignment
    `s2 = s1` lowers to field-wise loads/stores").  Legal where the
    destination is a struct-VALUE binder (the copy) or a WORD-class binder
    (B4's scalar assignment — see the AUTO-CELL note below); a `val`
    destination is a loud reject with the escape named.
  * `SWhile c B` — `while (c) { B }` (B4).  A statement, not a terminator:
    control FALLS THROUGH it into the rest of the block, which is what makes
    `while (..) { .. } return x;` read like C.
  * `SDoWhile B c` — `do { B } while (c);` (B4).  `continue` inside `B`
    evaluates `c` first (C's rule), which is why the surface form carries
    its condition instead of being desugared away in the parser.
  * `SFor { init, cond, step, body }` — `for (init; cond; step) { body }`
    (B4).  `init`/`step` are STATEMENTS (`word i = 0;`, `i = i + 1;`) and
    either may be absent, so C's `for (i = 0;; i = i + 1)` shape is
    spellable.  A `continue` in `body` RUNS `step` before re-testing —
    C semantics, produced by rewriting every `TContinue` in the body to
    `step; continue`.  SCOPE NOTE (stated, not hidden): `init` declares into
    the ENCLOSING block's scope — this language has one flat scope per defun
    — so `i` stays visible after the loop, unlike C's `for (int i = ..)`.

AUTO-CELL (B4, plan Q6).  A WORD-class binder (`word`/`int`/`bool`/`*T`)
that is the TARGET of an assignment anywhere in its defun is lowered to an
`allocN` CELL (its declaration allocates one word; reads are loads, writes
are stores) instead of a raw register.  A loop-carried local needs this
because a register cannot be live across a back edge without a phi — the
`Rt.copyWordsGo` discipline, automated — and a read-only binder stays a
register.  The judgment is deliberately DEFUN-WIDE rather than "inside a
loop body": the assigning set is syntactic, so there is no loop analysis to
mis-scope, and an assigned binder is a cell wherever it appears.
-}
type Stmt
    = SBind Type String Exp
    | SEffect Exp
    | SIf Exp Block (Maybe Block)
    | SFieldStore Exp String Exp
    | SIndexStore Exp Exp Exp
    | SStructBind { sname : String, name : String, init : StructInit }
    | SArrayBind { aty : Type, name : String, init : ArrayInit }
    | SVarStore String Exp
    | SWhile Exp Block
    | SDoWhile Block Exp
    | SFor { init : Maybe Stmt, cond : Exp, step : Maybe Stmt, body : Block }


{-| B2 — HOW a struct value is born, the three `S s ...` forms:

  * `InitZero` (`S s;`) — uninitialised-but-ZEROED storage (a `memset`,
    because uninitialised raw memory in a language with no `unsafe` marker
    is a silent-wrong-value generator; C's `S s;` leaves garbage, this one
    does not).
  * `InitFields [ (f, e) ]` (`S s = { a = 1; b = x };`) — storage then one
    field store per named field, in the order written.  Every field is
    optional (the rest stay zero) and a repeated field is a loud reject.
  * `InitCopy e` (`S s = other;`) — storage then a field-wise COPY of
    `other`'s words.  Aggregate initialisation COPIES, as in C: `S t = s;`
    must not alias.
-}
type StructInit
    = InitZero
    | InitFields (List ( String, Exp ))
    | InitCopy Exp


{-| B3 (plan Q5) — the TWO ways an array binder's storage is filled:

  * `AInitZero` (`word[N] a;`) — allocated and ZEROED (`memset`, the same
    rule and the same node `S s;` uses: uninitialised raw memory in a
    language with no `unsafe` marker is a silent-wrong-value generator).
  * `AInitFull [e1, .., eN]` (`word[N] a = { e1, .., eN };`) — allocated
    then ONE STORE PER ELEMENT, in the order written.

**A PARTIAL list is a CHECK REJECT, and `{0}` is a partial list.**  The
plan's reason is exact and it is the message: zero-filling the elements
you did not spell would put a `val` element at tag 0 (nil) — a handle that
LOOKS valid and is not the one the program meant, i.e. a garbage-tag trap
manufactured by the compiler.  Zero-init of the whole array is spelled by
the declaration itself (`word[N] a;`, which memsets) or explicitly
(`rawcall memset(base, 0, 40*N)`), never by a short literal.

An array-to-array COPY (`word[N] b = a;`) is NOT in this grammar (the tail
is a parse problem): it would need N unrolled element stores (a struct
copy's word loop keyed by element class) and no user needed it — declare
`word[N] b;` (zeroed) and store the elements.

-}
type ArrayInit
    = AInitZero
    | AInitFull (List Exp)


{-| `TRet` is `return e;` (L3: the block's value).  `TRecur` is
`recur(a, ..);` (L4: `App{fn=GRef own-key, force=False}` — the ONE self-tail
form; MEASURED, all 31 DSL sites are saturated self-GRef apps, so J4 pins the
arity == own param count statically, else the classifier would demote the
loop to a plain call).  `TIf` is the branch-final `if` (L5).
`TBreak`/`TContinue` (B4) are the loop LEAVES — they end
the block like `return` does (a block has exactly one terminator), and
`Check` rejects either one outside a loop.  `diverges` counts all four, so
the J7 "a mid-block if needs one diverging branch" rule admits
`if (c) { break; }` as the mid-block statement it is.
-}
type Term
    = TRet Exp
    | TRecur (List Exp)
    | TIf Exp Block (Maybe Block)
    | TBreak
    | TContinue



-- ============================ expressions ============================


{-| The surface expression grammar.  Constructors map 1:1 onto what the
DSL builds by hand (citations are the DSL helper / Lower case each one
transcribes):

  * `EInt` :word — `Lit LNumber` (RtPrims `n`).  `EFlt` :float — the float
    literal (the M4 promote arms; reaches the tree only nested in float
    positions).  `EStr` :val — `Lit LString` (THE SAFEPOINT — Rt.intern).
  * `EVar` — a surface NAME; the checker resolves it (J5) and the lowering
    assigns the binder id (ids are Dict keys, never emitted — plan fact F1).
  * `EWordBin` — `+ - * / & | ^ << >> >>>` (RawBin; word,word -> word).
  * `EWordCmp` — `== != < <= > >=` (RawCmp; word,word -> WORD 0/1: a bare
    compare IS a legal `:word` condition now (branch on it directly); box
    via `mkbool` to make a `:val` — the OLD DSL's `mkBool (cmpW ...)`
    discipline, which the compatibility seat still honours byte-identically).
  * `EFltBin` — `f+ f- f* f/` (RawFltBin; float,float -> float).
  * `EFltCmp` — `f< f<= f> f>= f== f!=` (RawFltCmp; float,float -> word 0/1,
    extsw-widened — Lower's RawFltCmp case).
  * `EShortAnd`/`EShortOr` — `&&` `||` (ShortAnd/ShortOr VERBATIM; val,val ->
    val: deepEq RETURNS `and2(..)` as a value, so these are value
    expressions, not statements).
  * `ECall` — `call Key(..)`: RawCall, ANY key that is a DEFUN OF THE PROGRAM
    (an injected `Rt.*` key, or a user `.mid` module's export), :val args and
    `:val` result (Lower's RawCall case rejects a key that is not a program
    defun loudly — it is no longer a `Rt.` name-shape test).
  * `ERawCall` — `rawcall sym(..)`: RawCallRaw, every arg and the result are
    WORDS (Lower lowers each arg through rawWordArg, `Base L` both sides);
    the symbol must be in `rawcallArity` (J3).
  * `EAggCall` — `aggcall ret|val f(..)`: RawCallAgg — call a runtime WORD
    (a code pointer expression) for an aggregate result; fn, args and the
    result (the sret buffer ADDRESS) are all WORDS; shape is `ret` or `val`
    (Lower rejects anything else).  0 uses today — in the grammar now for
    stage-6 (plan).
  * `EBuiltin` — the fixed builtin set, classes in `builtinClass`.
  * `EWithRoots` — `withroots [ids] block`: the listed ids must be :val
    binders in scope (J10); the block's terminator is the form's value.
    2 sites today (plan); WithRoots is the backend-INDEPENDENT statement of
    the rooting discipline (Mid.Ir's header).
  * `EIf` — `cond ? then : else` (T9b): the VALUE JOIN the plan's L6 names
    as the escape hatch.  Mid has no join, but `ty x = (c) ? e1 : e2;`
    lowers through the EXISTING L1 rule to `Let { x = If { .. } }`, whose
    join label the backend handles natively (the `Rt.readFileGo` growB
    binder is the measured wall this spell closes).  The branches must
    AGREE on a class (the result is that class) and the cond is `:val` —
    the same judgment the statement/term `if` applies, not a new one.
  * `EIfBlock` — `if (cond) { block } else { block }` (T23): the
    BLOCK-BRANCH if EXPRESSION, the form the three remaining DSL walls
    actually have: an `If` bound in a let-value whose BRANCHES carry
    let-chains (`Rt.readFileGo`'s growB, `Rt.epCmd`'s ago/rgo,
    `Rt.childCd`'s dirN #2) and whose VALUE the continuation reads —
    `?:` cannot spell those (its branches are bare expressions, no
    statements) and the statement/term `if` cannot (no value in an
    initializer slot).  Each branch is the EXISTING block grammar
    (`stmt* term`; the block's term is the branch's value) and the whole
    form is an expression, so it composes in any value slot — the
    lowering is the TERM `if`'s own (`mkIf` over the two lowered blocks),
    no new machinery.  The else block is REQUIRED (an expression needs a
    value from both arms); the cond is `:val` and the two branch classes
    must AGREE — the agreed class is the form's.  TWO MEASURED notes from
    the T23 review (T24): through the current TERM grammar the agreed class
    always COLLAPSES to the enclosing defun's `-> ty` (every term's class is
    `ctx.ret` — J6 pins each return, `TRecur` returns `ctx.ret`, the term
    `if` recurses), so a block-if composes only in a defun of that class
    and a WORD-valued join inside a `-> val` defun still needs `?:`; and a
    branch terminated by `recur` is checker-legal but UNPINNED by any row
    (it lowers to an `If` carrying a self-`App` value — shape-identical to
    the term `if`'s, classifier-safe per the plan's F3/L4).
  * `EField` — `p->f` (U1, midlang-u1): the postfix field READ.  At
    lowering it IS the existing `RawWordLoad { ptr = p, index = Lit off }`
    node (`wload(p, off)` with the field's constant offset — plan §3) for
    a word/pointer field, or `RawVecLoad` for a `val` field; U1 only
    parses it — the A1 checker (J13) resolves `f` to `S`'s field offset
    and the A2 lowerer emits the same node.  The constructor carries
    the pointer EXPRESSION and the field NAME (the offset is the A1
    checker's derived value, not the parser's).
  * `EIndex` — `p[i]` (U1): the postfix index READ.  `i` is an ELEMENT
    index (words for `*word`/`*val` — matching `wload`'s word-offset
    contract; structs for `*S`), an ordinary expression — unlike
    `payload`'s literal-slot index, this one is a computed value, exactly
    the generality `wload(p, i)` already has.
  * `EDeref` — `*p` (U1): the prefix deref, `*word` only → the existing
    `RawWordLoad { ptr = p, index = Lit 0 }`.  Postfix (`->`, `[]`) binds
    tighter than the prefix `*`, the C convention, so `*p->f` is
    `*(p->f)`.
  * `EBool` — `true` / `false` (B1, plan Q8): a BOOL literal.  It is a
    0/1 word (`Lit (LNumber 1|0)`) and at a `:val` position it BOXES to
    `RawMkValue tagBoolean [Lit 1|0]` — byte-identical to the
    `mkbool(1)`/`mkbool(0)` sugar it replaces, which is why `return true;`
    in a `-> val` defun emits the same bytes as before.
  * `ECast` — `[T](e)` (B1, plan Q10): Terra's mechanical cast.  The
    CHECKER owns the matrix (`Check.castClass` — word/int/pointer/bool
    identities, `[bool](w)` = a nonzero compare, `[float]`/`[word]` =
    itof/ftoi32, `[val](b)` = the box, and a LOUD reject for everything
    else, `val` casts above all); the lowering is one node per row and
    NOTHING (no node at all) for the identity rows.
  * `ESizeof` — `sizeof(S)` / `sizeof(T)` (B1, plan Q9): a compile-time
    WORD constant read from the ONE layout table (`Check.sizeofStruct`)
    for a struct, or the class width for a type.  Lowers to one
    `Lit (LNumber n)`.
  * `EAddrOf` — `&place` (B2, plan Q3): the address of a MEMORY-BACKED
    place, as a `*T` ready for the A1 matrix.  Legal on exactly the
    things that have storage (Check enforces it and the message names the
    rule): a struct VALUE (`&s` — the value IS its address, so this is
    the IDENTITY: no node at all), and a struct field selection whose
    field is one word or a nested struct (`&s.f` / `&p->f` / `&s.inner`
    — the base address plus the field's constant word offset, NO load).
    Everything else is a LOUD reject: a `word`/`int`/`bool`/`float`
    LOCAL, a parameter, a temporary, a literal — a binder is a temp or a
    40-byte Value slot in this lowering, so there is no address to take
    (spilling a scalar to memory is the named v2, plan Q3); `&` of a
    `val` is refused separately (a GC-interior address exposed as a raw
    word is the unrooted-view hazard — `vecaddr`/`payload` are the
    sanctioned reads).  Struct PARAMETERS are B6's (`&x` on a flattened
    struct param forces the stack spill copy), so there is nothing to
    take the address of there yet.

-}
type Exp
    = EInt Int
    | EFlt Float
    | EStr String
    | EBool Bool
    | EVar String
    | EWordBin WordBinOp Exp Exp
    | EWordCmp WordCmpOp Exp Exp
    | EFltBin FltBinOp Exp Exp
    | EFltCmp FltCmpOp Exp Exp
    | EShortAnd Exp Exp
    | EShortOr Exp Exp
    | EIf Exp Exp Exp
    | EIfBlock Exp Block Block
    | ECall Key (List Exp)
    | ERawCall Sym (List Exp)
    | EAggCall AggShape Exp (List Exp)
    | EBuiltin Builtin (List Exp)
    | EWithRoots (List String) Block
    | EField Exp String
    | EIndex Exp Exp
    | EDeref Exp
    | ECast Type Exp
    | ESizeof SizeTarget
    | EAddrOf Exp


{- WHERE STRUCT-VALUE STORAGE COMES FROM (B2) — the one plan premise this
unit MEASURED FALSE, recorded where the representation lives.

The plan (Q4) says a struct local "lowers to `allocN sizeof(S)`" over QBE
stack memory, "`Il.Alloc` exists and is EMITTED today (`Lower.elm:7906`)".
That seat is real but it is `Mid/Qbe/Il.elm`'s — BELOW `Mid.Qbe.Lower`,
the only consumer of THIS module's trees.  `Mid.Ir` (the IR `LowerToIr`
emits) has NO frame-allocation node at all: its only address producers are
`RawAllocVector`/`RawAllocRaw` (GC-heap), `RawVecAddr` (an interior
address into an existing GC array), `RawCStr`/`RawSym`/`RawDataAddr`
(static) and `RawCall*`.  And the plan itself puts the missing node —
`RawAllocN` — in B4's row, not B2's.

So a struct value's storage is `rawcall malloc(8 * sizeof(S))`: a C-heap
block, address-stable, invisible to the collector, never moved.  Three
consequences, all stated rather than hidden:

  1. IT IS HEAP, NOT STACK — the value's lifetime is the program's, not
     the frame's, and NOTHING frees it.  A struct binder inside a loop
     allocates per iteration (B4's problem to fund; the fix is
     `RawAllocN` in one function, `LowerToIr.structAlloc`).
  2. The GC does NOT see it, so a `val` FIELD is an unrooted handle —
     exactly plan §Q11's obligation (no-safepoint window + rooted
     referent), which B7 owns.  This is forced, not a shortcut:
     `RawAllocRaw` (the GC's own raw block) would be no better — a raw
     block that no root points at is SWEPT, because `runtime.mid`'s
     gcMarkRoots only follows rt_gc_roots_* slots and a raw word binder
     is not one.
  3. The representation is the ADDRESS, so `s`, `&s`, `p`, `&p` and a
     nested `s.inner` are all one raw word: `s.f` and `p->f` lower to the
     SAME node, which is the plan's own test for the design reading well.
-}


{-| `sizeof`'s operand (B1, plan Q9/Q10): a TYPE (`sizeof(word)` = 1,
`sizeof(val)` = 5, `sizeof(*S)` = 1) or a STRUCT NAME resolved in the
file's ONE layout table (`Check.sizeofStruct` — never a second copy).  A
bare struct name is NOT a `Type` in this grammar (struct/array VALUES are
B2/B3; `TStruct` does not exist), so the two spellings are two
constructors rather than a widened type grammar.  Both are compile-time
WORD constants: `ESizeof` lowers to a single `Lit (LNumber n)`.
-}
type SizeTarget
    = SizeType Type
    | SizeStruct String


{-| The word binops, 1:1 with Mid.Ir's RawBinOp (the lowerer maps each
constructor straight across; QBE widths/mnemonics stay in Lower).  `>>` is
the arithmetic shift (RShAr), `>>>` the zero-fill one (RShR) — the JS
contract Lower implements.
-}
type WordBinOp
    = WAdd
    | WSub
    | WMul
    | WDiv
    | WBitAnd
    | WBitOr
    | WBitXor
    | WShl
    | WShAr
    | WShR


{-| Signed i64 compares, 1:1 with RawCmpOp.  Result is a WORD 0/1, never a
val (see `EWordCmp` above).
-}
type WordCmpOp
    = WCeq
    | WCne
    | WClts
    | WCles
    | WCgts
    | WCges


{-| f64 binops, 1:1 with RawFltBinOp.  Operands are FLOAT-word expressions —
nested (`fload`/`itof`/another `f+`), never a val or an integer word
(Lower's RawFltBin: a QBE type error at parse time, loud by design).
-}
type FltBinOp
    = FAdd
    | FSub
    | FMul
    | FDiv


{-| f64 compares, 1:1 with RawFltCmpOp.  Result is a WORD 0/1 (extsw-widened
like the word compares) — branch on it directly, or box with `mkbool` for a
`:val`.
-}
type FltCmpOp
    = FLt
    | FLe
    | FGt
    | FGe
    | FEq
    | FNe


{-| The aggcall result shape: `ret` (the 80-B `:ret` bounce-loop call-result
shape) or `val` (the 40-B tagged Value) — exactly the two strings Lower's
RawCallAgg accepts.
-}
type AggShape
    = AggRet
    | AggVal


{-| The builtin set: 1:1 with the raw nodes the DSL builds (RtPrims'
builder block, `-- ---- values ----` onward), plus the two MEASURED macros
(`len32`, `reclen`) and the generic `mkval`.  Each constructor's lowered
node is cited at its `builtinClass` row.
-}
type Builtin
    = MkNum
    | MkBool
    | MkNil
    | MkStr
    | MkFlt
    | MkVec
    | MkVal
    | Payload
    | Payload32
    | Len32
    | TagIs
    | VecLoad
    | VecAddr
    | VecStore
    | StrByte
    | ByteLoad
    | ByteStore
    | WordLoad
    | WordStore
    | AllocVec
    | AllocRaw
    | IToF
    | FLoad
    | FToI32
    | Sext
    | Uext
    | BitNot
    | RecLen
    | RawStr
    | RawSym



-- ============================ J1: the class table ============================


{-| A builtin's class signature.  `Sig params result` is fixed-arity;
`SigMkVal` is the one genuinely variadic form (see `MkVal` below).
-}
type Sig
    = Sig (List Type) Type
    | SigMkVal


{-| J1 — EVERY builtin mapped to its fixed operand and result classes, each
row transcribed from the lowering that will consume it (a build-time
exhaustive `case`: adding a constructor without a row is a compile error,
so the table cannot go stale).  A val in a word slot or vice versa is a
REJECT here, with a source position — the same confusion Lower catches
late-and-cryptic (Lower's rawWordArg / "not a raw word" errors).

Rows and their MEASURED anchors (Lower = Mid.Qbe.Lower, RtPrims =
the DSL helper that builds the node):

  * MkNum  `[word] -> val`   RawMkValue tagNumber (RtPrims mkNum)
  * MkBool `[word] -> val`   RawMkValue tagBoolean (RtPrims mkBool; Lower
    boxes RawTagIs 0/1 with tag 3 to branch)
  * MkNil  `[] -> val`       RawMkValue tagNil
  * MkStr  `[word,word] -> val`   RawMkValue tagString [dataW, lenW]
  * MkFlt  `[float] -> val`  RawMkValue tagFloat — the one mk* taking a
    float word (storeValueWords stores float words with `stored`)
  * MkVec  `[word,word] -> val`   RawMkValue tagVector [dataW, lenW]
  * MkVal  VARIADIC          RawMkValue generic: `(tag :word, words..)`
    where each remaining word is word OR float (Lower's isFloatWordExp
    decides the store width) — hence `SigMkVal`, arity >= 1
  * Payload    `[val,word] -> word`   RawPayload (2nd arg: int-literal index)
  * Payload32  `[val,word] -> word`   RawPayload32 (same; the i32 fields —
    a 64-bit read of them is garbage, Mid.Ir's RawPayload32 contract)
  * Len32      `[val] -> word`        = payload32(v, 1), the i32 len field
  * TagIs      `[val,word] -> word`   RawTagIs (2nd arg: int-literal tag)
  * VecLoad    `[word,word] -> val`   RawVecLoad (vec is a raw ADDRESS —
    the DSL's `wOf l` feeding carV/cdrV — and the result is a blitted VALUE)
  * VecAddr    `[word,word] -> word`  RawVecAddr
  * VecStore   `[word,word,val] -> val`  RawVecStore — EFFECT: Lower ignores
    the dest (the binder slot stays zero); typed val because that is what
    the slot holds, read it and you get the DSL's dead-binder mistake
  * StrByte    `[val,word] -> word`   RawStrByte (str is a VALUE; 0..255)
  * ByteLoad   `[word,word] -> word`  RawByteLoad
  * ByteStore  `[word,word,word] -> val`  RawByteStore — effect, as VecStore
  * WordLoad   `[word,word] -> word`  RawWordLoad (index is a WORD offset)
  * WordStore  `[word,word,word] -> val`  RawWordStore — effect, as VecStore
  * AllocVec   `[word] -> word`       RawAllocVector — SAFEPOINT (the result
    is a raw address valid only to the next safepoint)
  * AllocRaw   `[word] -> word`       RawAllocRaw — SAFEPOINT
  * IToF       `[word] -> float`      RawIToF (sltof)
  * FLoad      `[val] -> float`       RawLoadFlt (a safe bit-read of any
    Value's payload word 0 — no trap on a mistagged arg)
  * FToI32     `[float] -> word`      RawUn RFToI32 (Dtosi; JS ToInt32 —
    its operand is the float word, MEASURED: Lower's RawUn reaches it
    through the same raw-arg evaluator that admits float nodes)
  * Sext       `[word] -> word`       RawUn RSext
  * Uext       `[word] -> word`       RawUn RUext
  * BitNot     `[word] -> word`       RawUn RBitNot
  * RecLen     `[val] -> word`        MACRO, not a node: exactly RtPrims'
    recLenOf tree — `RMul (payload32 v 1) (RSub 1 (tagis v nil))` — the
    nil-aware length that keeps the `{}` literal's unzeroed payload words
    from becoming a huge rt_vec_alloc (RtPrims:216-228)

The lowering (T6) expands the two macros and the mk* shapes from these
same rows — this table, not the lowerer, is where the classes are stated.
-}
builtinClass : Builtin -> Sig
builtinClass b =
    case b of
        MkNum ->
            Sig [ TWord ] TVal

        MkBool ->
            Sig [ TWord ] TVal

        MkNil ->
            Sig [] TVal

        MkStr ->
            Sig [ TWord, TWord ] TVal

        MkFlt ->
            Sig [ TFloat ] TVal

        MkVec ->
            Sig [ TWord, TWord ] TVal

        MkVal ->
            SigMkVal

        Payload ->
            Sig [ TVal, TWord ] TWord

        Payload32 ->
            Sig [ TVal, TWord ] TWord

        Len32 ->
            Sig [ TVal ] TWord

        TagIs ->
            Sig [ TVal, TWord ] TWord

        VecLoad ->
            Sig [ TWord, TWord ] TVal

        VecAddr ->
            Sig [ TWord, TWord ] TWord

        VecStore ->
            Sig [ TWord, TWord, TVal ] TVal

        StrByte ->
            Sig [ TVal, TWord ] TWord

        ByteLoad ->
            Sig [ TWord, TWord ] TWord

        ByteStore ->
            Sig [ TWord, TWord, TWord ] TVal

        WordLoad ->
            Sig [ TWord, TWord ] TWord

        WordStore ->
            Sig [ TWord, TWord, TWord ] TVal

        AllocVec ->
            Sig [ TWord ] TWord

        AllocRaw ->
            Sig [ TWord ] TWord

        IToF ->
            Sig [ TWord ] TFloat

        FLoad ->
            Sig [ TVal ] TFloat

        FToI32 ->
            Sig [ TFloat ] TWord

        Sext ->
            Sig [ TWord ] TWord

        Uext ->
            Sig [ TWord ] TWord

        BitNot ->
            Sig [ TWord ] TWord

        RecLen ->
            Sig [ TVal ] TWord

        RawStr ->
            -- the static C-string address form: `rawstr("...")` — the argument
            -- is a STRING LITERAL (EStr, class TVal) and the result is the raw
            -- word pointer to a content-keyed NUL-terminated data def.  The
            -- lowerer pattern-matches the EStr (a computed val is unrepresentable
            -- — the payload/tagis/mkval literal-slot discipline).
            Sig [ TVal ] TWord

        RawSym ->
            -- (stage 6 A1b) the FUNCTION-symbol address form: `rawsym("...")` —
            -- the argument is a STRING LITERAL (EStr, class TVal) naming a
            -- FUNCTION (a code label: rt_bounce/rt_callN/a q_Rt_* defun) and
            -- the result is the raw word pointer to that function, distinct
            -- from `rawstr`'s content-keyed DATA def.  The lowerer
            -- pattern-matches the EStr exactly as rawstr does.
            Sig [ TVal ] TWord


{-| The surface spelling of each builtin (the parser's keywords and the
checker's error messages read these — one spelling, one place).
-}
builtinName : Builtin -> String
builtinName b =
    case b of
        MkNum ->
            "mknum"

        MkBool ->
            "mkbool"

        MkNil ->
            "mknil"

        MkStr ->
            "mkstr"

        MkFlt ->
            "mkflt"

        MkVec ->
            "mkvec"

        MkVal ->
            "mkval"

        Payload ->
            "payload"

        Payload32 ->
            "payload32"

        Len32 ->
            "len32"

        TagIs ->
            "tagis"

        VecLoad ->
            "vecload"

        VecAddr ->
            "vecaddr"

        VecStore ->
            "vecstore"

        StrByte ->
            "strbyte"

        ByteLoad ->
            "byteload"

        ByteStore ->
            "bytestore"

        WordLoad ->
            "wload"

        WordStore ->
            "wstore"

        AllocVec ->
            "allocvec"

        AllocRaw ->
            "allocraw"

        IToF ->
            "itof"

        FLoad ->
            "fload"

        FToI32 ->
            "ftoi32"

        Sext ->
            "sext"

        Uext ->
            "uext"

        BitNot ->
            "bitnot"

        RecLen ->
            "reclen"

        RawStr ->
            "rawstr"

        RawSym ->
            "rawsym"


{-| The operator FAMILIES' signatures.  The class is the family's, not the
constructor's (every RawBin lowers word,word -> word regardless of op), so
these are constants rather than a per-op case — the op unions above pin the
constructor set, these pin its class contract:

  * `wordBinSig` — `+ - * / & | ^ << >> >>>` : word,word -> word
  * `wordCmpSig` — `== != < <= > >=` : word,word -> BOOL (B1/plan Q2: the
    result class is `bool`, not `word`; the lowered `RawCmp` is UNCHANGED,
    so the corpus is byte-identical — the change is checker-only.  Branch
    on a compare inline, bind it `bool b = ..`, or `mkbool(..)` it for a
    `:val`.)
  * `fltBinSig`  — `f+ f- f* f/` : float,float -> float
  * `fltCmpSig`  — `f< f<= f> f>= f== f!=` : float,float -> BOOL (same
    class change as wordCmpSig; the `RawFltCmp` node is unchanged)
  * `shortSig`   — `&& ||` : val,val -> val (ShortAnd/ShortOr verbatim)

The call forms are NOT rows here because their contracts live with their
own judgments: `ECall` (J2, val args/result — resolved against the user
module externs UNION the runtime's EXPORTED keys), `ERawCall` (J3 +
`rawcallArity`, all-word), `EAggCall` (word fn, word args, word result).
-}
wordBinSig : Sig
wordBinSig =
    Sig [ TWord, TWord ] TWord


wordCmpSig : Sig
wordCmpSig =
    Sig [ TWord, TWord ] TBool


fltBinSig : Sig
fltBinSig =
    Sig [ TFloat, TFloat ] TFloat


fltCmpSig : Sig
fltCmpSig =
    Sig [ TFloat, TFloat ] TBool


shortSig : Sig
shortSig =
    Sig [ TVal, TVal ] TVal



-- ============================ J3: the rawcall table ============================


{-| J3 — the per-symbol ARITY seat for `rawcall`: symbol -> number of WORD
args (every RawCallRaw arg and its result are words by construction —
Lower lowers them all through rawWordArg at `Base L`).  The checker
REJECTS a `rawcall` whose symbol is absent here, and one whose argument
count differs; result-void seats (`free`, `close`, `_exit`) still "return"
a word that the caller must dead-bind, exactly as the DSL does today.

This is a SKELETON that grows with stage-6's `rawAbi` defuns: when those
land they JOIN this table (plan R8's obligation), and any cap on directly-
passed args (the plan could not verify a "3 usable args" claim — mmap
passes 6 today) is enforced HERE, per symbol, not in Lower.

MEASURED arities — every entry below is either read off an actual
RtPrims/RtGc call site (all args explicit) or off the C prototype for
seats no Rt body calls yet (marked "plan"): the plan's J3 list, with the
plan's own `openat4?` resolved to 4 by the five measured openat sites.

C seats / libc, called from Rt bodies today:

  * malloc 1, memset 3 (the frame bulk-zero: dst, 0, 40*nslots bytes), free 1,
    mmap 6 (RtGc — the one 6-arg site)
  * write 3, read 3, lseek 3, openat 4, close 1
  * fork 0, waitpid 3, kill 2, execvp 2, _exit 1, getpid 0
  * chdir 1, getcwd 2, getenv 1, setenv 3
  * dup 1, dup2 2, pipe 1
  * opendir 1, readdir 1, closedir 1, fnmatch 3, mkstemp 1, unlink 1
  * __errno_location 0

rt_* seats (tools/qbe/rt.zig exports) called from Rt bodies today:

  * rt_halt 0 (the prim halt arm; retargets to the Mid Rt.halt under QBE_MIDDRIVER=1)
  * rt_gc_heap_bytes 0, rt_gc_roots_len 0
  * rt_gc_root_kind 1, rt_gc_root_slot 1, rt_gc_root_np 1
  * rt_ss_in 2, rt_ss_readbyte 1, rt_ss_close 1
  * rt_sym_intern 2, rt_value_slot 1, rt_float_text 1

(The rt.zig exports NOT here — rt_string, rt_vec_alloc, rt_raw_alloc,
rt_vec_store(_plain), rt_frame_enter/leave, rt_apply, rt_bounce,
rt_tail_known, rt_prim — are reached through dedicated nodes and
literals, never through `rawcall`.  The stage-6 A2/A4a DRIVER seats —
rt_boot, rt_parse_arg, rt_argv_install, rt_root_push_value_array — are
WORD-in/WORD-out (or void) by A2's shape deviations, so `rawcall` IS
their route and they sit in the table below.)

Plan-listed, no Rt-body call yet (arities from the C prototypes):

  * getdents64 3, fstatat 4, clock_gettime 2, strtod 2, getrlimit 2,
    setrlimit 2

The stage-6 A2 driver seats (arities from tools/qbe/rt.zig's exports):

  * rt_boot 0 (no args; 0 ok / 1 gc-init-failed), rt_parse_arg 2
    (dst *Value, arg cstr; 0 ok / 2 bad-arg), rt_argv_install 3
    (argv_mode, nargs, c_argv; void — the result is dead-bound),
    rt_root_push_value_array 2 (base ptr, live-count ptr; the count is
    read AT SCAN TIME, so the caller wstores it before the push)
-}
rawcallArity : Dict Sym Int
rawcallArity =
    Dict.fromList
        [ ( "malloc", 1 )
        , ( "memset", 3 )
        , ( "free", 1 )
        , ( "mmap", 6 )
        , ( "write", 3 )
        , ( "read", 3 )
        , ( "lseek", 3 )
        , ( "openat", 4 )
        , ( "close", 1 )
        , ( "fork", 0 )
        , ( "waitpid", 3 )
        , ( "kill", 2 )
        , ( "execvp", 2 )
        , ( "_exit", 1 )
        , ( "exit", 1 )
        , ( "getpid", 0 )
        , ( "chdir", 1 )
        , ( "getcwd", 2 )
        , ( "getenv", 1 )
        , ( "setenv", 3 )
        , ( "dup", 1 )
        , ( "dup2", 2 )
        , ( "pipe", 1 )
        , ( "opendir", 1 )
        , ( "readdir", 1 )
        , ( "closedir", 1 )
        , ( "fnmatch", 3 )
        , ( "mkstemp", 1 )
        , ( "unlink", 1 )
        , ( "__errno_location", 0 )
        , ( "rt_halt", 0 )
        , -- T18: the collector reads the U1c globals block through this
          -- accessor (Mid.RtGc's globAddrSym; Lower's finishModule emits the
          -- 0-arg func).  The DSL's `callW globAddrSym []` sites moved to the
          -- surface, and J3 must know the symbol the surface spells.
        ( "rt_glob_addr", 0 )
        , ( "rt_die", 1 )
        , ( "rt_gc_heap_bytes", 0 )
        , ( "rt_gc_roots_len", 0 )
        , ( "rt_gc_root_kind", 1 )
        , ( "rt_gc_root_slot", 1 )
        , ( "rt_gc_root_np", 1 )
        , ( "rt_ss_in", 2 )
        , ( "rt_ss_readbyte", 1 )
        , ( "rt_ss_close", 1 )
        , ( "rt_sym_intern", 2 )
        , ( "rt_value_slot", 1 )
        , ( "rt_float_text", 1 )
        , -- ===== the stage-6 A2 driver seats (A4a's rawcall route) =====
        ( "rt_boot", 0 )
        , ( "rt_parse_arg", 2 )
        , ( "rt_argv_install", 3 )
        , ( "rt_root_push_value_array", 2 )
        , -- ===== the stage-6 B0 frame machinery's remaining U1b root seats
          -- (rt_root_push_value_array is above): rt_root_watermark (the
          -- enter-time shadow-stack depth) and rt_root_pop_to (the
          -- popTo(wm)-NOT-pop truncation).  rt_root_push_ptr/rt_root_pop are
          -- NOT used by the frame pair (popTo, never a bare pop — the
          -- historical qbe-gcbug; pushArray, never pushPtr) — but the
          -- stage-6 B1 apply partial arm's `env_root` dance needs BOTH:
          -- pushPtr (root a COPY of the env pointer, re-read after the
          -- allocArray scavenge) and the bare pop that balances it.
        ( "rt_root_watermark", 0 )
        , ( "rt_root_pop_to", 1 )
        , ( "rt_root_push_ptr", 1 )
        , ( "rt_root_pop", 0 )
        , -- ===== the stage-6 A4b program/print seats (the A2 word-in/out
          -- seats the driver's tail reaches: isProgram/runProgram/print +
          -- the single-value root for the result/model slots)
        ( "rt_root_push_value", 1 )
        , ( "rt_is_program", 1 )
        , ( "rt_run_program", 2 )
        , ( "rt_print_value", 1 )
        , ( "getdents64", 3 )
        , ( "fstatat", 4 )
        , ( "clock_gettime", 2 )
        , ( "strtod", 2 )
        , ( "getrlimit", 2 )
        , ( "setrlimit", 2 )
        ]
