module Mid.RtLang.LowerToIr exposing
    ( lowerProgram
    )

{-| Mid.RtLang.LowerToIr — the surface language's LOWERER (tier-2 plan,
`handoff-osier-tier2-midlang-plan`, THE STATEMENT->EXPRESSION LOWERING
L1-L7): a checked `Mid.RtLang.Ast.Program` (T4/T5's `Check.checkProgram`
must have accepted it) goes in, `List Mid.Ir.Defun` comes out — the exact
trees the hand-rolled Elm DSL (Mid.RtPrims / Mid.RtGc) builds by hand.

Mid has NO CFG, NO join and NO early-return: a `Defun.value` is ONE nested
`Exp` whose head is a `Lam`.  The statement layer therefore lowers as
nested expression forms, rule by rule (the plan's numbering kept):

  * **L1** — `ty x = e; rest` -> `Let { binders = [ LetBind { binder, value
    = e } ], body = lower rest }`.  ONE binder per `Let`, nested to the
    LEFT — the DSL's `lets` shape (RtPrims.elm:145-156).  Binder ids come
    from a PER-DEFUN counter (params first: id 1..n, mirroring the DSL's
    `p1..p5`; locals continue n+1, n+2, ...).  Ids are Dict KEYS in the
    backend (plan fact F1: `binderSlots`/`rawWord : Dict Int`, never
    emitted), so they must be UNIQUE ACROSS THE WHOLE DEFUN — including
    across DISJOINT if-branches, where a collision would make two binders
    share one backend slot (the execGo b-100..277 discipline) — and the
    state is therefore threaded strictly sequentially through every
    subtree.  `name` = the surface id (provenance only; emission never
    reads it, Mid.Ir's Binder contract).
  * **L2** — an effect statement `e; rest` lowers exactly like L1 but with
    a FRESH UNUSED binder (the DSL's `(b 107, rStore ...)` dead-binding
    shape; the store builtins' result slot must be filled with a valid
    binder even though nothing reads it).
  * **L3** — `return e;` is the block's VALUE (`e` itself); a defun's last
    `return` is its `Lam` body.  Built by `lam`'s exact shape
    (RtPrims.elm:388-393): `{ key = key, value = Lam { params, body } }`.
  * **L4** — `recur(a..);` -> `App { fn = GRef { key = OWN key, force =
    False }, args }` — THE ONLY LOOP (MEASURED: all 31 DSL sites are this
    saturated non-forced self-GRef shape; the classifier grants
    edge-not-safepoint regardless of tailness, plan fact F3).
  * **L5** — a TERMINATING `if (c) A else B` (the block's value) lowers to
    `If { cond, thenBranch = lower A, elseBranch = lower B }` — both
    branches as block values.  A missing `else` lowers the false path to
    `mknil` (the DSL's dead-value convention: `haltV` = `(lets [(b 30,
    callW "rt_halt" [])] mkNil)` — a value the defun never returns because
    the true path diverged).  The LABEL STRINGS are IGNORED by the backend
    (plan fact F1: Lower invents `then_N/else_N/join_N` and never reads
    the tree's strings), so this module allocates readable per-defun
    `else_N`/`join_N` labels from its own counter; byte identity depends
    only on tree SHAPE.
  * **L6** — a MID-BLOCK `if` (an `SIf` statement) lowers by ELSE-NESTING:
    the CONTINUATION moves into the NON-DIVERGING branch — `if (c) {
    return x; } rest..` -> `If { c, then = x, else = lower rest.. }`, and
    symmetrically when only the else diverges.  BOTH branches diverging ->
    `If { c, A, B }` bound at a fresh DEAD binder with the continuation as
    the `Let` body (the execGo `(lets [(b 106, callW _exit ..)] mkNil)`
    precedent).  Check J7 already rejects both-branches-fall-through, so
    the remaining shapes are impossible for checked input; if the lowerer
    still sees one it is a LOUD internal error naming the judgment, never
    a silent choice.
  * **L7** — the owner's example shape (`if (region != 0) { return
    mknum(region); } base = rawcall mmap(..); ..`) lowers by the L6
    else-nesting rule exactly as written (pinned by a TestMain row).

Expressions lower 1:1 onto `Mid.Ir`: the four operator families onto
`RawBin`/`RawCmp`/`RawFltBin`/`RawFltCmp` (constructor-by-constructor — a
new surface op without a row here is a compile error), `&& ||` verbatim
onto `ShortAnd`/`ShortOr`, `call`->`RawCall`, `rawcall`->`RawCallRaw`,
`aggcall`->`RawCallAgg` (`shape` = `"ret"`/`"val"`, exactly Lower's two
accepted strings), `withroots`->`WithRoots` (ids resolved to their in-scope
binder records), and the builtins onto `UnsafeNode`s per `Ast.builtinClass`
— including the two MEASURED macros: `reclen` expands to RtPrims'
`recLenOf` 3-node tree (RtPrims.elm:216-228) and `len32` to
`RawPayload32` word 1.  Nothing else is invented.

LITERAL SLOTS.  `mkval`'s tag and the index/tag slots of
`payload`/`payload32`/`tagis` are CONSTANTS inside their lowered nodes
(`RawMkValue.tag : Int`, `RawPayload.word : Int`, `RawTagIs.tag : Int`),
so the lowerer requires those AST arguments to be `EInt` literals — the
same unrepresentable-else-reject discipline the parser applies to its
literal token slots.  A computed tag cannot lower; that is a loud internal
error naming the gap, never a silent guess.

TRUSTED INPUT.  Classes, arities, name binding, recur saturation and the
divergence rules were checked by `Mid.RtLang.Check` (J1-J8, J10); this
module re-derives only what its OWN rules need (`diverges`, mirrored from
Check's J7 predicate because the else-nesting rule reads it) and turns
every should-be-impossible shape into a loud internal error naming the
judgment that should have rejected it.  A CHECKED program cannot reach
them; they exist so a lowerer/checker drift fails loudly instead of
lowering a wrong tree.

SELFHOST DISCIPLINE (the mid-lane hazard, Rt.elm:531-545): every helper is
a TOP-LEVEL definition — the mutually recursive walk (`lowerExp` ⇄
`lowerStmt` ⇄ `lowerRest` ⇄ `lowerTerm` ⇄ `lowerBlock`) closes through
top-level bodies, never let-bound.  Only `Dict`/`List`/`String` functions
MEASURED in the selfhost's merged table are used (`List.reverse`,
`List.length`, `String.fromInt`, `String.startsWith`, `++`).

BACKEND-NEUTRAL (the `Mid.Rt` contract): imports are `Dict`, `Mid.Ir`,
`Mid.RtLang.Ast` and `Mid.RtLayout` (the tag constants — the same single
source of truth RtPrims/RtGc read).  No QBE type appears here.

NOT WIRED YET: nothing outside `TestMain` imports this module — T7 splices
`lowerProgram`'s output into `Mid.Rt.program`.  The corpus hash is the
emit-inert oracle.

-}

import Dict exposing (Dict)
import Mid.Ir exposing (Binder, Defun, Exp(..), LetBinder(..), Lit(..), RawBinOp(..), RawCmpOp(..), RawFltBinOp(..), RawFltCmpOp(..), RawUnOp(..), UnsafeNode(..))
import Mid.RtLang.Ast as Ast
import Mid.RtLang.Ast
    exposing
        ( AggShape(..)
        , Builtin(..)
        , Block
        , FltBinOp(..)
        , FltCmpOp(..)
        , Param
        , Program
        , Stmt(..)
        , Term(..)
        , WordBinOp(..)
        , WordCmpOp(..)
        , builtinName
        )
import Mid.RtLayout as RtLayout



-- ============================ the lowering state ============================


{-| Per-defun lowering state.  `nextId` hands out binder ids (unique across
the WHOLE defun — the backend keys its slot dicts by them, plan fact F1);
`nextLbl` hands out the If/ShortAnd/ShortOr label strings (IGNORED by the
backend — readability only); `scope` maps surface names to binder ids; `key`
is the defun's own key (L4's self-GRef target).
-}
type alias St =
    { key : String
    , nextId : Int
    , nextLbl : Int
    , scope : Dict String Int
    }


{-| A fresh binder: provenance name = the surface id, id = the next counter
value.
-}
fresh : String -> St -> ( Binder, St )
fresh name st =
    ( { id = st.nextId, name = name }
    , { st | nextId = st.nextId + 1 }
    )


{-| The label pair an `If`/`ShortAnd`/`ShortOr` node carries.  The backend
INVENTS its own labels (plan fact F1) and never reads these strings.
-}
freshLabels : St -> ( String, String, St )
freshLabels st =
    ( "else_" ++ String.fromInt st.nextLbl
    , "join_" ++ String.fromInt st.nextLbl
    , { st | nextLbl = st.nextLbl + 1 }
    )


mkNilExp : Exp
mkNilExp =
    Unsafe (RawMkValue { tag = RtLayout.tagNil, words = [] })



-- ============================ entry point ============================


{-| Lower a checked program to Mid defuns, preserving input order and keys
(guarded variants of one key lower as separate defuns — selecting the ONE
active variant per flag set is the wiring's job, T7).
-}
lowerProgram : Program -> Result String (List Defun)
lowerProgram program =
    lowerAll [] program


lowerAll : List Defun -> Program -> Result String (List Defun)
lowerAll acc program =
    case program of
        [] ->
            Ok (List.reverse acc)

        d :: rest ->
            case lowerDefun d of
                Err msg ->
                    Err msg

                Ok idef ->
                    lowerAll (idef :: acc) rest


{-| L3's defun shape, identical to the DSL's `lam` (RtPrims.elm:388-393):
params are binders with ids 1..n in order (the DSL's `p1..p5` convention),
the body is the block's lowered value.
-}
lowerDefun : Ast.Defun -> Result String Defun
lowerDefun d =
    let
        params =
            paramBinders 1 d.params

        st0 =
            { key = d.key
            , nextId = List.length d.params + 1
            , nextLbl = 1
            , scope = paramScope params
            }
    in
    case lowerBlock st0 d.body of
        Err msg ->
            Err msg

        Ok ( _, body ) ->
            Ok { key = d.key, value = Lam { params = params, body = body } }



-- ============================ params ============================


paramBinders : Int -> List Param -> List Binder
paramBinders i params =
    case params of
        [] ->
            []

        p :: rest ->
            { id = i, name = p.name } :: paramBinders (i + 1) rest


paramScope : List Binder -> Dict String Int
paramScope params =
    List.foldl (\p acc -> Dict.insert p.name p.id acc) Dict.empty params



-- ============================ blocks: L1/L2/L6 ============================


lowerBlock : St -> Block -> Result String (St, Exp)
lowerBlock st b =
    lowerRest st b.stmts b.term


{-| Lower `stmts` followed by `term` as ONE expression: statements are
folded right-to-left, each statement receiving the CONTINUATION (the rest
of the block's lowered value) — which is what L6's else-nesting needs.
-}
lowerRest : St -> List Stmt -> Term -> Result String (St, Exp)
lowerRest st stmts term =
    case stmts of
        [] ->
            lowerTerm st term

        s :: rest ->
            lowerStmt st s (\st1 -> lowerRest st1 rest term)


{-| Lower one statement against its continuation.  L1/L2 bind at a fresh
binder and wrap the continuation in a 1-binder `Let`; L6 else-nests.
-}
lowerStmt : St -> Stmt -> (St -> Result String (St, Exp)) -> Result String (St, Exp)
lowerStmt st stmt cont =
    case stmt of
        SBind _ name e ->
            case lowerExp st e of
                Err msg ->
                    Err msg

                Ok ( st1, v1 ) ->
                    let
                        ( binder, st2 ) =
                            fresh name st1

                        st3 =
                            { st2 | scope = Dict.insert name binder.id st2.scope }
                    in
                    case cont st3 of
                        Err msg ->
                            Err msg

                        Ok ( st4, body ) ->
                            Ok ( st4, Let { binders = [ LetBind { binder = binder, value = v1 } ], body = body } )

        SEffect e ->
            case lowerExp st e of
                Err msg ->
                    Err msg

                Ok ( st1, v1 ) ->
                    let
                        ( binder, st2 ) =
                            fresh "_eff" st1
                    in
                    case cont st2 of
                        Err msg ->
                            Err msg

                        Ok ( st4, body ) ->
                            Ok ( st4, Let { binders = [ LetBind { binder = binder, value = v1 } ], body = body } )

        SIf c t me ->
            case lowerExp st c of
                Err msg ->
                    Err msg

                Ok ( st1, c1 ) ->
                    let
                        thenDiv =
                            diverges t

                        elseDiv =
                            divergesMaybe me
                    in
                    if thenDiv && not elseDiv then
                        -- L6 else-nesting: the then-branch is a dead end (it
                        -- always diverges), so the continuation IS the false
                        -- path.  Lowered in reading order: then, else.
                        case lowerBlock st1 t of
                            Err msg ->
                                Err msg

                            Ok ( st2, t1 ) ->
                                case me of
                                    Just eb ->
                                        case lowerBranch st2 eb cont of
                                            Err msg ->
                                                Err msg

                                            Ok ( st3, e1 ) ->
                                                let
                                                    ( ie, stF ) =
                                                        mkIf st3 c1 t1 e1
                                                in
                                                Ok ( stF, ie )

                                    Nothing ->
                                        case cont st2 of
                                            Err msg ->
                                                Err msg

                                            Ok ( st3, e1 ) ->
                                                let
                                                    ( ie, stF ) =
                                                        mkIf st3 c1 t1 e1
                                                in
                                                Ok ( stF, ie )

                    else if elseDiv && not thenDiv then
                        -- Symmetric: the else-branch is a dead end and the
                        -- continuation splices into the THEN branch at its
                        -- fall-through point (which may be a DEEPER slot —
                        -- a nested one-sided if's false path).
                        case me of
                            Just eb ->
                                case lowerBlock st1 eb of
                                    Err msg ->
                                        Err msg

                                    Ok ( st2, e1 ) ->
                                        case lowerBranch st2 t cont of
                                            Err msg ->
                                                Err msg

                                            Ok ( st3, t1 ) ->
                                                let
                                                    ( ie, stF ) =
                                                        mkIf st3 c1 t1 e1
                                                in
                                                Ok ( stF, ie )

                            Nothing ->
                                Err (internal st "SIf" "a diverging else cannot be missing")

                    else if thenDiv && elseDiv then
                        -- Both diverge: the If dead-binds at a fresh binder
                        -- and the continuation continues (the execGo
                        -- `(lets [(b 106, callW _exit ..)] mkNil)` shape).
                        case me of
                            Just eb ->
                                let
                                    ( dead, stA ) =
                                        fresh "_if" st1
                                in
                                case lowerBlock stA t of
                                    Err msg ->
                                        Err msg

                                    Ok ( stB, t1 ) ->
                                        case lowerBlock stB eb of
                                            Err msg ->
                                                Err msg

                                            Ok ( stC, e1 ) ->
                                                case cont stC of
                                                    Err msg ->
                                                        Err msg

                                                    Ok ( stD, body ) ->
                                                        let
                                                            ( ie, stE ) =
                                                                mkIf stD c1 t1 e1
                                                        in
                                                        Ok ( stE, Let { binders = [ LetBind { binder = dead, value = ie } ], body = body } )

                            Nothing ->
                                Err (internal st "SIf" "both branches diverge but there is no else block")

                    else
                        Err
                            (internal st "SIf"
                                "a mid-block if with both branches falling through reached the lowerer — Check J7 must reject it first"
                            )


{-| L3/L4/L5: the terminator IS the block's value.
-}
lowerTerm : St -> Term -> Result String (St, Exp)
lowerTerm st term =
    case term of
        TRet e ->
            lowerExp st e

        TRecur args ->
            case lowerArgs st args of
                Err msg ->
                    Err msg

                Ok ( st1, es ) ->
                    Ok ( st1, App { fn = GRef { key = st.key, force = False }, args = es } )

        TIf c t me ->
            case lowerExp st c of
                Err msg ->
                    Err msg

                Ok ( st1, c1 ) ->
                    case lowerBlock st1 t of
                        Err msg ->
                            Err msg

                        Ok ( st2, t1 ) ->
                            case me of
                                Just eb ->
                                    case lowerBlock st2 eb of
                                        Err msg ->
                                            Err msg

                                        Ok ( st3, e1 ) ->
                                            let
                                                ( ie, stF ) =
                                                    mkIf st3 c1 t1 e1
                                            in
                                            Ok ( stF, ie )

                                Nothing ->
                                    if diverges t then
                                        -- L5: the false path has no value — the
                                        -- DSL's dead-value convention fills it
                                        -- with mknil (never returned: the true
                                        -- path diverged).
                                        let
                                            ( ie, stF ) =
                                                mkIf st2 c1 t1 mkNilExp
                                        in
                                        Ok ( stF, ie )

                                    else
                                        Err
                                            (internal st "TIf"
                                                "a terminating if without else whose then-branch falls through reached the lowerer — Check J7 must reject it first"
                                            )


mkIf : St -> Exp -> Exp -> Exp -> ( Exp, St )
mkIf st cond thenB elseB =
    let
        ( falseLbl, endLbl, st1 ) =
            freshLabels st
    in
    ( If
        { cond = cond
        , thenBranch = thenB
        , elseBranch = elseB
        , falseLabel = falseLbl
        , endLabel = endLbl
        }
    , st1
    )


{-| Lower a BRANCH BLOCK of a MID-BLOCK if, splicing `cont` — the
continuation after the whole if — at the branch's fall-through point(s).
A diverging terminator (`return`/`recur`, or a both-diverging if) is a
dead end and the continuation is never spliced there; the shapes are:

  * `TRet`/`TRecur` — dead end, the branch's value is the returned exp.
  * a one-sided `TIf` — the continuation splices into the ONE falling
    slot: the false path of a missing else, or the falling arm of an
    else'd if whose other arm diverges.  This is what makes the
    checker's divelse shape (J7 accept row) lower correctly: the
    outer branch's fall-through is its INNER if's false path, and that
    slot receives the continuation — not `mkNil`.
  * `mkNil` fills a fall-through slot ONLY at the defun's top-level
    terminator (`lowerTerm`), where no continuation exists.
  * a TIf with BOTH arms falling splices the continuation into BOTH —
    the continuation DUPLICATION the plan's J7 floor forbids at the
    direct-arm level, still legal one level down (the checker's
    `diverges` is terminator-only, so it admits this shape; MEASURED 0
    DSL sites — the DSL always nests the continuation into the one
    falling arm by hand).  Duplication is id-safe: each copy is lowered
    sequentially, so its binders get distinct ids.

-}
lowerBranch : St -> Block -> (St -> Result String (St, Exp)) -> Result String (St, Exp)
lowerBranch st b cont =
    lowerBranchRest st b.stmts b.term cont


lowerBranchRest : St -> List Stmt -> Term -> (St -> Result String (St, Exp)) -> Result String (St, Exp)
lowerBranchRest st stmts term cont =
    case stmts of
        [] ->
            lowerBranchTerm st term cont

        s :: rest ->
            lowerStmt st s (\st1 -> lowerBranchRest st1 rest term cont)


lowerBranchTerm : St -> Term -> (St -> Result String (St, Exp)) -> Result String (St, Exp)
lowerBranchTerm st term cont =
    case term of
        TRet e ->
            lowerExp st e

        TRecur args ->
            case lowerArgs st args of
                Err msg ->
                    Err msg

                Ok ( st1, es ) ->
                    Ok ( st1, App { fn = GRef { key = st.key, force = False }, args = es } )

        TIf c t me ->
            case lowerExp st c of
                Err msg ->
                    Err msg

                Ok ( st1, c1 ) ->
                    let
                        thenDiv =
                            diverges t

                        elseDiv =
                            divergesMaybe me
                    in
                    if thenDiv && not elseDiv then
                        case lowerBlock st1 t of
                            Err msg ->
                                Err msg

                            Ok ( st2, t1 ) ->
                                case me of
                                    Just eb ->
                                        case lowerBranch st2 eb cont of
                                            Err msg ->
                                                Err msg

                                            Ok ( st3, e1 ) ->
                                                let
                                                    ( ie, stF ) =
                                                        mkIf st3 c1 t1 e1
                                                in
                                                Ok ( stF, ie )

                                    Nothing ->
                                        -- The missing else IS the fall-through
                                        -- slot: splice the continuation there.
                                        case cont st2 of
                                            Err msg ->
                                                Err msg

                                            Ok ( st3, e1 ) ->
                                                let
                                                    ( ie, stF ) =
                                                        mkIf st3 c1 t1 e1
                                                in
                                                Ok ( stF, ie )

                    else if elseDiv && not thenDiv then
                        case lowerBlock st1 (maybeElse me) of
                            Err msg ->
                                Err msg

                            Ok ( st2, e1 ) ->
                                case lowerBranch st2 t cont of
                                    Err msg ->
                                        Err msg

                                    Ok ( st3, t1 ) ->
                                        let
                                            ( ie, stF ) =
                                                mkIf st3 c1 t1 e1
                                        in
                                        Ok ( stF, ie )

                    else if thenDiv && elseDiv then
                        -- Both arms diverge: the inner if is a dead end and
                        -- the continuation is unreachable from here.
                        case lowerBlock st1 t of
                            Err msg ->
                                Err msg

                            Ok ( st2, t1 ) ->
                                case me of
                                    Just eb ->
                                        case lowerBlock st2 eb of
                                            Err msg ->
                                                Err msg

                                            Ok ( st3, e1 ) ->
                                                let
                                                    ( ie, stF ) =
                                                        mkIf st3 c1 t1 e1
                                                in
                                                Ok ( stF, ie )

                                    Nothing ->
                                        Err (internal st "TIf" "both branches diverge but there is no else block")

                    else
                        -- Both arms fall: the continuation splices into BOTH
                        -- (the duplication documented above).
                        case lowerBranch st1 t cont of
                            Err msg ->
                                Err msg

                            Ok ( st2, t1 ) ->
                                case me of
                                    Just eb ->
                                        case lowerBranch st2 eb cont of
                                            Err msg ->
                                                Err msg

                                            Ok ( st3, e1 ) ->
                                                let
                                                    ( ie, stF ) =
                                                        mkIf st3 c1 t1 e1
                                                in
                                                Ok ( stF, ie )

                                    Nothing ->
                                        Err
                                            (internal st "TIf"
                                                "a terminating if without else whose then-branch falls through reached the lowerer — Check J7 must reject it first"
                                            )


maybeElse : Maybe Block -> Block
maybeElse me =
    case me of
        Just eb ->
            eb

        Nothing ->
            -- Unreachable for checked input (J7: a terminating if without
            -- else needs a diverging then-branch, so this arm is only entered
            -- when the else diverges — which requires an else to exist).
            { stmts = []
            , term = TRet (Ast.EBuiltin MkNil [])
            }


{-| The J7 divergence predicate, MIRRORED from Mid.RtLang.Check (whose copy
is not exposed): a block diverges iff control can never fall past its end,
decided by the TERMINATOR alone (`return`/`recur` always; a terminating
`if` only when BOTH branches diverge).  The lowerer reads the same
predicate the checker admitted the block with — L6's else-nesting picks
the branch that receives the continuation by it.  KEEP IN SYNC with
`Check.diverges`; if the two ever disagree, the loud internal errors above
fire instead of a silent mis-nest.
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



-- ============================ expressions ============================


lowerExp : St -> Ast.Exp -> Result String (St, Exp)
lowerExp st e =
    case e of
        Ast.EInt i ->
            Ok ( st, Lit (LNumber i) )

        Ast.EFlt f ->
            Ok ( st, Lit (LFloat f) )

        Ast.EStr s ->
            Ok ( st, Lit (LString s) )

        Ast.EVar name ->
            case Dict.get name st.scope of
                Just id ->
                    Ok ( st, Var id )

                Nothing ->
                    Err
                        (internal st ("name '" ++ name ++ "'")
                            "is unbound at the lowerer — Check J5 must reject it first"
                        )

        Ast.EWordBin op a b ->
            lower2 st a b (binLower (wordBinOp op))

        Ast.EWordCmp op a b ->
            lower2 st a b (cmpLower (wordCmpOp op))

        Ast.EFltBin op a b ->
            lower2 st a b (fltBinLower (fltBinOp op))

        Ast.EFltCmp op a b ->
            lower2 st a b (fltCmpLower (fltCmpOp op))

        Ast.EShortAnd a b ->
            lower2 st a b shortLower

        Ast.EShortOr a b ->
            lower2 st a b shortOrLower

        Ast.EIf c thn els ->
            -- the ?: VALUE JOIN (T9b), 1:1: the same `mkIf` the statement
            -- layer uses, so the form lowers to `If { .. }` with its
            -- falseLabel/endLabel — in an `SBind` value position that is
            -- exactly the plan L6 `Let { x = If { .. } }` shape, whose
            -- join label the backend handles natively.  No new lowering
            -- machinery: the L5/L6 statement rules are untouched.
            case lowerExp st c of
                Err msg ->
                    Err msg

                Ok ( st1, c1 ) ->
                    case lowerExp st1 thn of
                        Err msg ->
                            Err msg

                        Ok ( st2, t1 ) ->
                            case lowerExp st2 els of
                                Err msg ->
                                    Err msg

                                Ok ( st3, e1 ) ->
                                    let
                                        ( ie, stF ) =
                                            mkIf st3 c1 t1 e1
                                    in
                                    Ok ( stF, ie )

        Ast.ECall key args ->
            lowerCall st args (\es s -> ( Unsafe (RawCall { sym = key, args = es }), s ))

        Ast.ERawCall sym args ->
            lowerCall st args (\es s -> ( Unsafe (RawCallRaw { sym = sym, args = es }), s ))

        Ast.EAggCall shape fnExp args ->
            case lowerExp st fnExp of
                Err msg ->
                    Err msg

                Ok ( st1, f1 ) ->
                    case lowerArgs st1 args of
                        Err msg ->
                            Err msg

                        Ok ( st2, es ) ->
                            Ok ( st2, Unsafe (RawCallAgg { fn = f1, args = es, shape = aggShape shape }) )

        Ast.EBuiltin b args ->
            lowerBuiltin st b args

        Ast.EWithRoots ids block ->
            case resolveRoots st ids of
                Err msg ->
                    Err msg

                Ok ( st1, binders ) ->
                    case lowerBlock st1 block of
                        Err msg ->
                            Err msg

                        Ok ( st2, body ) ->
                            Ok ( st2, Unsafe (WithRoots { binders = binders, body = body }) )


{-| The four operator families lower constructor-by-constructor onto the
matching raw-node enums (annotated top-level so the partial applications
passed to `lower2` carry the surface/IR distinction in their types).
-}
binLower : RawBinOp -> Exp -> Exp -> St -> ( Exp, St )
binLower op x y st =
    ( Unsafe (RawBin { op = op, a = x, b = y }), st )


cmpLower : RawCmpOp -> Exp -> Exp -> St -> ( Exp, St )
cmpLower op x y st =
    ( Unsafe (RawCmp { op = op, a = x, b = y }), st )


fltBinLower : RawFltBinOp -> Exp -> Exp -> St -> ( Exp, St )
fltBinLower op x y st =
    ( Unsafe (RawFltBin { op = op, a = x, b = y }), st )


fltCmpLower : RawFltCmpOp -> Exp -> Exp -> St -> ( Exp, St )
fltCmpLower op x y st =
    ( Unsafe (RawFltCmp { op = op, a = x, b = y }), st )


shortLower : Exp -> Exp -> St -> ( Exp, St )
shortLower left right st =
    let
        ( falseLbl, endLbl, st1 ) =
            freshLabels st
    in
    ( ShortAnd { left = left, right = right, falseLabel = falseLbl, endLabel = endLbl }
    , st1
    )


shortOrLower : Exp -> Exp -> St -> ( Exp, St )
shortOrLower left right st =
    let
        ( falseLbl, endLbl, st1 ) =
            freshLabels st
    in
    ( ShortOr { left = left, right = right, falseLabel = falseLbl, endLabel = endLbl }
    , st1
    )


lower2 : St -> Ast.Exp -> Ast.Exp -> (Exp -> Exp -> St -> ( Exp, St )) -> Result String (St, Exp)
lower2 st a b k =
    case lowerExp st a of
        Err msg ->
            Err msg

        Ok ( st1, a1 ) ->
            case lowerExp st1 b of
                Err msg ->
                    Err msg

                Ok ( st2, b1 ) ->
                    let
                        ( ie, stF ) =
                            k a1 b1 st2
                    in
                    Ok ( stF, ie )


lowerCall : St -> List Ast.Exp -> (List Exp -> St -> ( Exp, St )) -> Result String (St, Exp)
lowerCall st args k =
    case lowerArgs st args of
        Err msg ->
            Err msg

        Ok ( st1, es ) ->
            let
                ( ie, stF ) =
                    k es st1
            in
            Ok ( stF, ie )


{-| Arguments in source order, state threaded left to right.
-}
lowerArgs : St -> List Ast.Exp -> Result String (St, List Exp)
lowerArgs st args =
    case args of
        [] ->
            Ok ( st, [] )

        a :: rest ->
            case lowerExp st a of
                Err msg ->
                    Err msg

                Ok ( st1, a1 ) ->
                    case lowerArgs st1 rest of
                        Err msg ->
                            Err msg

                        Ok ( st2, es ) ->
                            Ok ( st2, a1 :: es )


resolveRoots : St -> List String -> Result String (St, List Binder)
resolveRoots st ids =
    case ids of
        [] ->
            Ok ( st, [] )

        id :: rest ->
            case Dict.get id st.scope of
                Just binderId ->
                    case resolveRoots st rest of
                        Err msg ->
                            Err msg

                        Ok ( st1, tail ) ->
                            Ok ( st1, { id = binderId, name = id } :: tail )

                Nothing ->
                    Err
                        (internal st ("withroots id '" ++ id ++ "'")
                            "is unbound at the lowerer — Check J10 must reject it first"
                        )


aggShape : AggShape -> String
aggShape shape =
    case shape of
        AggRet ->
            "ret"

        AggVal ->
            "val"



-- ============================ builtins ============================


{-| Lower a builtin: all arguments first (state threaded), then the node is
built by the `Ast.builtinClass` table's row — arity and classes were
checked (J1), so a mismatched shape here is an internal error.
-}
lowerBuiltin : St -> Builtin -> List Ast.Exp -> Result String (St, Exp)
lowerBuiltin st b args =
    case lowerArgs st args of
        Err msg ->
            Err msg

        Ok ( st1, es ) ->
            case buildBuiltin b es of
                Err msg ->
                    Err (internal st ("builtin '" ++ builtinName b ++ "'") msg)

                Ok ie ->
                    Ok ( st1, ie )


buildBuiltin : Builtin -> List Exp -> Result String Exp
buildBuiltin b es =
    case b of
        MkNum ->
            buildMk RtLayout.tagNumber es

        MkBool ->
            buildMk RtLayout.tagBoolean es

        MkNil ->
            case es of
                [] ->
                    Ok (Unsafe (RawMkValue { tag = RtLayout.tagNil, words = [] }))

                _ ->
                    Err arityBug

        MkStr ->
            buildMk2 RtLayout.tagString es

        MkFlt ->
            buildMk RtLayout.tagFloat es

        MkVec ->
            buildMk2 RtLayout.tagVector es

        MkVal ->
            -- The generic value constructor: `mkval(tag, words..)`.  The tag
            -- is a CONSTANT inside RawMkValue, so the AST tag argument must
            -- be an int literal (the parser's literal-slot rule; a computed
            -- tag is unrepresentable and a loud error here, not a guess).
            case es of
                (Lit (LNumber tag)) :: rest ->
                    Ok (Unsafe (RawMkValue { tag = tag, words = rest }))

                _ ->
                    Err "needs an int-literal tag (RawMkValue's tag is a constant in Mid.Ir)"

        Payload ->
            case es of
                [ v, Lit (LNumber i) ] ->
                    Ok (Unsafe (RawPayload { value = v, word = i }))

                _ ->
                    Err "needs (value, int-literal index) — RawPayload's word is a constant"

        Payload32 ->
            case es of
                [ v, Lit (LNumber i) ] ->
                    Ok (Unsafe (RawPayload32 { value = v, word = i }))

                _ ->
                    Err "needs (value, int-literal index) — RawPayload32's word is a constant"

        Len32 ->
            -- The i32 len field = payload32(v, 1).
            case es of
                [ v ] ->
                    Ok (Unsafe (RawPayload32 { value = v, word = 1 }))

                _ ->
                    Err arityBug

        TagIs ->
            case es of
                [ v, Lit (LNumber t) ] ->
                    Ok (Unsafe (RawTagIs { value = v, tag = t }))

                _ ->
                    Err "needs (value, int-literal tag) — RawTagIs's tag is a constant"

        VecLoad ->
            build2 (\vec idx -> Unsafe (RawVecLoad { vec = vec, index = idx })) es

        VecAddr ->
            build2 (\vec idx -> Unsafe (RawVecAddr { vec = vec, index = idx })) es

        VecStore ->
            build3 (\vec idx v -> Unsafe (RawVecStore { vec = vec, index = idx, value = v })) es

        StrByte ->
            build2 (\str idx -> Unsafe (RawStrByte { str = str, index = idx })) es

        ByteLoad ->
            build2 (\ptr idx -> Unsafe (RawByteLoad { ptr = ptr, index = idx })) es

        ByteStore ->
            build3 (\ptr idx v -> Unsafe (RawByteStore { ptr = ptr, index = idx, value = v })) es

        WordLoad ->
            build2 (\ptr idx -> Unsafe (RawWordLoad { ptr = ptr, index = idx })) es

        WordStore ->
            build3 (\ptr idx v -> Unsafe (RawWordStore { ptr = ptr, index = idx, value = v })) es

        AllocVec ->
            build1 (\w -> Unsafe (RawAllocVector w)) es

        AllocRaw ->
            build1 (\w -> Unsafe (RawAllocRaw w)) es

        IToF ->
            build1 (\w -> Unsafe (RawIToF w)) es

        FLoad ->
            build1 (\v -> Unsafe (RawLoadFlt v)) es

        FToI32 ->
            build1 (\f -> Unsafe (RawUn { op = RFToI32, v = f })) es

        Sext ->
            build1 (\w -> Unsafe (RawUn { op = RSext, v = w })) es

        Uext ->
            build1 (\w -> Unsafe (RawUn { op = RUext, v = w })) es

        BitNot ->
            build1 (\w -> Unsafe (RawUn { op = RBitNot, v = w })) es

        RecLen ->
            -- The MEASURED macro (Ast's J1 table row; the tree is RtPrims'
            -- recLenOf, RtPrims.elm:216-228): len * (1 - isNil), the
            -- nil-aware i32 length.  `v` is pure, so lowering it twice is
            -- exactly what the DSL's macro writes.
            case es of
                [ v ] ->
                    Ok
                        (Unsafe
                            (RawBin
                                { op = RMul
                                , a = Unsafe (RawPayload32 { value = v, word = 1 })
                                , b =
                                    Unsafe
                                        (RawBin
                                            { op = RSub
                                            , a = Lit (LNumber 1)
                                            , b = Unsafe (RawTagIs { value = v, tag = RtLayout.tagNil })
                                            }
                                        )
                                }
                            )
                        )

                _ ->
                    Err arityBug


arityBug : String
arityBug =
    "lowered with the wrong arity — Check J1 must reject it first"


buildMk : Int -> List Exp -> Result String Exp
buildMk tag es =
    case es of
        [ w ] ->
            Ok (Unsafe (RawMkValue { tag = tag, words = [ w ] }))

        _ ->
            Err arityBug


buildMk2 : Int -> List Exp -> Result String Exp
buildMk2 tag es =
    case es of
        [ w1, w2 ] ->
            Ok (Unsafe (RawMkValue { tag = tag, words = [ w1, w2 ] }))

        _ ->
            Err arityBug


build1 : (Exp -> Exp) -> List Exp -> Result String Exp
build1 k es =
    case es of
        [ a ] ->
            Ok (k a)

        _ ->
            Err arityBug


build2 : (Exp -> Exp -> Exp) -> List Exp -> Result String Exp
build2 k es =
    case es of
        [ a, b ] ->
            Ok (k a b)

        _ ->
            Err arityBug


build3 : (Exp -> Exp -> Exp -> Exp) -> List Exp -> Result String Exp
build3 k es =
    case es of
        [ a, b, c ] ->
            Ok (k a b c)

        _ ->
            Err arityBug



-- ============================ the operator maps ============================


{-| 1:1 with Mid.Ir's RawBinOp (Ast's WordBinOp doc): `>>` is the ARITHMETIC
shift (RShAr), `>>>` the zero-fill one (RShR).
-}
wordBinOp : WordBinOp -> RawBinOp
wordBinOp op =
    case op of
        WAdd ->
            RAdd

        WSub ->
            RSub

        WMul ->
            RMul

        WDiv ->
            RDiv

        WBitAnd ->
            RBitAnd

        WBitOr ->
            RBitOr

        WBitXor ->
            RBitXor

        WShl ->
            RShl

        WShAr ->
            RShAr

        WShR ->
            RShR


wordCmpOp : WordCmpOp -> RawCmpOp
wordCmpOp op =
    case op of
        WCeq ->
            RCeq

        WCne ->
            RCne

        WClts ->
            RClts

        WCles ->
            RCles

        WCgts ->
            RCgts

        WCges ->
            RCges


fltBinOp : FltBinOp -> RawFltBinOp
fltBinOp op =
    case op of
        FAdd ->
            RFAdd

        FSub ->
            RFSub

        FMul ->
            RFMul

        FDiv ->
            RFDiv


fltCmpOp : FltCmpOp -> RawFltCmpOp
fltCmpOp op =
    case op of
        FLt ->
            RFLt

        FLe ->
            RFLe

        FGt ->
            RFGt

        FGe ->
            RFGe

        FEq ->
            RFEq

        FNe ->
            RFNe



-- ============================ internal errors ============================


{-| The loud internal error: names the defun, the nearest construct and the
judgment that should have rejected the shape first.  Checked input cannot
reach these.
-}
internal : St -> String -> String -> String
internal st what why =
    st.key ++ ": RtLang internal: " ++ what ++ " " ++ why
