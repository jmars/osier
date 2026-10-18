module Mid.RtLang.LowerToIr exposing
    ( lowerModule
    , lowerProgram
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
`Mid.RtLang.Ast`, `Mid.RtLang.Check` (only the layout TABLE readers —
`fieldOffset`/`sizeofStruct`, the one-table property) and `Mid.RtLayout` (the
tag constants — the same single source of truth RtPrims/RtGc read).  No QBE
type appears here.

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
        , Decl(..)
        , Field
        , FltBinOp(..)
        , FltCmpOp(..)
        , Module
        , PTy(..)
        , Param
        , Program
        , Stmt(..)
        , StructInit(..)
        , Term(..)
        , Type(..)
        , WordBinOp(..)
        , WordCmpOp(..)
        , builtinName
        )
import Mid.RtLang.Check as Check
import Mid.RtLayout as RtLayout



-- ============================ the lowering state ============================


{-| Per-defun lowering state.  `nextId` hands out binder ids (unique across
the WHOLE defun — the backend keys its slot dicts by them, plan fact F1);
`nextLbl` hands out the If/ShortAnd/ShortOr label strings (IGNORED by the
backend — readability only); `scope` maps surface names to binder ids; `key`
is the defun's own key (L4's self-GRef target); `types` is the DECLARED class
of every binder in scope; `decls` is the file's struct/enum table; `ret` is
the defun's declared result class (B1: the `return` site needs it to know
whether a bool operand goes through the bool→val BOX).
-}
type alias St =
    { key : String
    , nextId : Int
    , nextLbl : Int
    , scope : Dict String Int
    , types : Dict String Ast.Type
    , decls : List Decl
    , ret : Ast.Type
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
active variant per flag set is the wiring's job, T7).  The headerless
delegate: no file-scoped decls, so the field/index/deref arms have no
struct table to read (they can only fire on a structless program — the
runtime lane, which uses none of the A2 spellings yet).
-}
lowerProgram : Program -> Result String (List Defun)
lowerProgram program =
    lowerAll [] [] program


{-| Lower a whole MODULE — the decl-carrying entry the user lane and the
tree-equality pin use.  `decls` ride in the lowering state so the
field/index arms read the SAME struct table the A1 checker laid out from
(`Check.fieldOffset`/`Check.sizeofStruct` — the one-table property: no
second copy to skew).
-}
lowerModule : Module -> Result String (List Defun)
lowerModule module_ =
    lowerAll module_.decls [] module_.defuns


lowerAll : List Decl -> List Defun -> Program -> Result String (List Defun)
lowerAll decls acc program =
    case program of
        [] ->
            Ok (List.reverse acc)

        d :: rest ->
            case lowerDefun decls d of
                Err msg ->
                    Err msg

                Ok idef ->
                    lowerAll decls (idef :: acc) rest


