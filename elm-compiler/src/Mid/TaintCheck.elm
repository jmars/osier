module Mid.TaintCheck exposing (checkGroup)

{-| CONTRACT 4 (EFFECT CONTAINMENT) — the conservative RETURN floor.

plan.md §2.5 states the owner's rule: an Osier function MAY call into mid-c
and may USE the result freely INSIDE itself, but the result of a `!taint`
export must not reach the ENCLOSING FUNCTION'S RETURN (directly, or through a
returned closure's captures).  This module enforces the conservative floor the
plan measured as checkable NOW, WITHOUT the Phase-7 region/quantifier
machinery: a name-based dataflow pass over the PRE-LIFT group AST.

THE TWO QUANTITIES (least fixpoint over the group's functions):

  * `valueTaint(E)` — does expression E produce/reach a value derived from a
    `!taint` mid-c call.
  * `resultTaint(f)` — does function f's RESULT carry that taint (valueTaint
    of f's body).

THE ONE REFINEMENT (what keeps the owner's let + self-recursive case LEGAL):
a function REFERENCE contributes the callee's RESULT taint in HEAD position
(invoked) but its CAPTURE taint in VALUE position (returned).  `captureTaint(f)`
is the OR of the taints of the binders f's body references FREE (its closure's
captures), excluding top-level functions (global symbols — they resolve outside
the scope walk, so are never captures) and excluding f's own PARAMETERS (clean
inside the body).  A lambda
LITERAL's value taint is its capture taint — returning `\\y -> Midmath.answer`
is legal (the closure captures nothing tainted), while returning `\\y -> t`
captures tainted `t` and is rejected.

SCOPING: a `let` block is treated as ONE mutually-recursive group (letrec) for
the fixpoint — matching what `Frontend.Lift` does to a self-recursive local
function before the checker sees it.  This is what lets the pass read the
PRE-LIFT `go (n - 1)` self-reference as a call whose result taint is the
least fixpoint (False on a clean base case).  Value binders (let-destructuring,
case binders, module-level Destructuring) inherit their defining/scrutinee
expression's value taint; function PARAMETERS are CLEAN inside the body, with
argument taint propagated at the CALL SITE (`resultTaint(callee) OR
valueTaint(args)` — the conservative floor: a tainted argument taints the call
whatever the callee does with it).

The pass is EMIT-INERT on `Ok`: it runs before lowering and only ever returns
`Err` (reject) or `Ok ()`; it changes no emitted bytes.  When `taintedKeys` is
empty — every corpus group and the selfhost group, which import no mid module —
it returns `Ok ()` immediately without walking anything.

NOT here (Phase 7): region/quantifier containment; the polymorphic-laundering
leak (a tainted value passed through a `forall a` wrapper is invisible to a
name-based pass) is the plan's known, named hole — this floor is §2.5's own
intermediate, not the contract's final form.

-}

import Dict exposing (Dict)
import Elm.Syntax.Declaration exposing (Declaration(..))
import Elm.Syntax.Expression exposing (Expression(..), Function, LetDeclaration(..))
import Elm.Syntax.File as File
import Elm.Syntax.Module as Module
import Elm.Syntax.Node as Node exposing (Node(..))
import Elm.Syntax.Pattern exposing (Pattern(..))
import Elm.Syntax.Range exposing (Range)
import Set exposing (Set)


{-| Enforce the return-taint floor over one group's PRE-LIFT parsed files.

`taintedKeys` is the set of qualified export keys (`"Tainty.make"`) whose
`ExportSig.taint` is True — the user `.mid` exports UNION the runtime's
`exportedTypes`, filtered to `taint` (computed by the caller in
`Mid.QbeModule`).  `Ok ()` = every top-level function's result is clean;
`Err msg` = the first violating function, with a position.
-}
checkGroup : Set String -> List File.File -> Result String ()
checkGroup taintedKeys files =
    if Set.isEmpty taintedKeys then
        Ok ()

    else
        run taintedKeys files


-- =============================== the model ===============================


{-| What a name reference resolves to.  `RFn`/`RVal` carry the binder's stable
id (see the header: top-level function ids are pre-assigned; module and nested
binder ids are assigned by the deterministic walk, so they are stable across
fixpoint iterations).
-}
type Resolved
    = RKey
    | RFn Int
    | RVal Int
    | RClean


