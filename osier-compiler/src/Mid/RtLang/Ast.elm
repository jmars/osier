module Mid.RtLang.Ast exposing
    ( AggShape(..)
    , Builtin(..)
    , Block
    , BareBlock
    , BareDefun
    , BareProgram
    , Decl(..)
    , Defun
    , Effect(..)
    , EnumEntry
    , Exp(..)
    , Export
    , ExportSig
    , FfiParam
    , FfiSig
    , FfiTy(..)
    , Field
    , Flag(..)
    , FlagGuard(..)
    , FltBinOp(..)
    , FltCmpOp(..)
    , Header
    , Key
    , Located
    , Module
    , OTy(..)
    , PTy(..)
    , Param
    , Program
    , Sig(..)
    , SizeTarget(..)
    , Span
    , Stmt(..)
    , ArrayInit(..)
    , StructInit(..)
    , StructMember(..)
    , Sym
    , Term(..)
    , Type(..)
    , WordBinOp(..)
    , WordCmpOp(..)
    , allBuiltins
    , allWordSig
    , bareBlock
    , bareDefun
    , bareProgram
    , builtinClass
    , builtinName
    , fltBinSig
    , fltCmpSig
    , lineOf
    , rawcallArity
    , renderSpan
    , reposition
    , rowColOf
    , shortSig
    , splitArrow
    , splitLines
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

B7 — THE `val` BRIDGE, AS RULES (plan §Q11, Terra's Lua-value posture).

A `val` is the opaque 40-byte host handle.  What a user program MAY do with
one is a short list; what the compiler CANNOT check about it is TWO numbered
obligations.  Both are stated here, the way Terra states its Lua-value rules,
rather than left to be inferred from the lowering.

LEGAL on a `val` (each form has a positive row in TestMain's B7 section, and
the bridge fixture tools/qbe/fixtures/{Wbridge.mid,midb7.elm} RUNS them):
  * BIND — a parameter (`x : val`) or a local (`val v = ..;`);
  * PASS to a `call` (a `val` parameter) and RETURN (a `val` result);
  * STORE into a val slot — a struct field (`s.item = v;` / `p->item = v;`),
    a `val[N]` array element, or a `*val` view via `vecstore`/`p[i] = v`.
    The store is the 40-byte blit (`RawVecStore` at a VALUE-unit index —
    LowerToIr's field store addresses the field in BYTES and indexes 0);
  * READ BACK from those: `s.item`, `vecload(p, i)`, `p[i]`.  (`*p` is the
    `*word` deref only — there is no `*val` deref; index 0 is the spelling.)
  * ROOT existing ids for a block via `withroots [ids] { .. }` (J10);
  * BOX via the `mk*` primitives and unbox only through the sanctioned READS
    (`payload`, `payload32`, `len32`, `tagis`, `strbyte`, `fload`, `reclen`)
    — never a cast.

ILLEGAL, and ENFORCED (one negative row each; the judgment is named):
  * a `val` in a WORD SLOT — a `word`/`int`/`bool`/`*T` binder, a word
    builtin's operand, a `rawcall` argument, a `word` field or element
    (J1/J3/J13: "needs word, got val");
  * a WORD READING A VAL — the same judgments from the other side:
    `wload(v, 0)` (the address slot wants a word), `payload` of a word, a
    `val` bound into a word binder;
  * `==` / `<` ON VALUES — the six compares are `word,word -> bool`, so a
    `val` operand is a J1 reject, and the message now names the remedy
    (`call Rt.=(a, b)` for the boxed bool, `Rt.deepEq` for structural
    equality; `Check.checkWordCmp`).  There is no value ORDERING at all;
  * ANY CAST OF A `val` — `[word](v)`, `[int](v)`, `[*T](v)`, `[val](v)`,
    and `[val](e)` of anything but a `bool`, are all outside `castClass`'s
    matrix (plan Q10: val casts NONE);
  * a `val` CONDITION that is not a BOXED BOOL.  The val-cond PATH stays
    legal and is load-bearing (`mkbool(..)`, `&&`/`||`, a `val` binder or
    `call` that holds one — runtime.mid's own `if (isDup)`/`if (lessB)`
    sites); B7 enforces the sliver the checker can PROVE: `mknum`, `mkstr`,
    `mkvec`, `mkflt`, `mknil` and a string literal can never carry the
    boolean tag, and the value test is FALSE only for a boolean whose
    payload is 0 — every other tag is TRUE, so `if (mknum(0))` takes the
    then-branch (`Check.unboxedValCond`).  `mkval(tag, ..)` and a `val`
    binder/call stay legal: their tag is not decidable here, and that
    boundary is stated, not hidden.  So does `mkbool(1)` — a constant boxed
    bool in a condition is a constant branch (`if (1)`'s own objection), but
    the checker does not fold builtins, and pretending otherwise would be a
    second, weaker judgment in the same seat.

THE TWO OBLIGATIONS (documented; the compiler CANNOT check them).  Both come
from one fact: a `val` is a handful of WORDS, and only the roots the frame
machinery REGISTERED are scanned.

  1. ROOTING.  A `val` stored in RAW MEMORY — a struct field, an array
     element, a `*val` view, any seat that is not a `val` binder — is
     INVISIBLE to the collector: that copy roots nothing.  Its REFERENT must
     be rooted across every safepoint between the store and the last read of
     the copy.  The sanctioned long-lived seats are (a) a `val` BINDER:
     `rt_frame_enter` registers the whole pooled frame as one
     ROOT_VALUE_ARRAY, which is also why `withroots` is a documented NO-OP on
     this backend (Mid.Qbe.Lower's WithRoots arm — the roots it names already
     exist); and (b) a REGISTERED root array,
     `call Rt.rootPushValueArray(base, countPtr)`, whose elements
     `Rt.gcScanValueArray` follows and whose count is read AT SCAN TIME — the
     collector scans it AND (under a moving collector) updates it in place.
     An UNREGISTERED raw copy is scanned by neither, and the collector makes
     the consequence visible in the same place — the block's first word,
     which for a `value_array` is element 0's tag: the sweep writes the
     free-list link there (`Rt.gcSweep`), and the nursery scavenge POISONS it
     (tag 15 on the forwarded young body, `Rt.gcScavPtr`) before abandoning
     the young words.  The probe is
     tools/qbe/fixtures/{Wval.mid,valchurn.elm} and its `stale` arm reads 0
     either way.

  2. MOVE STALENESS.  A raw `val` is a byte copy, so it goes stale whenever
     its referent MOVES — even when the referent was rooted (the root slot
     gets the new address; the raw copy does not).  RULE: **a raw `val` may
     be READ only inside the no-safepoint window in which it was WRITTEN**;
     across a safepoint, re-load it from a rooted slot.  The safepoints a
     user program can reach are the allocating builtins (`allocvec`,
     `allocraw`), a string literal (`EStr` — the intern), and any `call`
     whose callee allocates.
     MEASURED — AND OBLIGATION 2 IS OBSERVABLE IN THE DEFAULT BUILD, which is
     what an earlier version of this header had INVERTED (it named a deleted
     Zig collector as the moving one).  There is ONE collector — the Mid
     program, `runtime.mid` — and it has TWO mechanisms that disagree on
     exactly this point:
       * THE NURSERY SCAVENGE (`Rt.gcScavenge`) is the MOVING one, and it is
         the DEFAULT since the flip: `run.js` splices the nursery on unless
         `QBE_MIDGC_YOUNG` is exactly "0".  `Rt.gcScavPtr` copies a surviving
         young body into old space, leaves the FORWARDED bit plus the
         forwarding address in the young header and POISONS its body word 0,
         and `Rt.gcScavRoots`/`Rt.gcScavValuesTab` write the new address BACK
         into the root slot.  Under it a rooted referent survives and the raw
         copy does not: the probe's `rooted` arm reads 1, i.e. the raw copy's
         tag was lost while the root slot read fine.
       * THE FULL COLLECT (`Rt.collect` -> `gcMarkRoots` -> `gcDrain` ->
         `gcSweep`) is a NON-MOVING mark-sweep (`gcMarkRoots` marks without
         writing anything back), so in a `QBE_MIDGC_YOUNG=0` run a rooted raw
         copy can never go stale — the same arm reads 11 there.
     The probe (tools/qbe/fixtures/{Wval.mid,valchurn.elm}) pins both from ONE
     binary at `QBE_HEAP_MB=16`: `10001` with the nursery ON — the DEFAULT
     (obligation 2 visible in the `rooted` arm: raw copy 0, rooted slot 1) —
     and `10011` with `QBE_MIDGC_YOUNG=0` (obligation 1 only; the same arm
     reads 11).  Both runs agree that the UNROOTED arm (`stale`) reads 0 once
     a collection runs, and that nothing breaks at all when the churn is too
     small to collect — the dose control that shows the mechanism is the
     collection, not the store.

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


{-| A whole `.mid` file: the header, the file-scoped `struct`/`enum`/
`extern` declarations (`decls`), and the defun list (`Program`).
`Parse.parseModule` returns this; the defun list is the same `Program`
every lowerer/checker already consumes (the header and the declarations
are NOT lowered — they ride beside the program, consumed by the
A1 checker (J11/J14) to build the struct/enum tables and the A2 lowerer to
lay out fields; an `extern` rides the same slot and is CONSULTED BY NO ONE
yet, cffi U2's typed call boundary being what reads it).  v1 has NO
cross-module import: these declarations are
FILE-SCOPED to their own `.mid` module — a `*S` in one module cannot name
a struct declared in another (pointers cross a module boundary only as
the opaque `word`/`*word` the plan §2.5 already pins).

`source` is the EXACT module text this AST was parsed from, verbatim —
never a re-render of the tree.  It rides the AST so that a diagnostic
raised on a `Module` (which may be handed to it long after the load lane
that read the file) can quote the offending line; today the text is only
in scope inside the loaders.  It is carried, not consulted: nothing
downstream reads it, so it cannot move an emitted byte.
-}
type alias Module =
    { header : Header
    , decls : List Decl
    , defuns : List Defun
    , source : String
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

`ExternDecl` is the THIRD file-scoped declaration (cffi plan §2) and rides
the same slot for the same reason: `Module.decls` already reaches both
consumers (the checker's declarative folds and the lowerer's `lowerAll`),
so a C signature needs no new plumbing.  It is not a layout table: it is
the width table for a `rawcall` symbol's C boundary (U2 reads it).
`Module.decls` carries it; NOTHING consults it in this unit.
-}
type Decl
    = StructDecl { name : String, members : List StructMember }
    | EnumDecl { name : String, entries : List EnumEntry }
    | ExternDecl { name : String, sig : FfiSig }


{-| THE C FFI WIDTH VOCABULARY (cffi plan §3) — the ONLY widths an `extern`
declaration may name, as a CALL-BOUNDARY REGISTER CLASS rather than a
memory layout.  Each row is a class the IL can already spell and the
vendored QBE already emits: `i32`/`u32` are a `w` call result (plus the
`extsw`/`extuw` extension the result read needs), `i64`/`u64`/`ptr` are an
`l` one, `f64` is `d`, and `void` keeps today's dead `l` temp — so a
declaration can never ask for an instruction the backend lacks.  A width
OUTSIDE this table (`u8`, `i16`, `char*`, a struct by value, `val`) is a
parse reject: narrow and sub-word widths are MEMORY widths, and
width-typed memory is the plan's own later unit (U6) with a layout oracle,
not this grammar.

DISTINCT FROM `OTy` (the export block's declared-type grammar): `OTy` is
polymorphic and is deliberately NOT an ABI vocabulary; folding `i32`/`ptr`
into it would put C register classes into the Osier type language.
-}
type FfiTy
    = FI32
    | FU32
    | FI64
    | FU64
    | FPtr
    | FF64
    | FVoid
    | -- (cffi U6) THE SUB-WORD WIDTHS — a FIELD width only.
      --
      -- They are in this vocabulary because a struct field's declared width IS
      -- the same table read the other way round (a field is "an `i16`", the
      -- call boundary is "an `i16` register argument"), and a separate
      -- near-identical width type would be the second table this repo keeps
      -- paying for.  BUT the two roles are not the same: `i8`/`u8`/`i16`/`u16`
      -- are MEMORY widths with a sign rule and a byte count, and C carries
      -- them in a 32-bit register when they cross a call boundary.
      --
      -- WHAT HAPPENS IF ONE IS WRITTEN AS A PARAMETER OR RESULT TYPE: the
      -- `extern` parser's own width table (`Parse.elm`'s `ffiTyOf`) does NOT
      -- admit them, so it is a PARSE reject with the R-01 message naming the
      -- field-only reason.  That is deliberate — it keeps these constructors
      -- UNREACHABLE from the call boundary, so no `case` on `FfiTy` in the
      -- call lowering can silently acquire a sub-word argument class.
      FI8
    | FU8
    | FI16
    | FU16


{-| One declared C parameter: its NAME is documentation only (the call site
passes positionally), its width is what the boundary checks.  `void` is not
a legal `FfiTy` here — the parser rejects it in this position (a parameter
must name an actual register class).
-}
type alias FfiParam =
    { name : String
    , ty : FfiTy
    }


{-| A declared C signature: the fixed parameters in declaration order, the
trailing `...` flag (`varargs`), and the result width.  CARRIED ONLY in
this unit: nothing in the checker or the lowerer CONSULTS it yet, so a
declaration emits no byte — the typed call boundary that reads it is the
plan's U2, and until it lands the declaration is a parsed-and-ignored
record (the "seat that is never called" shape, stated in the unit's report).
-}
type alias FfiSig =
    { params : List FfiParam
    , varargs : Bool
    , result : FfiTy
    }


{-| One struct BODY ITEM — B5 (handoff-midlang-b5): a named field, or an
ANONYMOUS UNION BLOCK (`union { n : word; p : *Msg; pair : Pair; }`).

THE UNION RULE (plan Q4, Terra's shape — this whole type exists for it):
the members of a union block SHARE the block's offset (the block's start),
and the block contributes `max(member sizes)` words to the struct, so the
NEXT field starts after that max, word-aligned like every other field.  A
member of a union block is a PROMOTED name: `m.n`, `m.p`, `m.pair` all
resolve through the file's ONE layout table (`Check.fieldOffset`) to the
same offset — there is no `m.u.n` spelling, because the block has no name.

WHAT THIS IS NOT.  This is a C union — a layout overlap, nothing more.  It
carries NO tag, and the language has no `match`/`switch` (Q2: dispatch is
`if` chains, the measured no-`Case` discipline): a tagged union is an
ordinary `word` tag field beside the block plus the if-chain that reads it.
Reading the member the tag does NOT select is the USER'S OBLIGATION — it
reinterprets the same words, exactly as in C, and no checker can see it.
A `val` member is allowed by the layout arithmetic (`val` = 5 words, beside
a `word` = 1 the block is 5) and is the §Q11 hazard in the open: raw memory
holding a handle is NOT traced, so the rooting obligation is on the writer,
not on the garbage collector.
-}
type StructMember
    = MField Field
    | MUnion (List Field)


{-| One struct field: a name, its type, and — cffi U6 — an OPTIONAL declared
MEMORY WIDTH (`Nothing` = the type's own width).  Fields are in DECLARATION
ORDER and the layout rule is order-preserving and BYTE-granular with
per-field alignment (`Check.layoutOf`), so a `u16` may sit at byte 4 where the
word before it ended.

`width` is what a libc struct needs and the `Type` grammar cannot say:
`events : u16` is an integer field FOUR BYTES INTO a `{ i32; u16; u16 }` —
half a word, and unsigned.  The spelling carries a `Type` AND a width because
the two answer different questions: `ty` is the CLASS the field reads/writes
as (always `TWord` for a narrow field — a sub-word load WIDENS into the word
register, so the surrounding expression sees a word), while `width` is the
BYTE COUNT and SIGN RULE the access lowers to (`loaduh`/`storeh` for `u16`,
`loadsh`/`storeh` for `i16`).  The width is thus the SAME information the load
node carries (Mid.Ir's `RawMemLoad { width, signed }`), taken from the ONE
place the declaration wrote it — which is the point: a field cannot be laid
out at one width and accessed at another without the two disagreeing loudly
(`Check`'s J11 rejects a width on a non-`TWord` field, and the lowerer reads
the width from the table, never from a guess).

WHAT A WIDTH IS NOT: it is not a `Type`.  A narrow field's VALUE is a word
(the widened read), there is no `i16` expression class, no narrow arithmetic
and no narrow array element — so `u16` is spellable in a FIELD position only
(the `extern` width table does not admit it: see `FfiTy`).  A NARROW ARRAY
ELEMENT (`d_name : u8[256]`, the `struct dirent` tail) is therefore NOT
expressible yet: arrays are word-scaled (`TArray Type Int`), and this unit
does not widen `Type`.  Named at the census fixture, not silently absent.

B5: a `Field` is also one MEMBER OF A UNION BLOCK (`MUnion` carries a list of
these) — the same record, a different layout rule applied to it.  A `_pad`
field is an ordinary word field — nothing special to check — it keeps the
layout table honest where a real layout has a hole (region word 7; globals
words 3–7, 14–15).  Field types are the `Type` grammar: `word`, `val` (40
bytes = 5 words, stored INLINE — allowed, nothing traces it, the rooting
discipline is a stated contract not a type property), `float` (parsed here;
REJECTED by the A1 checker's J11 — Mid.Ir has no raw-memory f64 load node),
and the three pointer families.  Self-reference by value (`next : S`) is the
A1 checker's J11 reject (infinite size); by pointer (`next : *S`) is the only
recursion.
-}
type alias Field =
    { name : String
    , ty : Type
    , width : Maybe FfiTy
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

`span` is the HEADER span — the `defun` keyword through the body's opening
`{`, which is the whole of the declaration a reader can point at when the
error is about the SIGNATURE (J5's duplicate parameter, `validateSig`).  It
does NOT cover the body: a body error carries its own statement's span.
-}
type alias Defun =
    { key : Key
    , flags : List FlagGuard
    , params : List Param
    , ret : Type
    , body : Block
    , span : Span
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

BOTH slots are `Located` (U2): every statement and the terminator remember the
source span they were parsed from, which is what a checker error points its
caret at.  A node the PARSER synthesized (a loop body's implicit `continue`,
the unreachable fall-through term) carries a span pointing at the block's own
`}` — never at a user token, and never a lie about where the code is
(Parse.elm's `block`/`loopBlock`).  The lowerer's own B4 rewrites reuse the
span of the node they stand in for.

`BareBlock` below is the SAME shape without the wrappers, for code that only
wants the tree (the test suite's expected literals).
-}
type alias Block =
    { stmts : List (Located Stmt)
    , term : Located Term
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
    spellable.  Each carries its OWN span, separate from the `for`
    statement's: an error inside the init points at the init (U2).  A `continue` in `body` RUNS `step` before re-testing —
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
    | SFor { init : Maybe (Located Stmt), cond : Exp, step : Maybe (Located Stmt), body : Block }


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

  1. IT WAS HEAP, NOT STACK — the value's lifetime was the program's, not
     the frame's, and NOTHING freed it (a struct binder inside a loop
     allocated per iteration).  CORRECTED BY B4b: `RawAllocN` landed in
     B4 and `LowerToIr.structAlloc` is now `RawAllocN sizeof(S)`, i.e.
     QBE stack memory the frame reclaims — no free exists or is needed.
     The reverse obligation arrived with it: the ADDRESS must not outlive
     the frame, which `Check`'s escape rule enforces (see its
     `frameAddrOf` note for what is enforced and what stays a documented
     obligation).
  2. The GC does NOT see it, so a `val` FIELD is an unrooted handle —
     exactly plan §Q11's obligation (no-safepoint window + rooted
     referent), which B7 owns.  This is forced, not a shortcut:
     `RawAllocRaw` (the GC's own raw block) would be no better — a raw
     block that no root points at is SWEPT, because `runtime.mid`'s
     gcMarkRoots only follows the MID ROOT REGISTRY's slots (and the values
     table's), and a raw word binder is not one.
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

C seats / libc STILL undeclared, called from Rt bodies today (cffi U5
migrated the rest to `runtime.mid`'s `extern` block, which DELETED their
rows — R-08 forbids a symbol in both tables):

  * getpid 0 — kept because nine TestMain rows pin the table MECHANISM by
    spelling `rawcall getpid()` (migrating it would rewrite the rows that pin
    the seat, for a width fix plan §7.1 MEASURED as not needed on this glibc).
  * malloc 1, free 1, write 3 — kept ONLY because live gate fixtures still
    rawcall them undeclared (tools/qbe/fixtures/ffiv-void.mid, Wnods.mid,
    Wesc.mid, Iopin.mid).  A `.mid` extern is FILE-scoped, so declaring them
    in runtime.mid would not type those sites; it would only delete the row
    out from under them (a loud J3 "in no signature table").  Migrate the
    fixtures, then declare — one move.
  * mmap 6 (RtGc — the one 6-arg site), exit 1 — outside the plan's U5 list.
  * clock_gettime 2 — see "plan-listed" below.
    (strtod was here; O5 seat 4b gave it its first site and declared it.
     getrlimit 2 and setrlimit 2 were here too and are now DECLARED: the
     rlimit seat COMPARES getrlimit's C `int` result, which is the measured
     live width class, so the pair moved to runtime.mid's `extern` block and
     their rows went with them — R-08 refuses a symbol in both tables.)

MIGRATED by cffi U5 (row DELETED, signature declared in runtime.mid):
openat 4, __errno_location 0, waitpid 3, readdir 1, opendir 1,
closedir 1, close 1, dup 1, dup2 2, pipe 1, unlink 1, mkstemp 1, fnmatch 3,
chdir 1, getcwd 2, getenv 1, setenv 3, kill 2, execvp 2, fork 0, read 3,
lseek 3, memset 3 (the frame bulk-zero, dst/0/40*nslots bytes — its IR-level
RawCallRaw seat in Mid.Rt is untouched by this table, but the SURFACE site in
runtime.mid is what the row governed), _exit 1, getrlimit 2, setrlimit 2.
STAGE 7E ADDED getdents64 3 and fstatat 4 to this list — the effect-loop
port's dir/stat leaves are their first call sites, and they are declared in
runtime.mid with the C prototypes' widths (getdents64's `int`, not the raw
syscall's `long`).

rt_* seats (tools/qbe/rt.zig exports) called from Rt bodies today:

  * rt_halt 0 (the prim halt arm; retargets to the Mid Rt.halt under QBE_MIDDRIVER=1)
  * (ZIGHOST Z4a) rt_gc_heap_bytes and rt_float_text DELETED — the heap knob
    is read by Rt.gcInit through Rt.gcEnvNum, and the float text is Mid's
    (Rt.floatText: strfromd/strtod + the three rules), so neither symbol is in
    rt.o any more
  * (ZIGHOST Z1) rt_gc_roots_len/root_kind/root_slot/root_np DELETED — the
    collector's root walk reads the MID ROOT REGISTRY in the globals block
    (words 4/5/6 = base/count/cap), so no body reads a root seat and the ten
    rt_root_*/rt_gc_root_* seats are gone from rt.o
  * (O5) rt_ss_in/readbyte/close DELETED — the registry is Mid-owned
  * (O5) rt_sym_intern DELETED — the intern table is Mid-owned
  * (O5 seat 3) rt_value_slot DELETED — the lookup is Mid's (the table stays
    the HOST's; rt_boot publishes its base into the GLOBALS BLOCK word 3)

(The rt.zig exports NOT here — rt_string, rt_vec_alloc, rt_raw_alloc,
rt_vec_store(_plain), rt_frame_enter/leave, rt_apply, rt_bounce,
rt_tail_known, rt_prim — are reached through dedicated nodes and
literals, never through `rawcall`.  The stage-6 A2 DRIVER seat rt_boot is
WORD-in/WORD-out by A2's shape deviation, so `rawcall` IS its route and it
sits in the table below.  rt_root_push_value_array was the second such seat
and is GONE at ZIGHOST Z1 with the rest of the family: the registry is Mid's,
reached by `call`, and its six WRITE seats are exported so a user `.mid` can
reach them too.  (O5 seat 4b: rt_parse_arg and rt_argv_install are GONE from the table
AND from the Zig host — the entry-arg parser and the *argv* list are Mid
defuns reached by `call`, which is what the A4a emission row now pins.)

Plan-listed, no Rt-body call yet (arities from the C prototypes):

  * clock_gettime 2

  (CORRECTION, MEASURED at cffi U5: `clock_gettime` x3 in Rt.collect — the
  GC-ARC F1 stats instrument — IS an Rt-body call site today, so "no Rt-body
  call yet" is stale for it.  It stays a row and stays UNDECLARED: nothing
  compares its result as a C `int`, so the width class that pulled
  `getrlimit`/`setrlimit` off this list does not apply.  `poll`, `getdents64`
  and `fstatat` have sites and are DECLARED — 7B for `poll`, 7E for the other
  two — so their rows are gone.  `strtod` LEFT this list at O5 seat 4b:
  Rt.parseArg is its site, so it is a declared extern with the C prototype's
  `f64` result.  `getrlimit`/`setrlimit` LEFT it too: Rt.main's rlimit seat
  COMPARES getrlimit's C `int` (`rc == 0`), the measured-live width class, so
  both are declared externs in runtime.mid and their rows are deleted.)

The stage-6 A2 driver seats (arities from tools/qbe/rt.zig's exports):

  * rt_boot 0 (no args; 0 ok / 1 gc-init-failed)

  (ZIGHOST Z1: rt_root_push_value_array's row is DELETED with its seat — the
  root registry is Mid-owned and reached by `call`.)

  (O5 seat 4b: rt_parse_arg 2 and rt_argv_install 3 are GONE from this table
  and from the Zig host.  runtime.mid's Rt.parseArg (dst *Value, arg cstr;
  mknum(0) ok / mknum(2) bad-arg) and Rt.argvInstall (argv_mode, nargs,
  c_argv; the *argv* cons list over a ROOTED C-heap accumulator slot) are Mid
  defuns.)
-}
rawcallArity : Dict Sym Int
rawcallArity =
    Dict.fromList
        [ -- ===== the libc rows cffi U5 CANNOT migrate yet (a live fixture
          -- still rawcalls each one UNDECLARED, and a `.mid` extern is
          -- file-scoped): see the docstring.  malloc/free/write.
        ( "malloc", 1 )
        , ( "free", 1 )
        , ( "write", 3 )
        , -- outside U5's list; the all-word shape stands
        ( "mmap", 6 )
        , ( "exit", 1 )
        , -- U5 LEFT IT: the TestMain suite's canonical undeclared rawcall
          -- sample (nine rows pin the table mechanism by spelling
          -- `rawcall getpid()`), and plan §7.1 MEASURED getpid
          -- pre-extended — no width fix to buy.  See runtime.mid's header.
        ( "getpid", 0 )
        , -- ===== plan §8 item 5: declared by the effect-loop port, not U5.
          -- clock_gettime DOES have Rt-body sites today (the GC stats
          -- instrument) and stays undeclared: its result is never compared as
          -- a C `int`.
          -- getdents64 and fstatat LEFT this table at stage 7E: that unit
          -- gave them their first call sites (the listDir walk and the stat
          -- leaf) and DECLARED them in runtime.mid, and R-08 refuses a symbol
          -- in both tables — so the row and the declaration move together,
          -- the rule U5 followed for the other twenty-four.
        ( "clock_gettime", 2 )
        , -- (O5 seat 4b) strtod LEFT this table: Rt.parseArg is its first
          -- call site and it is DECLARED in runtime.mid with the C
          -- prototype's `f64` result (a `=d call`), so R-08's both-tables
          -- refusal applies — the row and the declaration move together.
          -- getrlimit/setrlimit LEFT the same way (the rlimit width fix):
          -- Rt.main COMPARES getrlimit's C `int` result, so both are
          -- declared externs with `-> i32` now.
        ( "rt_halt", 0 )
        , -- T18: the collector reads the U1c globals block through this
          -- accessor (Mid.RtGc's globAddrSym; Lower's finishModule emits the
          -- 0-arg func).  The DSL's `callW globAddrSym []` sites moved to the
          -- surface, and J3 must know the symbol the surface spells.
        ( "rt_glob_addr", 0 )
        , ( "rt_die", 1 )
        -- (ZIGHOST Z4a: rt_gc_heap_bytes DELETED — Rt.gcInit reads
        --   QBE_HEAP_MB through Rt.gcEnvNum, so no body reads the seat)
        -- (ZIGHOST Z1: rt_gc_roots_len / rt_gc_root_kind / rt_gc_root_slot /
        --   rt_gc_root_np DELETED — the collector walks the Mid root registry
        --   now, so no body reads a root seat and these rows would name
        --   symbols rt.o no longer defines)
        -- (O5: rt_ss_in/readbyte/close DELETED — the string-stream registry
        --   is Mid-owned now, Region slots 38..39 + Rt.ssTab/ssIn/ssInGo/
        --   ssReadbyte/ssClose in runtime.mid)
        -- (O5 seat 2: rt_sym_intern DELETED — the intern table is Mid-owned)
        -- (O5 seat 3: rt_value_slot DELETED — Rt.value/Rt.valScanGo read the
        --   host table through the GLOBALS BLOCK word 3)
        -- (ZIGHOST Z4a: rt_float_text DELETED — Rt.str's float arm calls the
        --   Mid Rt.floatText, and no body rawcalls the seat)
        , -- ===== the stage-6 A2 driver seats (A4a's rawcall route) =====
        -- (O5 seat 4b: rt_parse_arg and rt_argv_install DELETED — the
        --   entry-arg parser and the *argv* list are runtime.mid's
        --   Rt.parseArg/Rt.argvInstall, reached by a Mid call)
        -- (ZIGHOST Z5: rt_boot DELETED — the boot is runtime.mid's Rt.boot,
        --   reached by `call`; the values table and the three standard streams
        --   are Mid's and the Zig Gc/Vm are never constructed)
          -- (ZIGHOST Z1: rt_root_push_value_array / rt_root_watermark /
          --   rt_root_pop_to / rt_root_push_ptr / rt_root_pop /
          --   rt_root_push_value DELETED with their seats.  The registry is
          --   Mid's now — runtime.mid's Rt.rootPushValueArray/rootWatermark/
          --   rootPopTo/rootPushPtr/rootPop/rootPushValue, reached by `call`
          --   (a Mid edge, so `rawcall` has no arity to record) — and the six
          --   write seats are EXPORTED so a user `.mid` can reach them.)
          -- ===== the stage-6 A4b program/print seats (the A2 word-in/out
          -- seats the driver's tail reaches: isProgram/runProgram/print)
          ( "rt_is_program", 1 )
        , ( "rt_run_program", 2 )
        -- (ZIGHOST Z4b: rt_print_value DELETED — the driver's output walk is
        --   runtime.mid's Rt.printValue, reached by `call`)
        ]


{-| EVERY builtin constructor, in one place — the surface's spelling set as
`builtinName` spells it.  Moved here from `Parse.elm` by cffi U2: the extern
declarations' J15 rule (R-07) must refuse a C symbol that collides with a
builtin SPELLING, and Check cannot import Parse (Parse imports Check's Ast).
Parse now reads this list, so the one-table property holds for the spellings
too — a builtin added here joins both the parser's keyword table and the
extern judgment without a second edit.
-}
allBuiltins : List Builtin
allBuiltins =
    [ MkNum
    , MkBool
    , MkNil
    , MkStr
    , MkFlt
    , MkVec
    , MkVal
    , Payload
    , Payload32
    , Len32
    , TagIs
    , VecLoad
    , VecAddr
    , VecStore
    , StrByte
    , ByteLoad
    , ByteStore
    , WordLoad
    , WordStore
    , AllocVec
    , AllocRaw
    , IToF
    , FLoad
    , FToI32
    , Sext
    , Uext
    , BitNot
    , RecLen
    , RawStr
    , RawSym
    ]


-- ==================== THE SOURCE-POSITION SEAT (U1) ====================
--
-- The surface language reports errors against the source text it was parsed
-- from.  This section is the WHOLE of the AST's part in that: a `Span` of raw
-- offsets, the `Located` wrapper that will carry one (U2 retypes `Block` and
-- `Defun` to use it — nothing in this section is referenced by the parse,
-- check or lower paths yet), and the ONE function that turns an offset pair
-- into the row/col/line/caret a renderer prints.


{-| A source SPAN — `start` and `end` are UTF-16 CODE-UNIT OFFSETS into the
module text, the parser's own unit (ParserFast.elm:373-380: "behind the scenes
it is just a flat array of UTF-16 characters"; an Elm `String` offset and a
`ParserFast` offset are therefore the same number, not two conventions to
convert between).

WHY OFFSETS RATHER THAN ROW/COLUMN RECORDED AT PARSE TIME (MEASURED): every
Parse dispatch site is already the `offsetSourceAndThen` pattern — 58
`ParserFast.offsetSourceAndThen` occurrences, none of them in a comment
(`rg -c 'ParserFast\.offsetSourceAndThen' Parse.elm`), `itemStep` Parse.elm:3061
and `atom` Parse.elm:729 among them — so a node's START offset is
in hand with zero combinator churn, while a row/column would have to be derived
from that same offset anyway to print the snippet line.  So the AST keeps the
offsets and `renderSpan` computes the position once, at render time, from the
source the error is reported against.

END CONVENTION (pinned, and the reason `renderSpan` trims): `end` is the offset
where the node's parser STOPPED, i.e. where the NEXT TOKEN begins.  Every token
reader consumes its own trailing whitespace and `//` comments (`spelled`,
Parse.elm:3770-3772), so `end` routinely OVERHANGS trailing spaces, a trailing
comment, and even comment-only lines — it never reaches into the next token.
A consumer must therefore never read `end` as "the node's last character"; the
pair is only meaningful through `renderSpan`.
-}
type alias Span =
    { start : Int
    , end : Int
    }


{-| A node that remembers the span it was parsed from.  U1 introduces the
wrapper only: U2 retypes `Block` (`stmts`/`term`) and gives `Defun` a header
span, so the checker can name the STATEMENT an error is on.  Sub-expression
(`Exp`) spans are deliberately NOT part of this arc — priced and deferred in
the plan's D1 decision.
-}
type alias Located a =
    { node : a
    , span : Span
    }


{-| The lines of a source text, split on `\n` and keeping every empty run —
`String.split "\n"` exactly, for callers that cannot have `String.split`.

`String.split` is NOT in this language's String surface (MEASURED: the
self-host front end rejects it — `Mid.RtLang.Parse`'s `firstSegment` note), and
this module IS compiled by that front end, so the split is spelled with the two
prims that do exist (`String.slice`, `String.length`).

THE ONE HOME: `Mid.Rt` and `Mid.RtLang.Parse` both import this module, so the
workaround lives here and nowhere else — it was `Mid.Rt`'s until the
source-position seat below needed line splitting too, and the dependency
direction (`Rt` imports `Ast`, `Parse` imports `Ast`) makes this module the
owner.
-}
splitLines : String -> List String
splitLines s =
    let
        go : Int -> Int -> List String -> List String
        go start i acc =
            if i >= String.length s then
                List.reverse (String.slice start i s :: acc)

            else if String.slice i (i + 1) s == "\n" then
                go (i + 1) (i + 1) (String.slice start i s :: acc)

            else
                go start (i + 1) acc
    in
    go 0 0 []


{-| The 1-based row/column of an offset — the SAME convention ParserFast
reports a parse error's position in (`DeadEnd`'s `row`/`col` start at 1,
ParserFast.elm:202), so a span-derived position and a parse error's position
read as one coordinate system in one error surface.

The row is the number of newlines before the offset, plus one; the column is
the 1-based offset WITHIN its own line.  Both are counted over the same UTF-16
units the offsets are in — one scan of the prefix (`newlinesIn`) yields the
count and the last newline, because `String.indexes` is not in this language's
String surface either.
-}
rowColOf : String -> Int -> { row : Int, col : Int }
rowColOf src offset =
    let
        before =
            newlinesIn 0 0 -1 (String.slice 0 offset src)
    in
    { row = before.count + 1
    , col = offset - before.last
    }


{-| How many `\n` a text holds, and the offset of the LAST one (`-1` when it
holds none) — exactly the two quantities `rowColOf` asks of it, read out of ONE
left-to-right scan in 1-char slices.

WHY NOT `String.indexes` (MEASURED): it is not in this language's String
surface, and this module is compiled by the front end that lacks it (see
`splitLines`).  The list of every newline offset was only ever read for its
LENGTH and its LAST element, so the scan carries both and allocates nothing.

The accumulators are threaded as ARGUMENTS rather than closed over by a
let-bound `go` for one reason: this helper's result is a record, and a
let-bound annotation with a record return type has no precedent in this group
(`splitLines` above annotates a `List String` one), while a top-level signature
returning a record is everywhere (`rowColOf`, `renderSpan`).
-}
newlinesIn : Int -> Int -> Int -> String -> { count : Int, last : Int }
newlinesIn i count last text =
    if i >= String.length text then
        { count = count, last = last }

    else if String.slice i (i + 1) text == "\n" then
        newlinesIn (i + 1) (count + 1) i text

    else
        newlinesIn (i + 1) count last text


{-| The source LINE containing `offset`, WITHOUT its terminating newline — the
text a renderer prints in its gutter.

Only `\n` splits a line (the parser's own row accounting, and what `rowColOf`
counts), so a CRLF source's line keeps its trailing `\r`; an offset at or past
the end of the text yields the last line, and empty input yields `""`.
-}
lineOf : String -> Int -> String
lineOf src offset =
    let
        row =
            (rowColOf src offset).row
    in
    splitLines src
        |> List.drop (row - 1)
        |> List.head
        |> Maybe.withDefault ""


{-| A span resolved against its source text — THE ONLY PLACE offset-to-position
and offset-to-caret arithmetic happens (the arc's D2 decision: the error
renderer formats AROUND this record and never sees a raw offset, so there is
one caret implementation, not one per caller).

  * `row`/`col` — where the span STARTS, 1-based (`col` equals `startCol` by
    construction; both are returned because a banner prints `row:col` while a
    gutter prints the caret run).
  * `line` — the START line's text, no newline (a multiline span still shows
    the line it starts on).
  * `startCol`/`endCol` — the caret run: 1-based, INCLUSIVE start, EXCLUSIVE
    end, so the caret is `endCol - startCol` wide and can never be empty.
  * `multiline` — the node's own text crosses a newline, so a caret under the
    start line would underline the wrong thing; the renderer switches to the
    `>`-margin form and prints no caret.

TRIM RULE (the caret and `multiline` both read it): `end` overhangs trailing
whitespace and comments (see `Span`), so the span's text is cut back to the
node's own text — trailing whitespace and any trailing `//` comment dropped —
before either is measured.  A run left EMPTY (the span points only at
whitespace, or only at a comment) still renders ONE caret at `startCol`: a
zero-width caret would be invisible, and such a span is a real position (the
parser synthesizes some), not a reason to print nothing.

WHY `multiline` IS MEASURED ON THE TRIMMED TEXT, not on `end` itself: `end` is
the next token's offset, so for a statement followed by a newline it crosses
one on essentially EVERY span (MEASURED: `spelled` skips ws+comments after each
token, Parse.elm:3770-3772).  Reading `end` raw would mark every statement
multiline and suppress every caret; the flag has to answer "is the NODE
multi-line", which is exactly the trimmed run.

The newline test is `anyUnit`, NOT `String.any`: the text it reads is a SLICE
of the source, and a slice can cut an astral pair — see `anyUnit`'s THE
SURROGATE TRAP, which is a measured infinite loop, not a style preference.
-}
renderSpan :
    String
    -> Span
    -> { row : Int, col : Int, line : String, startCol : Int, endCol : Int, multiline : Bool }
renderSpan src span =
    let
        at =
            rowColOf src span.start

        lineText =
            lineOf src span.start

        lineStart =
            span.start - (at.col - 1)

        runOnStartLine =
            String.slice (at.col - 1)
                (min (String.length lineText) (span.end - lineStart))
                lineText

        caretWidth =
            max 1 (String.length (spanCode runOnStartLine))
    in
    { row = at.row
    , col = at.col
    , line = lineText
    , startCol = at.col
    , endCol = at.col + caretWidth
    , multiline = anyUnit (\unit -> unit == "\n") (spanCode (String.slice span.start span.end src))
    }


{-| A span's text cut back to the NODE's own text: trailing whitespace and
trailing comments dropped (`renderSpan`'s trim rule).

RECURSIVE, not a single trim, because `end` can overhang comment-ONLY lines as
well as one trailing comment: a statement whose next token is three lines away
(blank line, `//` separator line, indent) is still a one-line statement.
-}
spanCode : String -> String
spanCode run =
    let
        trimmed =
            dropTrailingSpace run

        lastLine =
            List.head (List.reverse (splitLines trimmed)) |> Maybe.withDefault ""
    in
    case commentStartIn lastLine of
        Just at ->
            spanCode (String.dropRight (String.length lastLine - at) trimmed)

        Nothing ->
            trimmed


{-| A text without its TRAILING whitespace — `String.trimRight` for text this
lane owns, spelled with the 1-char slice because `String.trimRight` is not in
this language's String surface (see `splitLines`).

THE CHARACTER SET IS THE SOURCE'S, and it is stated rather than implied: space,
`\t`, `\r` and `\n` are the four whitespace characters a `.mid`/`.elm` source
can carry BETWEEN tokens — the parser's own whitespace class is exactly
space/`\n`/`\r` (ParserFast.elm:3177) and a tab can only sit inside a comment
(`Error.elm`'s NO TAB EXPANSION note).  So this is `trimRight` on every input
`spanCode` is handed, which is a slice of the source it was parsed from.
-}
dropTrailingSpace : String -> String
dropTrailingSpace run =
    let
        go : Int -> String
        go i =
            if i <= 0 then
                ""

            else
                case String.slice (i - 1) i run of
                    " " ->
                        go (i - 1)

                    "\t" ->
                        go (i - 1)

                    "\r" ->
                        go (i - 1)

                    "\n" ->
                        go (i - 1)

                    _ ->
                        String.slice 0 i run
    in
    go (String.length run)


{-| Whether ANY one-unit slice of `text` satisfies `is` — the scan form of
`String.any` this lane can actually run (see THE SURROGATE TRAP below).

WHY THE PREDICATE TAKES A `String` AND NOT A `Char`: every function in this
language's String surface that turns a String into a Char — `String.toList`,
`String.any`, `String.foldr` — is one of the three that HANG on an unpaired
surrogate, which is exactly what the callers here must survive.  So the scan
hands `is` the 1-unit SLICE it tested, and the predicates compare strings
(`== "\n"`, membership in the token set) instead of classifying a Char.

THE SURROGATE TRAP (MEASURED, and the reason this function exists).  Elm's
`String.any`/`String.toList`/`String.foldr` walk BACKWARD by UTF-16 unit and
treat a LOW surrogate as the second half of a pair, stepping an extra unit
back (elm/core 1.0.5, `Elm/Kernel/String.js:190-208`: `if (0xDC00 <= word &&
word <= 0xDFFF) { i--; ... }` inside `while (i--)`).  A string holding an
UNPAIRED LOW SURROGATE — exactly what a slice that starts on the second unit
of an astral pair produces — walks `i` past 0, and `while (i--)` on a negative
index never sees a falsy value again: an INFINITE LOOP.  MEASURED on the
previous spellings of both call sites below: no output, process still running
when the timeout killed it (exit 124) at 15s standalone and 20s against the
real module; the same inputs return instantly under this scan.  This scan reads
FORWARD by index, compares 1-unit slices, and never pairs units, so it
terminates on every input.

WHY `String.length` IN THE LOOP HEAD: it is O(1) in both lanes (a JS `length`,
and the selfhost's own prim), so re-reading it per step is free — the same
shape `splitLines` above uses.
-}
anyUnit : (String -> Bool) -> String -> Bool
anyUnit is text =
    let
        go : Int -> Bool
        go i =
            if i >= String.length text then
                False

            else if is (String.slice i (i + 1) text) then
                True

            else
                go (i + 1)
    in
    go 0


{-| Where a `//` COMMENT begins in a piece of source text, if one does — the
offset of its first slash, or `Nothing` when the text is all node.

The ABUT rule is the parser's own (`tokenCharBefore`, Parse.elm:2574-2576): the
character before the `//` is not a token character (`a//b` is `a`, then `/`,
then `/b` — a loud parse error, never a comment).

The LITERAL rule is NOT a condition the parser ever evaluates: `commentAt`
(Parse.elm:2561-2566) tests only the abut rule, because it is only ever called
at a token boundary, where no literal can be open — the parser's string-safety
is POSITIONAL.  This routine has no position, only text, so it RECONSTRUCTS the
parser's literal state left to right (`literalOpenAt`) and must agree with where
the parser would have been; the rule is re-stated here rather than imported
because Parse imports THIS module.

A per-LINE scan is enough, which is why `spanCode` hands over a single line: no
surface literal can contain a raw newline — a string's raw newline is a loud
reject (`stringChunkAt`, Parse.elm:1015-1016) and a char literal is exactly ONE
`isSurfaceChar` (ASCII 32..126, Parse.elm:1179-1181) — so a line boundary always
closes whatever is open and no literal state has to cross one.

WHAT IT STILL CANNOT SEE: the state is read from the text it is handed, so the
text must BEGIN at or before the node's own first character — a delimiter opened
before the first character passed in is invisible.  Both callers slice at a line
start or at a token boundary (`renderSpan`'s `runOnStartLine`), where no literal
can be open.  It also reads a `'` outside a string as a char literal
unconditionally, exactly as `atomAt` does (Parse.elm:744); a stray `'` is a loud
parse error, never text a caret is printed against.
-}
commentStartIn : String -> Maybe Int
commentStartIn run =
    commentStartFrom 0 run


{-| The FIRST `//` at or after `i` that BOTH rules admit, or `Nothing`.

A left-to-right scan rather than `String.indexes` and a filter over its result:
that function is not in this language's String surface (see `splitLines`), and
every caller reads only the FIRST admissible offset — which is the same offset
the scan reaches first, since `String.indexes` also enumerates left to right.
The scan also stops at the first hit, where the filtered form built the whole
list and ran the (per-candidate) literal scan over every later `//` as well.
-}
commentStartFrom : Int -> String -> Maybe Int
commentStartFrom i run =
    if String.slice i (i + 2) run == "//" then
        if (i == 0 || not (isTokenUnit (String.slice (i - 1) i run)))
            && not (literalOpenAt i run)
        then
            Just i

        else
            commentStartFrom (i + 1) run

    else if i >= String.length run then
        Nothing

    else
        commentStartFrom (i + 1) run


{-| The parser's token-character SET, which the comment-abut rule tests
(`isTokenUnit` is the 1-unit membership test over it).

WHY A STRING AND A SET SCAN, not `Char.isAlpha c || Char.isDigit c || c == '_'
|| c == '.'`: the Char form needs a Char, and no String-surface function yields
one without `toList`/`any`/`foldr` — the three that hang on an unpaired
surrogate (`anyUnit`'s THE SURROGATE TRAP).  The scan reads the set with the
same forward 1-unit slice the rest of this module uses.

THE SET IS THE PARSER'S STATED CLASS — `[A-Za-z0-9_.]`, the class
`tokenAtOff`'s doc names and the reason `Rt.getpid` reads as one token
(Parse.elm's `isTokenChar` is the Char spelling of it).  Its ONLY divergence
from that Char spelling is a non-ASCII LETTER: `Char.isAlpha` is ASCII
`[A-Za-z]` in the SELF-HOST lane (Prelude.elm:1334-1354 —
`charIsAlpha = charIsLower || charIsUpper`, both ASCII ranges) but the full
Unicode table in the stock elm/core lane, so this set agrees with the lane the
compiler is COMPILED BY and differs from the stock lane only for a non-ASCII
letter sitting immediately before a `//`.  That shape cannot reach here from a
parsed source: outside a literal the parser's token reader stops at a
non-token unit, so `café//x` is a LOUD parse error (the `/` has no grammar
position), and inside a string the literal rule below decides first — MEASURED
on both shapes, see this unit's record.
-}
isTokenUnit : String -> Bool
isTokenUnit unit =
    String.length unit == 1 && anyUnit (\c -> c == unit) tokenChars


{-| Every token character, one UTF-16 unit each.  A string rather than a list
of Char literals because a `Char` cannot be turned back into a String-comparable
unit here without `String.fromChar` per element — and because the SET is the
thing a reader checks against the parser's class, so it should read as one.
-}
tokenChars : String
tokenChars =
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_."


{-| Whether a string or char literal is OPEN at `at` — the literal state of the
text before `at`, scanned left to right.  Quote PARITY would not do: a char
literal may hold a quote (`'"'` is `EInt 34`, `charCodeAt` Parse.elm:1166-1181),
so two quotes do not mean two closed literals.

An INDEX scan over 1-unit slices (`literalScan`), not `String.toList` +
`List.foldl`: the slice `String.slice 0 at run` can cut an astral pair, and
`String.toList` of that is the measured hang (`anyUnit`'s THE SURROGATE TRAP).
The state is threaded as an ARGUMENT for the reason `newlinesIn` above states:
a top-level signature is what this group annotates, and a let-bound `go`
returning a TUPLE has no precedent here.
-}
literalOpenAt : Int -> String -> Bool
literalOpenAt at run =
    literalScan 0 at run ( NoLiteral, False )


{-| One unit of `literalOpenAt`'s scan: apply `literalStep` to the 1-unit slice
at `i`, and stop at `at` with "is a literal open?".
-}
literalScan : Int -> Int -> String -> ( Literal, Bool ) -> Bool
literalScan i at run state =
    if i >= at then
        case state of
            ( NoLiteral, _ ) ->
                False

            _ ->
                True

    else
        literalScan (i + 1) at run (literalStep (String.slice i (i + 1) run) state)


{-| Which delimiter, if either, a left-to-right literal scan is inside. -}
type Literal
    = NoLiteral
    | InString
    | InChar


{-| One UNIT of the literal scan — a 1-unit slice, not a Char (see
`isTokenUnit` for why a Char is out of reach): `escaped` swallows whatever
follows a backslash, a delimiter OPENS outside a literal, and only its own kind
CLOSES.  Every test is string equality, so no character class is involved and
the two lanes cannot disagree about it.
-}
literalStep : String -> ( Literal, Bool ) -> ( Literal, Bool )
literalStep unit ( mode, escaped ) =
    if escaped then
        ( mode, False )

    else
        case mode of
            NoLiteral ->
                if unit == "\"" then
                    ( InString, False )

                else if unit == "'" then
                    ( InChar, False )

                else
                    ( NoLiteral, False )

            InString ->
                if unit == "\\" then
                    ( InString, True )

                else if unit == "\"" then
                    ( NoLiteral, False )

                else
                    ( InString, False )

            InChar ->
                if unit == "\\" then
                    ( InChar, True )

                else if unit == "'" then
                    ( NoLiteral, False )

                else
                    ( InChar, False )


{-| The `Block`/`Defun`/`Program` shapes WITHOUT the `Located` wrappers and
without a defun's header span — the shape an expected-tree literal is written
in.

WHY THESE EXIST (the U1/U2 seam): U2 makes `Block` carry `Located` statements
and terms, which is one atomic Elm type change, and every existing expected-tree
literal in the test suite is written in TODAY's shape.  Naming that shape lets a
row be written (or rewritten once) as `BareBlock`/`BareDefun`/`BareProgram` and
survive the retype, so U2 changes the BODIES below and no row's data.

A comparison therefore wraps the PARSE, not the literal: `Result.map
Ast.bareProgram (Parse.parseProgram src) == Ok [ ..the old literal.. ]`.  The
strips DROP the spans, so a row pins the tree, not the source positions — the
position rows are the `renderSpan` family above, which is where a span is read.
-}
type alias BareBlock =
    { stmts : List Stmt
    , term : Term
    }


type alias BareDefun =
    { key : Key
    , flags : List FlagGuard
    , params : List Param
    , ret : Type
    , body : BareBlock
    }


type alias BareProgram =
    List BareDefun


{-| A DIFFERENT node at `like`'s source position: `reposition like node`.

The lowerer's B4 rewrites (LowerToIr's `forTail`/`doWhileTail`) synthesize
statements where a block's terminator was — a `continue` test in place of the
`continue`, a `break` term in place of the `if` that fell through.  Those nodes
have no token of their own, and the honest position is the node they stand in
for.  A SAME-KIND rewrite needs none of this (`{ located | node = ... }` keeps
the span), and Elm's record update cannot change a field's TYPE — which is
exactly the cross-kind case here, and the reason this is a function rather than
a record update at the call sites: the lowerer never reads or writes a span.
-}
reposition : Located a -> b -> Located b
reposition like node =
    { node = node, span = like.span }


bareBlock : Block -> BareBlock
bareBlock block =
    { stmts = List.map .node block.stmts
    , term = block.term.node
    }


bareDefun : Defun -> BareDefun
bareDefun defun =
    { key = defun.key
    , flags = defun.flags
    , params = defun.params
    , ret = defun.ret
    , body = bareBlock defun.body
    }


bareProgram : Program -> BareProgram
bareProgram program =
    List.map bareDefun program
