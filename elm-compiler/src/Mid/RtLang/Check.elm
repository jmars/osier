module Mid.RtLang.Check exposing
    ( checkExports
    , checkModule
    , checkProgram
    , fieldOffset
    , fieldWidth
    , guardsHold
    , sizeofStruct
    )

{-| Mid.RtLang.Check — the surface language's TYPECHECKER, judgments
J1-J14 of the tier-2 plan (`handoff-osier-tier2-midlang-plan`, THE
TYPECHECKER).  It runs when the compiler builds the Rt program — on EVERY
compile — and its `Err` is a compile error that fails the compile through
the existing `Err` plumbing (T7 wires the call: after
`Parse.parseModule`, call
`Check.checkExports exports arities` then
`Check.checkModule externTypes activeFlags module` —
`Check.checkProgram` is the decl-less delegate for the defun-only rows);
`Err msg` propagates exactly like `QbeLower.lower`'s).

NO INFERENCE, BY DESIGN.  Every binder declares its class (`word x = ..;`
/ parameters `x: val`) and every `EVar` resolves to the DECLARED class;
the checker only validates, it never deduces.  Inference would LAUNDER
class confusion, and class confusion IS the hazard this module exists
for: a `val` silently accepted into a `word` slot is precisely the bug
Lower catches late-and-cryptic (its "raw word binder" / "not a raw word"
errors, Lower.elm:1293/:1846) — here it is a loud reject with the defun
named.  An expression's class is always FIXED by its shape: literals
(int `:word`, float `:float`, string `:val`, `true`/`false` `:bool` (B1 —
`EBool`; the old `mkbool` sugar's tree is what the box still emits),
`mknil` `:val`, `'c'` `:word`), operators (the four families + `&& ||` via
`Ast`'s signature constants), builtins (`Ast.builtinClass`), `sizeof`
`:word`, a cast the TARGET's class, the three call forms, or a scope
lookup.

THE BOOL CLASS (B1, plan Q2 — the P1c seam's structural close).  `bool`
is over the 0/1 word and every bool expression lowers to a raw 0/1 TEMP
or a constant: comparisons, `[bool](w)`, a `bool` binder, `true`/`false`.
That closure is what makes a bool BINDER branchable where a `word` binder
is not: `word i = ..; if (i)` is rejected because the binder's
REPRESENTATION is the lowering's (a raw temp if its initializer was a
producer, a number-boxed SLOT otherwise — and the slot case is the
always-then misread the P1c review measured), while a bool binder's
representation is the CLASS's (a raw 0/1 temp, by the initializer rule
below), so `jnz` on it is exactly right.  Three consequences, each a loud
reject here rather than a QBE-layer surprise:
  * a `bool` BINDER's initializer must be a bool TEMP — a WORD compare
    (`EWordCmp`), a `[bool](w)` cast, or another bool binder.  Three
    shapes are rejected, each for the representation it would get: a
    LITERAL (`bool b = true;` — Lower's raw-Int binder reboxes as a
    NUMBER and a value test then reads tag 0: the always-then misread),
    a FLOAT compare (`RawFltCmp` is a word 0/1 that Lower's raw-word
    BINDER set deliberately excludes, so the binder would take the value
    path and fail there), and a bool JOIN (`If` is not a temp at all).
    A float compare is still branchable INLINE (`if (f < g)`) — it is
    only the binder that has no representation;
  * a constant bool CONDITION is rejected like `if (1)` (a constant
    branch is not a test);
  * `bool` is a BINDER class only — `surfaceType` does not spell it, so a
    bool parameter/return/field cannot even parse (the word ABI is B6).

THE JUDGMENTS ENFORCED HERE (T5 adds J7-J10):

  * **J1** — fixed operand/result classes everywhere: the four operator
    families (word ops/compares `:word`; float ops `:float`; `&& ||`
    `:val`), the builtin table, and the binder form `ty x = e;` (the
    initializer's class must BE the declared class — the DSL's
    never-bind-across-classes discipline).  Also two class facts the
    grammar pins but the parser cannot see:
      - an `if`/`SIf`/`?:` CONDITION is `:val` OR `:word`.  A bare
        `x == 1` is a WORD PRODUCER and is a legal condition AS-IS (the
        lowering jumps on the word directly — no box, no slot); the old
        spelling `mkbool(x == 1)` still works and lowers EXACTLY as it
        always did (the compatibility seat).  The OLD rule — condition
        must be `:val` — existed because the DSL's `jmpf` tested a
        boolean VALUE slot, so a raw word there was a runtime lie; the
        new word form tests the word directly.  The domain is a CONDITION
        that is a word PRODUCER — a compare, `tagis`, a word builtin, a
        rawcall — i.e. exactly the forms the lowering computes into a raw
        temp and `jnz`es on.  Three word SHAPES are rejected as
        conditions, each for a MEASURED reason: (a) a word-VALUED join
        (`(a == b) ? 1 : 0`, an `EIf`/`EIfBlock` whose branches agree on
        `:word`) — its value is a join, which needs a slot; (b) a word
        LITERAL (`if (1)`) — it lowers to `jnz 1` and the vendored qbe
        refuses a constant jump condition; (c) a bare word VARIABLE
        (`if (x)` for a `word x = ..` binder) — a binder whose
        initializer is not a raw-word producer is slot-boxed as a NUMBER
        and the checker cannot see the lowering's representation, so the
        branch would silently read as always-true.  Write the compare
        inline, or box a `:val`.  A `:float` word is still a reject (it
        is not a branchable word);
      - a LOCAL binder may not declare `:float` — float words are not
        let-bindable (MEASURED, Lower's rawFltArg: "A Var never appears —
        recompute"), so `float x = ..;` is a J1 reject: recompute the
        float expression at each use or bind it boxed via `mkflt`.
        (Parameters MAY declare `:float` — those exist for stage-6's
        rawAbi seats — this restriction is the SBind form only.)  This
        is the T4 decision Ast's header delegates here.
  * **J2** — `call Key`: `Key` must be a full `Rt.*` key and resolve in
    the surface defun set (order-independent — Rt bodies are mutually
    recursive) UNION the extern table; arity must match; arguments are
    checked against the callee's DECLARED parameter classes — for a TYPED
    extern seat (an exported key) the declared Osier types, projected to
    mid-c classes; for an unexported key the arity-only fallback (all
    `:val`, today's behaviour) — and the result is the callee's declared
    return class.
  * **J3** — `rawcall sym`: `sym` must be in `Ast.rawcallArity`, the
    arity must match, every argument and the result are `:word`.  This
    per-symbol table is the enforcement seat for the rawAbi caveat: the
    plan MEASURED that "rawcall caps at 3 usable args" is NOT in the tree
    today (mmap passes 6), so stage-6's future `rawAbi` defuns must JOIN
    `Ast.rawcallArity` when they land, and any per-symbol cap is enforced
    THERE — not here, not in Lower.
  * **J4** — `recur` arity must EQUAL the enclosing defun's parameter
    count, and each argument must match the parameter's declared class.
    An unsaturated `recur` would be demoted by the classifier to a plain
    call — the loop silently stops being a loop — so it is caught here,
    statically.
  * **J5** — scope discipline: unbound names, duplicate parameters, and
    USE-BEFORE-BIND.  Locals are STRICTLY ORDERED (the selfhost front
    end's own lesson, Rt.elm:531-545): an `SBind`'s initializer is
    checked BEFORE the binder enters scope, and a later statement cannot
    see an earlier statement's name until it is bound — exactly the shape
    the lowering produces (each statement becomes one nested `Let`).
    Shadowing IS allowed (a rebind is a fresh id, like the DSL's distinct
    b's); a shadowing initializer still sees the OUTER binding.
  * **J6** — every `return e` class-matches the defun's declared `-> ty`.
  * **J7** — the DIVERGENCE RULE (plan L6, the honest floor): a MID-BLOCK
    `if` (an `SIf` statement) is legal ONLY when at least one branch
    DIVERGES — `diverges` reads the block's terminator alone (`return`/
    `recur` always; a terminating `if` only when BOTH branches diverge).
    With both branches falling through, the block could only be lowered
    by continuation duplication (exponential in a chain) or a Case node
    (forbidden — the `Rt.=` regress), so it is REJECTED with the plan's
    exact floor: "bind through ?: or make it the last statement".  No
    join is invented.  Two further pins, stated so the rule is total:
      - a TERMINATING `if` (`TIf`) is not subject to the both-branches
        rule — its fall-through is the value join (L5) — but a `TIf` with
        a MISSING `else` needs a diverging then-branch (L5: "else is
        REQUIRED except when the then-branch diverges": the false path
        is the block's fall-through, and a falling then-branch leaves it
        with no value);
      - `diverges` ignores statements: dead code after a both-diverging
        mid-block `if` is not chased (its statements keep their own J7
        obligations), and a deeper one-sided divergent `if` does NOT make
        an enclosing branch diverge — the branch can still fall through
        its inner `if`'s false path.
    THE REMAINING HOLE, flagged for T6: a defun-level terminating `if (c)
    { return a; }` (else-less, diverging then — the early-exit guard)
    passes here; its false path has no value, and only T6's else-nesting
    knows whether a continuation exists to fill the else slot.  If T6
    cannot merge, ITS error fires there — nothing passes silently.
  * **J8** — the `@flag` guards.  The flag environment is a PARAMETER
    (`List Flag`, the ACTIVE set — `Ast.Flag` is exactly Rt.elm's three
    switches `consArr`/`rec`/`eqPtrFast`; T7 derives the list from
    `Rt.program`'s three Bools), so the module stays pure.  A defun is
    ACTIVE iff every one of its guards holds.  Every key must have
    EXACTLY ONE active defun: two or more active → reject (variants
    sharing one logical key must be mutually exclusive); zero active →
    reject (a key with no active definition is a silent hole — rtDeps
    still routes to it).  The MEASURED use is complementary variant pairs
    (the consArr/rec/eqPtrFast variation — 4 keys plus helperDefuns' rec
    emission), where exactly one arm holds per flag combination; guards
    deliberately do NOT conditionally omit a defun.  `surfacesOf`
    therefore resolves each key to its ONE active signature — the T4
    "last defun wins" note is closed loudly: duplicate unguarded keys
    are two active variants, a J8 reject.
  * **J9** — NOT CHECKED, DELIBERATELY.  Allocating/safepoint is DERIVED
    from the produced tree by `Mid.Rt.allocating`'s fixed point (plan
    fact F3); the existing TestMain partition rows are the enforcement.
    A checker-side J9 here could only disagree with the derived truth, so
    this module adds nothing for it.
  * **J10** — every `withroots` id must name a `:val` binder IN SCOPE at
    that point (a parameter or an earlier binder).  WithRoots roots
    EXISTING values for the block's duration; it does not create them.
    Inside the block the ids are re-bound `:val` — T4's half (what the
    roots ARE); the outer-scope check is this unit's.
  * **J11** — the STRUCT TABLE (round-1 §2, midlang-a1).  The file-scoped
    `struct`/`enum` declarations build two tables carried in `Env`: the
    struct table (`name -> ordered fields with computed word offsets` plus
    the struct's SIZE in words) and the enum table (`name -> constant name
    -> value`).  Rejections: a duplicate declaration name (struct AND enum
    names share ONE file-scoped namespace — `*S` and `Enum.c` must never
    be ambiguous); a duplicate field name inside one struct; a `float`
    field (Mid.Ir has no raw-memory f64 load node — a float field cannot
    lower, named, never silently word-typed); a pointer-to-unknown-struct
    field type (`f : *Nope` — the name must resolve in the table, looked
    up ORDER-INDEPENDENTLY so `struct A { b : *B; } struct B { .. }`
    forward pointers work); self-reference BY VALUE (`next : S`) would be
    infinite size and is REJECTED — but the U1 grammar has no struct-value
    `Type` constructor, so the rejection is STRUCTURAL today (a bare
    Uppercase field name is a parse reject, "expected a type"); the
    judgment's seat lands with B2's nested-struct unit.  Self-reference BY
    POINTER (`next : *S`) is the only recursion and is legal (one word).
    Layout is declaration-order, word-granular: `word`/`*T` = 1 word,
    `val` = 5 words inline.  The SAME table is the one the lowerer (A2)
    consumes — no second copy to skew.
  * **J12** — POINTER COERCIONS, the one-way matrix (round-1 §2, the
    design's load-bearing part).  `word -> *T` (any T) is legal at a typed
    binder — the view-cast, the direction the source spells.  `*T -> word`
    is legal wherever a word is expected (a pointer IS a word: binders,
    returns, rawcall/word builtin slots, comparisons).  `*S -> *word` is
    legal (the universal raw view — the mark-stack/freelist overlap
    sites).  EVERYTHING ELSE — `*S1 -> *S2` (cross-struct), `*word -> *S`,
    `*val -> *S` — is a REJECT: go through a `word` binder, one named
    line.  The only unchecked direction is `word -> *T`, which is exactly
    the source-spelled one.  The FIREWALL sits on top: a pointer operand
    in ARITHMETIC (`p + 1`, `p - 1`, `p & 3` — any `EWordBin`) is a J12
    REJECT even though `*T -> word` otherwise holds, because byte/word
    address math must happen on a `word` binder (bind `word w = p;`
    first) — no context-dependent scaling exists anywhere; struct-scaled
    math happens only through `p[i]`.  Pointer COMPARISON (`p == 0`,
    `p != 0`, `p < q`) is legal — it is address comparison, no scaling.
  * **J13** — FIELD/INDEX/DEREF rules (round-1 §2).  `p->f` / `p->f = e`:
    `p : *S`, `f` a field of `S`; the expression's class is the FIELD's
    declared class; a store class-checks `e` against the field class (a
    `val` into a `word` field is a J13 reject — never less checked than
    today's `wstore`).  `p[i]` / `p[i] = e`: `p : *word` (word element,
    `wload` stride), `p : *val` (val element, `vecload` stride), or
    `p : *S` (struct-scaled — the element read is the WORD at the element
    base, `RawWordLoad { index = i * sizeofS }` per round-1 §3; v1 has no
    struct values to yield); the index is a word offset.  `*p`: `*word`
    only, `:word`.  Chains `a->b->c` / `a->tab[i]` compose through the
    field/index classes.
  * **J14** — the ENUM table (round-1 §2).  Duplicate enum name (with any
    declaration) and duplicate constant name INSIDE one enum are rejects.
    An enum constant is an `EInt` alias (C-style named word constant) for
    every subsequent judgment — the `Enum.c` EXPRESSION form is not in the
    U1 grammar, so at A1 the table is built and validated and the alias
    rule is the seat the constant-expression grammar lands into.

POSITIONS — THE HONEST GAP, stated loudly.  The plan asks every rejection
to carry `defun:line:col`.  MEASURED: the T1 AST carries NO source
positions — no `Exp`/`Stmt`/`Term` constructor has one — so line:col is
unproducible from this AST.  Errors therefore carry the best position the
AST has: the DEFUN KEY, the judgment number, and the nearest NAMED
construct (binder name, builtin/symbol/key spelling, operand classes).
Retrofitting real positions means threading a position field through
every `Ast` constructor and every `ParserFast` combinator — a T1+T2-sized
change that would rewrite all of T2/T3's exact-AST rows; that is an
owner decision, not something this unit does silently.

SELFHOST DISCIPLINE (the mid-lane hazard, Rt.elm:531-545): every helper
is a TOP-LEVEL definition — the mutually recursive walk
(`checkExp` ⇄ `checkArgs` ⇄ `checkBlock` ⇄ `checkStmt` ⇄ `checkTerm`)
closes through top-level bodies, never let-bound, because the selfhost
front end resolves let binders strictly in order.  The module uses only
`Dict`/`List`/`String` functions MEASURED in the selfhost's merged global
table (Resolve.elm's dotted rows + core-libs): no `String.uncons`, no
`Debug`, and all `Maybe`/`Result` handling goes through `case`.

BACKEND-NEUTRAL (the `Mid.Rt` contract): imports are `Dict` and
`Mid.RtLang.Ast` only — no `Mid.Ir`, no QBE type.

-}

import Dict exposing (Dict)
import Mid.RtLang.Ast
import Mid.RtLang.Ast as Ast
    exposing
        ( AggShape(..)
        , ArrayInit(..)
        , Block
        , Decl(..)
        , Defun
        , EnumEntry
        , Exp(..)
        , Export
        , ExportSig
        , Field
        , Flag(..)
        , FlagGuard(..)
        , FltBinOp(..)
        , FltCmpOp(..)
        , Key
        , Module
        , OTy(..)
        , PTy(..)
        , Param
        , Program
        , Sig(..)
        , SizeTarget(..)
        , Stmt(..)
        , StructInit(..)
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
        , splitArrow
        , wordCmpSig
        )



-- ============================ the environment ============================


{-| What J2 resolves `call` targets against, supplied by the caller so the
module stays pure and testable: the surface signatures are derived from
the program itself; `externs` maps an extern `Rt.*` key to its DECLARED
signature (M2's typed extern table, the old arity-only table grown).  An
EXPORTED key carries its Osier types (`ExportSig`, projected to mid-c
classes); an unexported key carries the arity-only fallback (`valArity n`
— all-`:val` in, `:val` out, today's behaviour).  A surface defun's own
word/float params are honoured from its declared signature.
-}
type alias Env =
    { surfaces : Dict Key ( List Type, Type )
    , externs : Dict Key ExportSig
    , structs : StructTable
    , enums : EnumTable
    }


{-| One struct field with its computed word offset (declaration order, the
`Field` plus the offset `layoutOf` derived).  The LOWERER (A2) consumes
this SAME shape — name -> ordered fields -> (type, offset) — the one-table
property: no second copy to skew (plan risk R2).
-}
type alias StructField =
    { name : String
    , ty : Type
    , offset : Int
    }


{-| One struct's layout: the ordered fields (offsets derived) and the
struct's SIZE in words (the max field end — every field is a whole number
of 8-byte words, `val` = 5 inline).
-}
type alias StructInfo =
    { fields : List StructField
    , size : Int
    }


{-| The struct table: name -> layout.  Built from the file-scoped `struct`
declarations; field/pointer resolution reads THIS table.
-}
type alias StructTable =
    Dict String StructInfo


{-| The enum table: name -> (constant name -> value).  C-style named word
constants; the `Enum.c` expression form is not yet in the grammar (A1
builds and validates the table).
-}
type alias EnumTable =
    Dict String (Dict String Int)


{-| One defun's walking context: the program-wide env, the enclosing defun
(for J4's arity and J6's return class) and the binder scope (J5).
-}
type alias Ctx =
    { env : Env
    , key : Key
    , params : List Param
    , ret : Type
    , scope : Dict String Type
    }



-- ============================ entry point ============================


{-| Check a whole parsed program (J1-J8, J10).  `externs` is J2's typed
extern table (M2); `flags` is J8's ACTIVE flag set (T7 derives it from
`Rt.program`'s three Bools).  `Ok ()` means every defun passed; `Err msg`
is a loud compile error naming the defun and the judgment, fail-fast on
the first rejection.
-}
checkProgram : Dict Key ExportSig -> List Flag -> Program -> Result String ()
checkProgram externs flags program =
    checkModule externs flags
        { header = { name = Nothing, exports = [] }
        , decls = []
        , defuns = program
        }


{-| Check a whole parsed MODULE (J1-J8, J10-J14) — the decl-carrying entry
point `Rt.load` calls (the runtime.mid lane).  The file-scoped `decls`
build the struct/enum tables (J11/J14) BEFORE the defuns walk, and the
tables ride in `Env` for the field/index/deref/store and coercion
judgments.  `checkProgram` is the headerless, decl-less delegate the
existing defun-only rows (and the user-module lane) call.
-}
checkModule : Dict Key ExportSig -> List Flag -> Module -> Result String ()
checkModule externs flags module_ =
    case keyCheck module_.defuns of
        Err msg ->
            Err msg

        Ok () ->
            case guardCheck flags module_.defuns of
                Err msg ->
                    Err msg

                Ok () ->
                    case declCheck module_.decls of
                        Err msg ->
                            Err msg

                        Ok tables ->
                            checkAll (envOf externs flags module_.defuns tables) module_.defuns


{-| THE KEY AGREEMENT (M2, plan.md §2.5) — the FORWARD half, loud now.
`exports` is the module's export block; `arities` is the module's key ->
arity map (surface defuns UNION DSL seats — `load` supplies it).  Three
rejections, each an `Err` that fails the load:

  * a DUPLICATE export for one key (two declared types for one name);
  * an export key naming NO defun in the module (a typo'd or renamed key
    — the declared type would sit in the typed table with nothing behind
    it);
  * an export whose DECLARED arity (`splitArrow`'s param count) disagrees
    with the defun's actual arity — the declared type is wrong, and J2
    would then check surface calls against a lying signature.

The REVERSE half — "a defun intended to be reachable has an export" — is
DESIGNED here, not enforced here: an UNEXPORTED defun is MODULE-PRIVATE,
and the Osier import (M4) resolves ONLY against the export block, so a
private key named in an Osier `import`/call is rejected THERE.  In M2
nothing imports, so the reverse check is vacuous by construction.
-}
checkExports : List Export -> Dict Key Int -> Result String ()
checkExports exports arities =
    case exports of
        [] ->
            Ok ()

        e :: rest ->
            if List.any (\e2 -> e2.key == e.key) rest then
                Err ("RtLang: export: key '" ++ e.key ++ "' is exported more than once — one declared type per defun")

            else
                case Dict.get e.key arities of
                    Nothing ->
                        Err ("RtLang: export: key '" ++ e.key ++ "' names no defun in the module — every export must name an existing defun")

                    Just arity ->
                        if List.length (Tuple.first (splitArrow e.sig.ty)) == arity then
                            checkExports rest arities

                        else
                            Err
                                ("RtLang: export: key '"
                                    ++ e.key
                                    ++ "' declares arity "
                                    ++ String.fromInt (List.length (Tuple.first (splitArrow e.sig.ty)))
                                    ++ " but the defun has arity "
                                    ++ String.fromInt arity
                                )


{-| The one program-shape check this unit owns: a defun's key must be a
namespace-QUALIFIED key (a dotted `Mod.name`).  The `Rt.*`-only rule M2
landed generalized to this: since M3 the surface also defines USER `.mid`
modules, whose defun keys are qualified by THEIR module name (`Foo.bar`),
so the checker can no longer assume the `Rt.` prefix (a stray bare
`defun getpid()` would be uncallable and unlowerable).  The namespace
OWNERSHIP — a user key must not be `Rt.*`, a key must not collide with
another module's — is the CALLER's collision rule (QbeModule, M3), not a
shape judgment here.  Guard exclusivity is J8, right below.
-}
keyCheck : Program -> Result String ()
keyCheck program =
    case program of
        [] ->
            Ok ()

        d :: rest ->
            if isQualifiedKey d.key then
                keyCheck rest

            else
                Err
                    ("RtLang: defun key '"
                        ++ d.key
                        ++ "' must be namespace-qualified (a dotted 'Mod.name') — the runtime's keys are Rt.*, a user module's are its own name"
                    )


{-| A key is namespace-qualified when it carries at least one `.` (a
`Mod.name` key).  The runtime's are `Rt.*`; a user module's are qualified
by ITS module name (M3).  `String.toList` + `List.any` rather than
`String.contains` (absent from the selfhost Prelude).
-}
isQualifiedKey : String -> Bool
isQualifiedKey key =
    List.any (\c -> c == '.') (String.toList key)


{-| J8 — the `@flag` guard exclusivity walk: every key must have EXACTLY
ONE active defun under the flag environment (see the header).  Walked
per defun, counting the active variants of ITS key across the WHOLE
program — the first defun of an offending key names the error, and the
count doubles as the "how many" in the too-many message.  The whole
program is carried through the recursion (`guardWalk`): counting a
key-group's SECOND member against the already-walked tail would drop its
active sibling and report a phantom "no active defun".
-}
guardCheck : List Flag -> Program -> Result String ()
guardCheck flags program =
    guardWalk flags program program


guardWalk : List Flag -> Program -> Program -> Result String ()
guardWalk flags whole program =
    case program of
        [] ->
            Ok ()

        d :: rest ->
            case activeVariants flags whole d.key of
                0 ->
                    Err
                        (d.key
                            ++ ": J8: no active defun for key '"
                            ++ d.key
                            ++ "' under the active flag set — every key must have exactly one active definition, else the Rt program silently loses it while rtDeps still routes to it"
                        )

                1 ->
                    guardWalk flags whole rest

                n ->
                    Err
                        (d.key
                            ++ ": J8: "
                            ++ String.fromInt n
                            ++ " flag-guarded defuns are active at once for key '"
                            ++ d.key
                            ++ "' — variants sharing one logical key must be mutually exclusive"
                        )


{-| How many defuns of exactly this key are ACTIVE (all guards hold) —
unguarded defuns are always active, so duplicate unguarded keys count as
two and reject.
-}
activeVariants : List Flag -> Program -> Key -> Int
activeVariants flags program key =
    List.foldl
        (\d acc ->
            if d.key == key && guardsHold flags d.flags then
                acc + 1

            else
                acc
        )
        0
        program


{-| A defun's guard list holds against the ACTIVE flag set.  `@flag`
holds iff the flag is on, `@!flag` iff it is off; an empty list (an
unguarded defun) always holds.  Membership is by hand (`sameFlag`), NOT
`List.member`: MEASURED, the selfhost's `List.member` demands
`comparable` elements and rejects a user ADT like `Ast.Flag` (real Elm
derives comparable for ADTs; the selfhost's core-libs table does not —
the bootstrap emit failed on exactly this before the swap).

EXPOSED for T7 (the one change to this module's surface): Mid.Rt's splice
selects the ACTIVE surface defuns with THIS predicate — the same function
the checker enforces J8 with, so the two selection sites cannot skew.
-}
guardsHold : List Flag -> List FlagGuard -> Bool
guardsHold flags guards =
    case guards of
        [] ->
            True

        Guard f :: rest ->
            flagActive flags f && guardsHold flags rest

        GuardNot f :: rest ->
            not (flagActive flags f) && guardsHold flags rest


flagActive : List Flag -> Flag -> Bool
flagActive flags f =
    case flags of
        [] ->
            False

        g :: rest ->
            if sameFlag g f then
                True

            else
                flagActive rest f


sameFlag : Flag -> Flag -> Bool
sameFlag a b =
    case a of
        ConsArr ->
            case b of
                ConsArr ->
                    True

                _ ->
                    False

        Rec ->
            case b of
                Rec ->
                    True

                _ ->
                    False

        EqPtrFast ->
            case b of
                EqPtrFast ->
                    True

                _ ->
                    False


checkAll : Env -> Program -> Result String ()
checkAll env program =
    case program of
        [] ->
            Ok ()

        d :: rest ->
            case checkDefun env d of
                Err msg ->
                    Err msg

                Ok () ->
                    checkAll env rest


envOf : Dict Key ExportSig -> List Flag -> Program -> ( StructTable, EnumTable ) -> Env
envOf externs flags program tables =
    { surfaces = surfacesOf flags program
    , externs = externs
    , structs = Tuple.first tables
    , enums = Tuple.second tables
    }


-- ============================ J11/J14: the declaration tables ============================


{-| Build and validate the struct and enum tables from the file-scoped
declarations (J11/J14).  Fail-fast: the first bad declaration names the
judgment.  The two tables are the ones `Env` carries into every defun walk
and the ones the lowerer (A2) consumes — one table, one layout truth.
-}
declCheck : List Decl -> Result String ( StructTable, EnumTable )
declCheck decls =
    case duplicateDeclName decls of
        Just name ->
            Err
                ("RtLang: J11/J14: declaration name '"
                    ++ name
                    ++ "' is declared more than once — struct and enum names share ONE file-scoped namespace (a '*"
                    ++ name
                    ++ "' pointer and an '"
                    ++ name
                    ++ ".c' constant must never be ambiguous)"
                )

        Nothing ->
            case structsOf decls of
                Err msg ->
                    Err msg

                Ok structs ->
                    case enumsOf decls of
                        Err msg ->
                            Err msg

                        Ok enums ->
                            Ok ( structs, enums )


{-| The first declaration name used twice (struct/enum names in one
namespace), or `Nothing`.
-}
duplicateDeclName : List Decl -> Maybe String
duplicateDeclName decls =
    case decls of
        [] ->
            Nothing

        d :: rest ->
            if List.member (declName d) (List.map declName rest) then
                Just (declName d)

            else
                duplicateDeclName rest


declName : Decl -> String
declName d =
    case d of
        StructDecl s ->
            s.name

        EnumDecl e ->
            e.name


{-| The struct table: walk the `struct` declarations (ignoring enums),
resolving pointer targets against the FULL struct-name set (order-
independent forward references) and deriving each field's word offset and
the struct's size.
-}
structsOf : List Decl -> Result String StructTable
structsOf decls =
    structsFold decls (structNames decls) Dict.empty


structNames : List Decl -> List String
structNames decls =
    List.foldl
        (\d acc ->
            case d of
                StructDecl s ->
                    s.name :: acc

                EnumDecl _ ->
                    acc
        )
        []
        decls


structsFold : List Decl -> List String -> StructTable -> Result String StructTable
structsFold decls names acc =
    structsFoldAll decls decls names acc


{-| The walk keeps the WHOLE declaration list beside the remaining one: a
nested-struct field resolves its SIZE by re-reading the declarations, so
`layoutOf` must see every declaration, not just the ones after the struct
being laid out (MEASURED — passing the case scrutinee type-checked and
then rejected every nested struct as "names no declared struct").
-}
structsFoldAll : List Decl -> List Decl -> List String -> StructTable -> Result String StructTable
structsFoldAll all remaining names acc =
    case remaining of
        [] ->
            Ok acc

        d :: rest ->
            case d of
                EnumDecl _ ->
                    structsFoldAll all rest names acc

                StructDecl s ->
                    case layoutOf all names s.name s.fields of
                        Err msg ->
                            Err msg

                        Ok ( fields, size ) ->
                            structsFoldAll all rest names (Dict.insert s.name { fields = fields, size = size } acc)


{-| One struct's layout: declaration-order offsets, each field's size in
whole words (`word`/`*T` = 1, `val` = 5 inline, a nested struct = its own
size).  Rejections: a duplicate field name; a `float` field (no raw f64
load node); a pointer field naming an unknown struct; a struct field
naming an unknown struct; and a BY-VALUE CYCLE (`struct S { s : S; }`, or
`S { b : B }` beside `B { s : S }`) — B2, the layout seat the A1 note
reserved for exactly this unit.  `decls` is threaded for the nested-struct
SIZE only: the recursion re-walks the same declarations, it does not
build a second table.
-}
layoutOf : List Decl -> List String -> String -> List Field -> Result String ( List StructField, Int )
layoutOf decls names structName fields =
    case duplicateFieldName fields of
        Just f ->
            Err
                ("RtLang: J11: struct '"
                    ++ structName
                    ++ "' declares field '"
                    ++ f
                    ++ "' more than once — one name, one offset"
                )

        Nothing ->
            fieldsWalk decls names structName fields 0 []


fieldsWalk : List Decl -> List String -> String -> List Field -> Int -> List StructField -> Result String ( List StructField, Int )
fieldsWalk decls names structName fields offset acc =
    case fields of
        [] ->
            Ok ( List.reverse acc, offset )

        f :: rest ->
            case fieldSize decls names [ structName ] structName f.ty of
                Err msg ->
                    Err msg

                Ok sz ->
                    fieldsWalk decls names structName rest (offset + sz) ({ name = f.name, ty = f.ty, offset = offset } :: acc)


{-| A field type's size in words, with the J11 field-type rejections.  A
pointer field resolves its struct name against the full struct-name set
(order-independent); a STRUCT-VALUE field (B2, `inner : B`) recurses into
`structSizeOf` with `seen` carrying the enclosing struct names, so
self-reference BY VALUE — `struct S { s : S; }`, or a two-struct cycle —
is the infinite-size reject the A1 note reserved for this unit (it was
structurally unspellable before B2 added the `TStruct` type).
-}
fieldSize : List Decl -> List String -> List String -> String -> Type -> Result String Int
fieldSize decls names seen structName ty =
    case ty of
        TWord ->
            Ok 1

        TBool ->
            -- UNREACHABLE from the grammar (B1: `bool` is a BINDER class
            -- only — `surfaceType` does not spell it, so no field can carry
            -- it; the word ABI/B6 is what a bool field would need).  The arm
            -- exists because the layout table must be TOTAL over `Type`, and
            -- a bool IS a 0/1 word, so if the grammar ever admits it the
            -- honest size is 1.
            Ok 1

        TPtr (PStruct sname) ->
            if List.member sname names then
                Ok 1

            else
                Err
                    ("RtLang: J11: struct '"
                        ++ structName
                        ++ "' field type '*"
                        ++ sname
                        ++ "' names no declared struct — a pointer field must resolve in the file's struct table"
                    )

        TPtr _ ->
            Ok 1

        TVal ->
            Ok 5

        TStruct sname ->
            structSizeOf decls names seen sname

        TArray elem n ->
            -- B3: an array field is `n` contiguous copies of its element
            -- (row-major flat, so a nested array is just its element's size
            -- times its count).  `seen` rides through, so `struct S { t :
            -- S[2]; }` is the same BY-VALUE CYCLE reject a direct field is.
            if n <= 0 then
                Err
                    ("RtLang: J11: struct '"
                        ++ structName
                        ++ "' has an array field of length "
                        ++ String.fromInt n
                        ++ " — a fixed array's length is at least 1 (there is no storage to take the address of)"
                    )

            else
                case fieldSize decls names seen structName elem of
                    Err msg ->
                        Err msg

                    Ok w ->
                        Ok (w * n)

        TFloat ->
            Err
                ("RtLang: J11: struct '"
                    ++ structName
                    ++ "' has a float field — Mid.Ir has no raw-memory f64 load node, so a float field cannot lower (named, not silently word-typed)"
                )


{-| A struct's size in words, computed from the declarations with `seen`
carrying the enclosing names: the BY-VALUE CYCLE reject lives here (one
table, one rule).  An unknown struct is the same J11 reject the pointer
arm spells.
-}
structSizeOf : List Decl -> List String -> List String -> String -> Result String Int
structSizeOf decls names seen sname =
    if List.member sname seen then
        Err
            ("RtLang: J11: struct '"
                ++ sname
                ++ "' contains itself BY VALUE ("
                ++ String.join " -> " (List.reverse (sname :: seen))
                ++ ") — infinite size; a recursive struct must recurse through a pointer (`next : *"
                ++ sname
                ++ "`)"
            )

    else
        case fieldsOfDecl decls sname of
            Nothing ->
                Err
                    ("RtLang: J11: field type '"
                        ++ sname
                        ++ "' names no declared struct — a struct-value field must resolve in the file's struct table"
                    )

            Just fields ->
                sizesWalk decls names (sname :: seen) sname fields 0


sizesWalk : List Decl -> List String -> List String -> String -> List Field -> Int -> Result String Int
sizesWalk decls names seen structName fields acc =
    case fields of
        [] ->
            Ok acc

        f :: rest ->
            case fieldSize decls names seen structName f.ty of
                Err msg ->
                    Err msg

                Ok sz ->
                    sizesWalk decls names seen structName rest (acc + sz)


{-| A struct declaration's field list, structurally (the same `.fields` the
layout walk reads).  `Nothing` when no such struct is declared.
-}
fieldsOfDecl : List Decl -> String -> Maybe (List Field)
fieldsOfDecl decls sname =
    case decls of
        [] ->
            Nothing

        d :: rest ->
            case d of
                StructDecl s ->
                    if s.name == sname then
                        Just s.fields

                    else
                        fieldsOfDecl rest sname

                EnumDecl _ ->
                    fieldsOfDecl rest sname


{-| The first field name used twice inside one struct, or `Nothing`.
-}
duplicateFieldName : List Field -> Maybe String
duplicateFieldName fields =
    case fields of
        [] ->
            Nothing

        f :: rest ->
            if List.member f.name (List.map .name rest) then
                Just f.name

            else
                duplicateFieldName rest


{-| The enum table: name -> (constant name -> value), rejecting a
duplicate constant name INSIDE one enum (constants are scoped per enum;
two enums may each name a constant `ptr`).
-}
enumsOf : List Decl -> Result String EnumTable
enumsOf decls =
    enumsFold decls Dict.empty


enumsFold : List Decl -> EnumTable -> Result String EnumTable
enumsFold decls acc =
    case decls of
        [] ->
            Ok acc

        d :: rest ->
            case d of
                StructDecl _ ->
                    enumsFold rest acc

                EnumDecl e ->
                    case duplicateConstantName e.entries of
                        Just c ->
                            Err
                                ("RtLang: J14: enum '"
                                    ++ e.name
                                    ++ "' declares constant '"
                                    ++ c
                                    ++ "' more than once — one name, one value"
                                )

                        Nothing ->
                            enumsFold rest
                                (Dict.insert e.name
                                    (Dict.fromList (List.map (\en -> ( en.name, en.value )) e.entries))
                                    acc
                                )


duplicateConstantName : List EnumEntry -> Maybe String
duplicateConstantName entries =
    case entries of
        [] ->
            Nothing

        e :: rest ->
            if List.member e.name (List.map .name rest) then
                Just e.name

            else
                duplicateConstantName rest


{-| A struct's size in words, from the table — exposed for TestMain's
layout pins (sizeof(Region) == 13, sizeof(FrameHdr) == 5).  `Nothing`
when the struct is undeclared or the table rejects.
-}
sizeofStruct : List Decl -> String -> Maybe Int
sizeofStruct decls name =
    case structsOf decls of
        Err _ ->
            Nothing

        Ok table ->
            case Dict.get name table of
                Just info ->
                    Just info.size

                Nothing ->
                    Nothing


{-| A struct field's word offset, from the table — exposed for TestMain's
layout pins (the pad-hole pin: `Region._pad` at word 7).  `Nothing` when
the struct or field is unknown or the table rejects.
-}
fieldOffset : List Decl -> String -> String -> Maybe Int
fieldOffset decls structName fieldName =
    case structsOf decls of
        Err _ ->
            Nothing

        Ok table ->
            case Dict.get structName table of
                Just info ->
                    fieldOffsetIn info.fields fieldName

                Nothing ->
                    Nothing


fieldOffsetIn : List StructField -> String -> Maybe Int
fieldOffsetIn fields name =
    case fields of
        [] ->
            Nothing

        f :: rest ->
            if f.name == name then
                Just f.offset

            else
                fieldOffsetIn rest name


{-| A struct field's WIDTH in words, from the table — the B2 copy lowering's
read of the ONE layout rule (`fieldSize`, the function `layoutOf` lays out
with; this is a wrapper, not a second copy).  `Nothing` when the struct or
field is unknown or the table rejects.
-}
fieldWidth : List Decl -> String -> String -> Maybe Int
fieldWidth decls structName fieldName =
    case structsOf decls of
        Err _ ->
            Nothing

        Ok table ->
            case Dict.get structName table of
                Just info ->
                    case fieldTypeIn info.fields fieldName of
                        Just ty ->
                            case fieldSize decls (structNames decls) [ structName ] structName ty of
                                Ok n ->
                                    Just n

                                Err _ ->
                                    Nothing

                        Nothing ->
                            Nothing

                Nothing ->
                    Nothing


{-| The surface signature set, straight from the parsed program — so
`call` resolution is order-independent (a body may call a defun defined
later; Rt bodies are mutually recursive).  Only ACTIVE defuns
(guardsHold under the flag set) contribute a signature: J8 has already
guaranteed exactly one active defun per key, so the T4 "last defun wins"
note cannot fire silently.
-}
surfacesOf : List Flag -> Program -> Dict Key ( List Type, Type )
surfacesOf flags program =
    List.foldl
        (\d acc ->
            if guardsHold flags d.flags then
                Dict.insert d.key ( List.map .ty d.params, d.ret ) acc

            else
                acc
        )
        Dict.empty
        program


checkDefun : Env -> Defun -> Result String ()
checkDefun env d =
    case duplicateParam d.params of
        Just name ->
            Err (d.key ++ ": J5: duplicate parameter '" ++ name ++ "'")

        Nothing ->
            case validateSig (ctxOf env d) d.params d.ret of
                Err msg ->
                    Err msg

                Ok () ->
                    case checkBlock (ctxOf env d) d.body of
                        Err msg ->
                            Err msg

                        Ok _ ->
                            Ok ()


{-| J11 — every declared parameter/return type must name declared structs
(a `*S` whose `S` is absent is an unknown-struct reject at the defun's
SIGNATURE, before any use).  Raw pointees (`*word`/`*val`) and the
non-pointer classes need nothing.
-}
validateSig : Ctx -> List Param -> Type -> Result String ()
validateSig ctx params ret =
    let
        -- B6: the defun's ABI class, by the ONE rule (Ast.allWordSig), which
        -- is what decides whether a struct/bool parameter has a register to
        -- live in at all.
        wordAbi =
            Ast.allWordSig (List.map .ty params) ret
    in
    case ret of
        TStruct sname ->
            -- plan Q7: the ret path is ONE word, so a struct VALUE cannot
            -- come back (a ret buffer is new ABI machinery — named v2).
            -- B6 changed nothing here and the reason is unchanged: the WORD
            -- ABI's tail is one register, and a struct return needs either a
            -- hidden ret buffer (new ABI) or N registers (a multi-value
            -- return Mid does not have).
            Err
                (ctx.key
                    ++ ": J11: '-> "
                    ++ sname
                    ++ "' — a struct RETURN is REJECTED in v1 (plan Q7: the ret path is one word; a struct comes back through a caller-supplied '*"
                    ++ sname
                    ++ "' out-parameter)"
                )

        TArray _ _ ->
            Err
                (ctx.key
                    ++ ": J11: '-> "
                    ++ typeStr ret
                    ++ "' — an ARRAY RETURN is REJECTED in v1 (the ret path is one word; an array comes back through a caller-supplied '"
                    ++ "*word` out-parameter or a heap array whose base is passed)"
                )

        _ ->
            case validateType ctx ret of
                Err msg ->
                    Err msg

                Ok () ->
                    if ret == TBool && not wordAbi then
                        Err
                            (ctx.key
                                ++ ": J11: '-> bool' — a bool RESULT is a 0/1 word REGISTER, so it needs the WORD ABI; this defun's signature has a `val` (or `float`) in it, which forces the value ABI (one `:val` tail)"
                            )

                    else
                        validateParams ctx wordAbi params


validateParams : Ctx -> Bool -> List Param -> Result String ()
validateParams ctx wordAbi params =
    case params of
        [] ->
            Ok ()

        p :: rest ->
            case p.ty of
                TStruct sname ->
                    if wordAbi then
                        -- B6: a struct parameter BY VALUE.  The defun's whole
                        -- signature is word-class, so it takes the word ABI and
                        -- the caller passes the struct's ADDRESS as one `l`
                        -- register; the callee copies it into its own storage
                        -- at entry (by-value semantics: the callee's writes
                        -- never escape).  Every field read/`&x`/field store then
                        -- goes through the ordinary struct-value rules.
                        Ok ()

                    else
                        Err
                            (ctx.key
                                ++ ": J11: parameter '"
                                ++ p.name
                                ++ "' is a struct VALUE ("
                                ++ sname
                                ++ ") and this defun's signature is NOT all word-class, so it takes the value ABI — a struct parameter is legal only in a WORD-ABI defun (plan Q7; every parameter `word`/`int`/`bool`/`*T`/struct and the result `word`/`bool`/`*T`).  Make the signature all-word, or pass a '*"
                                ++ sname
                                ++ "'"
                            )

                TArray _ _ ->
                    Err
                        (ctx.key
                            ++ ": J11: parameter '"
                            ++ p.name
                            ++ "' is an ARRAY VALUE ("
                            ++ typeStr p.ty
                            ++ ") — an array parameter by value is still refused (B3's J11 rule; B6 does not open it: the flattening question there is the ELEMENT COUNT, not the register class).  Pass a `*word`/`*S` view of its base today"
                        )

                _ ->
                    if p.ty == TBool && not wordAbi then
                        Err
                            (ctx.key
                                ++ ": J11: parameter '"
                                ++ p.name
                                ++ "' is a bool, which is a 0/1 word REGISTER — it needs the WORD ABI, and this defun's signature has a `val` (or `float`) in it, which forces the value ABI (a 40-byte Value slot is not a bool)"
                            )

                    else
                        case validateType ctx p.ty of
                            Err msg ->
                                Err msg

                            Ok () ->
                                validateParams ctx wordAbi rest


{-| The struct-name check inside a declared type (J11): a `*S` must
resolve in the struct table.  Binders, params and returns all run this, so
an unknown struct is caught at its declaration site, not only its first
use.
-}
validateType : Ctx -> Type -> Result String ()
validateType ctx ty =
    case ty of
        TPtr (PStruct sname) ->
            case Dict.get sname ctx.env.structs of
                Just _ ->
                    Ok ()

                Nothing ->
                    Err
                        (ctx.key
                            ++ ": J11: pointer type '*"
                            ++ sname
                            ++ "' names no declared struct — every *S must resolve in the file's struct table"
                        )

        TStruct sname ->
            case Dict.get sname ctx.env.structs of
                Just _ ->
                    Ok ()

                Nothing ->
                    Err
                        (ctx.key
                            ++ ": J11: type '"
                            ++ sname
                            ++ "' names no declared struct — a struct VALUE must resolve in the file's struct table"
                        )

        TArray elem n ->
            if n <= 0 then
                Err
                    (ctx.key
                        ++ ": J11: '"
                        ++ typeStr (TArray elem n)
                        ++ "' — a fixed array's length is at least 1 (a zero-length array has no storage, so no address and no elements)"
                    )

            else if elem == TFloat then
                Err
                    (ctx.key
                        ++ ": J1: '"
                        ++ typeStr (TArray elem n)
                        ++ "' — a float array has no raw-memory seat (Mid.Ir has no f64 load/store node; the J11 float-field rule, same reason)"
                    )

            else
                validateType ctx elem

        _ ->
            Ok ()


ctxOf : Env -> Defun -> Ctx
ctxOf env d =
    { env = env
    , key = d.key
    , params = d.params
    , ret = d.ret
    , scope = paramScope d.params
    }


paramScope : List Param -> Dict String Type
paramScope params =
    List.foldl (\p acc -> Dict.insert p.name p.ty acc) Dict.empty params


duplicateParam : List Param -> Maybe String
duplicateParam params =
    case params of
        p :: rest ->
            if List.member p.name (List.map .name rest) then
                Just p.name

            else
                duplicateParam rest

        [] ->
            Nothing



-- ============================ statements and blocks ============================


{-| Check a block: statements left to right (scope threading — J5's
strict order), then the terminator.  Returns the terminator's class (the
block's value — `EWithRoots`'s value is its block's).
-}
checkBlock : Ctx -> Block -> Result String Type
checkBlock ctx b =
    case stmtsFold ctx b.stmts of
        Err msg ->
            Err msg

        Ok ctx2 ->
            checkTerm ctx2 b.term


stmtsFold : Ctx -> List Stmt -> Result String Ctx
stmtsFold ctx stmts =
    case stmts of
        [] ->
            Ok ctx

        s :: rest ->
            case checkStmt ctx s of
                Err msg ->
                    Err msg

                Ok ctx2 ->
                    stmtsFold ctx2 rest


checkStmt : Ctx -> Stmt -> Result String Ctx
checkStmt ctx stmt =
    case stmt of
        SBind ty name e ->
            if ty == TFloat then
                Err
                    (ctx.key
                        ++ ": J1: binder '"
                        ++ name
                        ++ "' declares float — float words are not let-bindable (MEASURED: Lower's rawFltArg never yields a Var): recompute the float expression at each use, or bind it boxed via mkflt"
                    )

            else if ty == TBool then
                bindBool ctx name e

            else
                case validateType ctx ty of
                    Err msg ->
                        Err msg

                    Ok () ->
                        case checkExp ctx e of
                            Err msg ->
                                Err msg

                            Ok cls ->
                                if coerce ty cls then
                                    Ok { ctx | scope = Dict.insert name ty ctx.scope }

                                else
                                    Err
                                        (ctx.key
                                            ++ ": J1: binder '"
                                            ++ name
                                            ++ "' declares "
                                            ++ typeStr ty
                                            ++ " but its initializer is "
                                            ++ typeStr cls
                                        )

        SEffect e ->
            case checkExp ctx e of
                Err msg ->
                    Err msg

                Ok _ ->
                    Ok ctx

        SIf c t me ->
            case checkIf ctx c t me of
                Err msg ->
                    Err msg

                Ok _ ->
                    if diverges t || divergesMaybe me then
                        Ok ctx

                    else
                        Err
                            (ctx.key
                                ++ ": J7: a mid-block 'if' with both branches falling through — Mid has no join and Case is forbidden: bind through ?: or make it the last statement"
                            )

        SFieldStore p f e ->
            checkFieldStore ctx p f e

        SIndexStore p i e ->
            checkIndexStore ctx p i e

        SStructBind rec ->
            checkStructBind ctx rec.sname rec.name rec.init

        SArrayBind rec ->
            checkArrayBind ctx rec.aty rec.name rec.init

        SVarStore name e ->
            checkVarStore ctx name e


{-| J1 (B1) — the `bool` BINDER rule: the class exists for the 0/1 word,
and a binder must carry a value whose representation is fixed by the CLASS
(a raw 0/1 TEMP) — that is the property that lets a bool binder be a
condition.  So the initializer must be a bool TEMP (`isBoolTemp`); a
literal, a float compare or a bool join are the three shapes whose values
are NOT temps, and each is a loud reject here rather than a misread (or a
QBE-layer failure) later.  See the module header for each reason.
-}
bindBool : Ctx -> String -> Exp -> Result String Ctx
bindBool ctx name e =
    case checkExp ctx e of
        Err msg ->
            Err msg

        Ok cls ->
            if cls /= TBool then
                Err
                    (ctx.key
                        ++ ": J1: binder '"
                        ++ name
                        ++ "' declares bool but its initializer is "
                        ++ typeStr cls
                    )

            else if isBoolTemp e then
                Ok { ctx | scope = Dict.insert name TBool ctx.scope }

            else
                Err
                    (ctx.key
                        ++ ": J1: binder '"
                        ++ name
                        ++ "' declares bool but its initializer is not a bool TEMP — a bool binder is branchable precisely because every bool value is a raw 0/1 temp (a comparison, a [bool](w) cast, or another bool binder): a literal (a raw-Int binder reads back as a NUMBER), a float compare (not a raw-word binder node) and a ?: join (a slot) have no such representation.  Branch the comparison inline, or bind a `val`"
                    )


{-| The bool TEMP forms — exactly the shapes that lower to a raw 0/1 temp
AND are raw-word/word-cond nodes in the backend: a word compare
(`RawCmp`), a `[bool](w)` cast (`RawCmp`), and a bool binder variable (a
temp by induction, since it was admitted by this same rule).  Deliberately
ABSENT: `EBool` (a `Lit`), `EFltCmp` (`RawFltCmp` is a word 0/1 but not a
raw-word BINDER node) and the joins (`If` — a slot).
-}
isBoolTemp : Exp -> Bool
isBoolTemp e =
    case e of
        EWordCmp _ _ _ ->
            True

        ECast ty _ ->
            ty == TBool

        EVar _ ->
            True

        _ ->
            False


{-| B2 — the struct-VALUE binder `S s;` / `S s = { .. };` / `S s = other;`.
Three judgments, all fail-fast and all loud:

  1. `S` must be a declared struct (J11) — and the same walk runs
     `validateType`, so an unknown name is caught at the BINDER, not at its
     first use.
  2. `name` must be NEW (J5's strict-order shadowing rule: a binder is a
     fresh id, so re-declaring one is a mistake, never an overwrite).
  3. the initialiser must fit the struct: `InitFields` names real fields,
     once each, and each value COERCES to its field's class; `InitCopy`
     needs an expression of the SAME struct value class (`TStruct S` — a
     `*S` is deliberately NOT accepted: the copy reads the VALUE's words,
     and a pointer would need a `*p` deref spelling this grammar lacks).
-}
checkStructBind : Ctx -> String -> String -> StructInit -> Result String Ctx
checkStructBind ctx sname name init =
    case Dict.get sname ctx.env.structs of
        Nothing ->
            Err
                (ctx.key
                    ++ ": J11: '"
                    ++ sname
                    ++ " "
                    ++ name
                    ++ "' — no such struct is declared in this module"
                )

        Just info ->
            if Dict.member name ctx.scope then
                Err
                    (ctx.key
                        ++ ": J5: '"
                        ++ name
                        ++ "' is already a binder in scope — a binder is a NEW id (shadowing is a rename, and a struct binder OWNS fresh storage)"
                    )

            else
                case checkStructInit ctx sname info name init of
                    Err msg ->
                        Err msg

                    Ok () ->
                        Ok { ctx | scope = Dict.insert name (TStruct sname) ctx.scope }


checkStructInit : Ctx -> String -> StructInfo -> String -> StructInit -> Result String ()
checkStructInit ctx sname info name init =
    case init of
        InitZero ->
            Ok ()

        InitFields fields ->
            initFieldsWalk ctx sname info name fields []

        InitCopy e ->
            case checkExp ctx e of
                Err msg ->
                    Err msg

                Ok (TStruct other) ->
                    if other == sname then
                        Ok ()

                    else
                        Err
                            (ctx.key
                                ++ ": J1: '"
                                ++ name
                                ++ "' is a "
                                ++ sname
                                ++ " but its initializer is a "
                                ++ other
                                ++ " value — a copy needs the SAME struct"
                            )

                Ok cls ->
                    Err
                        (ctx.key
                            ++ ": J1: '"
                            ++ name
                            ++ "' is a "
                            ++ sname
                            ++ " but its initializer is "
                            ++ typeStr cls
                            ++ " — a struct copy needs a struct VALUE of the same type (a '*"
                            ++ sname
                            ++ "' is not one)"
                        )


initFieldsWalk : Ctx -> String -> StructInfo -> String -> List ( String, Exp ) -> List String -> Result String ()
initFieldsWalk ctx sname info name fields seen =
    case fields of
        [] ->
            Ok ()

        ( f, e ) :: rest ->
            if List.member f seen then
                Err
                    (ctx.key
                        ++ ": J13: field '"
                        ++ f
                        ++ "' is initialised twice in '"
                        ++ name
                        ++ "' — one field, one initialiser"
                    )

            else
                case fieldTypeIn info.fields f of
                    Nothing ->
                        Err
                            (ctx.key
                                ++ ": J13: struct '"
                                ++ sname
                                ++ "' has no field '"
                                ++ f
                                ++ "' to initialise"
                            )

                    Just fty ->
                        case checkExp ctx e of
                            Err msg ->
                                Err msg

                            Ok vcls ->
                                if coerce fty vcls then
                                    initFieldsWalk ctx sname info name rest (f :: seen)

                                else
                                    Err
                                        (ctx.key
                                            ++ ": J1: initialiser for field '"
                                            ++ sname
                                            ++ "."
                                            ++ f
                                            ++ "' needs "
                                            ++ typeStr fty
                                            ++ ", got "
                                            ++ typeStr vcls
                                        )


{-| B3 (plan Q5) — the ARRAY BINDER `word[N] a;` / `word[N] a = { e1, ..,
eN };`.  Four judgments, all loud:

  1. the type must be an ARRAY (`TArray`) — the arm is only reachable that
     way, so a non-array here is a lowerer/parser drift, reported as such;
  2. the type must VALIDATE (an unknown struct element, a zero length, a
     float element — `validateType`'s arms);
  3. `name` must be NEW (J5's strict-order rule: an array binder OWNS fresh
     storage, so re-declaring one is a mistake, never an overwrite);
  4. a FULL initialiser must have EXACTLY `n` elements, and each must COERCE
     to the element class.  A SHORT (or long) list is the plan's PARTIAL
     reject, with the reason in the message: zero-filling the elements the
     program did not spell would put tag-0 handles in the `val` elements it
     skipped — a garbage-tag trap manufactured by the compiler, which is
     exactly what the bare declaration (a `memset`) does NOT do (it zeroes
     all of them, visibly).

A nested-array element cannot be initialised from a value (`{{1,2},{3,4}}` is
not in this grammar): the reject names the leaves' spelling.
-}
checkArrayBind : Ctx -> Type -> String -> ArrayInit -> Result String Ctx
checkArrayBind ctx aty name init =
    case aty of
        TArray elem n ->
            case validateType ctx aty of
                Err msg ->
                    Err msg

                Ok () ->
                    if Dict.member name ctx.scope then
                        Err
                            (ctx.key
                                ++ ": J5: '"
                                ++ name
                                ++ "' is already a binder in scope — a binder is a NEW id (shadowing is a rename, and an array binder OWNS fresh storage)"
                            )

                    else
                        case init of
                            AInitZero ->
                                Ok { ctx | scope = Dict.insert name aty ctx.scope }

                            AInitFull es ->
                                if List.length es /= n then
                                    Err
                                        (ctx.key
                                            ++ ": J11: '"
                                            ++ name
                                            ++ "' is a "
                                            ++ typeStr aty
                                            ++ " but the initialiser has "
                                            ++ String.fromInt (List.length es)
                                            ++ " element(s) — a PARTIAL initialiser is refused (C's `{0}` included): zero-filling the elements you did not spell puts tag-0 handles in the `val` elements it skipped, a garbage-tag trap manufactured by the compiler.  Zero the WHOLE array with the bare declaration (`"
                                            ++ typeStr aty
                                            ++ " "
                                            ++ name
                                            ++ ";` — a memset) or `rawcall memset(base, 0, 40*N)`, or spell every element"
                                        )

                                else
                                    case arrayElemWalk ctx elem name es 0 of
                                        Err msg ->
                                            Err msg

                                        Ok () ->
                                            Ok { ctx | scope = Dict.insert name aty ctx.scope }

        _ ->
            Err
                (ctx.key
                    ++ ": an ARRAY binder needs an array type, got "
                    ++ typeStr aty
                    ++ " — the parser only produces this statement from `T[N] id`, so this is a lowering/checker drift"
                )


arrayElemWalk : Ctx -> Type -> String -> List Exp -> Int -> Result String ()
arrayElemWalk ctx elem name es i =
    case es of
        [] ->
            Ok ()

        e :: rest ->
            if elem == TFloat then
                Err (ctx.key ++ ": J1: a float array element has no raw-memory seat")

            else if isArrayTy elem then
                Err
                    (ctx.key
                        ++ ": J11: element "
                        ++ String.fromInt i
                        ++ " of '"
                        ++ name
                        ++ "' — an ARRAY element cannot be initialised from a value ("
                        ++ typeStr elem
                        ++ " is itself an array): declare the array bare (zeroed) and store the leaves (`a[i][j] = e;`)"
                    )

            else
                case checkExp ctx e of
                    Err msg ->
                        Err msg

                    Ok cls ->
                        if coerce elem cls then
                            arrayElemWalk ctx elem name rest (i + 1)

                        else
                            Err
                                (ctx.key
                                    ++ ": J1: element "
                                    ++ String.fromInt i
                                    ++ " of '"
                                    ++ name
                                    ++ "' needs "
                                    ++ typeStr elem
                                    ++ ", got "
                                    ++ typeStr cls
                                )


isArrayTy : Type -> Bool
isArrayTy t =
    case t of
        TArray _ _ ->
            True

        _ ->
            False


{-| B2 — `s = other;` the aggregate COPY statement.  Only a struct-VALUE
binder may be assigned (Mid binders are single-assignment: a `word`/`val`/
pointer destination is a loud reject naming the rule), and the source must
be the SAME struct value class — this is a word-for-word copy into storage
that already exists.
-}
checkVarStore : Ctx -> String -> Exp -> Result String Ctx
checkVarStore ctx name e =
    case Dict.get name ctx.scope of
        Nothing ->
            Err (ctx.key ++ ": J5: unbound name '" ++ name ++ "' in an assignment")

        Just (TStruct sname) ->
            case checkExp ctx e of
                Err msg ->
                    Err msg

                Ok (TStruct other) ->
                    if other == sname then
                        Ok ctx

                    else
                        Err
                            (ctx.key
                                ++ ": J1: '"
                                ++ name
                                ++ "' is a "
                                ++ sname
                                ++ " but the assigned value is a "
                                ++ other
                                ++ " — a struct copy needs the SAME struct"
                            )

                Ok cls ->
                    Err
                        (ctx.key
                            ++ ": J1: '"
                            ++ name
                            ++ "' is a "
                            ++ sname
                            ++ " but the assigned value is "
                            ++ typeStr cls
                            ++ " — a struct copy needs a struct VALUE of the same type"
                        )

        Just (TArray _ _) ->
            Err
                (ctx.key
                    ++ ": J1: '"
                    ++ name
                    ++ "' is an ARRAY VALUE — an array cannot be assigned whole (that is an element-wise copy, not in v1): store the elements (`a[i] = e;`)"
                )

        Just cls ->
            Err
                (ctx.key
                    ++ ": J1: '"
                    ++ name
                    ++ "' is "
                    ++ typeStr cls
                    ++ " — only a struct VALUE can be assigned (Mid binders are single-assignment: a scalar rebind is a NEW binder, and a field is written `p->f = e;`)"
                )


{-| B2 — `&place`: the ADDRESS of a memory-backed place, as `*T`.  Legal on
exactly two shapes, both of which have storage in this lowering:

  * a struct VALUE expression — `&s`, `&s.inner`, `&(p[i] on a *S)`: its
    value IS its address, so this is the IDENTITY (`*S`);
  * a struct FIELD whose type is one word or a nested struct — `&s.f`,
    `&p->f`, `&s.inner`: base address + the field's constant offset
    (`*word` for a word/pointer field, `*B` for a nested struct field).

Everything else is refused with the reason: a `word`/`int`/`bool`/`float`
LOCAL or a PARAMETER (a binder is a temp or a Value slot — no address; a
scalar spill to memory is the named v2), a temporary/call/literal (no
place at all), and a `val` FIELD (`&s.v` — a GC-interior address exposed
as a raw word is the unrooted-view hazard; `vecaddr`/`payload` are the
sanctioned reads, plan Q11).
-}
checkAddrOf : Ctx -> Exp -> Result String Type
checkAddrOf ctx e =
    case e of
        EField base f ->
            case structPointer ctx base of
                Err msg ->
                    Err msg

                Ok ( sname, info ) ->
                    case fieldTypeIn info.fields f of
                        Nothing ->
                            Err
                                (ctx.key
                                    ++ ": J13: struct '"
                                    ++ sname
                                    ++ "' has no field '"
                                    ++ f
                                    ++ "' to take the address of"
                                )

                        Just (TStruct inner) ->
                            Ok (TPtr (PStruct inner))

                        Just TVal ->
                            Err
                                (ctx.key
                                    ++ ": J13: '&"
                                    ++ sname
                                    ++ "."
                                    ++ f
                                    ++ "' — a val field has no raw address: exposing a GC-interior pointer as a word is the unrooted-view hazard (use vecaddr/payload, plan Q11)"
                                )

                        Just ty2 ->
                            -- B3: an ARRAY field is a location too, and it
                            -- decays to the pointer spelling of its element
                            -- (`&s.tab` on `word[3]` is `*word`), exactly as
                            -- the array value itself does.  Everything else is
                            -- one word -> `*word` (B2's rule, unchanged).
                            case decayTo ty2 of
                                Just pty2 ->
                                    Ok pty2

                                Nothing ->
                                    Ok (TPtr PWord)

        _ ->
            case checkExp ctx e of
                Err msg ->
                    Err msg

                Ok (TStruct sname) ->
                    Ok (TPtr (PStruct sname))

                Ok (TPtr _) ->
                    Err
                        (ctx.key
                            ++ ": J13: '&' of a pointer — the pointer IS an address; `&p` would mean the address of the PARAMETER/BINDER holding it, and a binder has no storage in this lowering (spilling it is the named v2)"
                        )

                Ok cls ->
                    case decayTo cls of
                        Just pty2 ->
                            -- B3: `&a` on an ARRAY value is the IDENTITY — the
                            -- value already IS the address of its storage, so
                            -- the address-of node emits nothing (the same
                            -- treatment `&s` gets, for the same reason).
                            Ok pty2

                        Nothing ->
                            Err
                                (ctx.key
                                    ++ ": J13: '&' needs a struct value, an array value or a struct field with storage, got "
                                    ++ typeStr cls
                                    ++ " — a scalar local, a parameter and a temporary have no address in this lowering (a struct local (`S s;`), an array local (`word[N] a;`) or a struct field is the memory-backed seat)"
                                )


{-| J13 — `p->f = e;`: `p` must be a struct pointer, `f` a field of its
struct, and `e`'s class must COERCE to the field's (the J12 matrix — a
`val` into a `word` field is the pinned reject; a pointer into a word
field is a word, so it stores).  A bool into a `val` field is the ONE
implicit coercion (`coerce`'s bool→val row, boxed at lowering).
-}
checkFieldStore : Ctx -> Exp -> String -> Exp -> Result String Ctx
checkFieldStore ctx p f e =
    case structPointer ctx p of
        Err msg ->
            Err msg

        Ok ( sname, info ) ->
            case fieldTypeIn info.fields f of
                Nothing ->
                    Err
                        (ctx.key
                            ++ ": J13: struct '"
                            ++ sname
                            ++ "' has no field '"
                            ++ f
                            ++ "' to store"
                        )

                Just fty ->
                    case checkExp ctx e of
                        Err msg ->
                            Err msg

                        Ok vcls ->
                            if coerce fty vcls then
                                Ok ctx

                            else
                                Err
                                    (ctx.key
                                        ++ ": J13: store to field '"
                                        ++ sname
                                        ++ "."
                                        ++ f
                                        ++ "' needs "
                                        ++ typeStr fty
                                        ++ ", got "
                                        ++ typeStr vcls
                                    )


{-| J13 — `p[i] = e;`: the element class comes from the pointer's pointee
family (word/val/struct-scaled word), the index is a word offset, and `e`
coerces to the element class (a `val` into a `*word` slot is the pinned
reject).
-}
checkIndexStore : Ctx -> Exp -> Exp -> Exp -> Result String Ctx
checkIndexStore ctx p i e =
    case checkExp ctx p of
        Err msg ->
            Err msg

        Ok (TArray elem _) ->
            -- B3: the same element judgment as `p[i] = e` on a pointer, over
            -- the ARRAY's element type.  A nested-array element is the one
            -- shape the store cannot express (`a[i] = b;` would need the N
            -- unrolled element copies an array copy would need) — refused with
            -- the leaves' spelling.
            case validateType ctx elem of
                Err msg ->
                    Err msg

                Ok () ->
                    case wordIndex ctx i of
                        Err msg ->
                            Err msg

                        Ok () ->
                            case elem of
                                TArray _ _ ->
                                    Err
                                        (ctx.key
                                            ++ ": J13: an ARRAY element cannot be stored whole ("
                                            ++ typeStr elem
                                            ++ " is itself an array, so the store would be an element-wise copy): store the leaves (`a[i][j] = e;`)"
                                        )

                                _ ->
                                    case checkExp ctx e of
                                        Err msg ->
                                            Err msg

                                        Ok vcls ->
                                            if coerce elem vcls then
                                                Ok ctx

                                            else
                                                Err
                                                    (ctx.key
                                                        ++ ": J13: store to an array element needs "
                                                        ++ typeStr elem
                                                        ++ ", got "
                                                        ++ typeStr vcls
                                                    )

        Ok (TPtr pty) ->
            case wordIndex ctx i of
                Err msg ->
                    Err msg

                Ok () ->
                    case indexClass ctx pty of
                        Err msg ->
                            Err msg

                        Ok elemTy ->
                            case checkExp ctx e of
                                Err msg ->
                                    Err msg

                                Ok vcls ->
                                    if coerce elemTy vcls then
                                        Ok ctx

                                    else
                                        Err
                                            (ctx.key
                                                ++ ": J13: store to '"
                                                ++ typeStr (TPtr pty)
                                                ++ "' element needs "
                                                ++ typeStr elemTy
                                                ++ ", got "
                                                ++ typeStr vcls
                                            )

        Ok cls ->
            Err
                (ctx.key
                    ++ ": J13: index store needs a pointer target, got "
                    ++ typeStr cls
                )


{-| J13 — `p->f` / `p->f = e`: resolve the pointer expression to a struct
pointer and return `(struct name, its layout)`.  Anything else is a loud
reject (field access on a `*word`/`*val`/non-pointer).
-}
structPointer : Ctx -> Exp -> Result String ( String, StructInfo )
structPointer ctx p =
    case checkExp ctx p of
        Err msg ->
            Err msg

        Ok (TPtr (PStruct sname)) ->
            structAt ctx sname ("*" ++ sname)

        Ok (TStruct sname) ->
            -- B2: a struct VALUE is memory too, and its VALUE is its
            -- address — so `s.f` resolves exactly as `p->f`/`p.f` does.
            -- This ONE arm is what makes the `.`-auto-deref rule (Terra's:
            -- `p.f` on a `*S` derefs once) cost no new judgment.
            structAt ctx sname sname

        Ok (TPtr pty) ->
            Err
                (ctx.key
                    ++ ": J13: field access needs a struct pointer or a struct value, got "
                    ++ typeStr (TPtr pty)
                )

        Ok cls ->
            Err
                (ctx.key
                    ++ ": J13: field access needs a struct pointer or a struct value, got "
                    ++ typeStr cls
                )


structAt : Ctx -> String -> String -> Result String ( String, StructInfo )
structAt ctx sname what =
    case Dict.get sname ctx.env.structs of
        Just info ->
            Ok ( sname, info )

        Nothing ->
            Err
                (ctx.key
                    ++ ": J11: field access on '"
                    ++ what
                    ++ "' — no such struct is declared"
                )


fieldTypeIn : List StructField -> String -> Maybe Type
fieldTypeIn fields name =
    case fields of
        [] ->
            Nothing

        f :: rest ->
            if f.name == name then
                Just f.ty

            else
                fieldTypeIn rest name


{-| J13 — the element class of a pointer's pointee, for `p[i]` /
`p[i] = e`: `*word` -> word (`wload` stride), `*val` -> val (`vecload`
stride), `*S` -> word (struct-scaled — the WORD at the element base,
`RawWordLoad { index = i * sizeofS }` per round-1 §3; v1 has no struct
values to yield).
-}
indexClass : Ctx -> PTy -> Result String Type
indexClass ctx pty =
    case pty of
        PWord ->
            Ok TWord

        PVal ->
            Ok TVal

        PStruct sname ->
            case Dict.get sname ctx.env.structs of
                Just _ ->
                    Ok TWord

                Nothing ->
                    Err
                        (ctx.key
                            ++ ": J11: index access on '*"
                            ++ sname
                            ++ "' — no such struct is declared"
                        )


{-| J13 — the index of `p[i]` is a word offset (the `wload`/`vecload`
contract; the struct-scaled `*S` index is still a WORD element index, the
`sizeofS` multiply happens at lowering).
-}
wordIndex : Ctx -> Exp -> Result String ()
wordIndex ctx i =
    case checkExp ctx i of
        Err msg ->
            Err msg

        Ok TWord ->
            Ok ()

        Ok cls ->
            Err
                (ctx.key
                    ++ ": J13: index must be a word offset, got "
                    ++ typeStr cls
                )


checkTerm : Ctx -> Term -> Result String Type
checkTerm ctx term =
    case term of
        TRet e ->
            case checkExp ctx e of
                Err msg ->
                    Err msg

                Ok cls ->
                    if coerce ctx.ret cls then
                        Ok ctx.ret

                    else
                        Err
                            (ctx.key
                                ++ ": J6: return is "
                                ++ typeStr cls
                                ++ " but '-> "
                                ++ typeStr ctx.ret
                                ++ "' is declared"
                            )

        TRecur args ->
            checkRecur ctx args

        TIf c t me ->
            case me of
                Just _ ->
                    checkIf ctx c t me

                Nothing ->
                    if diverges t then
                        checkIf ctx c t me

                    else
                        Err
                            (ctx.key
                                ++ ": J7: a terminating 'if' without 'else' needs a diverging then-branch — the false path is the block's fall-through, and a falling then-branch leaves it with no value"
                            )


{-| J7's divergence predicate: a block DIVERGES iff control can never
fall past its end — decided by the block's TERMINATOR alone.  `return`
and `recur` diverge unconditionally; a terminating `if` diverges only
when BOTH of its branch blocks diverge (a missing else can fall
through).  Two stated non-facts, pinned in the header: statements never
contribute (dead code after a both-diverging mid-block `if` is not
chased), and a deeper one-sided divergent `if` does not make an
enclosing branch diverge — the branch can still fall through the inner
`if`'s false path.
-}
diverges : Block -> Bool
diverges b =
    case b.term of
        TRet _ ->
            True

        TRecur _ ->
            True

        TIf _ t me ->
            case me of
                Just e ->
                    diverges t && diverges e

                Nothing ->
                    False


divergesMaybe : Maybe Block -> Bool
divergesMaybe me =
    case me of
        Just e ->
            diverges e

        Nothing ->
            False


{-| J4 — the loop's saturation contract.  `recur` lowers to
`App{fn=GRef own-key, force=False}`; the classifier grants the
edge-not-safepoint edge to a SATURATED self-app, so a recur with the
wrong arity would silently stop being a loop (a plain call + bounce).
The class check on each argument is the same contract as `call` (J2):
the callee's declared parameter classes.
-}
checkRecur : Ctx -> List Exp -> Result String Type
checkRecur ctx args =
    if List.length args == List.length ctx.params then
        case
            checkArgs argOk
                ctx
                "J4"
                ("recur in '" ++ ctx.key ++ "'")
                (List.map .ty ctx.params)
                args
        of
            Ok () ->
                Ok ctx.ret

            Err msg ->
                Err msg

    else
        Err
            (ctx.key
                ++ ": J4: recur passes "
                ++ String.fromInt (List.length args)
                ++ " argument(s) but '"
                ++ ctx.key
                ++ "' declares "
                ++ String.fromInt (List.length ctx.params)
                ++ " parameter(s) — an unsaturated recur would be demoted to a plain call: the loop stops being a loop"
            )


{-| The shared if walk (`SIf` statement and `TIf` term).  J1: the
condition is `:val` OR a word PRODUCER (`:word` — a bare word compare/
tagis/builtin/rawcall branches directly on the word, no `mkbool` needed;
the old boxed spelling stays legal and byte-identical).  A word LITERAL,
a bare word VARIABLE and a word-VALUED join are rejects — see
`checkCond`.
The divergence rules around it are J7's — checked by the SIf arm of
`checkStmt` and the `TIf` arm of `checkTerm`, not here.
-}
checkIf : Ctx -> Exp -> Block -> Maybe Block -> Result String Type
checkIf ctx c t me =
    case checkCond ctx c of
        Err msg ->
            Err msg

        Ok _ ->
            case checkBlock ctx t of
                Err msg ->
                    Err msg

                Ok tCls ->
                    case me of
                        Just e ->
                            case checkBlock ctx e of
                                Err msg ->
                                    Err msg

                                Ok _ ->
                                    Ok tCls

                        Nothing ->
                            Ok tCls


checkCond : Ctx -> Exp -> Result String Type
checkCond ctx c =
    case checkExp ctx c of
        Err msg ->
            Err msg

        Ok TVal ->
            Ok TVal

        Ok TBool ->
            -- B1: a BOOL condition is branchable — a bool expression IS a
            -- raw 0/1 TEMP (the header's closure), so `jnz` on it is right
            -- and NO representation is left to the lowering.  That is
            -- exactly what a bare `word` VARIABLE cannot promise (below),
            -- which is the P1c seam this closes.
            --
            -- ONE form is refused: a CONSTANT (`if (true)`) — a constant
            -- branch is not a test, the same rule `if (1)` has had since
            -- P1c.
            if isConstExp c then
                Err
                    (ctx.key
                        ++ ": J1: 'if' condition is a CONSTANT bool — a constant branch is not a test (write the compare inline)"
                    )

            else
                Ok TBool

        Ok TWord ->
            -- A WORD condition is legal only as a BARE word PRODUCER (a
            -- compare/tagis/word-builtin/rawcall — the forms the lowering
            -- computes into a raw TEMP and jumps on directly).  Four word
            -- shapes must NOT be admitted, each for a MEASURED reason (the
            -- P1c review):
            --   * a word-VALUED join — `(a == b) ? 1 : 0`, an `EIf`/
            --     `EIfBlock` whose branches agree on `:word` — has no bare
            --     test: its value needs a slot, and admitting it would box
            --     the 0/1 as a NUMBER that jmpf silently misreads (always
            --     truthy: tag 0 /= tagBoolean);
            --   * a word VARIABLE — same silent misread: a binder whose
            --     initializer is not a raw-word producer (a literal, or a
            --     word-valued join) is slot-boxed as a number and the
            --     checker cannot see the lowering's representation.  (A
            --     raw-word binder `word i = wload(..); if (i)` WOULD lower
            --     correctly — rejecting it is a deliberate over-strictness
            --     until the checker tracks raw binders; write the compare
            --     inline, which is the form the feature exists for.  A
            --     `bool` binder IS branchable because its representation is
            --     the CLASS's — see the TBool arm above.)
            --   * a word LITERAL — `if (1)`.  CORRECTION (B1, MEASURED on
            --     this tree's `vendor/qbe/qbe`): that binary ACCEPTS `jnz 1`
            --     and folds it (`movl $1, %eax; ret`), so the reason is NOT
            --     an assembler refusal — it is that a constant branch is not
            --     a test, and a constant condition in a source language hides
            --     the compare the reader meant to write.  The rule is
            --     unchanged; only the stated reason is now the measured one.
            -- B1 extends the LITERAL rule (not the vocabulary): `sizeof(S)`
            -- and a cast of a constant are constants too, and would emit
            -- exactly the same constant condition.
            case c of
                EIf _ _ _ ->
                    Err
                        (ctx.key
                            ++ ": J1: 'if' condition is a word-valued '?:' join — a bare word test is needed (box it with mkbool or restructure)"
                        )

                EIfBlock _ _ _ ->
                    Err
                        (ctx.key
                            ++ ": J1: 'if' condition is a word-valued 'if' join — a bare word test is needed (box it with mkbool or restructure)"
                        )

                EVar _ ->
                    Err
                        (ctx.key
                            ++ ": J1: 'if' condition is a bare word variable — only a word PRODUCER (a compare/tagis/…) jumps directly; a binder's representation is the lowering's, not the checker's (write the compare inline, or bind it `bool` and branch on that)"
                        )

                _ ->
                    if isConstExp c then
                        Err
                            (ctx.key
                                ++ ": J1: 'if' condition is a CONSTANT word — a constant branch is not a test (write the compare inline)"
                            )

                    else
                        Ok TWord

        Ok cls ->
            Err
                (ctx.key
                    ++ ": J1: 'if' condition must be val or word — a float word cannot branch, got "
                    ++ typeStr cls
                )


{-| B1 — does this expression FOLD TO A CONSTANT, i.e. would it lower to a
bare `Lit`?  Only the forms whose lowering is exactly one `Lit`: an int, a
float, a string, a bool literal, a `sizeof`, and a cast of one of those
through a row that emits no node (`[word]`/`[int]`/`[bool]`/`[*T]`).  Used
ONLY by `checkCond`'s constant-branch rejects, which is why it can be this
narrow: a form it misses is a form whose cond the lowering computes into a
temp (the thing such a cond is supposed to be).
-}
isConstExp : Exp -> Bool
isConstExp c =
    case c of
        EInt _ ->
            True

        EFlt _ ->
            True

        EStr _ ->
            True

        EBool _ ->
            True

        ESizeof _ ->
            True

        ECast target inner ->
            (target == TWord || target == TBool || isPtr target) && isConstExp inner

        _ ->
            False



-- ============================ J1/J2/J3: expressions ============================


{-| The expression walk: every case returns the expression's FIXED class.
Nothing is inferred — an `EVar` IS its declared class, a literal its
family's, a form its table row's.  The forms whose class is COMPUTED are
`EIf` and `EIfBlock` (T23): their branches must agree (checked right
here) and the agreed class is the form's.
-}
checkExp : Ctx -> Exp -> Result String Type
checkExp ctx e =
    case e of
        EInt _ ->
            Ok TWord

        EFlt _ ->
            Ok TFloat

        EStr _ ->
            Ok TVal

        EBool _ ->
            Ok TBool

        ESizeof target ->
            case sizeofWords ctx target of
                Err msg ->
                    Err msg

                Ok _ ->
                    Ok TWord

        ECast ty inner ->
            castClass ctx ty inner

        EVar name ->
            case Dict.get name ctx.scope of
                Just ty ->
                    Ok ty

                Nothing ->
                    Err (ctx.key ++ ": J5: unbound name '" ++ name ++ "'")

        EAddrOf inner ->
            checkAddrOf ctx inner

        EWordBin op a b ->
            checkWordBin ctx op a b

        EWordCmp op a b ->
            checkSig ctx ("operator '" ++ wordCmpName op ++ "' (yields a bool — branch on it directly, bind it `bool b = ..`, or box with mkbool for a val)") wordCmpSig [ a, b ]

        EFltBin op a b ->
            checkSig ctx ("operator '" ++ fltBinName op ++ "'") fltBinSig [ a, b ]

        EFltCmp op a b ->
            checkSig ctx ("operator '" ++ fltCmpName op ++ "'") fltCmpSig [ a, b ]

        EShortAnd a b ->
            checkSig ctx "operator '&&'" shortSigOf [ a, b ]

        EShortOr a b ->
            checkSig ctx "operator '||'" shortSigOf [ a, b ]

        EIf c thn els ->
            case checkCond ctx c of
                Err msg ->
                    Err msg

                Ok _ ->
                    case checkExp ctx thn of
                        Err msg ->
                            Err msg

                        Ok thnCls ->
                            case checkExp ctx els of
                                Err msg ->
                                    Err msg

                                Ok elsCls ->
                                    joinClass ctx "?:" thnCls elsCls

        EIfBlock c thn els ->
            -- T23: the block-branch if EXPRESSION.  Same cond judgment as
            -- every if (`checkCond`); each BRANCH's class is its block's
            -- VALUE class (`checkBlock` — the block's terminator's class),
            -- the two must AGREE, and the agreed class is the form's, so
            -- it composes in a word or val slot.  Each block is checked
            -- against the ENCLOSING ctx — a branch's binders end at its
            -- own `}` and cannot leak into the other branch or the
            -- continuation.  (MEASURED note: every TERM's class is the
            -- defun's `-> ty` — J6 pins each `return`, TRecur returns
            -- ctx.ret, TIf recurses on blocks — so through the existing
            -- term grammar the two branch classes always agree once both
            -- blocks check; the agreement arm states the judgment the
            -- form's contract needs and stays correct if the term grammar
            -- ever gains a value-introducing term.)
            case checkCond ctx c of
                Err msg ->
                    Err msg

                Ok _ ->
                    case checkBlock ctx thn of
                        Err msg ->
                            Err msg

                        Ok thnCls ->
                            case checkBlock ctx els of
                                Err msg ->
                                    Err msg

                                Ok elsCls ->
                                    joinClass ctx "block-if" thnCls elsCls

        ECall key args ->
            checkCall ctx key args

        ERawCall sym args ->
            checkRawCall ctx sym args

        EAggCall shape fnExp args ->
            checkAggCall ctx shape fnExp args

        EBuiltin b args ->
            checkSig ctx ("builtin '" ++ builtinName b ++ "'") (builtinClass b) args

        EWithRoots ids block ->
            case checkRoots ctx ids of
                Err msg ->
                    Err msg

                Ok () ->
                    checkBlock { ctx | scope = bindRoots ids ctx.scope } block

        EField p f ->
            case structPointer ctx p of
                Err msg ->
                    Err msg

                Ok ( sname, info ) ->
                    case fieldTypeIn info.fields f of
                        Just fty ->
                            Ok fty

                        Nothing ->
                            Err
                                (ctx.key
                                    ++ ": J13: struct '"
                                    ++ sname
                                    ++ "' has no field '"
                                    ++ f
                                    ++ "'"
                                )

        EIndex p i ->
            case checkExp ctx p of
                Err msg ->
                    Err msg

                Ok (TArray elem _) ->
                    -- B3: `a[i]` on an ARRAY VALUE.  The array's value IS its
                    -- address (decay is free), the index is the same one
                    -- integer class `wload` takes, and the READ's class is the
                    -- ELEMENT type — which is what makes `a[i].f` (a struct
                    -- element) and `m[i][j]` (a nested array element) compose
                    -- through the ordinary field/index rules, no second
                    -- judgment.
                    case validateType ctx elem of
                        Err msg ->
                            Err msg

                        Ok () ->
                            case wordIndex ctx i of
                                Err msg ->
                                    Err msg

                                Ok () ->
                                    Ok elem

                Ok (TPtr pty) ->
                    case wordIndex ctx i of
                        Err msg ->
                            Err msg

                        Ok () ->
                            indexClass ctx pty

                Ok cls ->
                    Err
                        (ctx.key
                            ++ ": J13: index access needs a pointer, got "
                            ++ typeStr cls
                        )

        EDeref p ->
            case checkExp ctx p of
                Err msg ->
                    Err msg

                Ok (TPtr PWord) ->
                    Ok TWord

                Ok (TPtr pty) ->
                    Err
                        (ctx.key
                            ++ ": J13: deref '*p' is '*word' only, got "
                            ++ typeStr (TPtr pty)
                        )

                Ok cls ->
                    Err
                        (ctx.key
                            ++ ": J13: deref needs a '*word' pointer, got "
                            ++ typeStr cls
                        )


{-| The two branch classes must AGREE, with exactly ONE coercion admitted
(B1): bool→val.  Everything else is the J1 reject it always was — the
matrix is NOT `coerce`'s (a pointer branch against a word branch is still
the loud reject; the join has no view-cast).

A `bool`-agreed join is itself a REJECT: a join needs a SLOT, and a bool
value's whole contract is that it is a raw 0/1 TEMP (see the header) — a
bool-valued `If` would put a raw word where the lowering expects a value
(the `?.`-binder shape the P1c review MEASURED as always-then).  Write the
two compares where they are branched or let the join be a `:val`
(`mkbool(..)`), which is the shape the corpus already uses.
-}
joinClass : Ctx -> String -> Type -> Type -> Result String Type
joinClass ctx what thnCls elsCls =
    if thnCls == elsCls then
        if thnCls == TBool then
            Err
                (ctx.key
                    ++ ": J1: "
                    ++ what
                    ++ " branches agree on bool — a bool value is a raw 0/1 TEMP, and a join needs a slot (it would be read back as a NUMBER): branch each compare where it is written, or make the join a `:val` with mkbool(..)"
                )

        else
            Ok thnCls

    else if thnCls == TVal && elsCls == TBool then
        -- the ONE implicit coercion (plan Q2): bool->val BOXES to
        -- RawMkValue tagBoolean — the tree the true/false sugar emitted.
        Ok TVal

    else if thnCls == TBool && elsCls == TVal then
        Ok TVal

    else
        Err
            (ctx.key
                ++ ": J1: "
                ++ what
                ++ " branches disagree — then is "
                ++ typeStr thnCls
                ++ ", else is "
                ++ typeStr elsCls
                ++ " (the value join needs ONE class)"
            )


{-| J1 (B1, plan Q10) — the CAST matrix: `[T](e)`.  `expected` is the
target class; each row is a checker judgment AND a lowering:
`c' stands for the target's class, `src` the operand's.

  * `[word](e)` / `[int](e)` — word|pointer|bool -> word: the IDENTITY
    (a pointer is a word; a bool is its 0/1 word), no node at all.
  * `[bool](e)` — word -> bool: a nonzero compare (`RawCmp WCne e 0`).
  * `[bool](b)` — bool -> bool: identity.
  * `[*T](e)` — word -> any pointer: the J12 view-cast, made explicit,
    NOTHING emitted.
  * `[float](e)` — word -> float: `RawIToF` (the existing itof).
  * `[word](f)` / `[int](f)` — float -> word: `RawUn RFToI32` (the
    existing ftoi32, an i32 result — Q10's row, stated as it is).
  * `[val](b)` — bool -> val: the ONE box, explicit (`RawMkValue
    tagBoolean`).

Everything else is a LOUD reject, and the two families that matter most
are named in their message: a `val` cast in EITHER direction (`[val]` of
anything but a bool, `[word](v)`) because `val` is the opaque handle —
`payload`/`tagis` are the sanctioned reads (plan Q11) — and a POINTER->
POINTER cast (`[*T2](p)`), which is J12's matrix spelled as a cast: go
through a `word` binder, one named line.  A FLOAT<->INT conversion is the
two explicit rows above, never implicit.
-}
castClass : Ctx -> Type -> Exp -> Result String Type
castClass ctx target inner =
    case validateType ctx target of
        Err msg ->
            Err msg

        Ok () ->
            case checkExp ctx inner of
                Err msg ->
                    Err msg

                Ok src ->
                    if target == TWord && (src == TWord || isPtr src || src == TBool) then
                        Ok TWord

                    else if target == TBool && (src == TWord || src == TBool) then
                        Ok TBool

                    else if isPtr target && src == TWord then
                        Ok target

                    else if target == TFloat && src == TWord then
                        Ok TFloat

                    else if target == TWord && src == TFloat then
                        Ok TWord

                    else if target == TVal && src == TBool then
                        Ok TVal

                    else
                        Err
                            (ctx.key
                                ++ ": J10: cast to "
                                ++ typeStr target
                                ++ " from "
                                ++ typeStr src
                                ++ " is not in the cast matrix — legal: [word]/[int] of word|pointer|bool, [bool] of word|bool, [*T] of word, [float]/[word] of the other, [val] of bool; a `val` cast (either direction) and a pointer->pointer cast are REJECTS (go through a `word` binder)"
                            )


{-| J1/Q9 — `sizeof`'s value in WORDS (the layout's own unit: every field
is a whole number of 8-byte words).  A struct reads the ONE table the
checker already built (`Env.structs` — the A1 layout, no second copy); a
type reads its class width.  `float` is a reject for the reason J11 rejects
a float FIELD: Mid.Ir has no raw-memory f64 load node, so a float's raw
width is a number this language cannot honour.
-}
sizeofWords : Ctx -> SizeTarget -> Result String Int
sizeofWords ctx target =
    case target of
        SizeStruct name ->
            case Dict.get name ctx.env.structs of
                Just info ->
                    Ok info.size

                Nothing ->
                    Err
                        (ctx.key
                            ++ ": J11: sizeof("
                            ++ name
                            ++ ") — no such struct is declared in this module"
                        )

        SizeType ty ->
            case ty of
                TStruct sname ->
                    case Dict.get sname ctx.env.structs of
                        Just info ->
                            Ok info.size

                        Nothing ->
                            Err
                                (ctx.key
                                    ++ ": J11: sizeof("
                                    ++ sname
                                    ++ ") — no such struct is declared in this module"
                                )

                TWord ->
                    Ok 1

                TBool ->
                    Ok 1

                TPtr _ ->
                    Ok 1

                TArray elem n ->
                    -- B3: `sizeof(word[5])` = 5, `sizeof(word[3][4])` = 12 —
                    -- the element's width times the count, recursively.  This
                    -- is the heap-array spelling (`rawcall malloc(8 *
                    -- sizeof(word[N]))`), which is why it is here.
                    case sizeofWords ctx (SizeType elem) of
                        Err msg ->
                            Err msg

                        Ok w ->
                            Ok (w * n)

                TVal ->
                    Ok 5

                TFloat ->
                    Err
                        (ctx.key
                            ++ ": J1: sizeof(float) — Mid.Ir has no raw-memory f64 seat, so a float's word width is not a thing this language can promise (the J11 float-field rule, same reason)"
                        )


{-| J10 — every `withroots` id must ALREADY name a `:val` binder in scope
at that point (a parameter or an earlier binder): WithRoots roots
EXISTING values for the block's duration, it does not create them.  A
`:word` binder is a reject (roots hold Values, not raw words) and an
unknown id is a reject.  Inside the block the ids are re-bound `:val` by
`bindRoots` — T4's half, what the roots ARE.
-}
checkRoots : Ctx -> List String -> Result String ()
checkRoots ctx ids =
    case ids of
        [] ->
            Ok ()

        id :: rest ->
            case Dict.get id ctx.scope of
                Just TVal ->
                    checkRoots ctx rest

                Just cls ->
                    Err
                        (ctx.key
                            ++ ": J10: withroots id '"
                            ++ id
                            ++ "' is a "
                            ++ typeStr cls
                            ++ " binder — only val binders can be rooted"
                        )

                Nothing ->
                    Err
                        (ctx.key
                            ++ ": J10: withroots id '"
                            ++ id
                            ++ "' is not a binder in scope"
                        )


{-| `&& ||` — `val,val -> val` (Ast.shortSig; deepEq returns `and2(..)` as
a value).  A local constant so the two operator rows read like the rest.
-}
shortSigOf : Sig
shortSigOf =
    Sig [ TVal, TVal ] TVal


{-| J2 — `call Key`: a namespace-qualified key (the `Rt.*`-only rule,
generalized for user `.mid` modules in M3), resolved against surfaces
UNION externs, arity and per-argument classes against the callee's
declared signature (extern seats: all-`:val`, matching today's Rt
surface).
-}
checkCall : Ctx -> Key -> List Exp -> Result String Type
checkCall ctx key args =
    if isQualifiedKey key then
        case resolveCall ctx.env key of
            Just ( paramTys, retTy ) ->
                case checkArgs argOk ctx "J2" ("call '" ++ key ++ "'") paramTys args of
                    Ok () ->
                        Ok retTy

                    Err msg ->
                        Err msg

            Nothing ->
                Err
                    (ctx.key
                        ++ ": J2: call target '"
                        ++ key
                        ++ "' resolves to no surface defun and no extern seat (unseeded key)"
                    )

    else
        Err
            (ctx.key
                ++ ": J2: call target '"
                ++ key
                ++ "' must be a namespace-qualified 'Mod.name' key"
            )


resolveCall : Env -> Key -> Maybe ( List Type, Type )
resolveCall env key =
    case Dict.get key env.surfaces of
        Just sig ->
            Just sig

        Nothing ->
            case Dict.get key env.externs of
                Just sig ->
                    Just (projectSig sig)

                Nothing ->
                    Nothing


{-| The typed extern table's J2 view: flatten the declared type's
top-level arrows into `(params, result)` and project each Osier type to
its mid-c class.  An exported key's declared types win; an unexported key
carries the `valArity n` fallback and projects to exactly today's
all-`:val` seat.  `project` is TOTAL — an unprojectable type (a type
variable, a quantifier, an unknown constructor like `Ref`) reads as
`:val`, the conservative default, so M2 never rejects a call it cannot
classify; M4 owns the real Osier-side mapping.
-}
projectSig : ExportSig -> ( List Type, Type )
projectSig sig =
    let
        ( params, result ) =
            splitArrow sig.ty
    in
    ( List.map project params, project result )


{-| Osier type -> mid-c class (the §2.5 three-class mapping): the opaque
atoms map to themselves; `Word` is the opaque word; `Val`/`Int` and every
other boxed Osier type map to `:val` (`Float` included — §2.5: a Float
parameter is BOXED, never trusted for unboxing); `float` is the raw f64
word.  Anything else (a bound variable, a quantifier, an unknown
constructor) is the conservative `:val`.  M4 refines this — it is the
placeholder that keeps M2 total.
-}
project : OTy -> Type
project ty =
    case ty of
        OVal ->
            TVal

        OFloat ->
            TFloat

        OWord ->
            TWord

        OCon name _ ->
            if name == "Word" then
                TWord

            else
                TVal

        OVar _ ->
            TVal

        OArrow _ _ ->
            TVal

        OForall _ _ ->
            TVal

        OExists _ _ ->
            TVal


{-| J3 — `rawcall sym`: the symbol must be in `Ast.rawcallArity` (the
per-symbol SIGNATURE TABLE — the enforcement seat for stage-6's rawAbi
defuns: when those land they JOIN the table, and any cap on
directly-passed args is enforced per-symbol THERE), arity must match,
and every argument is a `:word` (Lower lowers each through rawWordArg);
the result is `:word` (result-void seats still yield the dead word the
caller must ignore, exactly as the DSL does today).
-}
checkRawCall : Ctx -> Sym -> List Exp -> Result String Type
checkRawCall ctx sym args =
    case Dict.get sym rawcallArity of
        Nothing ->
            Err
                (ctx.key
                    ++ ": J3: rawcall symbol '"
                    ++ sym
                    ++ "' is in no signature table — add it to Ast.rawcallArity (stage-6 rawAbi seats must join the table when they land)"
                )

        Just n ->
            if List.length args == n then
                case
                    checkArgs argOk
                        ctx
                        "J3"
                        ("rawcall '" ++ sym ++ "'")
                        (List.repeat n TWord)
                        args
                of
                    Ok () ->
                        Ok TWord

                    Err msg ->
                        Err msg

            else
                Err
                    (ctx.key
                        ++ ": J3: rawcall '"
                        ++ sym
                        ++ "' takes "
                        ++ String.fromInt n
                        ++ " word argument(s), got "
                        ++ String.fromInt (List.length args)
                    )


{-| The aggcall family (J1's call row): the fn expression and every argument
are `:word`, and the RESULT is the sret buffer ADDRESS as `:word` for BOTH
shapes — `ret` (80 B, read the fields with wload) and `val` (40 B, the
tagged Value the callee wrote).  The shape selects only the AGGREGATE SIZE
the callee's sret occupies, never the result class: Lower's isRawWordExp
classifies EVERY RawCallAgg as a word producer (the sret address), so the
checker must agree — the A4a AggVal->TVal reading made `val x = aggcall val`
check :val while Lower bound a raw word, an unreadable binder (stage 6 A4b
hit it: payload = "raw word in VALUE position", wload = "needs word, got
val").  The driver reaches the Value by PASSING the sret ADDRESS to the
rt_is_program/rt_run_program/rt_print_value seats — no Mid :val binder is
ever materialised, which is exactly the driver's shape.
-}
checkAggCall : Ctx -> AggShape -> Exp -> List Exp -> Result String Type
checkAggCall ctx shape fnExp args =
    case checkExp ctx fnExp of
        Err msg ->
            Err msg

        Ok TWord ->
            case
                checkArgs argOk
                    ctx
                    "J1"
                    ("aggcall in '" ++ ctx.key ++ "'")
                    (List.repeat (List.length args) TWord)
                    args
            of
                Ok () ->
                    Ok TWord

                Err msg ->
                    Err msg

        Ok cls ->
            Err
                (ctx.key
                    ++ ": J1: aggcall fn must be word (the runtime code pointer), got "
                    ++ typeStr cls
                )


{-| The fixed-signature engine behind the operators and the builtins:
arguments are checked positionally against `Sig`'s operand classes, the
result is `Sig`'s.  The one variadic form (`mkval`) dispatches to
`checkMkVal`.
-}
checkSig : Ctx -> String -> Sig -> List Exp -> Result String Type
checkSig ctx what sig args =
    case sig of
        Sig tys res ->
            case checkArgs sigArgOk ctx "J1" what tys args of
                Ok () ->
                    Ok res

                Err msg ->
                    Err msg

        SigMkVal ->
            checkMkVal ctx args


{-| `mkval(tag, words..)` — the one variadic form: the tag is `:word`,
each payload word is `:word` OR `:float` (Lower's isFloatWordExp decides
the store width), and a `:val` payload is a REJECT (a value cannot nest
inside the raw payload words).  Result `:val`.
-}
checkMkVal : Ctx -> List Exp -> Result String Type
checkMkVal ctx args =
    case args of
        [] ->
            Err (ctx.key ++ ": J1: builtin 'mkval' needs at least the tag word")

        tag :: rest ->
            case checkExp ctx tag of
                Err msg ->
                    Err msg

                Ok TWord ->
                    mkValWords ctx 1 rest

                Ok cls ->
                    Err
                        (ctx.key
                            ++ ": J1: builtin 'mkval' tag must be word, got "
                            ++ typeStr cls
                        )


mkValWords : Ctx -> Int -> List Exp -> Result String Type
mkValWords ctx i args =
    case args of
        [] ->
            Ok TVal

        a :: rest ->
            case checkExp ctx a of
                Err msg ->
                    Err msg

                Ok TVal ->
                    Err
                        (ctx.key
                            ++ ": J1: builtin 'mkval' payload argument "
                            ++ String.fromInt i
                            ++ " is val — a value cannot nest in the raw payload words (word or float only)"
                        )

                Ok _ ->
                    mkValWords ctx (i + 1) rest


{-| Zip the expected classes against the argument expressions; the first
mismatch (or arity difference) is the error.  `jn` names the owning
judgment (J1 builtins/operators, J2 call, J3 rawcall, J4 recur).  The
compatibility predicate is `argOk` at every boundary: a pointer, and since
B1 a bool, pass where a `word` is expected (both ARE words — the identity);
nothing passes into a `:val` slot unwrapped.
-}
checkArgs : (Type -> Type -> Bool) -> Ctx -> String -> String -> List Type -> List Exp -> Result String ()
checkArgs ok ctx jn what tys args =
    case ( tys, args ) of
        ( [], [] ) ->
            Ok ()

        ( [], _ ) ->
            Err
                (ctx.key
                    ++ ": "
                    ++ jn
                    ++ ": "
                    ++ what
                    ++ " takes "
                    ++ String.fromInt (List.length tys)
                    ++ " argument(s), got "
                    ++ String.fromInt (List.length args)
                )

        ( _, [] ) ->
            Err
                (ctx.key
                    ++ ": "
                    ++ jn
                    ++ ": "
                    ++ what
                    ++ " takes "
                    ++ String.fromInt (List.length tys)
                    ++ " argument(s), got "
                    ++ String.fromInt (List.length args)
                )

        ( t :: ts, a :: as_ ) ->
            case checkExp ctx a of
                Err msg ->
                    Err msg

                Ok cls ->
                    if ok t cls then
                        checkArgs ok ctx jn what ts as_

                    else
                        Err
                            (ctx.key
                                ++ ": "
                                ++ jn
                                ++ ": "
                                ++ what
                                ++ " argument "
                                ++ String.fromInt (List.length tys - List.length ts + 1)
                                ++ " needs "
                                ++ typeStr t
                                ++ ", got "
                                ++ typeStr cls
                            )


bindRoots : List String -> Dict String Type -> Dict String Type
bindRoots ids scope =
    List.foldl (\id acc -> Dict.insert id TVal acc) scope ids



-- ============================ J12: the coercion matrix ============================


{-| B3 — the ARRAY VALUE's decay: the pointer type an array decays to, or
`Nothing` for everything that is not an array.  Decay is FREE because an
array's representation IS the address of its storage (Ast's `TArray` note), so
this is a CLASS statement, not a conversion: no node is emitted anywhere the
decay is admitted.

`word`/`int`/pointer elements decay to `*word` (`*int` is the same family —
B1's alias), `val` elements to `*val`, struct elements to `*S`.  A NESTED
array decays to its ELEMENT's pointer (`word[3][4]` -> `*word`), which is what
makes a multidimensional array passable as the flat row-major block it is.
-}
decayTo : Type -> Maybe Type
decayTo t =
    case t of
        TArray TWord _ ->
            Just (TPtr PWord)

        TArray (TPtr _) _ ->
            Just (TPtr PWord)

        TArray TBool _ ->
            Just (TPtr PWord)

        TArray TVal _ ->
            Just (TPtr PVal)

        TArray (TStruct sname) _ ->
            Just (TPtr (PStruct sname))

        TArray inner _ ->
            decayTo inner

        _ ->
            Nothing


{-| Does `actual` DECAY to `expected`?  The one way an array reaches a
pointer slot without a cast (`*word p = a;`, `f(a)` into a `*T` parameter) —
the "decay-to-pointer is free" row of plan Q5.
-}
decays : Type -> Type -> Bool
decays expected actual =
    case decayTo actual of
        Just p ->
            p == expected

        Nothing ->
            False


{-| The ONE-WAY coercion matrix (J12) — the `coerce expected actual`
predicate a binder, store and return accept.  The legal movements:

  * `expected == actual` (identity, every class);
  * `word` <- any pointer (`*T -> word`: a pointer IS a word — rawcall/
    arithmetic/wstore/returns take it);
  * any pointer <- `word` (`word -> *T`: the view-cast, the direction the
    source spells);
  * `*word` <- `*S` (the universal raw view — the mark-stack/freelist
    overlap sites);
  * `val` <- `bool` (B1, plan Q2: the ONE implicit coercion — the bool is
    BOXED to `RawMkValue tagBoolean` at lowering, the exact tree the
    `true`/`false` sugar emitted.  This is what keeps `return true;` in a
    `-> val` defun legal and byte-identical and what lets a `?:` arm be
    `false` beside a val).

Everything else — `*S1 -> *S2` (cross-struct), `*word -> *S`, `*val -> *S`,
`*word -> *val`, `val <-> word`, and `word <- bool` (a bool is the 0/1 word
but NAMING that is the explicit `[word](b)` cast, plan Q10) — is FALSE: go
through a `word` binder, one named line.  The only unchecked direction is
`word -> *T`, which is exactly the source-spelled one.
-}
coerce : Type -> Type -> Bool
coerce expected actual =
    if expected == actual then
        True

    else
        case ( expected, actual ) of
            ( TWord, TPtr _ ) ->
                True

            ( TPtr _, TWord ) ->
                True

            ( TPtr PWord, TPtr (PStruct _) ) ->
                True

            ( TWord, TArray _ _ ) ->
                -- B3: an array's value IS the address of its storage, so a
                -- WORD slot takes it exactly as it takes a pointer (the
                -- `*T -> word` row above, one step further out).
                True

            ( TVal, TBool ) ->
                True

            ( TWord, TBool ) ->
                -- B1: a bool IS the 0/1 word, so binding/storing/returning one
                -- where a WORD is expected is the IDENTITY — the same node, no
                -- conversion (the `[word](b)` cast, implicit).  MEASURED
                -- correction to the plan: it expected ZERO such sites ("the
                -- MEASURED 0-site fact is the safe row" for a reject), and
                -- runtime.mid has two — `word isStr = payload(stream, 1) > 1;`
                -- in Rt.close and a twin — which lower to a raw-word binder and
                -- rebox with `mkbool(isStr)`.  Rejecting the row would have
                -- moved the corpus, so the row is the legal one.  It is sound
                -- for the reason the word-binder COND reject gives: nothing
                -- here branches on the binder (`if (isStr)` is still a J1
                -- reject — write `bool b = ..` for that).
                True

            _ ->
                decays expected actual


{-| The ARGUMENT-compatibility predicate behind `checkArgs` (J1/J2/J3/J4):
the expected class must match, OR a pointer is acceptable where a `word`
is expected (`*T -> word` — a pointer is a word).  The reverse (`word ->
*T`) is NOT legal at a call/recur boundary — the view-cast is spelled only
at a typed binder, never implicit at a call.

A BOOL also passes where a `word` is expected (B1): a bool IS the 0/1 word,
so the conversion is the identity — `isWordish`, the same predicate the
arithmetic operator uses.  That is what keeps `mkbool(a == b)` (the
309-site corpus spelling), `payload(accN, 0) + (fdW == 0)` and a `word`
binder initialized from a compare legal and byte-identical.  It does NOT
admit a bool where a `:val` is expected — that is the box and needs the
spelling (`mkbool(..)` / `[val](b)`).

B3 adds the DECAY row: an ARRAY argument passes where its element's pointer
type is expected (`f(a)` into a `*word` parameter).  It is free — the array's
value already is that address — so nothing is boxed or converted.
-}
argOk : Type -> Type -> Bool
argOk expected actual =
    expected == actual
        || (expected == TWord && isPtr actual)
        || (expected == TWord && actual == TBool)
        || (expected == TWord && isArrayTy actual)
        || decays expected actual



{-| The BUILTIN/operator argument predicate (`checkSig`): `argOk` plus the
bool→val coercion.  Both halves are things the LOWERING boxes or passes
through with no guess, because a builtin's operand classes are STATIC
(`Ast.builtinClass`; `&&`/`||` are `Ast.shortSig`'s val,val): a bool at a
`:val` slot is boxed to `RawMkValue tagBoolean`, and a bool at a `word` slot
is already that word.  A CALL argument is deliberately NOT this predicate —
the lowering has no callee signatures, so a bool into a `:val` parameter
keeps the explicit `mkbool(..)`/`[val](b)` spelling (`argOk`).
-}
sigArgOk : Type -> Type -> Bool
sigArgOk expected actual =
    argOk expected actual || (expected == TVal && actual == TBool)


isPtr : Type -> Bool
isPtr t =
    case t of
        TPtr _ ->
            True

        _ ->
            False


{-| Is this class a WORD for the purpose of a word OPERAND?  `word`/`int`
(`TWord`), and — since B1 — `bool`, which IS the 0/1 word: `RawBin`/
`RawCmp`'s operands lower through `rawWordArg`, which computes a bool temp
with no node, so the arithmetic is exact.  MEASURED: runtime.mid already
relies on it (`mknum(payload(accN, 0) + (fdW == 0))` in Rt.epCountStdin),
which is why the plan's "bool is EXPLICIT only" line could not hold without
moving the corpus.  A POINTER is deliberately NOT wordish here — that is
J12's arithmetic firewall.
-}
isWordish : Type -> Bool
isWordish t =
    t == TWord || t == TBool


{-| J12's FIREWALL on top of the matrix: a pointer operand in `EWordBin`
arithmetic/bitwise (`p + 1`, `p - 1`, `p & 3`) is a REJECT even though
`*T -> word` otherwise holds.  Byte/word address math must happen on a
`word` binder (bind `word w = p;` first) — no context-dependent scaling
exists anywhere; struct-scaled math happens only through `p[i]`.  Both
operands must be `:word` (the firewall catches the pointer; a float/val
operand stays the J1 class reject).
-}
checkWordBin : Ctx -> WordBinOp -> Exp -> Exp -> Result String Type
checkWordBin ctx op a b =
    case checkExp ctx a of
        Err msg ->
            Err msg

        Ok aCls ->
            if isPtr aCls then
                Err
                    (ctx.key
                        ++ ": J12: pointer arithmetic on '"
                        ++ wordBinName op
                        ++ "' — address math must happen on a word binder (bind `word w = p;` first); struct-scaled math happens only through p[i]"
                    )

            else if not (isWordish aCls) then
                Err
                    (ctx.key
                        ++ ": J1: operator '"
                        ++ wordBinName op
                        ++ "' needs word operands, got "
                        ++ typeStr aCls
                    )

            else
                case checkExp ctx b of
                    Err msg ->
                        Err msg

                    Ok bCls ->
                        if isPtr bCls then
                            Err
                                (ctx.key
                                    ++ ": J12: pointer arithmetic on '"
                                    ++ wordBinName op
                                    ++ "' — address math must happen on a word binder (bind `word w = p;` first); struct-scaled math happens only through p[i]"
                                )

                        else if not (isWordish bCls) then
                            Err
                                (ctx.key
                                    ++ ": J1: operator '"
                                    ++ wordBinName op
                                    ++ "' needs word operands, got "
                                    ++ typeStr bCls
                                )

                        else
                            Ok TWord



-- ============================ message spellings ============================


{-| The classes' surface spellings, for the error messages.
-}
typeStr : Type -> String
typeStr t =
    case t of
        TStruct sname ->
            sname

        TWord ->
            "word"

        TBool ->
            "bool"

        TFloat ->
            "float"

        TVal ->
            "val"

        TPtr pty ->
            case pty of
                PStruct name ->
                    "*" ++ name

                PWord ->
                    "*word"

                PVal ->
                    "*val"

        TArray elem n ->
            typeStr elem ++ "[" ++ String.fromInt n ++ "]"


{-| Operator spellings for the J1 messages (checker-owned message text —
`Ast` has no op-name table and T6 gets its spellings from `Mid.Ir`'s own
enums).
-}
wordBinName : WordBinOp -> String
wordBinName op =
    case op of
        WAdd ->
            "+"

        WSub ->
            "-"

        WMul ->
            "*"

        WDiv ->
            "/"

        WBitAnd ->
            "&"

        WBitOr ->
            "|"

        WBitXor ->
            "^"

        WShl ->
            "<<"

        WShAr ->
            ">>"

        WShR ->
            ">>>"


wordCmpName : WordCmpOp -> String
wordCmpName op =
    case op of
        WCeq ->
            "=="

        WCne ->
            "!="

        WClts ->
            "<"

        WCles ->
            "<="

        WCgts ->
            ">"

        WCges ->
            ">="


fltBinName : FltBinOp -> String
fltBinName op =
    case op of
        FAdd ->
            "f+"

        FSub ->
            "f-"

        FMul ->
            "f*"

        FDiv ->
            "f/"


fltCmpName : FltCmpOp -> String
fltCmpName op =
    case op of
        FLt ->
            "f<"

        FLe ->
            "f<="

        FGt ->
            "f>"

        FGe ->
            "f>="

        FEq ->
            "f=="

        FNe ->
            "f!="
