module Mid.RtLang.Ast exposing
    ( AggShape(..)
    , Builtin(..)
    , Block
    , Defun
    , Effect(..)
    , Exp(..)
    , Export
    , ExportSig
    , Flag(..)
    , FlagGuard(..)
    , FltBinOp(..)
    , FltCmpOp(..)
    , Header
    , Key
    , Module
    , OTy(..)
    , Param
    , Program
    , Sig(..)
    , Stmt(..)
    , Sym
    , Term(..)
    , Type(..)
    , WordBinOp(..)
    , WordCmpOp(..)
    , builtinClass
    , builtinName
    , fltBinSig
    , fltCmpSig
    , rawcallArity
    , shortSig
    , splitArrow
    , valArity
    , wordBinSig
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
expression-only — see the header), val (a tagged 40-byte Value).
-}
type Type
    = TWord
    | TFloat
    | TVal


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


{-| A whole `.mid` file: the header plus the defun list (`Program`).
`Parse.parseModule` returns this; the defun list is the same `Program`
every lowerer/checker already consumes (the header is NOT lowered).
-}
type alias Module =
    { header : Header
    , defuns : List Defun
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
-}
type Stmt
    = SBind Type String Exp
    | SEffect Exp
    | SIf Exp Block (Maybe Block)


{-| `TRet` is `return e;` (L3: the block's value).  `TRecur` is
`recur(a, ..);` (L4: `App{fn=GRef own-key, force=False}` — the ONLY loop;
MEASURED, all 31 DSL sites are saturated self-GRef apps, so J4 pins the
arity == own param count statically, else the classifier would demote the
loop to a plain call).  `TIf` is the branch-final `if` (L5).
-}
type Term
    = TRet Exp
    | TRecur (List Exp)
    | TIf Exp Block (Maybe Block)



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
    compare is NOT a :val, it must be boxed via `mkbool` to branch — the
    DSL's `mkBool (cmpW ...)` discipline everywhere).
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

-}
type Exp
    = EInt Int
    | EFlt Float
    | EStr String
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
like the word compares) — box with `mkbool` to branch.
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
  * `wordCmpSig` — `== != < <= > >=` : word,word -> word (0/1; box via
    mkbool to branch)
  * `fltBinSig`  — `f+ f- f* f/` : float,float -> float
  * `fltCmpSig`  — `f< f<= f> f>= f== f!=` : float,float -> word (0/1)
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
    Sig [ TWord, TWord ] TWord


fltBinSig : Sig
fltBinSig =
    Sig [ TFloat, TFloat ] TFloat


fltCmpSig : Sig
fltCmpSig =
    Sig [ TFloat, TFloat ] TWord


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

  * malloc 1, free 1, mmap 6 (RtGc — the one 6-arg site)
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