type alias Frame =
    Dict String Resolved


type alias Scope =
    List Frame


type alias TopFn =
    { id : Int
    , name : String
    , range : Range
    , params : List (Node Pattern)
    , body : Node Expression
    , moduleFns : Dict String Resolved
    }


type alias FileInfo =
    { file : File.File
    , moduleName : String
    , moduleFns : Dict String Resolved
    , fns : List TopFn
    }


type alias Static =
    { taintedKeys : Set String
    , topLevels : Dict String Resolved
    , files : List FileInfo
    , nextIdStart : Int
    }


type alias Walk =
    { taint : Dict Int Bool
    , result : Dict Int Bool
    , nextId : Int
    }


-- ================================ entry =================================


run : Set String -> List File.File -> Result String ()
run taintedKeys files =
    let
        static =
            collectStatic taintedKeys files

        ( finalTaint, finalResult ) =
            fixpoint static
    in
    report static finalTaint finalResult


collectStatic : Set String -> List File.File -> Static
collectStatic taintedKeys files =
    let
        ( topLevels, fileInfos, nextId ) =
            assignTopFns files
    in
    { taintedKeys = taintedKeys
    , topLevels = topLevels
    , files = List.reverse fileInfos
    , nextIdStart = nextId
    }


-- ===================== pre-pass: top-level function ids ===================


moduleNameStr : File.File -> String
moduleNameStr file =
    Module.moduleName (Node.value file.moduleDefinition)
        |> String.join "."


fnImpl : Function -> { name : String, range : Range, params : List (Node Pattern), body : Node Expression }
fnImpl fn =
    let
        d =
            Node.value fn.declaration
    in
    { name = Node.value d.name
    , range = Node.range d.name
    , params = d.arguments
    , body = d.expression
    }


topFnDecl : Node Declaration -> Maybe Function
topFnDecl (Node _ decl) =
    case decl of
        FunctionDeclaration fn ->
            Just fn

        _ ->
            Nothing


type alias RawFn =
    { id : Int, name : String, range : Range, params : List (Node Pattern), body : Node Expression }


type alias FnAcc =
    { rawFns : List RawFn
    , moduleFns : Dict String Resolved
    , nextId : Int
    , top : Dict String Resolved
    }


assignTopFns : List File.File -> ( Dict String Resolved, List FileInfo, Int )
assignTopFns files =
    List.foldl
        (\file ( topAcc, infosAcc, nextId ) ->
            let
                modName =
                    moduleNameStr file

                decls =
                    List.filterMap topFnDecl file.declarations

                acc =
                    List.foldl (assignFnId modName)
                        { rawFns = [], moduleFns = Dict.empty, nextId = nextId, top = topAcc }
                        decls

                fns =
                    List.map
                        (\r ->
                            { id = r.id
                            , name = r.name
                            , range = r.range
                            , params = r.params
                            , body = r.body
                            , moduleFns = acc.moduleFns
                            }
                        )
                        (List.reverse acc.rawFns)
            in
            ( acc.top
            , { file = file, moduleName = modName, moduleFns = acc.moduleFns, fns = fns } :: infosAcc
            , acc.nextId
            )
        )
        ( Dict.empty, [], 0 )
        files


