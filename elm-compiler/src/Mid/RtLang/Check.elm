module Mid.RtLang.Check exposing
    ( checkExports
    , checkProgram
    , guardsHold
    )

{-| Mid.RtLang.Check — the surface language's TYPECHECKER, judgments
J1-J8 and J10 of the tier-2 plan (`handoff-osier-tier2-midlang-plan`, THE
TYPECHECKER).  It runs when the compiler builds the Rt program — on EVERY
compile — and its `Err` is a compile error that fails the compile through
the existing `Err` plumbing (T7 wires the call: after
`Parse.parseModule`, call
`Check.checkExports exports arities` then
`Check.checkProgram externTypes activeFlags program`;
`Err msg` propagates exactly like `QbeLower.lower`'s).

NO INFERENCE, BY DESIGN.  Every binder declares its class (`word x = ..;`
/ parameters `x: val`) and every `EVar` resolves to the DECLARED class;
the checker only validates, it never deduces.  Inference would LAUNDER
class confusion, and class confusion IS the hazard this module exists
for: a `val` silently accepted into a `word` slot is precisely the bug
Lower catches late-and-cryptic (its "raw word binder" / "not a raw word"
errors, Lower.elm:1293/:1846) — here it is a loud reject with the defun
named.  An expression's class is always FIXED by its shape: literals
(int `:word`, float `:float`, string `:val`, `true`/`false` = `mkbool`
sugar `:val`, `mknil` `:val`), operators (the four families + `&& ||` via
`Ast`'s signature constants), builtins (`Ast.builtinClass`), the three
call forms, or a scope lookup.

THE JUDGMENTS ENFORCED HERE (T5 adds J7-J10):

  * **J1** — fixed operand/result classes everywhere: the four operator
    families (word ops/compares `:word`; float ops `:float`; `&& ||`
    `:val`), the builtin table, and the binder form `ty x = e;` (the
    initializer's class must BE the declared class — the DSL's
    never-bind-across-classes discipline).  Also two class facts the
    grammar pins but the parser cannot see:
      - an `if`/`SIf` CONDITION must be `:val` — a bare `x == 1` is a
        WORD 0/1 and must be boxed, `mkbool(x == 1)` (RtPrims' `mkBool
        (cmpW ..)` discipline; the runtime's jmpf tests a boolean VALUE
        slot, so a raw word there is a runtime lie);
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
    exposing
        ( AggShape(..)
        , Block
        , Defun
        , Exp(..)
        , Export
        , ExportSig
        , Flag(..)
        , FlagGuard(..)
        , FltBinOp(..)
        , FltCmpOp(..)
        , Key
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
        , splitArrow
        , wordBinSig
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
    }


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
    case keyCheck program of
        Err msg ->
            Err msg

        Ok () ->
            case guardCheck flags program of
                Err msg ->
                    Err msg

                Ok () ->
                    checkAll (envOf externs flags program) program


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


envOf : Dict Key ExportSig -> List Flag -> Program -> Env
envOf externs flags program =
    { surfaces = surfacesOf flags program
    , externs = externs
    }


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
            case checkBlock (ctxOf env d) d.body of
                Err msg ->
                    Err msg

                Ok _ ->
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

            else
                case checkExp ctx e of
                    Err msg ->
                        Err msg

                    Ok cls ->
                        if cls == ty then
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


checkTerm : Ctx -> Term -> Result String Type
checkTerm ctx term =
    case term of
        TRet e ->
            case checkExp ctx e of
                Err msg ->
                    Err msg

                Ok cls ->
                    if cls == ctx.ret then
                        Ok cls

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
            checkArgs ctx
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
condition is `:val` (box word compares with `mkbool`).  The divergence
rules around it are J7's — checked by the SIf arm of `checkStmt` and the
`TIf` arm of `checkTerm`, not here.
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

        Ok cls ->
            Err
                (ctx.key
                    ++ ": J1: 'if' condition must be val — a word 0/1 compare must be boxed with mkbool, got "
                    ++ typeStr cls
                )



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

        EVar name ->
            case Dict.get name ctx.scope of
                Just ty ->
                    Ok ty

                Nothing ->
                    Err (ctx.key ++ ": J5: unbound name '" ++ name ++ "'")

        EWordBin op a b ->
            checkSig ctx ("operator '" ++ wordBinName op ++ "'") wordBinSig [ a, b ]

        EWordCmp op a b ->
            checkSig ctx ("operator '" ++ wordCmpName op ++ "' (yields a word 0/1 — box with mkbool to branch)") wordCmpSig [ a, b ]

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
                                    if thnCls == elsCls then
                                        Ok thnCls

                                    else
                                        Err
                                            (ctx.key
                                                ++ ": J1: '?:' branches disagree — then is "
                                                ++ typeStr thnCls
                                                ++ ", else is "
                                                ++ typeStr elsCls
                                                ++ " (the value join needs ONE class)"
                                            )

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
                                    if thnCls == elsCls then
                                        Ok thnCls

                                    else
                                        Err
                                            (ctx.key
                                                ++ ": J1: block-if branches disagree — then is "
                                                ++ typeStr thnCls
                                                ++ ", else is "
                                                ++ typeStr elsCls
                                                ++ " (the value join needs ONE class)"
                                            )

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
                case checkArgs ctx "J2" ("call '" ++ key ++ "'") paramTys args of
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
                    checkArgs ctx
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
                checkArgs ctx
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
            case checkArgs ctx "J1" what tys args of
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
judgment (J1 builtins/operators, J2 call, J3 rawcall, J4 recur).
-}
checkArgs : Ctx -> String -> String -> List Type -> List Exp -> Result String ()
checkArgs ctx jn what tys args =
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
                    if cls == t then
                        checkArgs ctx jn what ts as_

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



-- ============================ message spellings ============================


{-| The classes' surface spellings, for the error messages.
-}
typeStr : Type -> String
typeStr t =
    case t of
        TWord ->
            "word"

        TFloat ->
            "float"

        TVal ->
            "val"


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