{-| L3's defun shape, identical to the DSL's `lam` (RtPrims.elm:388-393):
params are binders with ids 1..n in order (the DSL's `p1..p5` convention),
the body is the block's lowered value.
-}
lowerDefun : List Decl -> Ast.Defun -> Result String Defun
lowerDefun decls d =
    let
        params =
            paramBinders 1 d.params

        st0 =
            { key = d.key
            , nextId = List.length d.params + 1
            , nextLbl = 1
            , scope = paramScope params
            , types = paramTypes d.params
            , decls = decls
            , ret = d.ret
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


{-| The parameter binder's DECLARED class, name -> type — the lowerer's own
scope for resolving a pointer base's pointee family (`*word`/`*val`/`*S`),
mirroring the checker's `paramScope` (Check.elm).  The lowerer reads only
this (and the `SBind` insert below); it does not re-derive classes.
-}
paramTypes : List Param -> Dict String Ast.Type
paramTypes params =
    List.foldl (\p acc -> Dict.insert p.name p.ty acc) Dict.empty params



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
        SBind ty name e ->
            case lowerExp st e of
                Err msg ->
                    Err msg

                Ok ( st1, v1 ) ->
                    let
                        -- B1: a bool initializer at a `:val` slot goes through
                        -- the box (the checker's ONE implicit coercion).
                        v2 =
                            if ty == Ast.TVal && isBoolExp st e then
                                boolToVal v1

                            else
                                v1

                        ( binder, st2 ) =
                            fresh name st1

                        st3 =
                            { st2
                                | scope = Dict.insert name binder.id st2.scope
                                , types = Dict.insert name ty st2.types
                            }
                    in
                    case cont st3 of
                        Err msg ->
                            Err msg

                        Ok ( st4, body ) ->
                            Ok ( st4, Let { binders = [ LetBind { binder = binder, value = v2 } ], body = body } )

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

        SFieldStore p f e ->
            -- A2: `p->f = e;` — dead-binder Lets of the field's store node(s)
            -- (the EXACT `wstore(p, off, e);` / `vecstore(p, off, e);` tree,
            -- plan §3).  The value lowers FIRST (state threading), then the
            -- dead binder binds the effect and the continuation continues.
            -- B2: a struct-typed FIELD stores as a word-for-word copy, so
            -- the node count is the field's width (`fieldStoreNodes`).
            case resolvePointee st p of
                Err msg ->
                    Err msg

                Ok (PStruct sname) ->
                    case fieldInfo st sname f of
                        Err msg ->
                            Err msg

                        Ok ( off, fty ) ->
                            case lowerExp st p of
                                Err msg ->
                                    Err msg

                                Ok ( st1, p1 ) ->
                                    case lowerExp st1 e of
                                        Err msg ->
                                            Err msg

                                        Ok ( st2, e1 ) ->
                                            let
                                                -- B1: the same bool→val box, at
                                                -- a `val` FIELD slot.
                                                e2 =
                                                    if fty == Ast.TVal && isBoolExp st2 e then
                                                        boolToVal e1

                                                    else
                                                        e1
                                            in
                                            case fieldStoreNodes st sname f p1 e2 of
                                                Err msg ->
                                                    Err msg

                                                Ok stores ->
                                                    withStores "_fieldstore" st2 stores cont

                Ok pty ->
                    Err
                        (internal st "field store (`p->f = e;`)"
                            ("needs a struct pointer, got *"
                                ++ ptyStr pty
                                ++ " — Check J13 must reject it first"
                            )
                        )

        SStructBind rec ->
            -- B2: the struct-VALUE binder.  Storage FIRST (`structAlloc`), then
            -- the initialiser's stores, then the binder and the continuation —
            -- `Let s = <addr> in Let dead = <store> in ..`, so the address is a
            -- raw word binder exactly like any other.
            case structAlloc st rec.sname of
                Err msg ->
                    Err msg

                Ok alloc ->
                    let
                        ( binder, st1 ) =
                            fresh rec.name st

                        st2 =
                            { st1
                                | scope = Dict.insert rec.name binder.id st1.scope
                                , types = Dict.insert rec.name (Ast.TStruct rec.sname) st1.types
                            }
                    in
                    -- The stores address the BINDER (`Var id`), never the
                    -- `malloc` expression: re-lowering the alloc as the store
                    -- base would fill a SECOND, discarded block (MEASURED —
                    -- the first cut read back an all-zero copy).
                    case structInitNodes st2 rec.sname (Var binder.id) rec.init of
                        Err msg ->
                            Err msg

                        Ok ( st3, stores ) ->
                            case withStores "_structinit" st3 stores cont of
                                Err msg ->
                                    Err msg

                                Ok ( st4, body ) ->
                                    Ok
                                        ( st4
                                        , Let
                                            { binders = [ LetBind { binder = binder, value = alloc } ]
                                            , body = body
                                            }
                                        )

        SVarStore name e ->
            -- B2: `s = other;` — the aggregate COPY into storage that already
            -- exists.  The destination's address is its binder (a raw word).
            case ( Dict.get name st.scope, Dict.get name st.types ) of
                ( Just id, Just (Ast.TStruct sname) ) ->
                    case lowerExp st e of
                        Err msg ->
                            Err msg

                        Ok ( st1, e1 ) ->
                            case copyStores st sname 0 0 (Var id) e1 of
                                Err msg ->
                                    Err msg

                                Ok stores ->
                                    withStores "_structcopy" st1 stores cont

                _ ->
                    Err
                        (internal st ("assignment to '" ++ name ++ "'")
                            "needs a struct-VALUE binder — Check J1 must reject it first"
                        )

        SIndexStore p i e ->
            -- A2: `p[i] = e;` — the same dead-binder Let, index scaled by the
            -- pointee family (word stride: the index IS the word offset;
            -- `*S`: the index is a struct element, scaled by sizeof S).
            case resolvePointee st p of
                Err msg ->
                    Err msg

                Ok pty ->
                    case lowerExp st p of
                        Err msg ->
                            Err msg

                        Ok ( st1, p1 ) ->
                            case lowerExp st1 i of
                                Err msg ->
                                    Err msg

                                Ok ( st2, i1 ) ->
                                    case lowerExp st2 e of
                                        Err msg ->
                                            Err msg

                                        Ok ( st3, e1 ) ->
                                            let
                                                -- B1: the bool→val box at a
                                                -- `*val` ELEMENT slot.
                                                e2 =
                                                    if pty == PVal && isBoolExp st3 e then
                                                        boolToVal e1

                                                    else
                                                        e1
                                            in
                                            case indexStore st pty p1 i i1 e2 of
                                                Err msg ->
                                                    Err msg

                                                Ok storeNode ->
                                                    let
                                                        ( dead, st4 ) =
                                                            fresh "_indexstore" st3
                                                    in
                                                    case cont st4 of
                                                        Err msg ->
                                                            Err msg

                                                        Ok ( st5, body ) ->
                                                            Ok
                                                                ( st5
                                                                , Let
                                                                    { binders =
                                                                        [ LetBind
                                                                            { binder = dead
                                                                            , value = storeNode
                                                                            }
                                                                        ]
                                                                    , body = body
                                                                    }
                                                                )


{-| L3/L4/L5: the terminator IS the block's value.
-}
lowerTerm : St -> Term -> Result String (St, Exp)
lowerTerm st term =
    case term of
        TRet e ->
            case lowerExp st e of
                Err msg ->
                    Err msg

                Ok ( st1, v1 ) ->
                    -- B1: the bool→val box at a `-> val` return — the site
                    -- that keeps `return true;` byte-identical to the old
                    -- `mkbool(1)` sugar.
                    if st.ret == Ast.TVal && isBoolExp st e then
                        Ok ( st1, boolToVal v1 )

                    else
                        Ok ( st1, v1 )

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

        Ast.EBool b ->
            -- B1: the bool literal is the 0/1 WORD (`Lit 1`/`Lit 0`) — the
            -- bool class's constant form.  At a `:val` position the bool→val
            -- box wraps it (`boolToVal`), and `RawMkValue tagBoolean [Lit k]`
            -- is EXACTLY the tree the `mkbool(k)` sugar this replaced emitted
            -- — that is the byte-identity the corpus gate checks.
            Ok ( st, Lit (LNumber (boolWord b)) )

        Ast.ESizeof target ->
            case sizeofWords st target of
                Err msg ->
                    Err (internal st "sizeof" msg)

                Ok n ->
                    Ok ( st, Lit (LNumber n) )

        Ast.ECast target inner ->
            lowerCast st target inner

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
            -- B1: `&&`/`||` are val,val -> val (Ast.shortSig), so a bool
            -- operand is BOXED here — the inferred chain is
            -- `mkbool(x) || false`, whose `false` arm is the old mkbool(0) tree.
            lower2 st a b (\x y s1 -> shortLower (boxIfValBool st Ast.TVal a x) (boxIfValBool st Ast.TVal b y) s1)

        Ast.EShortOr a b ->
            lower2 st a b (\x y s1 -> shortOrLower (boxIfValBool st Ast.TVal a x) (boxIfValBool st Ast.TVal b y) s1)

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
                                        -- B1: the join's ONE implicit
                                        -- coercion — a bool arm beside a
                                        -- `:val` arm is BOXED (the checker's
                                        -- `joinClass`; a bool-vs-bool join is
                                        -- its reject, so exactly one side can
                                        -- need this).
                                        t2 =
                                            if isBoolExp st thn && not (isBoolExp st els) then
                                                boolToVal t1

                                            else
                                                t1

                                        e2 =
                                            if isBoolExp st els && not (isBoolExp st thn) then
                                                boolToVal e1

                                            else
                                                e1

                                        ( ie, stF ) =
                                            mkIf st3 c1 t2 e2
                                    in
                                    Ok ( stF, ie )

        Ast.EIfBlock c thn els ->
            -- T23: the BLOCK-BRANCH if EXPRESSION — the TERM `if`'s own
            -- lowering (`mkIf` over the two blocks lowered by the EXISTING
            -- `lowerBlock`), in an expression slot.  Position-free by
            -- construction: Mid's `If` carries only its invented
            -- falseLabel/endLabel and the backend invents its own labels
            -- and never reads the tree's (plan fact F1) — there is no
            -- isTail flag in this pipeline to vary — so the SAME node
            -- serves the tail position (the defun's value) and the VALUE
            -- position (an `SBind` initializer: L1 wraps it into
            -- `Let { x = If { .. } }`, the join the backend handles
            -- natively).  Each branch lowers as a BLOCK (its statements
            -- fold into the 1-binder Let chain of L1/L2, its terminator is
            -- the branch's value — a `return`/`recur` branch value is
            -- exactly the TIf branch's), else-nesting and both-diverge
            -- mid-block ifs inside a branch work unchanged, and the else
            -- branch is parsed-required so no dead-value fill is needed.
            case lowerExp st c of
                Err msg ->
                    Err msg

                Ok ( st1, c1 ) ->
                    case lowerBlock st1 thn of
                        Err msg ->
                            Err msg

                        Ok ( st2, t1 ) ->
                            case lowerBlock st2 els of
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

        Ast.EField p f ->
            -- A2: `p->f` IS the `wload(p, off)` spelling (plan §3 — the
            -- one-node property the whole arc is cheap on).  A word/pointer
            -- field -> `RawWordLoad { ptr = p, index = Lit off }`; a `val`
            -- field -> `RawVecLoad { vec = p, index = Lit off }` (the 5-word
            -- `vecload` contract — the field offset is a word offset, so the
            -- backend's `elemAddr` lands on `p + 40*off`, exactly the inline
            -- val slot).
            case resolvePointee st p of
                Err msg ->
                    Err msg

                Ok (PStruct sname) ->
                    case fieldInfo st sname f of
                        Err msg ->
                            Err msg

                        Ok ( off, fty ) ->
                            case lowerExp st p of
                                Err msg ->
                                    Err msg

                                Ok ( st1, p1 ) ->
                                    Ok ( st1, fieldLoad fty p1 off )

                Ok pty ->
                    Err
                        (internal st "field access (`p->f`)"
                            ("needs a struct pointer, got *"
                                ++ ptyStr pty
                                ++ " — Check J13 must reject it first"
                            )
                        )

        Ast.EIndex p i ->
            -- A2: `p[i]` — the index scaled by the pointee family.  `*word`:
            -- the index IS the word offset (`wload`'s contract).  `*val`:
            -- `vecload`.  `*S`: the index is a STRUCT ELEMENT, so the word
            -- offset is `i * sizeof S` (folded to `Lit (k*sizeofS)` for a
            -- literal index).
            case resolvePointee st p of
                Err msg ->
                    Err msg

                Ok pty ->
                    case lowerExp st p of
                        Err msg ->
                            Err msg

                        Ok ( st1, p1 ) ->
                            case lowerExp st1 i of
                                Err msg ->
                                    Err msg

                                Ok ( st2, i1 ) ->
                                    case indexLoad st pty p1 i i1 of
                                        Err msg ->
                                            Err msg

                                        Ok loadNode ->
                                            Ok ( st2, loadNode )

        Ast.EDeref p ->
            -- A2: `*p` is `*word` only (J13) -> `RawWordLoad { ptr = p,
            -- index = Lit 0 }` — `wload(p, 0)`.
            case lowerExp st p of
                Err msg ->
                    Err msg

                Ok ( st1, p1 ) ->
                    Ok ( st1, Unsafe (RawWordLoad { ptr = p1, index = Lit (LNumber 0) }) )

        Ast.EAddrOf inner ->
            -- B2: `&place`.  A FIELD is its base's address plus the field's
            -- constant word offset (`addrPlus` — the same arithmetic the
            -- field read uses, with the load dropped); a struct VALUE is
            -- already its own address, so `&s` is the IDENTITY and emits
            -- nothing.  Check has already refused everything without
            -- storage, so the fallthrough is exact.
            case inner of
                Ast.EField base f ->
                    case resolvePointee st base of
                        Err msg ->
                            Err msg

                        Ok (PStruct sname) ->
                            case fieldInfo st sname f of
                                Err msg ->
                                    Err msg

                                Ok ( off, _ ) ->
                                    case lowerExp st base of
                                        Err msg ->
                                            Err msg

                                        Ok ( st1, b1 ) ->
                                            Ok ( st1, addrPlus b1 off )

                        Ok pty ->
                            Err
                                (internal st "address-of (`&p->f`)"
                                    ("needs a struct pointer, got *"
                                        ++ ptyStr pty
                                        ++ " — Check J13 must reject it first"
                                    )
                                )

                _ ->
                    lowerExp st inner



-- ============================ B1: bool, casts, sizeof ============================


{-| `true`/`false` as the 0/1 word.
-}
boolWord : Bool -> Int
boolWord b =
    if b then
        1

    else
        0


{-| The bool→val BOX (plan Q2's ONE implicit coercion): the operand is a raw
0/1 word, the result is a boolean Value — the node `mkbool(..)` builds, which
is the tree the `true`/`false` sugar used to emit (`RawMkValue tagBoolean
[Lit 1|0]`).  The checker admits the operand at exactly the `:val` SLOTS this
module can see syntactically (a `:val` binder, a `:val` field/element store, a
`-> val` return, and a `?:` arm beside a val), so every site calls this with a
word it has already lowered.
-}
boolToVal : Exp -> Exp
boolToVal word =
    Unsafe (RawMkValue { tag = RtLayout.tagBoolean, words = [ word ] })


{-| Does this expression have class `bool`?  The LOWERING's mirror of
`Check`'s TBool class, and it is TOTAL because the checker admits no other
bool shape (`Check.isBoolTemp` is the binder rule; a bool join, a bool
param/return and a bool field cannot parse or check).  Used for the two
decisions the checker cannot make for it: where the bool→val box goes, and
which cast rows are the identity.
-}
isBoolExp : St -> Ast.Exp -> Bool
isBoolExp st e =
    case e of
        Ast.EBool _ ->
            True

        Ast.EWordCmp _ _ _ ->
            True

        Ast.EFltCmp _ _ _ ->
            True

        Ast.ECast target _ ->
            target == Ast.TBool

        Ast.EVar name ->
            Dict.get name st.types == Just Ast.TBool

        _ ->
            False


{-| Is this expression a FLOAT word (`d`)?  Only the cast rows need it: the
`[word]`/`[int]` cast is the identity for a word operand and `ftoi32` for a
float one.  Float words are never let-bound (`Check` J1), so the binding
shapes are the four expression forms plus a float PARAMETER (a stage-6 rawAbi
seat; a user defun's float param is B6's).  A shape this misses is a shape
whose cast would be an identity on a `d` temp — a loud QBE-layer type error,
never a silent wrong value.
-}
isFloatExp : St -> Ast.Exp -> Bool
isFloatExp st e =
    case e of
        Ast.EFlt _ ->
            True

        Ast.EFltBin _ _ _ ->
            True

        Ast.EBuiltin Ast.IToF _ ->
            True

        Ast.EBuiltin Ast.FLoad _ ->
            True

        Ast.EVar name ->
            Dict.get name st.types == Just Ast.TFloat

        _ ->
            False


{-| Box every bool operand whose expected class is `:val` — the general form
of the ONE implicit coercion, used wherever the expected classes are STATIC in
the tree: a builtin's operand slots (`Ast.builtinClass`) and the `&&`/`||`
operands (`Ast.shortSig` is val,val).  The other coercion sites are the ones
whose `:val` slot is explicit in the node being built (a binder, a field/
element store, a return, a `?:` arm) and box inline.
-}
boxArgs : St -> List Ast.Type -> List Ast.Exp -> List Exp -> List Exp
boxArgs st tys args es =
    case ( tys, args, es ) of
        ( t :: ts, a :: as_, e :: es_ ) ->
            boxIfValBool st t a e :: boxArgs st ts as_ es_

        _ ->
            es


{-| ONE operand: box it iff the expected class is `:val` and the surface
expression is a bool.  The single decision `boxArgs` folds over, so the
`&&`/`||` arms (whose expected class is `Ast.shortSig`'s val,val) and the
builtin slot walk cannot disagree.
-}
boxIfValBool : St -> Ast.Type -> Ast.Exp -> Exp -> Exp
boxIfValBool st expected a e =
    if expected == Ast.TVal && isBoolExp st a then
        boolToVal e

    else
        e


{-| The builtin form of `boxArgs`: a fixed-arity `Sig`'s operand classes;
`SigMkVal`'s payload words take a bool AS a word (rawWordArg computes the
0/1 temp), so nothing is boxed there.
-}
boxBuiltinArgs : St -> Ast.Builtin -> List Ast.Exp -> List Exp -> List Exp
boxBuiltinArgs st b args es =
    case Ast.builtinClass b of
        Ast.Sig tys _ ->
            boxArgs st tys args es

        Ast.SigMkVal ->
            es


{-| `[T](e)` — one arm per row of the checker's matrix (`Check.castClass` is
the judge; this is the emission).  The identity rows emit NO node at all:

  * `[word]`/`[int]` of word|pointer|bool — identity; of a FLOAT — `ftoi32`.
  * `[bool]` of word — a nonzero compare (`RawCmp WCne e 0`); of bool —
    identity.
  * `[*T]` of word — identity (the J12 view-cast, made explicit).
  * `[float]` of word — `RawIToF` (itof).
  * `[val]` of bool — the box.

Anything else is the checker's reject, so a fall-through here is an internal
error and says so.
-}
lowerCast : St -> Ast.Type -> Ast.Exp -> Result String (St, Exp)
lowerCast st target inner =
    case lowerExp st inner of
        Err msg ->
            Err msg

        Ok ( st1, e1 ) ->
            if target == Ast.TVal then
                Ok ( st1, boolToVal e1 )

            else if target == Ast.TFloat then
                if isFloatExp st inner then
                    Err (internal st "cast to float" "the operand is already a float word — Check J10 must reject it first")

                else
                    Ok ( st1, Unsafe (RawIToF e1) )

            else if target == Ast.TBool then
                if isBoolExp st inner then
                    Ok ( st1, e1 )

                else
                    Ok ( st1, Unsafe (RawCmp { op = RCne, a = e1, b = Lit (LNumber 0) }) )

            else if target == Ast.TWord then
                if isFloatExp st inner then
                    Ok ( st1, Unsafe (RawUn { op = RFToI32, v = e1 }) )

                else
                    Ok ( st1, e1 )

            else
                -- a pointer target: the `[*T](w)` identity (J12's view-cast)
                Ok ( st1, e1 )


{-| `sizeof`'s word count, from the ONE layout table (`Check.sizeofStruct`,
the same numbers the checker validated) or the class width — `word`/`int`/
pointer = 1, `val` = 5 inline words, `bool` = 1.  `float` is the checker's
reject (no raw f64 seat), so it is an internal error here.
-}
sizeofWords : St -> Ast.SizeTarget -> Result String Int
sizeofWords st target =
    case target of
        Ast.SizeStruct name ->
            case Check.sizeofStruct st.decls name of
                Just n ->
                    Ok n

                Nothing ->
                    Err ("no struct '" ++ name ++ "' in the layout table — Check J11 must reject it first")

        Ast.SizeType ty ->
            case ty of
                Ast.TStruct sname ->
                    case Check.sizeofStruct st.decls sname of
                        Just n ->
                            Ok n

                        Nothing ->
                            Err ("no struct '" ++ sname ++ "' in the layout table — Check J11 must reject it first")

                Ast.TWord ->
                    Ok 1

                Ast.TBool ->
                    Ok 1

                Ast.TPtr _ ->
                    Ok 1

                Ast.TVal ->
                    Ok 5

                Ast.TFloat ->
                    Err "a float has no raw-memory word width (Check J1 must reject it first)"


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
            let
                -- B1: a bool operand at a `:val` slot is BOXED (the implicit
                -- coercion; `Ast.builtinClass` is the class table, so the
                -- slot's class is static — no guessing).
                es2 =
                    boxBuiltinArgs st b args es
            in
            case buildBuiltin b es2 of
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

        RawStr ->
            -- the static C-string address (stage 6 U2): the content is the
            -- STRING LITERAL (an EStr — the only AST the parser admits for
            -- this builtin's one slot), lowered to `Lit (LString s)` then to
            -- the RawCStr WORD node.  A non-literal reaches this Err loudly
            -- (never a silent guess).
            case es of
                [ Lit (LString s) ] ->
                    Ok (Unsafe (RawCStr s))

                _ ->
                    Err "rawstr needs a string literal (the content is static data — RawCStr)"

        Ast.RawSym ->
            -- the FUNCTION-symbol address (stage 6 A1b): the symbol is the
            -- STRING LITERAL (an EStr, the only AST the parser admits for this
            -- builtin's one slot), lowered to the RawSym WORD node whose
            -- content is the function's name VERBATIM.  A non-literal reaches
            -- this Err loudly (never a silent guess).
            case es of
                [ Lit (LString s) ] ->
                    Ok (Unsafe (Mid.Ir.RawSym s))

                _ ->
                    Err "rawsym needs a string literal (the symbol is a static code label — RawSym)"


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



-- ============================ A2: field/index/deref lowering ============================


{-| Resolve a pointer-typed expression's POINTEE family — the lowerer's own
read of the ONE table the A1 checker laid out.  Handles the forms that can
PRODUCE a pointer: a binder whose declared type is `*T` (the type scope the
lowerer threads beside the binder ids), a pointer FIELD via its struct table,
and a pointer-valued `?:` join whose branches agree (J1).  Anything else is a
LOUD internal error: the checker admitted a pointer here (J13 resolved `p`),
so an unresolvable base is a lowering gap named, never a silent guess.
-}
resolvePointee : St -> Ast.Exp -> Result String PTy
resolvePointee st e =
    case e of
        Ast.EVar name ->
            case Dict.get name st.types of
                Just (TPtr pty) ->
                    Ok pty

                Just (TStruct sname) ->
                    -- B2: a struct VALUE's value IS its address, so for
                    -- every field/index resolution below it behaves exactly
                    -- like a `*S` pointing at itself.
                    Ok (PStruct sname)

                Just ty ->
                    Err
                        (internal st ("field/index base '" ++ name ++ "'")
                            ("is " ++ typeStrOf ty ++ ", not a pointer — Check J13 must reject it first")
                        )

                Nothing ->
                    Err (internal st ("field/index base '" ++ name ++ "'") "is unbound at the lowerer — Check J5 must reject it first")

        Ast.EField base f ->
            case resolvePointee st base of
                Err msg ->
                    Err msg

                Ok (PStruct sname) ->
                    case fieldTyIn st.decls sname f of
                        Just (TPtr pty) ->
                            Ok pty

                        Just (TStruct inner) ->
                            Ok (PStruct inner)

                        Just ty ->
                            Err
                                (internal st ("field '" ++ sname ++ "." ++ f ++ "'")
                                    ("is " ++ typeStrOf ty ++ ", not a pointer — Check J13 must reject it first")
                                )

                        Nothing ->
                            Err
                                (internal st ("field '" ++ sname ++ "." ++ f ++ "'")
                                    "is not in the struct table — Check J13 must reject it first"
                                )

                Ok pty ->
                    Err
                        (internal st "field access"
                            ("needs a struct pointer, got *" ++ ptyStr pty ++ " — Check J13 must reject it first")
                        )

        Ast.EIf _ a _ ->
            -- the branches agree (J1), so the then-branch's pointee is the
            -- join's.
            resolvePointee st a

        _ ->
            Err
                (internal st "a field/index base"
                    "is a pointer-typed expression form the lowerer cannot resolve (a pointer-returning call / block-if join) — a lowering gap, not a checker reject"
                )


{-| A struct field's word offset and its declared type, from the SAME table
the checker built (`Check.fieldOffset` — the one-table property).  `Nothing`
here is a lowerer/checker drift, loud, never a guessed offset.
-}
fieldInfo : St -> String -> String -> Result String ( Int, Type )
fieldInfo st sname fname =
    case Check.fieldOffset st.decls sname fname of
        Just off ->
            case fieldTyIn st.decls sname fname of
                Just fty ->
                    Ok ( off, fty )

                Nothing ->
                    Err
                        (internal st ("field '" ++ sname ++ "." ++ fname ++ "'")
                            "is not in the struct table — Check J13 must reject it first"
                        )

        Nothing ->
            Err
                (internal st ("field '" ++ sname ++ "." ++ fname ++ "'")
                    "is not in the struct table — Check J13 must reject it first"
                )


{-| A struct field's DECLARED type, structurally — a pure read of the decl
(the same `.ty` the checker's layout and class rules read).  This is NOT
layout logic: the offset/size arithmetic lives in `Check`, this only
discriminates word/pointer vs `val` for the node shape.
-}
fieldTyIn : List Decl -> String -> String -> Maybe Type
fieldTyIn decls structName fieldName =
    case decls of
        [] ->
            Nothing

        d :: rest ->
            case d of
                StructDecl s ->
                    if s.name == structName then
                        fieldTyInFields s.fields fieldName

                    else
                        fieldTyIn rest structName fieldName

                EnumDecl _ ->
                    fieldTyIn rest structName fieldName


fieldTyInFields : List Field -> String -> Maybe Type
fieldTyInFields fields name =
    case fields of
        [] ->
            Nothing

        f :: rest ->
            if f.name == name then
                Just f.ty

            else
                fieldTyInFields rest name


{-| `base + 8*off` — the ADDRESS of a struct's field.  Two rules wear it:
a struct-typed field READ (the field IS a location, so no load happens)
and the `&place` lowering.  `off = 0` is the IDENTITY, so the emitted tree
for a field at offset 0 is unchanged from before B2 (the A2 pins compare
trees, and they must keep passing).

MEASURED NOTE — THE VAL-FIELD SCALING THIS FIXES.  `RawVecLoad`/
`RawVecStore` index in VALUE units (the backend's `elemAddr` multiplies by
40), while the layout table gives offsets in WORD units.  Passing a word
offset straight to a vec node was therefore a 40x misplacement for any
`val` field NOT at word 0 (`struct S { a : word; v : val; }` put `v` at
word 1 = byte 8; the node addressed byte 40).  A1's rows could not see it
(the pinned structs had a single val field, at offset 0) and A2's tree pins
still pass because offset 0 is the identity.  Addressing the field in BYTES
(`addrPlus`) and indexing the vec at 0 is exact for every offset.
-}
addrPlus : Exp -> Int -> Exp
addrPlus base off =
    if off <= 0 then
        base

    else
        Unsafe (RawBin { op = RAdd, a = base, b = Lit (LNumber (8 * off)) })


{-| The field READ node: `val` -> `RawVecLoad` (the 5-word Blit) at the
field's BYTE address, a nested STRUCT -> its address (`addrPlus`, no load),
everything else (word/pointer — the checker rejects float fields, J11) ->
`RawWordLoad` at the field's word offset.
-}
fieldLoad : Type -> Exp -> Int -> Exp
fieldLoad fty p1 off =
    case fty of
        TVal ->
            Unsafe (RawVecLoad { vec = addrPlus p1 off, index = Lit (LNumber 0) })

        TStruct _ ->
            addrPlus p1 off

        _ ->
            Unsafe (RawWordLoad { ptr = p1, index = Lit (LNumber off) })


{-| The single-node field STORE, matching `fieldLoad`'s word/val rows.  A
`TStruct` field never reaches here: `fieldStoreNodes` branches to the
word-for-word COPY first (one node cannot express it, and a one-word store
of a struct's address would be silently wrong).
-}
fieldStore : Type -> Exp -> Int -> Exp -> Exp
fieldStore fty p1 off e1 =
    case fty of
        TVal ->
            Unsafe (RawVecStore { vec = addrPlus p1 off, index = Lit (LNumber 0), value = e1 })

        _ ->
            Unsafe (RawWordStore { ptr = p1, index = Lit (LNumber off), value = e1 })


-- ==================== B2: struct VALUES (storage, copy, address) ====================


{-| THE ONE PLACE STRUCT STORAGE IS ALLOCATED (B2).  `malloc(8 * sizeof S)`
— a C-heap block, because `Mid.Ir` has no frame-allocation node and
`Mid/Qbe/Il.elm`'s `Alloc` is a tier BELOW this module (Ast's `EAddrOf`
note records the measured refutation of the plan's `Il.Alloc` premise).
Swapping to stack memory is ONE edit here when B4 lands `RawAllocN`.

`size` comes from `Check.sizeofStruct` — the one layout table.
-}
structAlloc : St -> String -> Result String Exp
structAlloc st sname =
    case Check.sizeofStruct st.decls sname of
        Just size ->
            Ok (Unsafe (RawCallRaw { sym = "malloc", args = [ Lit (LNumber (8 * size)) ] }))

        Nothing ->
            Err
                (internal st ("struct value '" ++ sname ++ "'")
                    "has no layout in the struct table — Check J11 must reject it first"
                )


{-| The ZEROED tail of `S s;` — `memset(addr, 0, 8*sizeof S)`: uninitialised
raw memory is a silent-wrong-value generator, and this language has no
`unsafe` marker to opt into it.
-}
structZero : St -> String -> Exp -> Result String Exp
structZero st sname addr =
    case Check.sizeofStruct st.decls sname of
        Just size ->
            Ok
                (Unsafe
                    (RawCallRaw
                        { sym = "memset"
                        , args = [ addr, Lit (LNumber 0), Lit (LNumber (8 * size)) ]
                        }
                    )
                )

        Nothing ->
            Err
                (internal st ("struct value '" ++ sname ++ "'")
                    "has no layout in the struct table — Check J11 must reject it first"
                )


{-| A struct declaration's field list, structurally — the same `.fields` the
checker's layout walks (NOT layout logic: offsets and widths are read from
`Check.fieldOffset`/`Check.fieldWidth`, the one table).
-}
fieldsOf : List Decl -> String -> Maybe (List Field)
fieldsOf decls sname =
    case decls of
        [] ->
            Nothing

        d :: rest ->
            case d of
                StructDecl sd ->
                    if sd.name == sname then
                        Just sd.fields

                    else
                        fieldsOf rest sname

                EnumDecl _ ->
                    fieldsOf rest sname


{-| The WORD OFFSETS a struct value occupies, relative to its base, in field
order — every field expanded to the whole words it covers (`val` = 5,
nested struct = its own size, word/pointer = 1).  This is what the COPY
walks: one 8-byte load/store per word is exact for a val slot too (a
40-byte Value is five words, which is why the copy needs no Blit node and
no class rule).
-}
structWordsAt : St -> String -> Int -> Result String (List Int)
structWordsAt st sname bias =
    case fieldsOf st.decls sname of
        Nothing ->
            Err
                (internal st ("struct value '" ++ sname ++ "'")
                    "is not in the decl table — Check J11 must reject it first"
                )

        Just fields ->
            fieldsWords st sname bias fields


fieldsWords : St -> String -> Int -> List Field -> Result String (List Int)
fieldsWords st sname bias fields =
    case fields of
        [] ->
            Ok []

        f :: rest ->
            case Check.fieldOffset st.decls sname f.name of
                Nothing ->
                    Err
                        (internal st ("field '" ++ sname ++ "." ++ f.name ++ "'")
                            "has no offset in the struct table — Check J13 must reject it first"
                        )

                Just off ->
                    case Check.fieldWidth st.decls sname f.name of
                        Nothing ->
                            Err
                                (internal st ("field '" ++ sname ++ "." ++ f.name ++ "'")
                                    "has no width in the struct table — Check J13 must reject it first"
                                )

                        Just w ->
                            case fieldsWords st sname bias rest of
                                Err msg ->
                                    Err msg

                                Ok tailWords ->
                                    case fieldWords st bias off f.ty w of
                                        Err msg ->
                                            Err msg

                                        Ok here ->
                                            Ok (here ++ tailWords)


{-| One field's word offsets: a nested struct recurses (its own base is the
outer offset — a struct value is contiguous by the layout rule), everything
else is `w` consecutive words at `off`.
-}
fieldWords : St -> Int -> Int -> Type -> Int -> Result String (List Int)
fieldWords st bias off ty w =
    case ty of
        TStruct inner ->
            structWordsAt st inner (bias + off)

        _ ->
            Ok (intsFrom (bias + off) w)


intsFrom : Int -> Int -> List Int
intsFrom off n =
    if n <= 0 then
        []

    else
        off :: intsFrom (off + 1) (n - 1)


{-| ONE word copy: `dst[dOff] = src[sOff]`.
-}
wordCopy : Exp -> Int -> Exp -> Int -> Exp
wordCopy dst dOff src sOff =
    Unsafe
        (RawWordStore
            { ptr = dst
            , index = Lit (LNumber dOff)
            , value = Unsafe (RawWordLoad { ptr = src, index = Lit (LNumber sOff) })
            }
        )


{-| The word-for-word COPY of `sname`'s words from `src` (at `srcOff`) into
`dst` (at `dstOff`) — the aggregate-init / assignment / struct-field store
lowering (plan Q4).  `dstOff` is the field's offset when the destination is
a FIELD of a bigger struct, 0 for a whole value.
-}
copyStores : St -> String -> Int -> Int -> Exp -> Exp -> Result String (List Exp)
copyStores st sname dstOff srcOff dst src =
    case structWordsAt st sname 0 of
        Err msg ->
            Err msg

        Ok words ->
            Ok (List.map (\w -> wordCopy dst (dstOff + w) src (srcOff + w)) words)


{-| The store-node list for `base.f = e` (and for one `S s = { f = e; }`
initialiser entry): a `TStruct` field is a COPY (its own word list, at the
field's offset), every other field is the single `fieldStore` node.  A
one-node store of a struct's address would be silently wrong — that is the
seam this function closes.
-}
fieldStoreNodes : St -> String -> String -> Exp -> Exp -> Result String (List Exp)
fieldStoreNodes st sname f base e =
    case fieldInfo st sname f of
        Err msg ->
            Err msg

        Ok ( off, TStruct inner ) ->
            copyStores st inner off 0 base e

        Ok ( off, fty ) ->
            Ok [ fieldStore fty base off e ]


{-| The store nodes one `S s = ...` initialiser needs, WITH the state the
initialiser expressions consumed (an `InitCopy`/`InitFields` operand is a
real expression, lowered in order like any other).
-}
structInitNodes : St -> String -> Exp -> StructInit -> Result String ( St, List Exp )
structInitNodes st sname addr init =
    case init of
        InitZero ->
            case structZero st sname addr of
                Err msg ->
                    Err msg

                Ok zero ->
                    Ok ( st, [ zero ] )

        InitFields fields ->
            initFieldsNodes st sname addr fields []

        InitCopy e ->
            case lowerExp st e of
                Err msg ->
                    Err msg

                Ok ( st1, e1 ) ->
                    case copyStores st sname 0 0 addr e1 of
                        Err msg ->
                            Err msg

                        Ok stores ->
                            Ok ( st1, stores )


initFieldsNodes : St -> String -> Exp -> List ( String, Ast.Exp ) -> List Exp -> Result String ( St, List Exp )
initFieldsNodes st sname addr fields acc =
    case fields of
        [] ->
            Ok ( st, acc )

        ( f, e ) :: rest ->
            case fieldInfo st sname f of
                Err msg ->
                    Err msg

                Ok ( _, fty ) ->
                    case lowerExp st e of
                        Err msg ->
                            Err msg

                        Ok ( st1, e1 ) ->
                            let
                                -- B1's box, at a `val` FIELD slot: the same
                                -- rule SFieldStore applies.
                                e2 =
                                    if fty == Ast.TVal && isBoolExp st e then
                                        boolToVal e1

                                    else
                                        e1
                            in
                            case fieldStoreNodes st sname f addr e2 of
                                Err msg ->
                                    Err msg

                                Ok nodes ->
                                    initFieldsNodes st1 sname addr rest (acc ++ nodes)


{-| Run a list of store nodes IN ORDER, each bound to its own fresh dead
binder (L2's `(b 107, rStore ..)` shape — a store's result slot must be a
valid binder even though nothing reads it), then the continuation.
-}
withStores : String -> St -> List Exp -> (St -> Result String (St, Exp)) -> Result String (St, Exp)
withStores label st stores cont =
    case stores of
        [] ->
            cont st

        e :: rest ->
            let
                ( dead, st1 ) =
                    fresh label st
            in
            case withStores label st1 rest cont of
                Err msg ->
                    Err msg

                Ok ( st2, body ) ->
                    Ok ( st2, Let { binders = [ LetBind { binder = dead, value = e } ], body = body } )



{-| The index READ node, scaled by the pointee family: `*word` -> `wload`'s
word-offset index; `*val` -> `vecload`; `*S` -> the index scaled by
`sizeof S` (a word multiply, folded to a literal for a literal index).
-}
indexLoad : St -> PTy -> Exp -> Ast.Exp -> Exp -> Result String Exp
indexLoad st pty p1 astI i1 =
    case pty of
        PWord ->
            Ok (Unsafe (RawWordLoad { ptr = p1, index = i1 }))

        PVal ->
            Ok (Unsafe (RawVecLoad { vec = p1, index = i1 }))

        PStruct sname ->
            case Check.sizeofStruct st.decls sname of
                Just size ->
                    Ok (Unsafe (RawWordLoad { ptr = p1, index = scaledIndex astI i1 size }))

                Nothing ->
                    Err
                        (internal st ("index access on '*" ++ sname ++ "'")
                            "has no struct in the table — Check J11 must reject it first"
                        )


{-| The index STORE node, matching `indexLoad`'s shape.
-}
indexStore : St -> PTy -> Exp -> Ast.Exp -> Exp -> Exp -> Result String Exp
indexStore st pty p1 astI i1 e1 =
    case pty of
        PWord ->
            Ok (Unsafe (RawWordStore { ptr = p1, index = i1, value = e1 }))

        PVal ->
            Ok (Unsafe (RawVecStore { vec = p1, index = i1, value = e1 }))

        PStruct sname ->
            case Check.sizeofStruct st.decls sname of
                Just size ->
                    Ok (Unsafe (RawWordStore { ptr = p1, index = scaledIndex astI i1 size, value = e1 }))

                Nothing ->
                    Err
                        (internal st ("index store on '*" ++ sname ++ "'")
                            "has no struct in the table — Check J11 must reject it first"
                        )


{-| The `*S` index scale: the index is a STRUCT ELEMENT, so the word offset
is `i * sizeof S`.  A literal index folds to `Lit (k*sizeofS)` (the plan §3
fold); a computed index lowers to `RawBin { op = RMul, a = i, b = Lit size }`.
-}
scaledIndex : Ast.Exp -> Exp -> Int -> Exp
scaledIndex astI i1 size =
    case astI of
        Ast.EInt k ->
            Lit (LNumber (k * size))

        _ ->
            Unsafe (RawBin { op = RMul, a = i1, b = Lit (LNumber size) })


ptyStr : PTy -> String
ptyStr pty =
    case pty of
        PStruct sname ->
            sname

        PWord ->
            "word"

        PVal ->
            "val"


typeStrOf : Type -> String
typeStrOf ty =
    case ty of
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
            "*" ++ ptyStr pty



-- ============================ internal errors ============================


{-| The loud internal error: names the defun, the nearest construct and the
judgment that should have rejected the shape first.  Checked input cannot
reach these.
-}
internal : St -> String -> String -> String
internal st what why =
    st.key ++ ": RtLang internal: " ++ what ++ " " ++ why