assignFnId : String -> Function -> FnAcc -> FnAcc
assignFnId modName fn acc =
    let
        impl0 =
            fnImpl fn

        qualified =
            modName ++ "." ++ impl0.name

        raw =
            { id = acc.nextId, name = impl0.name, range = impl0.range, params = impl0.params, body = impl0.body }

        -- A zero-argument top-level binding is a VALUE (its reference yields the
        -- body's value), not a function; only arity>0 bindings are functions
        -- (whose reference yields a closure with a capture taint).  elm-syntax
        -- parses BOTH as FunctionDeclaration; the arity is the discriminator.
        resolved =
            if List.isEmpty impl0.params then
                RVal acc.nextId

            else
                RFn acc.nextId
    in
    { rawFns = raw :: acc.rawFns
    , moduleFns = Dict.insert impl0.name resolved acc.moduleFns
    , nextId = acc.nextId + 1
    , top = Dict.insert qualified resolved acc.top
    }


-- ============================ the fixpoint ===============================


fixpoint : Static -> ( Dict Int Bool, Dict Int Bool )
fixpoint static =
    iterate static Dict.empty Dict.empty


iterate : Static -> Dict Int Bool -> Dict Int Bool -> ( Dict Int Bool, Dict Int Bool )
iterate static taint result =
    let
        ( newTaint, newResult ) =
            walkIteration static taint result
    in
    if newTaint == taint && newResult == result then
        ( newTaint, newResult )

    else
        iterate static newTaint newResult


walkIteration : Static -> Dict Int Bool -> Dict Int Bool -> ( Dict Int Bool, Dict Int Bool )
walkIteration static oldTaint oldResult =
    let
        walk =
            List.foldl (walkFile static oldTaint oldResult)
                { taint = Dict.empty, result = Dict.empty, nextId = static.nextIdStart }
                static.files
    in
    ( walk.taint, walk.result )


walkFile : Static -> Dict Int Bool -> Dict Int Bool -> FileInfo -> Walk -> Walk
walkFile static oldTaint oldResult file walk =
    let
        ( walk1, moduleFrame ) =
            List.foldl (walkModuleDecl static oldTaint oldResult file) ( walk, Dict.empty ) file.file.declarations

        walk2 =
            List.foldl (walkTopFn static oldTaint oldResult file moduleFrame) walk1 file.fns
    in
    walk2


-- Module-level Destructuring binders are VALUE binders at module scope,
-- sequential in declaration order (each RHS sees earlier module binders).
walkModuleDecl : Static -> Dict Int Bool -> Dict Int Bool -> FileInfo -> Node Declaration -> ( Walk, Frame ) -> ( Walk, Frame )
walkModuleDecl static oldTaint oldResult file (Node _ decl) ( walk, moduleFrame ) =
    case decl of
        Destructuring pat expr ->
            let
                ( t, walk1 ) =
                    valueTaint static oldTaint oldResult file.moduleFns [ moduleFrame ] expr walk

                ( binders, walk2 ) =
                    bindPattern t pat walk1

                moduleFrame1 =
                    List.foldl (\( name, id ) f -> Dict.insert name (RVal id) f) moduleFrame binders
            in
            ( walk2, moduleFrame1 )

        _ ->
            ( walk, moduleFrame )


walkTopFn : Static -> Dict Int Bool -> Dict Int Bool -> FileInfo -> Frame -> TopFn -> Walk -> Walk
walkTopFn static oldTaint oldResult file moduleFrame topFn walk =
    if List.isEmpty topFn.params then
        -- A zero-argument top-level binding is a VALUE: its taint IS the body's
        -- value taint (a reference yields the value, and the return check is
        -- exactly "does this value carry the taint").
        let
            ( valueTaint_, walk1 ) =
                valueTaint static oldTaint oldResult topFn.moduleFns [ moduleFrame ] topFn.body walk
        in
        { walk1 | taint = Dict.insert topFn.id valueTaint_ walk1.taint }

    else
        let
            bodyScope =
                paramFrame topFn.params :: [ moduleFrame ]

            ( resultTaint, walk1 ) =
                valueTaint static oldTaint oldResult topFn.moduleFns bodyScope topFn.body walk

            capTaint =
                captureTaint oldTaint [ moduleFrame ] (paramNames topFn.params) topFn.body
        in
        { walk1
            | result = Dict.insert topFn.id resultTaint walk1.result
            , taint = Dict.insert topFn.id capTaint walk1.taint
        }


-- ============================ name resolution ============================


lookupScope : Scope -> String -> Maybe Resolved
lookupScope scope name =
    case scope of
        [] ->
            Nothing

        frame :: rest ->
            case Dict.get name frame of
                Just r ->
                    Just r

                Nothing ->
                    lookupScope rest name


resolve : Static -> Dict String Resolved -> Scope -> List String -> String -> Resolved
resolve static moduleFns scope moduleName name =
    let
        qualified =
            String.join "." (moduleName ++ [ name ])
    in
    if Set.member qualified static.taintedKeys then
        RKey

    else if moduleName == [] then
        case lookupScope scope name of
            Just r ->
                r

            Nothing ->
                case Dict.get name moduleFns of
                    Just r ->
                        r

                    Nothing ->
                        RClean

    else
        case Dict.get qualified static.topLevels of
            Just r ->
                r

            Nothing ->
                RClean


getTaint : Dict Int Bool -> Int -> Bool
getTaint dict id =
    Maybe.withDefault False (Dict.get id dict)


refValueTaint : Resolved -> Dict Int Bool -> Bool
refValueTaint resolved taint =
    case resolved of
        RKey ->
            True

        RFn id ->
            getTaint taint id

        RVal id ->
            getTaint taint id

        RClean ->
            False


-- ============================ value taint ================================


valueTaint : Static -> Dict Int Bool -> Dict Int Bool -> Dict String Resolved -> Scope -> Node Expression -> Walk -> ( Bool, Walk )
valueTaint static oldTaint oldResult moduleFns scope (Node _ expr) walk =
    case expr of
        UnitExpr ->
            ( False, walk )

        Application (head :: args) ->
            let
                ( headT, walk1 ) =
                    case Node.value head of
                        FunctionOrValue modName name ->
                            ( case resolve static moduleFns scope modName name of
                                RFn id ->
                                    getTaint oldResult id

                                r ->
                                    refValueTaint r oldTaint
                            , walk
                            )

                        LambdaExpression lam ->
                            valueTaint static oldTaint oldResult moduleFns (paramFrame lam.args :: scope) lam.expression walk

                        _ ->
                            valueTaint static oldTaint oldResult moduleFns scope head walk

                ( t, walk2 ) =
                    List.foldl
                        (\a ( acc, w ) ->
                            let
                                ( at, w1 ) =
                                    valueTaint static oldTaint oldResult moduleFns scope a w
                            in
                            ( acc || at, w1 )
                        )
                        ( headT, walk1 )
                        args
            in
            ( t, walk2 )

        Application [] ->
            ( False, walk )

        OperatorApplication _ _ left right ->
            let
                ( lt, walk1 ) =
                    valueTaint static oldTaint oldResult moduleFns scope left walk

                ( rt, walk2 ) =
                    valueTaint static oldTaint oldResult moduleFns scope right walk1
            in
            ( lt || rt, walk2 )

        FunctionOrValue modName name ->
            ( refValueTaint (resolve static moduleFns scope modName name) oldTaint, walk )

        IfBlock c t e ->
            List.foldl
                (stepTaint static oldTaint oldResult moduleFns scope)
                ( valueTaint static oldTaint oldResult moduleFns scope c walk )
                [ t, e ]

        PrefixOperator _ ->
            ( False, walk )

        Operator _ ->
            ( False, walk )

        Integer _ ->
            ( False, walk )

        Hex _ ->
            ( False, walk )

        Floatable _ ->
            ( False, walk )

        Negation e ->
            valueTaint static oldTaint oldResult moduleFns scope e walk

        Literal _ ->
            ( False, walk )

        CharLiteral _ ->
            ( False, walk )

        TupledExpression es ->
            List.foldl
                (stepTaint static oldTaint oldResult moduleFns scope)
                ( False, walk )
                es

        ParenthesizedExpression e ->
            valueTaint static oldTaint oldResult moduleFns scope e walk

        LetExpression { declarations, expression } ->
            valueTaintLet static oldTaint oldResult moduleFns scope declarations expression walk

        CaseExpression { expression, cases } ->
            let
                ( scrutT, walk1 ) =
                    valueTaint static oldTaint oldResult moduleFns scope expression walk

                ( branchesT, walk2 ) =
                    List.foldl
                        (\( pat, branch ) ( acc, w ) ->
                            let
                                ( binders, w1 ) =
                                    bindPattern scrutT pat w

                                branchScope =
                                    bindersFrame binders :: scope

                                ( bt, w2 ) =
                                    valueTaint static oldTaint oldResult moduleFns branchScope branch w1
                            in
                            ( acc || bt, w2 )
                        )
                        ( False, walk1 )
                        cases
            in
            ( scrutT || branchesT, walk2 )

        LambdaExpression lam ->
            -- a lambda's VALUE taint is its CAPTURE taint (returning the closure).
            ( captureTaint oldTaint scope (paramNames lam.args) lam.expression, walk )

        RecordExpr setters ->
            List.foldl
                (\(Node _ ( _, e )) -> stepTaint static oldTaint oldResult moduleFns scope e)
                ( False, walk )
                setters

        ListExpr es ->
            List.foldl
                (stepTaint static oldTaint oldResult moduleFns scope)
                ( False, walk )
                es

        RecordAccess e _ ->
            valueTaint static oldTaint oldResult moduleFns scope e walk

        RecordAccessFunction _ ->
            ( False, walk )

        RecordUpdateExpression _ setters ->
            List.foldl
                (\(Node _ ( _, e )) -> stepTaint static oldTaint oldResult moduleFns scope e)
                ( False, walk )
                setters

        InsertionValue e ->
            valueTaint static oldTaint oldResult moduleFns scope e walk

        GLSLExpression _ ->
            ( False, walk )


stepTaint : Static -> Dict Int Bool -> Dict Int Bool -> Dict String Resolved -> Scope -> Node Expression -> ( Bool, Walk ) -> ( Bool, Walk )
stepTaint static oldTaint oldResult moduleFns scope e ( acc, walk ) =
    let
        ( t, walk1 ) =
            valueTaint static oldTaint oldResult moduleFns scope e walk
    in
    ( acc || t, walk1 )


valueTaintLet : Static -> Dict Int Bool -> Dict Int Bool -> Dict String Resolved -> Scope -> List (Node LetDeclaration) -> Node Expression -> Walk -> ( Bool, Walk )
valueTaintLet static oldTaint oldResult moduleFns scope declarations expression walk =
    let
        ( fnAssigns, walk1 ) =
            List.foldl assignLetFnId ( [], walk ) declarations

        fnFrame =
            Dict.fromList (List.map (\( id, fn ) -> ( letFnName fn, RFn id )) fnAssigns)

        ( valFrame, walk2 ) =
            List.foldl (walkLetVal static oldTaint oldResult moduleFns scope fnFrame) ( Dict.empty, walk1 ) declarations

        blockScope =
            valFrame :: fnFrame :: scope

        walk3 =
            List.foldl (walkLetFn static oldTaint oldResult moduleFns blockScope) walk2 fnAssigns

        ( t, walk4 ) =
            valueTaint static oldTaint oldResult moduleFns blockScope expression walk3
    in
    ( t, walk4 )


assignLetFnId : Node LetDeclaration -> ( List ( Int, Function ), Walk ) -> ( List ( Int, Function ), Walk )
assignLetFnId (Node _ decl) ( acc, walk ) =
    case decl of
        LetFunction fn ->
            -- Zero-argument let-functions are VALUES (see walkLetVal), not part
            -- of the recursive function group.
            if List.isEmpty (letFnParams fn) then
                ( acc, walk )

            else
                let
                    id =
                        walk.nextId
                in
                ( ( id, fn ) :: acc, { walk | nextId = id + 1 } )

        _ ->
            ( acc, walk )


walkLetVal : Static -> Dict Int Bool -> Dict Int Bool -> Dict String Resolved -> Scope -> Frame -> Node LetDeclaration -> ( Frame, Walk ) -> ( Frame, Walk )
walkLetVal static oldTaint oldResult moduleFns scope fnFrame (Node _ decl) ( valFrame, walk ) =
    case decl of
        LetDestructuring pat expr ->
            let
                rhsScope =
                    valFrame :: fnFrame :: scope

                ( t, walk1 ) =
                    valueTaint static oldTaint oldResult moduleFns rhsScope expr walk

                ( binders, walk2 ) =
                    bindPattern t pat walk1

                valFrame1 =
                    List.foldl (\( name, id ) f -> Dict.insert name (RVal id) f) valFrame binders
            in
            ( valFrame1, walk2 )

        LetFunction fn ->
            -- elm-syntax parses `let v = e in ...` as a zero-argument
            -- LetFunction; semantically that is a VALUE binding (evaluated once,
            -- its reference yields the value), so it joins the valFrame exactly
            -- like a LetDestructuring to a single VarPattern.
            if List.isEmpty (letFnParams fn) then
                let
                    name =
                        letFnName fn

                    rhsScope =
                        valFrame :: fnFrame :: scope

                    ( t, walk1 ) =
                        valueTaint static oldTaint oldResult moduleFns rhsScope (letFnBody fn) walk

                    id =
                        walk1.nextId

                    walk2 =
                        { walk1 | taint = Dict.insert id t walk1.taint, nextId = id + 1 }

                    valFrame1 =
                        Dict.insert name (RVal id) valFrame
                in
                ( valFrame1, walk2 )

            else
                ( valFrame, walk )


walkLetFn : Static -> Dict Int Bool -> Dict Int Bool -> Dict String Resolved -> Scope -> ( Int, Function ) -> Walk -> Walk
walkLetFn static oldTaint oldResult moduleFns blockScope ( id, fn ) walk =
    let
        bodyScope =
            paramFrame (letFnParams fn) :: blockScope

        ( resultTaint, walk1 ) =
            valueTaint static oldTaint oldResult moduleFns bodyScope (letFnBody fn) walk

        capTaint =
            captureTaint oldTaint blockScope (paramNames (letFnParams fn)) (letFnBody fn)
    in
    { walk1
        | result = Dict.insert id resultTaint walk1.result
        , taint = Dict.insert id capTaint walk1.taint
    }


-- ============================ capture taint ==============================

{-| The value taint of a function's CLOSURE: the OR of the taints of the
binders its body references FREE (captured from `outerScope`).  Top-level
functions are never captured (they resolve outside `outerScope`), and
`paramNames` plus the function's inner binders are excluded by the free-variable
walk — so a self-recursive `go` contributes nothing to its OWN capture taint.
-}
captureTaint : Dict Int Bool -> Scope -> List String -> Node Expression -> Bool
captureTaint oldTaint outerScope boundNames body =
    let
        frees =
            freeVars (Set.fromList boundNames) body
    in
    Set.foldl
        (\name acc ->
            acc
                || (case lookupScope outerScope name of
                        Just (RVal id) ->
                            getTaint oldTaint id

                        Just (RFn id) ->
                            getTaint oldTaint id

                        _ ->
                            False
                   )
        )
        False
        frees


freeVars : Set String -> Node Expression -> Set String
freeVars bound (Node _ expr) =
    case expr of
        FunctionOrValue [] name ->
            if Set.member name bound then
                Set.empty

            else
                Set.singleton name

        FunctionOrValue _ _ ->
            Set.empty

        Application exprs ->
            List.foldl (\n acc -> Set.union acc (freeVars bound n)) Set.empty exprs

        OperatorApplication _ _ left right ->
            Set.union (freeVars bound left) (freeVars bound right)

        IfBlock c t e ->
            Set.union (freeVars bound c) (Set.union (freeVars bound t) (freeVars bound e))

        Negation e ->
            freeVars bound e

        TupledExpression es ->
            List.foldl (\n acc -> Set.union acc (freeVars bound n)) Set.empty es

        ParenthesizedExpression e ->
            freeVars bound e

        LetExpression { declarations, expression } ->
            freeVarsLet bound declarations expression

        CaseExpression { expression, cases } ->
            let
                scrut =
                    freeVars bound expression
            in
            List.foldl
                (\( pat, branch ) acc ->
                    Set.union acc (freeVars (Set.union bound (Set.fromList (patternNames (Node.value pat)))) branch)
                )
                scrut
                cases

        LambdaExpression { args, expression } ->
            freeVars (Set.union bound (Set.fromList (List.concatMap (\p -> patternNames (Node.value p)) args))) expression

        RecordExpr setters ->
            List.foldl (\(Node _ ( _, e )) acc -> Set.union acc (freeVars bound e)) Set.empty setters

        ListExpr es ->
            List.foldl (\n acc -> Set.union acc (freeVars bound n)) Set.empty es

        RecordAccess e _ ->
            freeVars bound e

        RecordAccessFunction _ ->
            Set.empty

        RecordUpdateExpression _ setters ->
            List.foldl (\(Node _ ( _, e )) acc -> Set.union acc (freeVars bound e)) Set.empty setters

        InsertionValue e ->
            freeVars bound e

        _ ->
            Set.empty


freeVarsLet : Set String -> List (Node LetDeclaration) -> Node Expression -> Set String
freeVarsLet bound declarations expression =
    let
        allNames =
            Set.fromList (List.concatMap declNames declarations)

        innerBound =
            Set.union bound allNames

        declFree =
            List.foldl
                (\decl acc ->
                    case Node.value decl of
                        LetFunction fn ->
                            Set.union acc (freeVars (Set.union innerBound (Set.fromList (paramNames (letFnParams fn)))) (letFnBody fn))

                        LetDestructuring _ e ->
                            Set.union acc (freeVars innerBound e)
                )
                Set.empty
                declarations
    in
    Set.union declFree (freeVars innerBound expression)


declNames : Node LetDeclaration -> List String
declNames (Node _ decl) =
    case decl of
        LetFunction fn ->
            [ letFnName fn ]

        LetDestructuring pat _ ->
            patternNames (Node.value pat)


-- ============================ patterns ===================================


patternNames : Pattern -> List String
patternNames pat =
    case pat of
        VarPattern name ->
            [ name ]

        AsPattern inner (Node _ name) ->
            name :: patternNames (Node.value inner)

        RecordPattern fields ->
            List.map Node.value fields

        NamedPattern _ subpats ->
            List.concatMap (\p -> patternNames (Node.value p)) subpats

        UnConsPattern left right ->
            patternNames (Node.value left) ++ patternNames (Node.value right)

        ListPattern ps ->
            List.concatMap (\p -> patternNames (Node.value p)) ps

        TuplePattern ps ->
            List.concatMap (\p -> patternNames (Node.value p)) ps

        ParenthesizedPattern inner ->
            patternNames (Node.value inner)

        _ ->
            []


{-| Assign a stable id to each pattern binder, recording its value taint (the
pattern inherits the SCRUTINEE's taint — rule (e)).  Returns the (name, id)
list so the caller can extend a scope frame.
-}
bindPattern : Bool -> Node Pattern -> Walk -> ( List ( String, Int ), Walk )
bindPattern t (Node _ pat) walk =
    List.foldl
        (\name ( acc, w ) ->
            let
                id =
                    w.nextId
            in
            ( ( name, id ) :: acc
            , { w | taint = Dict.insert id t w.taint, nextId = id + 1 }
            )
        )
        ( [], walk )
        (patternNames pat)


bindersFrame : List ( String, Int ) -> Frame
bindersFrame binders =
    Dict.fromList (List.map (\( name, id ) -> ( name, RVal id )) binders)


paramFrame : List (Node Pattern) -> Frame
paramFrame params =
    Dict.fromList (List.map (\name -> ( name, RClean )) (List.concatMap (\p -> patternNames (Node.value p)) params))


paramNames : List (Node Pattern) -> List String
paramNames params =
    List.concatMap (\p -> patternNames (Node.value p)) params


letFnName : Function -> String
letFnName fn =
    Node.value (Node.value fn.declaration).name


letFnParams : Function -> List (Node Pattern)
letFnParams fn =
    (Node.value fn.declaration).arguments


letFnBody : Function -> Node Expression
letFnBody fn =
    (Node.value fn.declaration).expression


-- ============================== report ===================================


report : Static -> Dict Int Bool -> Dict Int Bool -> Result String ()
report static taint result =
    case firstViolation static taint result of
        Just ( name, range ) ->
            Err (renderError name range static.taintedKeys)

        Nothing ->
            Ok ()


firstViolation : Static -> Dict Int Bool -> Dict Int Bool -> Maybe ( String, Range )
firstViolation static taint result =
    List.foldl
        (\fi acc ->
            case acc of
                Just _ ->
                    acc

                Nothing ->
                    List.foldl
                        (\topFn a ->
                            case a of
                                Just _ ->
                                    a

                                Nothing ->
                                    -- A zero-argument binding is a value: its
                                    -- return taint IS its value taint.  An
                                    -- arity>0 function's return taint is resultTaint.
                                    if (if List.isEmpty topFn.params then
                                            getTaint taint topFn.id

                                        else
                                            getTaint result topFn.id
                                       )
                                    then
                                        Just ( topFn.name, topFn.range )

                                    else
                                        Nothing
                        )
                        Nothing
                        fi.fns
        )
        Nothing
        static.files


renderError : String -> Range -> Set String -> String
renderError name range taintedKeys =
    let
        keys =
            String.join ", " (Set.toList taintedKeys)
    in
    "taint error at "
        ++ String.fromInt range.start.row
        ++ ":"
        ++ String.fromInt range.start.column
        ++ ": the result of "
        ++ name
        ++ " may carry a mid-c value to its return (contract 4) — "
        ++ keys
        ++ " is !taint"
