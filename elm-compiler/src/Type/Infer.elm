module Type.Infer exposing ( inferUnit, CheckedUnit )

{-| Algorithm W over `Node Expression`/`Node Pattern`, reusing `Type.Unify`
state threading (`Uni.State{ subst, fresh }`).

This pass infers a type for every top-level function in a single module
(treated as ONE recursive group, order-independent), checks each body against
its signature (or a fresh mono variable for unsignatured definitions), and
EMITS the three surgical AST rewrites the lowerer needs:

  1. `a ++ b`  ->  `String.append a b` / `List.append a b`, chosen by zonking
     the site's `appendable` variable at the end of the declaration
     (still-flex -> `ambiguous (++)`).  `List.append` takes ANY element type.
  2. `Record.remove '<lit>' r`  ->  `Prelude.removeFieldImpl "<lit>" r`
     (the label literal is normalized to a `String`).
  3. `InsertionValue e`  ->  `e`  (an insertion setter RHS unwraps to its
     inner expression; insertion and update lower identically = prepend).

The rewritten `File` is returned so `Lower.Module.compileSources` (S6) can
lower it unchanged.

Name resolution mirrors `Lower.Expr` (local scope -> alias-table rows
first-match -> globals membership -> self-qualified fallback), sharing
`Lower.Module.aliasTableFor`/`exportedNames` so the two passes cannot drift.

Type aliases are transparent: a `TCon` whose name is a registered alias is
expanded (row-kind generics splice into row-tail positions via `zonk`).

This module is pure Elm (elm/core + elm-syntax + the Type.* modules + the
shared Lower.Module alias tables).

-}

import Set exposing (Set)
import Dict exposing (Dict)
import Type.Exhaustive as Exhaustive
import Elm.Syntax.Declaration as Declaration exposing (Declaration(..))
import Elm.Syntax.Expression as Expression exposing ( Expression(..), Function, Case, RecordSetter, LetDeclaration(..) )
import Elm.Syntax.File as File
import Elm.Syntax.Module as SyntaxModule
import Elm.Syntax.Node as Node exposing (Node(..))
import Elm.Syntax.Pattern as Pattern exposing (Pattern(..), QualifiedNameRef)
import Elm.Syntax.Range as Range exposing (Range)
import Lower.Expr as LowerExpr
import Lower.Resolve as LowerModule
import Type.Builtins as Builtins
import Type.Env as Env exposing (Scheme, Env)
import Type.Error as Error exposing (TypeError)
import Type.Representation as Rep exposing (Flex(..), Kind(..), Row, RowTail(..), Type(..), VarId)
import Type.Unify as Uni



-- ======================= PUBLIC API =======================


{-| A checked + rewritten unit: the rewritten `File` (ready to lower) and the
unit's value schemes (qualified `"Mod.name"` keys) for merging into the global
environment for downstream units.
-}
type alias CheckedUnit =
    { file : File.File
    , schemes : List ( String, Scheme )
    }


{-| Infer + rewrite one module. `env` is the MERGED environment (all units'
signatures, ADT constructors, and aliases — `Env.collectFile`/`Env.merge`);
it must already contain this unit's own signatures/ctors/aliases.
-}
inferUnit : Env -> File.File -> Result TypeError CheckedUnit
inferUnit env file =
    let
        self =
            moduleNameOf file

        selfStr =
            joinName self

        fnDecls =
            List.filterMap
                (\nd ->
                    case Node.value nd of
                        FunctionDeclaration _ ->
                            Just nd

                        _ ->
                            Nothing
                )
                file.declarations

        groups =
            groupFnDecls fnDecls

        names =
            List.map Tuple.first groups

        definedNames =
            names ++ ctorNames file.declarations

        exported =
            LowerModule.exportedNames file.moduleDefinition definedNames

        aliasTable =
            LowerModule.aliasTableFor self exported file.imports

        ( top, unsignatured, state0 ) =
            seedTop env selfStr names Uni.emptyState

        ctx =
            { self = self
            , env = env
            , envFree = Env.freeVarsOfEnv env
            , top = top
            , locals = []
            , aliasTable = aliasTable
            , moduleAliases = LowerModule.moduleAliasTable file.imports
            , openTypeModules = LowerModule.openTypeModules file.imports
            }

        refs name =
            refsOf self names groups name

        sccs =
            sccOrder names refs
    in
    -- Check the unit's top-level groups in DEPENDENCY order (SCCs), generalizing
    -- each non-recursive SCC before its dependents are checked — the authentic
    -- HM/Elm treatment (a helper used at many types, like `show`, must be
    -- polymorphic at its use sites; only mutually-recursive SCCs stay mono).
    checkSccs ctx unsignatured groups sccs { uni = state0, appends = [], refinedTargets = [], refinedTails = [], refinedTypeEqs = [], existentials = [], nonExhaustive = Nothing }
        |> Result.map
            (\( rewritten, finalTop, _ ) ->
                { file = rebuildFile rewritten file
                , schemes =
                    List.map (\( n, s ) -> ( selfStr ++ "." ++ n, s )) (Dict.toList finalTop)
                }
            )



-- ======================= INFERENCE MONAD =======================


{-| Inference state: the unification state (substitution + fresh counter) plus
the pending `++` sites accumulated while typing the current clause body.
`existentials` are the constructor-introduced EXISTENTIAL variable ids
instantiated rigid by the most recent pattern(s) — the branch-scope visitor
(see `inferCaseClause`) reads them per branch.
-}
type alias InferState =
    { uni : Uni.State
    , appends : List AppendSite
    , refinedTargets : List Int
    , refinedTails : List ( Int, Int )
    , refinedTypeEqs : List ( VarId, Type )
    , existentials : List Int
    , nonExhaustive : Maybe ( Range, String )
    }


{-| A pending `++` application: the `appendable` variable to zonk, the source
range of the `++` node, and its (un-rewritten) operand nodes.
-}
type alias AppendSite =
    { var : VarId
    , range : Range
    , left : Node Expression
    , right : Node Expression
    }


{-| A monadic action threading `InferState` and failing with a `TypeError`.
-}
type alias M a =
    InferState -> Result TypeError ( a, InferState )


emptyInferState : InferState
emptyInferState =
    { uni = Uni.emptyState, appends = [], refinedTargets = [], refinedTails = [], refinedTypeEqs = [], existentials = [], nonExhaustive = Nothing }


ok : a -> M a
ok a state =
    Ok ( a, state )


fail : TypeError -> M a
fail err _ =
    Err err


-- Flipped bind, so `m |> andThen (\a -> ...)` reads as `andThen (\a -> ...) m`.
andThen : (a -> M b) -> M a -> M b
andThen f m state =
    case m state of
        Err err ->
            Err err

        Ok ( a, state2 ) ->
            f a state2


{-| Alternation: on failure run the handler with the ORIGINAL state (the
failed action's partial effects are discarded — the retry starts from the
pre-action state). Used by the GADT result-discharge retry, which must not
inherit the failed attempt's bindings.
-}
orElse : (TypeError -> M a) -> M a -> M a
orElse handler m state =
    case m state of
        Err err ->
            handler err state

        Ok res ->
            Ok res


map : (a -> b) -> M a -> M b
map f m =
    andThen (\a -> ok (f a)) m


mapM : (a -> M b) -> List a -> M (List b)
mapM f xs =
    case xs of
        [] ->
            ok []

        x :: rest ->
            f x
                |> andThen (\b -> mapM f rest |> map (\bs -> b :: bs))


foldM : (a -> b -> M b) -> b -> List a -> M b
foldM f acc xs =
    case xs of
        [] ->
            ok acc

        x :: rest ->
            f x acc
                |> andThen (\acc2 -> foldM f acc2 rest)


fresh : Kind -> Flex -> M VarId
fresh kind flex state =
    let
        ( v, uni2 ) =
            Uni.freshVar kind flex state.uni
    in
    Ok ( v, { state | uni = uni2 } )


instantiate : Env -> Range -> Scheme -> M Type
instantiate env range scheme state =
    let
        ( t, uni2 ) =
            Env.instantiate scheme state.uni
    in
    case Env.expandAliases env t uni2 of
        Err msg ->
            Err (Error.atRange range msg "")

        Ok ( expanded, uni3 ) ->
            Ok ( expanded, { state | uni = uni3 } )


{-| Instantiate a constructor scheme for a PATTERN with its true existentials
rigid (see `Env.instantiateExistential` and `resolveCtorType`).
-}
instantiateExistential : Env -> Range -> Scheme -> List VarId -> M Type
instantiateExistential env range scheme determined state =
    let
        ( t, uni2 ) =
            Env.instantiateExistential determined scheme state.uni
    in
    case Env.expandAliases env t uni2 of
        Err msg ->
            Err (Error.atRange range msg "")

        Ok ( expanded, uni3 ) ->
            Ok ( expanded, { state | uni = uni3 } )


{-| Instantiate a signature scheme for checking the signatured function's own
body under OPTION-B: the `type <name>+ .`-bound quantifiers are skolemized
(rigid, locally abstract), the rest flexible. Reference sites keep using
`instantiate` (flexible) above; the "not more general" check in `inferClause`
restores soundness for the flexible ones.
-}
instantiatePartial : Env -> Range -> Scheme -> M Type
instantiatePartial env range scheme state =
    let
        ( t, uni2 ) =
            Env.instantiatePartial scheme state.uni
    in
    case Env.expandAliases env t uni2 of
        Err msg ->
            Err (Error.atRange range msg "")

        Ok ( expanded, uni3 ) ->
            Ok ( expanded, { state | uni = uni3 } )


zonkM : Type -> M Type
zonkM t state =
    Ok ( Rep.zonk state.uni.subst t, state )


unifyM : Range -> Type -> Type -> M ()
unifyM range t1 t2 state =
    case Uni.unify state.uni t1 t2 of
        Err err ->
            Err (Error.atRange range (Uni.describe err) "")

        Ok uni2 ->
            Ok ( (), { state | uni = uni2 } )


{-| Unify at a BODY-INFERENCE use site (function application, if-join, list
element, operator argument): like `unifyM`, but on a RIGID-vs-concrete failure
consults the branch's equation store — a matching TYPE equation (the branch's
witness refinement, e.g. `a ~ Int` from matching `WInt`) licenses the use of
an already-bound `x : a` at the recovered type (one-way zonk through the
equation, never a binding; the equation still dies at branch end). This is
the variable-USE discharge, generalising the record-selection site; nothing
is bound, so a use can never leak the refinement out of the branch.
-}
unifyUseM : Range -> Type -> Type -> M ()
unifyUseM range t1 t2 state =
    let
        -- Zonk BOTH sides first: the rigid variable the error names may only
        -- appear after resolving the substitution (an argument's type is a
        -- FRESH id bound to the signature's rigid var), so the discharge
        -- replacement below must operate on the resolved forms or it misses
        -- the target and re-unifies into the same rigid conflict.
        zt1 =
            Rep.zonk state.uni.subst t1

        zt2 =
            Rep.zonk state.uni.subst t2
    in
    case Uni.unify state.uni zt1 zt2 of
        Ok uni2 ->
            Ok ( (), { state | uni = uni2 } )

        Err (Uni.RigidVar a t) ->
            case Uni.dischargeType state.uni a of
                Just ( target, body ) ->
                    if Rep.occurs target body then
                        Err (Error.atRange range (Uni.describe (Uni.RigidVar a t)) "")

                    else
                        case Uni.unify state.uni (replaceVar target.id body zt1) (replaceVar target.id body zt2) of
                            Ok uni2 ->
                                Ok ( (), { state | uni = uni2 } )

                            Err err2 ->
                                case err2 of
                                    Uni.RigidVar b2 _ ->
                                        if b2.id /= a.id then
                                            unifyUseM range (replaceVar target.id body zt1) (replaceVar target.id body zt2) state

                                        else
                                            Err (Error.atRange range (Uni.describe err2) "")

                                    _ ->
                                        Err (Error.atRange range (Uni.describe err2) "")

                Nothing ->
                    Err (Error.atRange range (Uni.describe (Uni.RigidVar a t)) "")

        Err err ->
            Err (Error.atRange range (Uni.describe err) "")


{-| Unify, but on the RIGID-ROW failure consult the branch's equation store:
if some equation explains the base row (zonked through ONCE) as exposing the
wanted label, the selection is licensed by the branch's local refinement —
return the discharged element type instead of failing. This is the row
discharge rule; nothing is bound.
-}
unifyMOrDischarge : Range -> Type -> String -> Type -> M ()
unifyMOrDischarge range base field wanted state =
    case Uni.unify state.uni base wanted of
        Ok uni2 ->
            Ok ( (), { state | uni = uni2 } )

        Err (Uni.RigidVar a t) ->
            case Uni.dischargeRow state.uni a field of
                Just ( t2, _ ) ->
                    -- The equation exposes the field; tie the site's fresh
                    -- element var to the discharged type instead.
                    case Uni.unify state.uni (TVar (elemVarOfWanted wanted)) t2 of
                        Ok uni2 ->
                            Ok ( (), { state | uni = uni2 } )

                        Err err ->
                            Err (Error.atRange range (Uni.describe err) "")

                Nothing ->
                    Err (Error.atRange range (Uni.describe (Uni.RigidVar a t)) "")

        Err err ->
            Err (Error.atRange range (Uni.describe err) "")


elemVarOfWanted : Type -> VarId
elemVarOfWanted wanted =
    case wanted of
        TRecord rec ->
            case rec.fields of
                [ ( _, TVar v ) ] ->
                    v

                _ ->
                    Rep.var (-1) KType FNone

        _ ->
            Rep.var (-1) KType FNone


recordAppend : AppendSite -> M ()
recordAppend site state =
    Ok ( (), { state | appends = site :: state.appends } )


resetAppends : M ()
resetAppends state =
    Ok ( (), { state | appends = [] } )



-- ======================= CONTEXT & RESOLUTION =======================


{-| The checking context: the current module name, the merged environment, the
unit's own top-level bindings (bare name -> scheme, seeded up front), the local
scope (innermost first), and the shared alias table.
-}
type alias Ctx =
    { self : List String
    , env : Env
    , envFree : List VarId
    , top : Dict String Scheme
    , locals : List ( String, Scheme )
    , aliasTable : List ( String, String )
    , moduleAliases : List ( String, String )
    , openTypeModules : List (List String)
    }


lookupLocal : String -> List ( String, Scheme ) -> Maybe Scheme
lookupLocal name locals =
    case locals of
        [] ->
            Nothing

        ( n, s ) :: rest ->
            if n == name then
                Just s

            else
                lookupLocal name rest


{-| Resolve a (possibly qualified) value/constructor reference to its scheme,
mirroring `Lower.Expr`'s resolution order. `Nothing` = unknown name.
-}
resolveScheme : Ctx -> List String -> String -> Maybe Scheme
resolveScheme ctx modName name =
    if List.isEmpty modName then
        case lookupLocal name ctx.locals of
            Just s ->
                Just s

            Nothing ->
                case Dict.get name ctx.top of
                    Just s ->
                        Just s

                    Nothing ->
                        case resolveTokenScheme ctx name of
                            Just s ->
                                Just s

                            Nothing ->
                                resolveOpenCtor name ctx

    else if modName == ctx.self then
        -- Self-qualified reference: resolves to the unit's own TOP-LEVEL
        -- binding (like a bare name, but a local `SelfQual.x` is not allowed
        -- to reach a let-bound x).  Check the top group first — an
        -- unsignatured self function lives there, not in the env.
        case Dict.get name ctx.top of
            Just s ->
                Just s

            Nothing ->
                resolveGlobalScheme (joinName (ctx.self ++ [ name ])) ctx

    else
        resolveTokenScheme ctx (LowerExpr.resolveModuleAlias ctx.moduleAliases (joinName (modName ++ [ name ])))


resolveTokenScheme : Ctx -> String -> Maybe Scheme
resolveTokenScheme ctx token =
    case resolveImport token ctx.aliasTable of
        Just key ->
            resolveGlobalScheme key ctx

        Nothing ->
            case resolveGlobalScheme token ctx of
                Just s ->
                    Just s

                Nothing ->
                    resolveGlobalScheme (joinName (ctx.self ++ [ token ])) ctx


resolveGlobalScheme : String -> Ctx -> Maybe Scheme
resolveGlobalScheme key ctx =
    case Builtins.lookupValue key of
        Just s ->
            Just s

        Nothing ->
            Env.lookupValue key ctx.env


{-| `T(..)` imports put the type's constructors in scope as bare names; try
`M.name` against the env for each such module (see Lower.Resolve.openTypeModules).
-}
resolveOpenCtor : String -> Ctx -> Maybe Scheme
resolveOpenCtor name ctx =
    case ctx.openTypeModules of
        [] ->
            Nothing

        m :: rest ->
            case resolveGlobalScheme (joinName (m ++ [ name ])) ctx of
                Just s ->
                    Just s

                Nothing ->
                    resolveOpenCtor name { ctx | openTypeModules = rest }


resolveImport : String -> List ( String, String ) -> Maybe String
resolveImport name rows =
    case rows of
        [] ->
            Nothing

        ( alias, target ) :: rest ->
            if alias == name then
                Just target

            else
                resolveImport name rest


{-| Resolve + instantiate a value/constructor reference to a mono type.
-}
resolveValue : Ctx -> Range -> List String -> String -> M Type
resolveValue ctx range modName name =
    if List.isEmpty modName && (name == "True" || name == "False") then
        ok Rep.tBool

    else if modName == [ "Record" ] && name == "remove" then
        -- `Record.remove` only typechecks through the magic 2-argument literal
        -- surface in `inferExpr`; used as a value or partially applied it is
        -- not in `Builtins.valueTable`, so give a clear diagnostic instead of
        -- the misleading "unknown name: Record.remove".
        fail (Error.atRange range "Record.remove must be fully applied with a literal field name" "")

    else
        case resolveScheme ctx modName name of
            Just scheme ->
                instantiate ctx.env range scheme

            Nothing ->
                fail (Error.atRange range ("unknown name: " ++ joinName (modName ++ [ name ])) "")


{-| The scheme of an operator used as a value (`(+)`, `(++)`, ...).
-}
resolveOperator : Env -> Range -> String -> M Type
resolveOperator env range op =
    case Builtins.operatorScheme op of
        Just scheme ->
            instantiate env range scheme

        Nothing ->
            fail (Error.atRange range ("unsupported operator: " ++ op) "")


{-| Free variables of the enclosing environment (globals + top-level group +
locals) — the rigid set for let-generalization.
-}
scopeFreeVars : Ctx -> List VarId
scopeFreeVars ctx =
    -- `ctx.envFree` is the free variables of the merged environment, computed
    -- ONCE per unit (they are fixed during a unit's checking) — recomputing
    -- them per let-binding over the ~4KLOC core-libs corpus was the S5
    -- deferred hot spot.
    dedupeIds
        (ctx.envFree
            ++ List.concatMap (\( _, s ) -> Env.freeVarsOfScheme s) ctx.locals
            ++ List.concatMap Env.freeVarsOfScheme (Dict.values ctx.top)
        )



-- ======================= EXPRESSIONS =======================


inferExpr : Ctx -> Node Expression -> M Type
inferExpr ctx (Node range expr) =
    case expr of
        UnitExpr ->
            ok Rep.tUnit

        Integer _ ->
            fresh KType FNumber |> map TVar

        Hex _ ->
            fresh KType FNumber |> map TVar

        Floatable _ ->
            ok Rep.tFloat

        Literal _ ->
            ok Rep.tString

        CharLiteral _ ->
            ok Rep.tChar

        FunctionOrValue modName name ->
            resolveValue ctx range modName name

        PrefixOperator op ->
            resolveOperator ctx.env range op

        Operator op ->
            resolveOperator ctx.env range op

        Negation inner ->
            fresh KType FNumber
                |> andThen (\n ->
                    inferExpr ctx inner
                        |> andThen (\it ->
                            unifyUseM range it (TVar n)
                                |> map (\_ -> TVar n)
                        )
                )

        ParenthesizedExpression inner ->
            inferExpr ctx inner

        Application nodes ->
            case nodes of
                [] ->
                    fail (Error.atRange range "empty application" "")

                head :: args ->
                    if isRecordRemove head args then
                        inferRecordRemove ctx range args

                    else
                        inferExpr ctx head
                            |> andThen (\ft ->
                                inferExprs ctx args
                                    |> andThen (\argTypes -> applyTypes range ft argTypes)
                            )

        OperatorApplication op _ left right ->
            if op == "++" then
                inferAppend ctx range left right

            else
                resolveOperator ctx.env range op
                    |> andThen (\opType ->
                        inferExpr ctx left
                            |> andThen (\lt ->
                                inferExpr ctx right
                                    |> andThen (\rt -> applyTypes range opType [ lt, rt ])
                            )
                    )

        IfBlock c t e ->
            inferExpr ctx c
                |> andThen (\ct ->
                    unifyM range ct Rep.tBool
                        |> andThen (\_ ->
                            inferExpr ctx t
                                |> andThen (\tt ->
                                    inferExpr ctx e
                                        |> andThen (\te ->
                                            unifyUseM range tt te |> map (\_ -> tt)
                                        )
                                )
                        )
                )

        LambdaExpression lam ->
            inferPatterns False ctx lam.args
                |> andThen (\( argTypes, binds ) ->
                    inferExpr { ctx | locals = binds ++ ctx.locals } lam.expression
                        |> map (\bt -> List.foldr TFun bt argTypes)
                )

        LetExpression block ->
            inferLet ctx block.declarations
                |> andThen (\ctx2 -> inferExpr ctx2 block.expression)

        CaseExpression block ->
            inferExpr ctx block.expression
                |> andThen (\st ->
                    zonkM st
                        |> andThen (\stZ0 ->
                            fresh KType FNone
                                |> andThen (\resultVar ->
                                    mapM (inferCaseClause ctx stZ0 st (TVar resultVar)) block.cases
                                        |> andThen (\pts ->
                                            requireExhaustive ctx range st pts (List.map Tuple.first block.cases)
                                                |> map (\_ -> TVar resultVar)
                                        )
                                )
                        )
                )

        RecordExpr setters ->
            foldM
                (\setter fields ->
                    inferExpr ctx (setterValue setter)
                        |> map (\t -> fields ++ [ ( nodeString (setterField setter), t ) ])
                )
                []
                setters
                |> map (\fields -> TRecord { fields = fields, tail = REmpty })

        ListExpr xs ->
            fresh KType FNone
                |> andThen (\elem ->
                    inferExprs ctx xs
                        |> andThen (\ts ->
                            foldM (\( xr, t ) _ -> unifyUseM (Node.range xr) t (TVar elem)) ()
                                (List.map2 Tuple.pair xs ts)
                                |> map (\_ -> Rep.tList (TVar elem))
                        )
                )

        TupledExpression xs ->
            inferExprs ctx xs |> map TTuple

        RecordAccess rec nameNode ->
            inferExpr ctx rec
                |> andThen (\rt ->
                    fresh KType FNone
                        |> andThen (\a ->
                            fresh KRow FNone
                                |> andThen (\beta ->
                                    let
                                        field =
                                            nodeString nameNode
                                    in
                                    -- Selection through a RIGID row tail (e.g.
                                    -- `{ rho | m : t }.l` under a GADT refinement
                                    -- `rho ~ {l:t|rho'}`): before failing, consult
                                    -- the branch's equation store and zonk
                                    -- through ONE matching equation (no binding).
                                    unifyMOrDischarge range rt field
                                        (TRecord { fields = [ ( field, TVar a ) ], tail = RVar beta })
                                        |> map (\_ -> TVar a)
                                )
                        )
                )

        RecordAccessFunction name ->
            let
                field =
                    String.dropLeft 1 name
            in
            fresh KType FNone
                |> andThen (\a ->
                    fresh KRow FNone
                        |> map (\beta ->
                            TFun (TRecord { fields = [ ( field, TVar a ) ], tail = RVar beta }) (TVar a)
                        )
                )

        RecordUpdateExpression baseNode setters ->
            let
                baseName =
                    nodeString baseNode
            in
            case lookupLocal baseName ctx.locals of
                Nothing ->
                    fail (Error.atNode baseNode "record update base must be a local variable" ("cannot update " ++ baseName))

                Just scheme ->
                    instantiate ctx.env (Node.range baseNode) scheme
                        |> andThen (\baseType -> inferSetters ctx baseType setters)

        InsertionValue inner ->
            inferExpr ctx inner

        GLSLExpression _ ->
            fail (Error.atRange range "GLSL is not supported" "")


inferExprs : Ctx -> List (Node Expression) -> M (List Type)
inferExprs ctx nodes =
    mapM (inferExpr ctx) nodes


{-| Apply a function type to argument types by peeling one `TFun` per argument
(with a fresh result variable between steps).  Applying a CONCRETE non-function
to an argument is the arity error; a type variable still unifies against a
fresh `TFun` (an occurs check rejects the infinite `5 3` case).
-}
applyTypes : Range -> Type -> List Type -> M Type
applyTypes range fn args =
    case args of
        [] ->
            ok fn

        a :: rest ->
            zonkM fn
                |> andThen
                    (\zfn ->
                        case zfn of
                            TVar _ ->
                                applyStep range zfn a rest

                            TFun _ _ ->
                                applyStep range zfn a rest

                            _ ->
                                fail (Error.atRange range "apply non-function" ("cannot apply " ++ Rep.pretty zfn ++ " to an argument"))
                    )


applyStep : Range -> Type -> Type -> List Type -> M Type
applyStep range fn a rest =
    fresh KType FNone
        |> andThen (\res ->
            unifyUseM range fn (TFun a (TVar res))
                |> andThen (\_ -> applyTypes range (TVar res) rest)
        )


inferAppend : Ctx -> Range -> Node Expression -> Node Expression -> M Type
inferAppend ctx range left right =
    fresh KType FAppendable
        |> andThen (\a ->
            inferExpr ctx left
                |> andThen (\lt ->
                    inferExpr ctx right
                        |> andThen (\rt ->
                            unifyM range lt (TVar a)
                                |> andThen (\_ ->
                                    unifyM range rt (TVar a)
                                        |> andThen (\_ ->
                                            recordAppend { var = a, range = range, left = left, right = right }
                                                |> map (\_ -> TVar a)
                                        )
                                )
                        )
                )
        )


{-| Is this application the magic `Record.remove <lit> r` surface?
-}
isRecordRemove : Node Expression -> List (Node Expression) -> Bool
isRecordRemove head args =
    case ( Node.value head, args ) of
        ( FunctionOrValue [ "Record" ] "remove", [ labelNode, _ ] ) ->
            case Node.value labelNode of
                Literal _ ->
                    True

                CharLiteral _ ->
                    True

                _ ->
                    False

        _ ->
            False


inferRecordRemove : Ctx -> Range -> List (Node Expression) -> M Type
inferRecordRemove ctx range args =
    case args of
        [ labelNode, recNode ] ->
            case labelString labelNode of
                Nothing ->
                    fail (Error.atRange range "Record.remove requires a literal field name" "")

                Just l ->
                    inferExpr ctx recNode
                        |> andThen (\rt ->
                            zonkM rt
                                |> andThen
                                    (\zrt ->
                                        case zrt of
                                            TRecord row ->
                                                case restrictField l row of
                                                    Nothing ->
                                                        fail (Error.atNode labelNode ("record does not have field " ++ l) "")

                                                    Just ( _, remainder ) ->
                                                        ok (TRecord remainder)

                                            _ ->
                                                fail (Error.atNode recNode "Record.remove expects a record" "")
                                    )
                        )

        _ ->
            fail (Error.atRange range "Record.remove expects a field and a record" "")


labelString : Node Expression -> Maybe String
labelString (Node _ e) =
    case e of
        Literal s ->
            Just s

        CharLiteral c ->
            Just (String.fromChar c)

        _ ->
            Nothing


{-| Infer a record update/insertion's setters sequentially.  An `InsertionValue`
RHS is a free extension (may duplicate); any other RHS is an update
(restrict+extend: the label MUST already exist).
-}
inferSetters : Ctx -> Type -> List (Node RecordSetter) -> M Type
inferSetters ctx baseType setters =
    case setters of
        [] ->
            ok baseType

        setter :: rest ->
            inferSetter ctx baseType setter
                |> andThen (\newBase -> inferSetters ctx newBase rest)


inferSetter : Ctx -> Type -> Node RecordSetter -> M Type
inferSetter ctx baseType (Node r ( fieldNode, valNode )) =
    let
        f =
            nodeString fieldNode
    in
    case Node.value valNode of
        InsertionValue inner ->
            inferExpr ctx inner
                |> andThen (\tv ->
                    zonkM baseType
                        |> andThen (\zb ->
                            -- INSERTION is shape-CHANGING: under a branch's
                            -- row refinement the inserted label would extend
                            -- the refined row beyond what the equation (and
                            -- the branch-local discharge discipline) license.
                            -- The store must NOT be consulted (the conjecture's
                            -- boundary case): reject explicitly.
                            refinedTailVarM zb
                                |> andThen (\maybe ->
                                    case maybe of
                                        Just a ->
                                            fail (Error.atNode fieldNode
                                                ("insertion under rigid row refinement: cannot insert "
                                                    ++ f
                                                    ++ " while "
                                                    ++ Rep.pretty (TVar a)
                                                    ++ " is refined by this branch"
                                                )
                                                ""
                                            )

                                        Nothing ->
                                            ensureRecordForInsert r zb
                                                |> map (\row -> TRecord { fields = ( f, tv ) :: row.fields, tail = row.tail })
                                )
                        )
                )

        _ ->
            inferExpr ctx valNode
                |> andThen (\tv ->
                    zonkM baseType
                        |> andThen
                            (\zb ->
                                case zb of
                                    TRecord row ->
                                        case restrictField f row of
                                            Nothing ->
                                                -- R-UPD discharge: the label may
                                                -- be present only through the
                                                -- branch's refinement equation;
                                                -- zonk through it ONCE (no
                                                -- binding) and update in place
                                                -- on the discharged shape.
                                                dischargeSetterM fieldNode r f row tv

                                            Just ( oldT, remainder ) ->
                                                unifyM r tv oldT
                                                    |> map (\_ -> TRecord { fields = ( f, tv ) :: remainder.fields, tail = remainder.tail })

                                    -- An unbound base variable is constrained to
                                    -- carry the field (Elm's own behavior for
                                    -- `{ p | x = v }` with a fresh `p`).
                                    TVar v ->
                                        fresh KType FNone
                                            |> andThen (\tf ->
                                                fresh KRow FNone
                                                    |> andThen (\beta ->
                                                        unifyM r (TVar v) (TRecord { fields = [ ( f, TVar tf ) ], tail = RVar beta })
                                                            |> andThen (\_ ->
                                                                unifyM r tv (TVar tf)
                                                                    |> map (\_ -> TRecord { fields = [ ( f, tv ) ], tail = RVar beta })
                                                            )
                                                    )
                                            )

                                    _ ->
                                        fail (Error.atNode valNode "expected a record for update" "")
                            )
                )


{-| The update-setter discharge: `restrictField` failed on the KNOWN fields,
but the branch's store may explain the base's rigid tail as exposing `f`.
Zonk through ONE matching equation and update in place on the discharged
shape (shape-preserving: same domain, the equation licenses reading it).
Still fails when no equation exposes `f`.
-}
dischargeSetterM : Node String -> Range -> String -> Row -> Type -> M Type
dischargeSetterM fieldNode r f row tv state =
    let
        missing =
            fail (Error.atNode fieldNode ("record does not have field " ++ f) "") state
    in
    case rowTailVar row of
        Just a ->
            case Uni.dischargeRow state.uni a f of
                Just ( oldT, remainder ) ->
                    case unifyM r tv oldT state of
                        Err err ->
                            Err err

                        Ok ( (), state2 ) ->
                            Ok ( TRecord { fields = ( f, tv ) :: row.fields ++ remainder.fields, tail = remainder.tail }, state2 )

                Nothing ->
                    missing

        Nothing ->
            missing


{-| The row tail variable of a record, if it is a variable at all.
-}
rowTailVar : Row -> Maybe VarId
rowTailVar row =
    case row.tail of
        RVar a ->
            Just a

        REmpty ->
            Nothing


{-| Does this (zonked) base type mention a row tail that the CURRENT branch
refines? Used by the insertion rejection.
-}
refinedTailVarM : Type -> M (Maybe VarId)
refinedTailVarM zb state =
    case zb of
        TRecord row ->
            case rowTailVar row of
                Just a ->
                    if List.any (\eq -> eq.target.id == a.id) state.uni.eqs then
                        Ok ( Just a, state )

                    else
                        Ok ( Nothing, state )

                Nothing ->
                    Ok ( Nothing, state )

        _ ->
            Ok ( Nothing, state )


{-| Ensure a base is a record for INSERTION; an unbound type variable becomes
an open empty record (`{ | beta }`), a concrete record passes through.
-}
ensureRecordForInsert : Range -> Type -> M Row
ensureRecordForInsert range t =
    case t of
        TRecord row ->
            ok row

        TVar v ->
            fresh KRow FNone
                |> andThen (\beta ->
                    let
                        emptyRecord =
                            TRecord { fields = [], tail = RVar beta }
                    in
                    unifyM range (TVar v) emptyRecord
                        |> map (\_ -> { fields = [], tail = RVar beta })
                )

        _ ->
            fail (Error.atRange range "expected a record for insertion" "")


{-| The paper's `restrict`: remove the FIRST concrete occurrence of `l`,
returning its type and the remainder row (inner duplicates are kept).
`Nothing` means `l` is not a concrete field (scoped labels forbid removing an
unknown/tail-only field).
-}
restrictField : String -> Row -> Maybe ( Type, Row )
restrictField l row =
    case row.fields of
        [] ->
            Nothing

        ( l2, t ) :: rest ->
            if l2 == l then
                Just ( t, { fields = rest, tail = row.tail } )

            else
                restrictField l { fields = rest, tail = row.tail }
                    |> Maybe.map
                        (\( ft, remainder ) ->
                            ( ft, { fields = ( l2, t ) :: remainder.fields, tail = remainder.tail } )
                        )


setterField : Node RecordSetter -> Node String
setterField (Node _ ( f, _ )) =
    f


setterValue : Node RecordSetter -> Node Expression
setterValue (Node _ ( _, v )) =
    v



-- ======================= LET =======================


inferLet : Ctx -> List (Node LetDeclaration) -> M Ctx
inferLet ctx decls =
    case decls of
        [] ->
            ok ctx

        d :: rest ->
            inferLetDecl ctx d
                |> andThen (\ctx2 -> inferLet ctx2 rest)


inferLetDecl : Ctx -> Node LetDeclaration -> M Ctx
inferLetDecl ctx (Node _ decl) =
    case decl of
        LetFunction fn ->
            inferLetFunction ctx fn
                |> map (\scheme -> { ctx | locals = ( fnName fn, scheme ) :: ctx.locals })

        LetDestructuring patNode eNode ->
            inferExpr ctx eNode
                |> andThen (\et ->
                    inferPattern False ctx patNode
                        |> andThen (\( binds, pt ) ->
                            unifyM (Node.range patNode) pt et
                                |> andThen
                                    (\_ state ->
                                        generalizeBinds (generalizationRigid ctx state) binds state
                                            |> Result.map (\( gens, state2 ) -> ( { ctx | locals = gens ++ ctx.locals }, state2 ))
                                    )
                        )
                )

inferLetFunction : Ctx -> Function -> M Scheme
inferLetFunction ctx fn =
    let
        impl =
            Node.value fn.declaration
    in
    inferPatterns False ctx impl.arguments
        |> andThen (\( argTypes, binds ) ->
            inferExpr { ctx | locals = binds ++ ctx.locals } impl.expression
                |> andThen
                    (\bt ->
                        zonkM (List.foldr TFun bt argTypes)
                            |> andThen (\zt state -> ok (generalizeLet (generalizationRigid ctx state) zt) state)
                    )
        )


{-| Generalize a list of destructuring binds.  Each bind's body is ZONKED first:
a pattern variable bound to a CLOSED type (e.g. `let y = h x` with a concrete
record result) would otherwise still look like a free `TVar` (bound in the
substitution) to `freeVars`, get quantified, and re-instantiate to a FRESH var —
losing the concrete record and making a later `{ y | f = ... }` update fail with
"record does not have field f".  Zonking first turns such a body into the closed
record, whose free-variable set is empty, so nothing is quantified.
-}
generalizeBinds : List Int -> List ( String, Scheme ) -> M (List ( String, Scheme ))
generalizeBinds rigid binds =
    case binds of
        [] ->
            ok []

        ( n, s ) :: rest ->
            zonkM s.body
                |> andThen (\zt -> generalizeBinds rigid rest |> map (\gens -> ( n, generalizeLet rigid zt ) :: gens))


{-| Let-generalization: quantify the free variables of `t` that are not rigid
in the enclosing environment AND are not `appendable` (the zonk exception — an
`appendable` variable stays shared so it can be resolved at the enclosing
declaration's end-of-declaration zonk).
-}
generalizeLet : List Int -> Type -> Scheme
generalizeLet rigid t =
    { quantifiers =
        Env.freeVars t
            |> List.filter (\v -> not (List.member v.id rigid) && v.flex /= FAppendable)
    , body = t
    , bound = []
    }


{-| The variables let-generalization must NOT quantify: the enclosing scope's
free variables PLUS every variable a branch-local equation is currently
refining. The equation's TAIL is the crucial one: it is a FLEXIBLE variable
that is a proper sub-row of the equation's rigid head, so quantifying it in a
`let` would let the binding be re-instantiated at the head's row and the tail
escape its branch — the `escapeViaTail` check sees only the direct tail, so the
laundered (fresh) variable slips past it (the let-laundering counterexample).
Heads and refined targets are included too (harmless: heads are signature
skolems already in `scopeFreeVars`; targets are the KType equation subjects).
-}
generalizationRigid : Ctx -> InferState -> List Int
generalizationRigid ctx state =
    dedupeInts
        (List.map .id (scopeFreeVars ctx)
            ++ state.refinedTargets
            ++ List.concatMap (\( h, t ) -> [ h, t ]) state.refinedTails
            -- The KType equation BODIES' free variables (the determined field
            -- vars): a `let` inside the branch must not generalize them, or the
            -- binding launders the field var away from the equation and the
            -- occurs check can no longer see `a ~ List a_field` reach `List a`.
            -- This is the KType mirror of the row-tail laundering guard above.
            ++ List.concatMap (\( _, body ) -> List.map .id (Env.freeVars body)) state.refinedTypeEqs
        )



-- ======================= CASE =======================


inferCaseClause : Ctx -> Type -> Type -> Type -> Case -> M Type
inferCaseClause ctx scrutinee0 scrutineeType resultType ( patNode, bodyNode ) =
    -- BRANCH-LOCAL REFINEMENT: unify the pattern type against the scrutinee in
    -- BRANCH mode (would-be rigid bindings become delayed equations on the
    -- store), infer the body with those equations visible (the discharge sites
    -- consult them), then roll the store back to the pre-branch snapshot so
    -- nothing global binds — each case branch refines only itself.
    --
    -- The snapshot is taken BEFORE pattern inference: a NESTED constructor's
    -- sub-pattern unification now also runs in branch mode (see `peelCtor`), so
    -- the equations it pushes are captured by this same snapshot and dropped at
    -- branch end — a nested `Then prev Unlock` refines the outer ctor's
    -- existential branch-locally, exactly like the top-level unify below.
    --
    -- WITNESS REFINEMENT AT VARIABLE USES (the `a` of a rigid index, e.g.
    -- `Witness a`): a signature index variable that this branch's pattern
    -- RESULT fixes to a NON-VARIABLE type (WInt -> a ~ Int) is LIFTED to rigid
    -- for the branch's duration (and restored after), so the equation
    -- `a ~ Int` is CAPTURED by the branch unify below instead of binding `a`
    -- globally through the global path — sibling branches may then fix `a`
    -- differently. The lift is targeted: only variables free in the scrutinee
    -- type that the ctor result equates to a concrete (non-variable) type are
    -- lifted, and only inside this branch.
    snapshotEqsM
        |> andThen
            (\snapshot ->
                inferPattern True ctx patNode
                    |> andThen
                        (\( binds, pt ) ->
                            branchExistentialsM
                                |> andThen
                                    (\branchExistentials ->
                                        liftRefinedIndicesM scrutinee0 pt
                                            |> andThen (\lifted ->
                                                unifyBranchM (Node.range patNode) pt scrutineeType
                                                    |> andThen (\_ ->
                                                        captureUniM
                                                            |> andThen (\postPatternUni ->
                                                                inferExpr { ctx | locals = binds ++ ctx.locals } bodyNode
                                                                    |> andThen (\bt ->
                                                                        unifyResultM postPatternUni (Node.range bodyNode) bt resultType
                                                                            |> andThen (\_ -> restoreEqsM snapshot)
                                                                            |> andThen (\_ -> unliftRigidM lifted)
                                                                            |> andThen (\_ -> restoreExistentialsM branchExistentials)
                                                                            |> andThen (\_ -> zonkM pt)
                                                                    )
                                                            )
                                                    )
                                            )
                                    )
                        )
            )


{-| The branch's own constructor-introduced existentials: the ids recorded by
`resolveCtorType` while inferring THIS branch's pattern (the pending list
carries them once the pattern is inferred; a pattern without ctor existentials
records nothing new).
-}
branchExistentialsM : M (List Int)
branchExistentialsM state =
    Ok ( state.existentials, state )


{-| Collect (variable, non-variable) pairs from two ctor-shaped types' parallel
argument lists: a type variable on one side and a concrete type on the other is
a potential index refinement (`Witness a` vs `Witness Int` gives `(a, Int)`).
Top-level (not a local `let`) because the self-hosted checker does not resolve
LOCAL recursive bindings — and this one recurses on nested `TCon` arguments.
-}
argPairs : Type -> Type -> List ( Type, Type )
argPairs t1 t2 =
    case ( t1, t2 ) of
        ( TCon n1 a1, TCon n2 a2 ) ->
            if n1 == n2 then
                List.concatMap (\( x, y ) -> argPairs x y) (List.map2 Tuple.pair a1 a2)

            else
                []

        _ ->
            if isVarType t1 then
                [ ( t1, t2 ) ]

            else if isVarType t2 then
                [ ( t2, t1 ) ]

            else
                []


isVarType : Type -> Bool
isVarType t =
    case t of
        TVar _ ->
            True

        _ ->
            False


{-| The scrutinee type's free variables that the pattern's ctor RESULT fixes
to a non-variable type: e.g. scrutinee `Witness a` with pattern `WInt` (ctor
result `Witness Int`) equates `a ~ Int`. Only these are lifted to rigid —
the targeted set for the branch scope. Returns the lifted ids (for restore).

`scrutinee0` is the scrutinee ZONKED AT CASE START (before any branch's
pattern inference), NOT re-zonked per branch. That is the whole point: an
earlier branch's pattern unification may bind a PATTERN-INTRODUCED variable
into the scrutinee (`x := Maybe c1` from the `Nothing` arm), which the
per-branch zonk would then mistake for a signature index. Lifting such a
variable captures `c1 ~ (a,b)` as a dropped equation, leaving the scrutinee
`Maybe c1` dangling and every `Just (a,b)` arm reported non-exhaustive.
The case-start snapshot has no pattern-introduced variables in it, so only
the enclosing signature's index variables are liftable.
-}
liftRefinedIndicesM : Type -> Type -> M (List Int)
liftRefinedIndicesM scrutinee0 pt state =
    case scrutinee0 of
        TVar _ ->
            -- BARE-variable scrutinee (an unsignatured lambda/case scrutinee
            -- whose type is still a fresh variable): there is NO enclosing
            -- signature index to protect. Lifting the var and then dropping
            -- its branch equation would leave it UNBOUND at branch end, so the
            -- function over-generalises to `forall a. a -> r` (the CE-2
            -- counterexample: `f x = case x of A -> 1` then `f B` compiles
            -- clean and crashes), and `requireExhaustive`'s `mostResolved`
            -- fallback would then concretise to the single arm's index and
            -- wrongly refute the siblings. Leave the var FLEXIBLE: the pattern
            -- unify below binds it globally (`f : Tag Int -> r`), and the
            -- exhaustiveness check sees the concrete index.
            Ok ( [], state )

        zScrutinee ->
            let
                scrutineeVars =
                    -- ONLY variables free in the (case-start-zonked) SCRUTINEE
                    -- type are liftable: they are the enclosing signature's index
                    -- variables (w1's `Witness a`), whose branch-local refinement
                    -- must not bind globally. A PATTERN-fresh variable (the ctor
                    -- scheme's own instantiation, e.g. `Just exponent`'s `a` under
                    -- a CONCRETE scrutinee `Maybe Int`) is NOT lifted — it must
                    -- stay flexible and bind normally, because rigidifying it
                    -- would turn every later `number`/`comparable` unification
                    -- against it into a FlexConflict (the constraint discipline
                    -- for genuine skolems, wrong for an ordinary ADT payload).
                    Env.freeVars zScrutinee
            in
            case argPairs zScrutinee (Rep.zonk state.uni.subst pt) of
                [] ->
                    Ok ( [], state )

                pairs ->
                    let
                        liftOne scrutVar bound acc =
                            case ( scrutVar, bound ) of
                                ( TVar v, _ ) ->
                                    if
                                        v.flex == FNone
                                            && not (Uni.isRigid state.uni v)
                                            -- The var must be the SIGNATURE's index
                                            -- (free in the scrutinee), not the
                                            -- pattern's fresh instantiation.
                                            && memberById v.id scrutineeVars
                                    then
                                        v.id :: acc

                                    else
                                        acc

                                _ ->
                                    acc

                        lifted =
                            List.foldl (\( x, y ) acc -> if isVarType y then acc else liftOne x y acc) [] pairs
                    in
                    -- Mark lifted ids rigid and remember them for restore. The
                    -- branch unify below then CAPTURES their binding as an equation
                    -- (branch mode) instead of binding through the global path.
                    Ok
                        ( lifted
                        , { state
                            | uni =
                                List.foldl (\id_ st -> { st | rigid = Set.insert id_ st.rigid })
                                    state.uni
                                    lifted
                          }
                        )


{-| Restore the branch's lifted rigid ids (the witness-refinement scope exit).
-}
unliftRigidM : List Int -> M ()
unliftRigidM lifted state =
    Ok
        ( ()
        , { state | uni = List.foldl (\id_ st -> { st | rigid = Set.remove id_ st.rigid }) state.uni lifted }
        )


{-| Restore the pre-branch existentials list (the branch's constructor
existentials die with the branch).
-}
restoreExistentialsM : List Int -> M ()
restoreExistentialsM previous state =
    Ok ( (), { state | existentials = previous } )


{-| The branch's result unification. If it fails on a RIGID variable that a
branch equation could have explained, the equation was needed OUTSIDE the
branch — the refinement cannot survive the branch boundary: report the
explicit escape error (the calculus's H2 obligation).

R-RESULT-DISCHARGE (classic GADTs): when the branch's equation on `a` is a
TYPE equation (`a ~ Int`, i.e. NOT a row refinement — `TRecord` bodies are row
equations and never discharge here), the equation IS discharged at the branch
result: the branch body is RE-CHECKED against the expected type with `a`
one-way replaced by the equation's body. This is the standard GADT rule — a
branch knowing `a ~ Int` may return an `Int` AT type `a` — and it is a
one-way coercion, never a bind: the equation still dies at branch end.
-}
unifyResultM : Uni.State -> Range -> Type -> Type -> M ()
unifyResultM postPattern range t1 t2 state =
    let
        -- Zonk BOTH sides first (same reason as `unifyUseM`): the rigid var
        -- the error names may only appear after resolving the substitution.
        zt1 =
            Rep.zonk state.uni.subst t1

        zt2 =
            Rep.zonk state.uni.subst t2
    in
    case Uni.unify state.uni zt1 zt2 of
        Ok uni2 ->
            if dropIntroduced postPattern state.uni uni2 t1 state.refinedTails then
                Err (tailEscapeError range)

            else
                case refinedTargetAliasedBy state.uni state.refinedTargets t1 t2 of
                    Just target ->
                        Err (Error.atRange range (Uni.describe (Uni.RigidVar target (Rep.zonk state.uni.subst t1))) "")

                    Nothing ->
                        -- The branch-end occurs check (the equation lifecycle's
                        -- discharge): a pending KType equation whose zonked body
                        -- now contains its target is refuting and must error,
                        -- not be dropped at restoreEqsM unexamined. Covers the
                        -- alias formed in the body or by this result unify (the
                        -- retry path, where the equations are still in scope).
                        case Uni.pendingTypeOccurs uni2 of
                            Just ( target, body ) ->
                                Err (Error.atRange range (Uni.describe (Uni.InfiniteType target body)) "")

                            Nothing ->
                                Ok ( (), { state | uni = uni2 } )

        Err (Uni.RigidVar a t) ->
            if rebuildMatches state a t then
                -- Domain-preserving rebuild: `t` IS the head's refinement
                -- re-built, so the identification is the equation itself.
                -- Accept without binding anything (the rigid head stays
                -- unbound; the equation still dies at branch end).
                Ok ( (), state )

            else
                case Uni.dischargeType state.uni a of
                    Just ( target, body ) ->
                        -- TYPE equation: discharge at the branch result. Re-check
                        -- the branch body against the expected type with `a`
                        -- one-way coerced to the equation's body. A wrong body
                        -- (e.g. String where the equation says Int) still fails —
                        -- this unify, not the escape check, rejects it.
                        --
                        -- Guard: the equation is only usable when its body does
                        -- not depend on the very type being re-checked (a
                        -- refinement `a ~ (a, b)` must not coerce `a` in the
                        -- RESULT: the equation's own `a` is the branch's
                        -- existential, but if the body mentions rigid vars that
                        -- survive in t2's context, the discharge would identify
                        -- two unrelated skolems — refuse and fall through to the
                        -- escape error). Concretely: `body` may not mention `a`
                        -- itself (occurs) — the single-pass replaceVar keeps the
                        -- re-check terminating.
                        --
                        -- The replacement is applied to BOTH sides: the refined
                        -- variable may sit in the BODY's type (t1 — e.g. a branch
                        -- returning an argument `x : a` under `a ~ Int` where
                        -- the expected result mentions the signature's abstract
                        -- `a`) or in the EXPECTED type (t2 — the classic GADT
                        -- shape). Neither direction binds anything.
                        if Rep.occurs target body then
                            Err (escapeOrRigid range state.uni a t)

                        else
                            case Uni.unify state.uni (replaceVar target.id body zt1) (replaceVar target.id body zt2) of
                                Ok uni2 ->
                                    Ok ( (), { state | uni = uni2 } )

                                Err err2 ->
                                    -- A nested rigid failure (the replaced type
                                    -- mentions ANOTHER refined variable, e.g.
                                    -- Pair's `(a, b)` under a second equation on
                                    -- `b`): recurse once instead of failing.
                                    case err2 of
                                        Uni.RigidVar b2 _ ->
                                            if b2.id /= a.id then
                                                unifyResultM postPattern range (replaceVar target.id body zt1) (replaceVar target.id body zt2) state

                                            else
                                                Err (Error.atRange range (Uni.describe err2) "")

                                        _ ->
                                            Err (Error.atRange range (Uni.describe err2) "")

                    Nothing ->
                        if List.member a.id state.existentials then
                            -- The rigid variable is this branch's CONSTRUCTOR
                            -- INTRODUCED existential (e.g. `Some w x`'s `a`):
                            -- the payload's type is only known inside the
                            -- branch (through its witness), so it may not
                            -- escape into the result.
                            Err
                                (Error.atRange range
                                    ("escaping existential: the constructor's type variable "
                                        ++ Rep.pretty (TVar a)
                                        ++ " (known in this branch only as "
                                        ++ Rep.pretty t
                                        ++ ") cannot escape the branch that matched it"
                                    )
                                    ""
                                )

                        else if escapesThrough state.uni a then
                            Err
                                (Error.atRange range
                                    ("escaping row equation: the branch's refinement of "
                                        ++ Rep.pretty (TVar a)
                                        ++ " ("
                                        ++ Rep.pretty t
                                        ++ ") is needed to type the result, but a branch equation may not escape its branch"
                                    )
                                    ""
                                )

                        else
                            Err (Error.atRange range (Uni.describe (Uni.RigidVar a t)) "")

        Err err ->
            Err (Error.atRange range (Uni.describe err) "")


escapeOrRigid : Range -> Uni.State -> VarId -> Type -> TypeError
escapeOrRigid range uni a t =
    if escapesThrough uni a then
        Error.atRange range
            ("escaping row equation: the branch's refinement of "
                ++ Rep.pretty (TVar a)
                ++ " ("
                ++ Rep.pretty t
                ++ ") is needed to type the result, but a branch equation may not escape its branch"
            )
            ""

    else
        Error.atRange range (Uni.describe (Uni.RigidVar a t)) ""


{-| One-way variable replacement (the discharge coercion): `t` with every
occurrence of variable `id` replaced by `body`. SINGLE PASS, deliberately NOT
`Rep.zonk` — the equation body may itself mention `a` (e.g. Pair's refinement
`a ~ (a, b)`, where the ctor's `a` is the branch-local existential), and a
fixpoint zonk would loop or capture. The replacement happens in the type the
branch is re-checked against, never in the substitution.
-}
replaceVar : Int -> Type -> Type -> Type
replaceVar id body t =
    if Rep.occurs (Rep.var id KType FNone) t then
        case t of
            TVar v ->
                if v.id == id then
                    body

                else
                    t

            TCon n args ->
                TCon n (List.map (replaceVar id body) args)

            TFun p q ->
                TFun (replaceVar id body p) (replaceVar id body q)

            TTuple ts ->
                TTuple (List.map (replaceVar id body) ts)

            TRecord row ->
                TRecord
                    { fields = List.map (\( l, ft ) -> ( l, replaceVar id body ft )) row.fields
                    , tail =
                        case row.tail of
                            RVar v ->
                                if v.id == id then
                                    -- A KType equation can never target a row
                                    -- tail (kinds are guarded upstream), so
                                    -- this is unreachable; kept total.
                                    row.tail

                                else
                                    row.tail

                            REmpty ->
                                row.tail
                    }

    else
        t


escapesThrough : Uni.State -> VarId -> Bool
escapesThrough uni a =
    List.any (\eq -> eq.target.id == a.id) uni.eqs


{-| Did a result unification silently alias a FLEXIBLE variable to a RIGID
variable that the branch's equations refined (`refinedTargets`)? That is the
UNSOUND flex → rigid alias: the flexible variable binds to the rigid index and
the equation that refined it is DROPPED, so the body is accepted at the index's
type without ever satisfying the refinement. `get : type a. Box a -> a` whose
body returns the ctor field `v : a` of `MkBox : a -> Box (List a)` is exactly
this — the equation `a ~ List a` is dropped and `get (MkBox 3)` is accepted at
`List Int` while its value is `3`. Returns the rigid target when the shape is
present.
-}
refinedTargetAliasedBy : Uni.State -> List Int -> Type -> Type -> Maybe VarId
refinedTargetAliasedBy uni targets t1 t2 =
    case ( Rep.zonk uni.subst t1, Rep.zonk uni.subst t2 ) of
        ( TVar v1, TVar v2 ) ->
            if
                v1.id /= v2.id
                    && not (Uni.isRigid uni v1)
                    && Uni.isRigid uni v2
                    && List.member v2.id targets
            then
                Just v2

            else
                Nothing

        _ ->
            Nothing


{-| The clause's final result unification (signature-directed): a rigid
failure on a variable a BRANCH refined during this clause means the branch's
refinement was needed to type the result — the equation tried to ESCAPE
its branch. Report the explicit escape error.
-}
unifyClauseResultM : Range -> Type -> Type -> M ()
unifyClauseResultM range t1 t2 state =
    case Uni.unify state.uni t1 t2 of
        Ok uni2 ->
            if dropIntroduced state.uni state.uni uni2 t1 state.refinedTails then
                Err (tailEscapeError range)

            else
                case refinedTargetAliasedBy state.uni state.refinedTargets t1 t2 of
                    Just target ->
                        Err (Error.atRange range (Uni.describe (Uni.RigidVar target (Rep.zonk state.uni.subst t1))) "")

                    Nothing ->
                        -- The clause-end occurs check: the alias that refutes a
                        -- KType equation may form HERE (the plain path — the
                        -- branch-level `unifyResultM` unified against a fresh
                        -- result var, so the field variable was still free), so
                        -- the check runs over the surviving refined-type
                        -- equations on the clause's result substitution.
                        case Uni.typeOccursIn state.refinedTypeEqs uni2 of
                            Just ( target, body ) ->
                                Err (Error.atRange range (Uni.describe (Uni.InfiniteType target body)) "")

                            Nothing ->
                                Ok ( (), { state | uni = uni2 } )

        Err (Uni.RigidVar a t) ->
            if List.member a.id (List.map (\( h, _ ) -> h) state.refinedTails) then
                -- A refined ROW head that the result unification could not
                -- join against the result type: either the bare tail (the
                -- silent-alias drop, caught above by `dropIntroduced`) or a
                -- domain CHANGE (the body added/dropped a field the head's
                -- refinement does not expose). Both are the row refinement
                -- escaping its branch. The domain-preserving REBUILD never
                -- reaches here — the retry's branch-level `unifyResultM`
                -- accepts it (see `rebuildMatches`).
                Err (tailEscapeError range)

            else if List.member a.id state.refinedTargets then
                Err
                    (Error.atRange range
                        ("escaping row equation: this branch's refinement of "
                            ++ Rep.pretty (TVar a)
                            ++ " (to "
                            ++ Rep.pretty t
                            ++ ") is needed to type the result, but a branch equation may not escape its branch"
                        )
                        ""
                    )

            else
                Err (Error.atRange range (Uni.describe (Uni.RigidVar a t)) "")

        Err err ->
            Err (Error.atRange range (Uni.describe err) "")


{-| The result unify's escape check is DOMAIN-based, not syntactic. A row
refinement `head ~ { L | tail }` (recorded in `refinedTails` as a (head, tail)
pair) may not escape its branch: the tail is a PROPER sub-row of the head, so
identifying them — directly, or by binding the flexible tail to a row whose
tail chain reaches the rigid head — would claim a value one (or more) cells
shorter at the full row's type. That identification is the silent flex-alias
unification cannot see on its own.

The check is therefore NOT "does the tail occur in the body": a REBUILT row
`{ L | tail }` (e.g. `HCons x rest : HList { l : t | rho' }`) also mentions
the tail, yet preserves the head's domain and is legitimate. Instead it asks
whether THIS result unify newly made the tail reach the head — whether the
tail's (zonked) row now has the head in its tail spine. The bare-tail return
(drop) does; the rebuild (accepted below by `rebuildMatches`) does not bind
the tail at all.
-}
tailEscapeError : Range -> TypeError
tailEscapeError range =
    Error.atRange range
        "escaping row equation: a branch refined the row and returned only its tail where the full row is expected"
        ""


{-| Is `tailId`'s zonked row reaching `headId` in its tail spine? A `KRow`
variable only ever binds to a `TRecord` (never a bare `TVar`), so zonk splices
empty/fielded wrappers transitively; `headId` reachable means the tail has
been identified with the head (or with a row built on the head) — the drop.
-}
tailReachesHead : Uni.State -> Int -> Int -> Bool
tailReachesHead uni tailId headId =
    Rep.occurs (Rep.var headId KRow FNone) (Rep.zonk uni.subst (TVar (Rep.var tailId KRow FNone)))


{-| Did a refined tail ESCAPE the branch? Two shapes, both sound:

DIRECT drop — the tail (fresh just after the pattern unify, before the body)
reaches its head after this result unification AND the result type IS the tail
(`rest : HList rho'`). The post-pattern baseline (not the pre-result-unify
state) is what closes the CE-1 bypass: a body that aliases the tail to the head
BEFORE the result unify (`choose True xs rest` forcing `HList rho ~ HList rho'`)
still fires, because the tail was fresh before the body and the result is the
tail.

INDIRECT leak — this result unify NEWLY aliased a refined tail to its head
(the shared-resultVar wildcard leak: a sibling branch returned the tail, this
branch returns the full row, and unifying them against the shared result var
is the alias). The pre-result-unify baseline here is deliberate: a tail the
BODY already aliased (as a side effect) must not fire — that is what keeps
`rowgadt_select`'s / `rowgadt_setx`'s `There` branch clean, whose recursive
call aliases the tail to the signature's rigid index while its result type
(`t` / `{rho|l:t}`) does not mention the tail.
-}
dropIntroduced : Uni.State -> Uni.State -> Uni.State -> Type -> List ( Int, Int ) -> Bool
dropIntroduced postPattern pre post resultType tails =
    List.any
        (\( headId, tailId ) ->
            let
                reachesPost =
                    tailReachesHead post tailId headId
            in
            (not (tailReachesHead postPattern tailId headId) && reachesPost && resultIsTail postPattern resultType tailId)
                || (not (tailReachesHead pre tailId headId) && reachesPost)
        )
        tails


{-| Is the branch result type literally the refined tail (the drop: a value of
the tail's type returned where the head's type is expected)? Zonked with the
POST-PATTERN substitution — after the pattern unify bound the pattern's variable
to the tail's row but BEFORE the body's alias — so the tail occurrence is still
visible (zonking with the post-body substitution would chase the tail straight
to the head and hide exactly the occurrence we must catch).
-}
resultIsTail : Uni.State -> Type -> Int -> Bool
resultIsTail postPattern resultType tailId =
    Rep.occurs (Rep.var tailId KRow FNone) (Rep.zonk postPattern.subst resultType)


{-| The domain-preserving REBUILD: unifying a branch result against a rigid
row head fails (`RigidVar a t`) whenever the body presents a fielded row, yet
that row may be exactly the head's refinement (`a ~ { L | tail }`) re-built —
`HCons x rest : HList { l : t | rho' }` at `HList rho`. Such a result is
legitimate iff the presented row `t` unifies with the head's equation body
(domain AND field types AND tail all consistent) — the identification is the
equation itself, not a domain change. Accept without binding anything (the
rigid head stays unbound). A row that does NOT unify with the equation body
(a different label, a wrong field type, a tail that is not the equation's) is
a domain change and falls through to the escape error.
-}
rebuildMatches : InferState -> VarId -> Type -> Bool
rebuildMatches state a t =
    -- `a` must not occur in `t`: the rebuild is `a ~ { L | tail }` with `t` the
    -- fielded row built on the equation's TAIL. A `RigidVar a (TRecord r2)`
    -- where `a` is r2's own tail comes from the row REWRITE extending a rigid
    -- tail (a fielded-vs-fielded mismatch, e.g. the body adds a field the
    -- expected row's tail cannot absorb) — that is a domain CHANGE, not a
    -- rebuild, and must fall through to the escape error.
    if List.member a.id (List.map (\( h, _ ) -> h) state.refinedTails) && not (Rep.occurs a t) then
        case t of
            TRecord _ ->
                case findEquation state.uni a of
                    Just body ->
                        case Uni.unify state.uni t body of
                            Ok _ ->
                                True

                            Err _ ->
                                False

                    Nothing ->
                        False

            _ ->
                False

    else
        False


{-| The most recent equation on `a` in the branch store, zonked. The store is
most-recent-first (`pushEq` prepends).
-}
findEquation : Uni.State -> VarId -> Maybe Type
findEquation uni a =
    List.filter (\eq -> eq.target.id == a.id) uni.eqs
        |> List.head
        |> Maybe.map (\eq -> Rep.zonk uni.subst eq.body)


{-| The unifier state just AFTER the branch's pattern-vs-scrutinee unify (the
refined tails are recorded, and each tail var is still UNBOUND — its equation
lives on the store, not the substitution), and BEFORE the body. This is the
baseline for the DIRECT drop check in `dropIntroduced`: a tail that reaches its
head after the result unify, but was fresh here, escaped either in the body or
in the result unify. It is also the substitution `resultIsTail` zonks with — the
body's later alias would otherwise zonk the tail away, hiding the occurrence we
must catch.
-}
captureUniM : M Uni.State
captureUniM state =
    Ok ( state.uni, state )


snapshotEqsM : M (List Uni.Equation)
snapshotEqsM state =
    Ok ( Uni.snapshotEqs state.uni, state )


restoreEqsM : List Uni.Equation -> M ()
restoreEqsM snapshot state =
    Ok ( (), { state | uni = Uni.dropEqsFrom snapshot state.uni } )


{-| Branch-local unification: like `unifyM` but captures rigid bindings as
delayed equations (see `Uni.unifyBranch`). Fails with the same error surface
for every non-rigid conflict.
-}
unifyBranchM : Range -> Type -> Type -> M ()
unifyBranchM range t1 t2 state =
    case Uni.unifyBranch state.uni t1 t2 of
        Err err ->
            Err (Error.atRange range (Uni.describe err) "")

        Ok ( uni2, pushed ) ->
            -- The pushed equations die at branch end, but the clause REMEMBERS
            -- which variables were refined by a branch: a later rigid failure
            -- on such a variable is an escaping-refinement error, not a plain
            -- skolem error. It also remembers each row equation's TAIL (head,
            -- tail): the tail is a proper sub-row of the head, so returning a
            -- value whose row is the tail where the head is expected is an
            -- escape even though the flexible tail would alias the head
            -- "successfully" (see `escapeViaTail`).
            let
                newTargets =
                    List.foldl (\eq acc -> if List.member eq.target.id acc then acc else eq.target.id :: acc)
                        state.refinedTargets
                        pushed

                newTails =
                    List.foldl
                        (\eq acc ->
                            case Rep.zonk uni2.subst eq.body of
                                TRecord r ->
                                    case r.tail of
                                        RVar b ->
                                            let
                                                pair =
                                                    ( eq.target.id, b.id )
                                            in
                                            if List.member pair acc then
                                                acc

                                            else
                                                pair :: acc

                                        REmpty ->
                                            acc

                                _ ->
                                    acc
                        )
                        state.refinedTails
                        pushed

                -- The KType equations survive the branch (like refinedTargets)
                -- so the clause-level result unification can run their occurs
                -- check: the flex → rigid alias that refutes them (`a ~ List a`)
                -- may form in `unifyClauseResultM`, after `restoreEqsM` has
                -- already dropped the live store.
                newTypeEqs =
                    List.foldl
                        (\eq acc ->
                            if eq.target.kind == KType && not (List.any (\( t, _ ) -> t.id == eq.target.id) acc) then
                                ( eq.target, eq.body ) :: acc

                            else
                                acc
                        )
                        state.refinedTypeEqs
                        pushed
            in
            Ok ( (), { state | uni = uni2, refinedTargets = newTargets, refinedTails = newTails, refinedTypeEqs = newTypeEqs } )



-- ======================= PATTERNS =======================


inferPatterns : Bool -> Ctx -> List (Node Pattern) -> M ( List Type, List ( String, Scheme ) )
inferPatterns branchMode ctx pats =
    case pats of
        [] ->
            ok ( [], [] )

        p :: rest ->
            inferPattern branchMode ctx p
                |> andThen (\( binds, pt ) ->
                    inferPatterns branchMode ctx rest
                        |> map (\( pts, moreBinds ) -> ( pt :: pts, binds ++ moreBinds ))
                )


inferPattern : Bool -> Ctx -> Node Pattern -> M ( List ( String, Scheme ), Type )
inferPattern branchMode ctx (Node r pat) =
    case pat of
        AllPattern ->
            fresh KType FNone |> map (\v -> ( [], TVar v ))

        UnitPattern ->
            ok ( [], Rep.tUnit )

        CharPattern _ ->
            ok ( [], Rep.tChar )

        StringPattern _ ->
            ok ( [], Rep.tString )

        IntPattern _ ->
            ok ( [], Rep.tInt )

        HexPattern _ ->
            ok ( [], Rep.tInt )

        FloatPattern _ ->
            ok ( [], Rep.tFloat )

        VarPattern name ->
            fresh KType FNone |> map (\v -> ( [ ( name, Env.monoScheme (TVar v) ) ], TVar v ))

        TuplePattern ps ->
            inferPatterns branchMode ctx ps |> map (\( pts, binds ) -> ( binds, TTuple pts ))

        RecordPattern fields ->
            fresh KRow FNone
                |> andThen
                    (\tail ->
                        foldM
                            (\field ( fieldTypes, binds ) ->
                                fresh KType FNone
                                    |> map
                                        (\v ->
                                            ( fieldTypes ++ [ ( nodeString field, TVar v ) ]
                                            , binds ++ [ ( nodeString field, Env.monoScheme (TVar v) ) ]
                                            )
                                        )
                            )
                            ( [], [] )
                            fields
                            |> map (\( fieldTypes, binds ) -> ( binds, TRecord { fields = fieldTypes, tail = RVar tail } ))
                    )

        UnConsPattern left right ->
            fresh KType FNone
                |> andThen (\elem ->
                    inferPattern branchMode ctx left
                        |> andThen (\( lb, lt ) ->
                            unifyM r lt (TVar elem)
                                |> andThen (\_ ->
                                    inferPattern branchMode ctx right
                                        |> andThen (\( rb, rt ) ->
                                            unifyM r rt (Rep.tList (TVar elem))
                                                |> map (\_ -> ( lb ++ rb, Rep.tList (TVar elem) ))
                                        )
                                )
                        )
                )

        ListPattern ps ->
            fresh KType FNone
                |> andThen (\elem ->
                    inferPatterns branchMode ctx ps
                        |> andThen (\( pts, binds ) ->
                            foldM (\( pr, pt ) _ -> unifyM (Node.range pr) pt (TVar elem)) ()
                                (List.map2 Tuple.pair ps pts)
                                |> map (\_ -> ( binds, Rep.tList (TVar elem) ))
                        )
                )

        NamedPattern qref subpats ->
            resolveCtorType ctx r qref
                |> andThen (\ctorType -> peelCtor branchMode ctx subpats ctorType)

        AsPattern inner nameNode ->
            inferPattern branchMode ctx inner
                |> map (\( binds, t ) -> ( binds ++ [ ( nodeString nameNode, Env.monoScheme t ) ], t ))

        ParenthesizedPattern inner ->
            inferPattern branchMode ctx inner



{-| Peel the `TFun` chain off a ctor scheme's type to reach its RESULT type
(e.g. `Witness Int` for `WInt`, `Any` for `Some`, `Dict k v` for a Dict ctor).
-}
peelResult : Type -> Type
peelResult t =
    case t of
        TFun _ res ->
            peelResult res

        _ ->
            t


{-| RECORD a non-exhaustive `case` (do not fail here): zonk the scrutinee,
resolve its EFFECTIVE type (the first pattern's type when the scrutinee still
holds a flexible, non-rigid variable — an unsignatured `List a` element — but
the RIGID abstract index of a GADT scrutinee stays authoritative), and run the
coverage check. A gap is stashed in the state and reported by
`failNonExhaustive` only AFTER the clause's body and result type-check — so a
pre-existing type error (the escape rejection in `rowgadt_evalbad`, say) keeps
its own diagnostic, and exhaustiveness fires exactly where a `case` would
otherwise COMPILE CLEAN and raise `non-exhaustive case` at runtime. `pts` are
the clauses' inferred pattern types (one per `case`), from `inferCaseClause`.
-}
requireExhaustive : Ctx -> Range -> Type -> List Type -> List (Node Pattern) -> M ()
requireExhaustive ctx range st pts pats state =
    case Rep.zonk state.uni.subst st of
        stZ ->
            let
                flexible =
                    List.any (\v -> not (Set.member v.id state.uni.rigid)) (Env.freeVars stZ)

                scrut =
                    if flexible then
                        -- A bare flexible type variable must never license
                        -- refutation. A `type a.`-less index (`Tag a`) is
                        -- genuinely polymorphic, so every constructor is
                        -- POSSIBLE; handing the check a single clause's
                        -- concrete index (`Tag Int`) is what made
                        -- `f : Tag a -> Int` matching only `A` refute `B` and
                        -- accept a partial function. The zonked scrutinee is
                        -- authoritative for its index; the only recovery from
                        -- the clause pattern types is the HEAD when the
                        -- scrutinee is still a bare variable (an unsignatured
                        -- scrutinee whose variable the branch lift rolled
                        -- back), so the check can find the constructors.
                        case stZ of
                            TVar _ ->
                                mostResolved pts stZ

                            _ ->
                                stZ

                    else
                        stZ
            in
            case Exhaustive.check ctx.env scrut pats of
                Ok () ->
                    Ok ( (), state )

                Err witness ->
                    Ok
                        ( ()
                        , { state
                            | nonExhaustive =
                                case state.nonExhaustive of
                                    Just _ ->
                                        state.nonExhaustive

                                    Nothing ->
                                        Just ( range, witness )
                          }
                        )


{-| The most-resolved of the clauses' pattern types (the one with the FEWEST
free variables) — used as the effective scrutinee when the zonked scrutinee
still carries an unresolved flexible variable. A leading `Nothing` arm infers
`Maybe a` (generic payload) while a later `Just (a, b)` arm infers
`Maybe (a, b)`; the latter is the type the patterns really refine to.
-}
mostResolved : List Type -> Type -> Type
mostResolved pts fallback =
    case pts of
        [] ->
            fallback

        p :: rest ->
            pickMostResolved p rest


pickMostResolved : Type -> List Type -> Type
pickMostResolved best rest =
    case rest of
        [] ->
            best

        p :: more ->
            if List.length (Env.freeVars p) < List.length (Env.freeVars best) then
                pickMostResolved p more

            else
                pickMostResolved best more


{-| Report the first recorded non-exhaustive `case` (if any) once the clause's
own type-checking has succeeded.
-}
failNonExhaustive : M ()
failNonExhaustive state =
    case state.nonExhaustive of
        Just ( range, witness ) ->
            Err (Error.atRange range ("non-exhaustive case: missing " ++ witness) "")

        Nothing ->
            Ok ( (), state )


resolveCtorType : Ctx -> Range -> QualifiedNameRef -> M Type
resolveCtorType ctx range qref =
    if List.isEmpty qref.moduleName && (qref.name == "True" || qref.name == "False") then
        ok Rep.tBool

    else
        case resolveScheme ctx qref.moduleName qref.name of
            Just scheme ->
                -- A constructor matched in a PATTERN: its TRUE EXISTENTIALS
                -- (quantifiers absent from the ctor's result type, e.g.
                -- `Some : Witness a -> a -> Any`'s `a`) are instantiated
                -- RIGID (branch-scoped skolems — OutsideIn's touchables), so
                -- a nested witness match can only REFINE them branch-locally
                -- instead of binding globally. Quantifiers free in the
                -- result stay flexible; the branch unify against the
                -- scrutinee fixes them exactly as before.
                --
                -- Non-GADT constructors (result = `TCon name generics`) have
                -- EVERY quantifier free in the result, so nothing is
                -- rigidified and ordinary ADT patterns are unchanged.
                let
                    -- The quantifiers the SCRUTINEE determines are those free in
                    -- the ctor's RESULT type (the scrutinee's type unifies with
                    -- the whole result, so every result-generic is fixed by it).
                    -- Quantifiers free ONLY in the arguments are the ctor's TRUE
                    -- EXISTENTIALS and stay rigid. (The old "last result arg"
                    -- heuristic missed the earlier args — e.g. `Dict k v`'s `k` —
                    -- and wrongly rigidified them, and `Any`'s zero-arg result
                    -- made `Some`'s `a` look determined.)
                    determined =
                        List.filter
                            (\v -> memberById v.id (Env.freeVars (peelResult scheme.body)))
                            scheme.quantifiers
                in
                instantiateExistential ctx.env range scheme determined
                    |> andThen
                        (\ctorType state ->
                            let
                                exVars =
                                    List.filter
                                        (\v -> not (memberById v.id determined))
                                        (Env.freeVars ctorType)
                            in
                            Ok ( ctorType, { state | existentials = List.foldl (\v acc -> if List.member v acc then acc else v :: acc) state.existentials (List.map .id exVars) } )
                        )

            Nothing ->
                fail (Error.atRange range ("unknown name: " ++ joinName (qref.moduleName ++ [ qref.name ])) "")


peelCtor : Bool -> Ctx -> List (Node Pattern) -> Type -> M ( List ( String, Scheme ), Type )
peelCtor branchMode ctx subpats ctorType =
    case subpats of
        [] ->
            ok ( [], ctorType )

        p :: rest ->
            case ctorType of
                TFun arg res ->
                    inferPattern branchMode ctx p
                        |> andThen (\( binds, pt ) ->
                            -- In a case branch the sub-pattern unifies against
                            -- the ctor's argument type in BRANCH mode, so a
                            -- NESTED constructor's GADT result index is captured
                            -- as a branch-local equation (the same discipline
                            -- the top-level pattern-vs-scrutinee unify gets) —
                            -- a nested `Then prev Unlock` can then refine the
                            -- outer ctor's existential `from ~ {}` without
                            -- binding it globally. Outside a branch (function
                            -- argument / let / lambda patterns) the global path
                            -- is unchanged: a rigid binding there is still an
                            -- error, never a captured equation.
                            (if branchMode then
                                unifyBranchM (Node.range p) pt arg

                             else
                                unifyM (Node.range p) pt arg
                            )
                                |> andThen (\_ ->
                                    peelCtor branchMode ctx rest res
                                        |> map (\( more, result ) -> ( binds ++ more, result ))
                                )
                        )

                _ ->
                    fail (Error.atRange (Node.range p) "constructor applied to too many arguments" "")



-- ======================= TOP-LEVEL GROUP =======================


{-| Group `FunctionDeclaration` nodes by (bare) name, preserving clause order.
-}
groupFnDecls : List (Node Declaration) -> List ( String, List (Node Declaration) )
groupFnDecls decls =
    case decls of
        [] ->
            []

        nd :: rest ->
            let
                name =
                    declName nd

                ( same, others ) =
                    List.partition (\d -> declName d == name) rest
            in
            ( name, nd :: same ) :: groupFnDecls others


declName : Node Declaration -> String
declName (Node _ decl) =
    case decl of
        FunctionDeclaration fn ->
            fnName fn

        _ ->
            ""


fnName : Function -> String
fnName fn =
    case fn.declaration of
        Node _ impl ->
            nodeString impl.name


ctorNames : List (Node Declaration) -> List String
ctorNames decls =
    List.concatMap
        (\(Node _ decl) ->
            case decl of
                CustomTypeDeclaration typeDecl ->
                    List.map
                        (\vcNode ->
                            case Node.value vcNode of
                                vc ->
                                    nodeString vc.name
                        )
                        typeDecl.constructors

                _ ->
                    []
        )
        decls


{-| Seed the unit's top-level bindings: signatured names get their (already
generalized) scheme from the merged environment; unsignatured names get a
fresh mono variable (monomorphic recursion, generalized per-SCC — see
`checkSccs`).
-}
seedTop : Env -> String -> List String -> Uni.State -> ( Dict String Scheme, List String, Uni.State )
seedTop env selfStr names state =
    List.foldl (seedOne env selfStr) ( Dict.empty, [], state ) names


seedOne : Env -> String -> String -> ( Dict String Scheme, List String, Uni.State ) -> ( Dict String Scheme, List String, Uni.State )
seedOne env selfStr name ( dict, unsig, state ) =
    case Env.lookupValue (selfStr ++ "." ++ name) env of
        Just scheme ->
            ( Dict.insert name scheme dict, unsig, state )

        Nothing ->
            let
                ( v, st ) =
                    Uni.freshVar KType FNone state
            in
            ( Dict.insert name (Env.monoScheme (TVar v)) dict, name :: unsig, st )


generalizeUnsig : List String -> Dict String Scheme -> Uni.State -> Dict String Scheme
generalizeUnsig names top state =
    List.foldl
        (\n dict ->
            case Dict.get n dict of
                Just scheme ->
                    Dict.insert n (Env.generalize (Rep.zonk state.subst scheme.body)) dict

                Nothing ->
                    dict
        )
        top
        names



-- ======================= SCC ORDER + CHECK =======================
-- Real Elm checks top-level definitions in STRONGLY-CONNECTED-COMPONENT order
-- (dependencies first) and generalizes a non-recursive definition BEFORE its
-- dependents see it.  The previous "one recursive group, generalized at the
-- end" design was too conservative: a helper used at several types in the same
-- unit (e.g. `show` in cmporder) stayed monomorphic and failed to unify its
-- multiple uses.


{-| The top-level names a function's (checked) body references, restricted to
the unit's own top-level names.  Trusted bodies are skipped, so they contribute
NO references — this also breaks the fake cycle `compare <-> cmpList`, where
`compare`'s body is skipped but its signature is already fixed.
-}
refsOf : List String -> List String -> List ( String, List (Node Declaration) ) -> String -> List String
refsOf self names groups name =
    if Builtins.isTrusted (joinName (self ++ [ name ])) then
        []

    else
        case List.filterMap (\( n, cl ) -> if n == name then Just cl else Nothing) groups of
            clauses :: _ ->
                List.concatMap (clauseRefs self names) clauses

            [] ->
                []


clauseRefs : List String -> List String -> Node Declaration -> List String
clauseRefs self names (Node _ decl) =
    case decl of
        FunctionDeclaration fn ->
            fnRefs self names fn

        _ ->
            []


fnRefs : List String -> List String -> Function -> List String
fnRefs self names fn =
    case fn.declaration of
        Node _ impl ->
            collectRefs self names impl.expression


collectRefs : List String -> List String -> Node Expression -> List String
collectRefs self names (Node _ expr) =
    collectRefsExpr self names expr


collectRefsExpr : List String -> List String -> Expression -> List String
collectRefsExpr self names expr =
    case expr of
        FunctionOrValue modName name ->
            if (List.isEmpty modName || modName == self) && List.member name names then
                [ name ]

            else
                []

        Application nodes ->
            List.concatMap (collectRefs self names) nodes

        OperatorApplication _ _ l r ->
            collectRefs self names l ++ collectRefs self names r

        Negation x ->
            collectRefs self names x

        ParenthesizedExpression x ->
            collectRefs self names x

        IfBlock c t e ->
            collectRefs self names c ++ collectRefs self names t ++ collectRefs self names e

        LambdaExpression lam ->
            collectRefs self names lam.expression

        LetExpression lb ->
            List.concatMap (collectRefsLetDecl self names) lb.declarations
                ++ collectRefs self names lb.expression
        CaseExpression cb ->
            collectRefs self names cb.expression
                ++ List.concatMap (\( _, e ) -> collectRefs self names e) cb.cases

        RecordExpr setters ->
            List.concatMap (\(Node _ ( _, v )) -> collectRefs self names v) setters

        ListExpr xs ->
            List.concatMap (collectRefs self names) xs

        TupledExpression xs ->
            List.concatMap (collectRefs self names) xs

        RecordAccess rec _ ->
            collectRefs self names rec

        RecordUpdateExpression _ setters ->
            List.concatMap (\(Node _ ( _, v )) -> collectRefs self names v) setters

        InsertionValue x ->
            collectRefs self names x

        _ ->
            []


collectRefsLetDecl : List String -> List String -> Node LetDeclaration -> List String
collectRefsLetDecl self names (Node _ decl) =
    case decl of
        LetFunction fn ->
            fnRefs self names fn

        LetDestructuring _ e ->
            collectRefs self names e


{-| Compute the SCCs of the top-level names in dependency order (dependencies
first).  A name is ready once every name it references has already been placed;
if nothing is ready but names remain, the remaining names are mutually
recursive and form ONE SCC (a sound over-grouping for the tiny corpus).
-}
sccOrder : List String -> (String -> List String) -> List (List String)
sccOrder names refs =
    sccGo names [] [] refs


sccGo : List String -> List String -> List (List String) -> (String -> List String) -> List (List String)
sccGo remaining placed acc refs =
    case remaining of
        [] ->
            List.reverse acc

        _ ->
            case findReady remaining placed refs of
                Just n ->
                    sccGo (List.filter (\m -> m /= n) remaining) (n :: placed) ([ n ] :: acc) refs

                Nothing ->
                    sccGo [] (placed ++ remaining) (remaining :: acc) refs


findReady : List String -> List String -> (String -> List String) -> Maybe String
findReady remaining placed refs =
    case remaining of
        [] ->
            Nothing

        n :: rest ->
            -- A self-recursive function (refs n includes n) is ready on its
            -- own: monomorphic recursion generalizes a SINGLE function fine,
            -- and grouping it with unrelated helpers that USE it at another
            -- type (e.g. `map` used at `Char` by a String helper) would
            -- wrongly constrain its scheme.  Only genuinely mutual recursion
            -- (n -> m -> n, neither placed) still forms one SCC.
            if List.all (\r -> r == n || List.member r placed) (refs n) then
                Just n

            else
                findReady rest placed refs


checkSccs : Ctx -> List String -> List ( String, List (Node Declaration) ) -> List (List String) -> InferState -> Result TypeError ( Dict NodeKey Function, Dict String Scheme, InferState )
checkSccs ctx unsig groups sccs state =
    case sccs of
        [] ->
            Ok ( Dict.empty, ctx.top, state )

        scc :: rest ->
            checkScc ctx scc groups state
                |> Result.andThen
                    (\( dict, s2 ) ->
                        let
                            ctx2 =
                                { ctx | top = generalizeScc scc unsig ctx.top s2.uni }
                        in
                        checkSccs ctx2 unsig groups rest s2
                            |> Result.map (\( dict2, finalTop, s3 ) -> ( Dict.union dict dict2, finalTop, s3 ))
                    )


checkScc : Ctx -> List String -> List ( String, List (Node Declaration) ) -> InferState -> Result TypeError ( Dict NodeKey Function, InferState )
checkScc ctx scc groups state =
    typeClauses ctx (List.concatMap (\( n, cl ) -> if List.member n scc then cl else []) groups) state


generalizeScc : List String -> List String -> Dict String Scheme -> Uni.State -> Dict String Scheme
generalizeScc scc unsig top state =
    generalizeUnsig (List.filter (\n -> List.member n scc) unsig) top state


typeClauses : Ctx -> List (Node Declaration) -> InferState -> Result TypeError ( Dict NodeKey Function, InferState )
typeClauses ctx clauses state =
    case clauses of
        [] ->
            Ok ( Dict.empty, state )

        clause :: rest ->
            typeOneClause ctx clause state
                |> Result.andThen
                    (\( key, fn, s2 ) ->
                        typeClauses ctx rest s2
                            |> Result.map (\( d, s3 ) -> ( Dict.insert key fn d, s3 ))
                    )


typeOneClause : Ctx -> Node Declaration -> InferState -> Result TypeError ( NodeKey, Function, InferState )
typeOneClause ctx node state =
    case node of
        Node r (FunctionDeclaration fn) ->
            case inferClause ctx fn state of
                Err err ->
                    Err err

                Ok ( fn2, s2 ) ->
                    Ok ( keyOf r, fn2, s2 )

        _ ->
            Err (Error.atRange Range.empty "internal: not a function declaration" "")


{-| Peel an (instantiated) signature type into its argument types and result
type.  A concrete `TFun` chain is split directly; a bare type variable (an
unsignatured mono var, possibly already bound by an earlier clause) is unified
against a fresh `arg1 -> ... -> argn -> rest` shape so the split always
succeeds.
-}
peelArity : Range -> Type -> Int -> M ( List Type, Type )
peelArity range t n =
    zonkM t
        |> andThen
            (\zt ->
                case ( n, zt ) of
                    ( 0, _ ) ->
                        ok ( [], zt )

                    ( _, TFun a b ) ->
                        peelArity range b (n - 1)
                            |> map (\( args, res ) -> ( a :: args, res ))

                    ( _, TVar v ) ->
                        fresh KType FNone
                            |> andThen (\a ->
                                fresh KType FNone
                                    |> andThen (\rest ->
                                        unifyM range (TVar v) (TFun (TVar a) (TVar rest))
                                            |> andThen (\_ ->
                                                peelArity range (TVar rest) (n - 1)
                                                    |> map (\( args, res ) -> ( TVar a :: args, res ))
                                            )
                                    )
                            )

                    _ ->
                        fail (Error.atRange range "arity mismatch: too many arguments for the signature" "")
            )


unifyEach : Range -> List Type -> List Type -> M ()
unifyEach range ts1 ts2 =
    case ( ts1, ts2 ) of
        ( [], [] ) ->
            ok ()

        ( t1 :: r1, t2 :: r2 ) ->
            unifyM range t1 t2
                |> andThen (\_ -> unifyEach range r1 r2)

        _ ->
            fail (Error.atRange range "arity mismatch" "")


inferClause : Ctx -> Function -> M Function
inferClause ctx fn =
    let
        impl =
            Node.value fn.declaration

        name =
            nodeString impl.name

        qualified =
            joinName (ctx.self ++ [ name ])
    in
    if Builtins.isTrusted qualified then
        -- Trusted body (e.g. Prelude.removeFieldImpl): skip inference AND
        -- rewriting; its call-site scheme comes from Type.Builtins (the
        -- record-removal impl pattern-matches a record as a raw assoc list,
        -- which the TRecord-typed checker must never see).
        ok fn

    else
        case Dict.get name ctx.top of
            Nothing ->
                fail (Error.atRange (Node.range fn.declaration) ("internal: unseeded top-level name " ++ name) "")

            Just scheme ->
                instantiatePartial ctx.env (Node.range fn.declaration) scheme
                    |> andThen (\expected ->
                        inferPatterns False ctx impl.arguments
                            |> andThen (\( argTypes, binds ) ->
                                peelArity (Node.range fn.declaration) expected (List.length argTypes)
                                    |> andThen (\( argExpecteds, resultExpected ) ->
                                        -- Annotation-directed: constrain each pattern
                                        -- arg by the signature BEFORE the body, so a
                                        -- signatured record update sees the concrete
                                        -- field set (and can raise "does not have
                                        -- field x") instead of an unbound variable.
                                        unifyEach (Node.range fn.declaration) argTypes argExpecteds
                                            |> andThen (\_ ->
                                                let
                                                    ctx2 =
                                                        { ctx | locals = binds ++ ctx.locals }
                                                in
                                                resetAppends
                                                    |> andThen (\_ ->
                                                        inferExpr ctx2 impl.expression
                                                            |> andThen (\bodyType ->
                                                                unifyClauseResultM (Node.range fn.declaration) bodyType resultExpected
                                                                    |> andThen (\_ ->
                                                                        resolveAppends
                                                                            |> andThen (\siteMap ->
                                                                                checkNoResidualAppendable (Node.range fn.declaration) (List.foldr TFun bodyType argTypes)
                                                                                    |> andThen (\_ ->
                                                                                        annotationNotTooGeneral ctx.env (Node.range fn.declaration) scheme (List.foldr TFun bodyType argTypes)
                                                                                            |> andThen (\_ ->
                                                                                                failNonExhaustive
                                                                                                    |> map
                                                                                                        (\_ ->
                                                                                                            { fn
                                                                                                                | declaration =
                                                                                                                    Node (Node.range fn.declaration)
                                                                                                                        { impl | expression = rewriteExpr siteMap impl.expression }
                                                                                                            }
                                                                                                        )
                                                                                            )
                                                                                    )
                                                                            )
                                                                    )
                                                            )
                                                            |> orElse
                                                                (\plainErr ->
                                                                    -- R-RESULT-DISCHARGE (classic GADTs): the
                                                                    -- plain path cannot join a GADT case's
                                                                    -- branches bottom-up (each branch refines
                                                                    -- the result index differently), so when
                                                                    -- the body IS a case and the plain path
                                                                    -- failed, re-check it DECLARATION-DIRECTED:
                                                                    -- each branch body checks against the
                                                                    -- declared result type, with the branch's
                                                                    -- own equations discharged at its result
                                                                    -- (see unifyResultM). Non-GADT programs
                                                                    -- never reach here (plain succeeds), and
                                                                    -- if the retry also fails the HISTORICAL
                                                                    -- error is reported — every pre-existing
                                                                    -- diagnostic is unchanged.
                                                                    case Node.value impl.expression of
                                                                        CaseExpression block2 ->
                                                                            (inferExpr ctx2 block2.expression
                                                                                |> andThen (\st2 ->
                                                                                    zonkM st2
                                                                                        |> andThen (\stZ20 ->
                                                                                            mapM (inferCaseClause ctx2 stZ20 st2 resultExpected) block2.cases
                                                                                                |> andThen (\pts2 ->
                                                                                                    requireExhaustive ctx2 (Node.range impl.expression) st2 pts2 (List.map Tuple.first block2.cases)
                                                                                                )
                                                                                        )
                                                                                )
                                                                            )
                                                                                |> andThen
                                                                                    (\_ ->
                                                                                        -- Same tail as the plain path: resolve
                                                                                        -- the retry's `++` sites (the retry is a
                                                                                        -- full re-inference, so its appends
                                                                                        -- must be rewritten too) and reject a
                                                                                        -- residual appendable.
                                                                                        resolveAppends
                                                                                            |> andThen (\siteMap ->
                                                                                                checkNoResidualAppendable (Node.range fn.declaration) resultExpected
                                                                                                    |> andThen (\_ ->
                                                                                                        annotationNotTooGeneral ctx.env (Node.range fn.declaration) scheme (List.foldr TFun resultExpected argTypes)
                                                                                                            |> andThen (\_ ->
                                                                                                                failNonExhaustive
                                                                                                                    |> map
                                                                                                                        (\_ ->
                                                                                                                            { fn
                                                                                                                                | declaration =
                                                                                                                                    Node (Node.range fn.declaration)
                                                                                                                                        { impl | expression = rewriteExpr siteMap impl.expression }
                                                                                                                            }
                                                                                                                        )
                                                                                                            )
                                                                                                    )
                                                                                            )
                                                                                    )
                                                                                |> orElse (\_ -> fail plainErr)

                                                                        _ ->
                                                                            fail plainErr
                                                                )
                                                    )
                                            )
                                    )
                            )
                    )



-- ======================= APPENDABLE ZONK & REWRITES =======================


type alias SiteMap =
    Dict NodeKey ( String, Node Expression, Node Expression )


resolveAppends : M SiteMap
resolveAppends state =
    resolveSites state.appends Dict.empty state


resolveSites : List AppendSite -> SiteMap -> InferState -> Result TypeError ( SiteMap, InferState )
resolveSites sites acc state =
    case sites of
        [] ->
            Ok ( acc, { state | appends = [] } )

        site :: rest ->
            case Rep.zonk state.uni.subst (TVar site.var) of
                TCon "String" [] ->
                    resolveSites rest (Dict.insert (keyOf site.range) ( "String.append", site.left, site.right ) acc) state

                TCon "List" _ ->
                    resolveSites rest (Dict.insert (keyOf site.range) ( "List.append", site.left, site.right ) acc) state

                _ ->
                    Err (Error.atRange site.range "ambiguous (++)" "")


checkNoResidualAppendable : Range -> Type -> M ()
checkNoResidualAppendable range t state =
    case residualAppendable (Rep.zonk state.uni.subst t) of
        Just v ->
            Err (Error.atRange range "ambiguous (++)" ("cannot resolve appendable of type " ++ Rep.pretty (TVar v)))

        Nothing ->
            Ok ( (), state )


{-| OPTION-B soundness (the "(c)" check): a signature whose generic variables
are NOT bound by a `type <name>+ .` prefix is checked with those variables
FLEXIBLE, so a body may specialize them (`f : a -> a / f x = "hello"` binds
`a := String`). Call sites still use the DECLARED scheme (`forall a. a -> a`),
so that specialization would be silently wrong. After inferring the body,
generalize its inferred type `fullType` and reject if the declared scheme is
NOT an instance of it — i.e. if the declared annotation is more general than
what the body actually implements (Elm's "annotation is too general").

The instance test is the standard skolem check: skolemize the declared
scheme's quantifiers, flex-instantiate the body's generalized scheme, unify; a
rigid-bind failure means the body specialized a variable the annotation
promised to keep general.
-}
annotationNotTooGeneral : Env -> Range -> Scheme -> Type -> M ()
annotationNotTooGeneral env range declared fullType state =
    let
        bodyScheme =
            Env.generalize (Rep.zonk state.uni.subst fullType)

        ( rigidDeclared, st1 ) =
            Env.instantiateRigid declared state.uni

        ( flexBody, st2 ) =
            Env.instantiate bodyScheme st1
    in
    case Env.expandAliases env rigidDeclared st2 of
        Err msg ->
            Err (Error.atRange range msg "")

        Ok ( rigidExpanded, st3 ) ->
            case Env.expandAliases env flexBody st3 of
                Err msg ->
                    Err (Error.atRange range msg "")

                Ok ( flexExpanded, st4 ) ->
                    case Uni.unify st4 rigidExpanded flexExpanded of
                        Ok _ ->
                            Ok ( (), state )

                        Err _ ->
                            Err (Error.atRange range "annotation is too general: the definition specializes a type variable the annotation promises to keep general" "")


residualAppendable : Type -> Maybe VarId
residualAppendable t =
    case t of
        TVar v ->
            if v.flex == FAppendable then
                Just v

            else
                Nothing

        TCon _ args ->
            firstJust (List.map residualAppendable args)

        TFun a b ->
            firstJust [ residualAppendable a, residualAppendable b ]

        TTuple ts ->
            firstJust (List.map residualAppendable ts)

        TRecord row ->
            firstJust (List.map (\( _, ft ) -> residualAppendable ft) row.fields)


{-| The phase-2 rewrite: replace resolved `++` sites, `Record.remove`
applications, and unwrap `InsertionValue` markers (recursively).
-}
rewriteExpr : SiteMap -> Node Expression -> Node Expression
rewriteExpr sites (Node range expr) =
    case expr of
        InsertionValue inner ->
            rewriteExpr sites inner

        _ ->
            case Dict.get (keyOf range) sites of
                Just ( appendFn, left, right ) ->
                    Node range
                        (Application
                            [ Node.empty (FunctionOrValue [] appendFn)
                            , rewriteExpr sites left
                            , rewriteExpr sites right
                            ]
                        )

                Nothing ->
                    Node range (rewriteExprValue sites expr)


rewriteExprValue : SiteMap -> Expression -> Expression
rewriteExprValue sites expr =
    case expr of
        UnitExpr ->
            UnitExpr

        Application nodes ->
            case recordRemoveArgs nodes of
                Just ( labelNode, recNode ) ->
                    Application
                        [ Node.empty (FunctionOrValue [ "Prelude" ] "removeFieldImpl")
                        , labelNode
                        , rewriteExpr sites recNode
                        ]

                Nothing ->
                    Application (List.map (rewriteExpr sites) nodes)

        OperatorApplication op dir l r ->
            OperatorApplication op dir (rewriteExpr sites l) (rewriteExpr sites r)

        FunctionOrValue m n ->
            FunctionOrValue m n

        IfBlock c t e ->
            IfBlock (rewriteExpr sites c) (rewriteExpr sites t) (rewriteExpr sites e)

        PrefixOperator op ->
            PrefixOperator op

        Operator op ->
            Operator op

        Integer n ->
            Integer n

        Hex n ->
            Hex n

        Floatable f ->
            Floatable f

        Negation x ->
            Negation (rewriteExpr sites x)

        Literal s ->
            Literal s

        CharLiteral c ->
            CharLiteral c

        TupledExpression xs ->
            TupledExpression (List.map (rewriteExpr sites) xs)

        ParenthesizedExpression x ->
            ParenthesizedExpression (rewriteExpr sites x)

        LetExpression lb ->
            LetExpression
                { declarations = List.map (rewriteLetDecl sites) lb.declarations
                , expression = rewriteExpr sites lb.expression
                }

        CaseExpression cb ->
            CaseExpression
                { expression = rewriteExpr sites cb.expression
                , cases = List.map (\( p, e ) -> ( p, rewriteExpr sites e )) cb.cases
                }

        LambdaExpression lam ->
            LambdaExpression { args = lam.args, expression = rewriteExpr sites lam.expression }

        RecordExpr setters ->
            RecordExpr (List.map (rewriteSetter sites) setters)

        ListExpr xs ->
            ListExpr (List.map (rewriteExpr sites) xs)

        RecordAccess rec n ->
            RecordAccess (rewriteExpr sites rec) n

        RecordAccessFunction n ->
            RecordAccessFunction n

        RecordUpdateExpression base setters ->
            RecordUpdateExpression base (List.map (rewriteSetter sites) setters)

        InsertionValue x ->
            Node.value (rewriteExpr sites x)

        GLSLExpression s ->
            GLSLExpression s


recordRemoveArgs : List (Node Expression) -> Maybe ( Node Expression, Node Expression )
recordRemoveArgs nodes =
    case nodes of
        headNode :: labelNode :: recNode :: [] ->
            case ( Node.value headNode, Node.value labelNode ) of
                ( FunctionOrValue [ "Record" ] "remove", Literal s ) ->
                    Just ( Node (Node.range labelNode) (Literal s), recNode )

                ( FunctionOrValue [ "Record" ] "remove", CharLiteral c ) ->
                    Just ( Node (Node.range labelNode) (Literal (String.fromChar c)), recNode )

                _ ->
                    Nothing

        _ ->
            Nothing


rewriteSetter : SiteMap -> Node RecordSetter -> Node RecordSetter
rewriteSetter sites (Node r ( field, val )) =
    Node r ( field, rewriteExpr sites val )


rewriteLetDecl : SiteMap -> Node LetDeclaration -> Node LetDeclaration
rewriteLetDecl sites (Node r decl) =
    Node r
        (case decl of
            LetFunction fn ->
                LetFunction (rewriteFnExpr sites fn)

            LetDestructuring pat e ->
                LetDestructuring pat (rewriteExpr sites e)
        )


rewriteFnExpr : SiteMap -> Function -> Function
rewriteFnExpr sites fn =
    case fn.declaration of
        Node r impl ->
            { fn | declaration = Node r { impl | expression = rewriteExpr sites impl.expression } }



-- ======================= FILE REBUILD =======================


rebuildFile : Dict NodeKey Function -> File.File -> File.File
rebuildFile rewritten file =
    { file | declarations = List.map (rewriteDecl rewritten) file.declarations }


rewriteDecl : Dict NodeKey Function -> Node Declaration -> Node Declaration
rewriteDecl rewritten (Node r decl) =
    case decl of
        FunctionDeclaration fn ->
            case Dict.get (keyOf r) rewritten of
                Just fn2 ->
                    Node r (FunctionDeclaration fn2)

                Nothing ->
                    Node r decl

        _ ->
            Node r decl



-- ======================= HELPERS =======================


moduleNameOf : File.File -> List String
moduleNameOf file =
    case file.moduleDefinition of
        Node _ modDef ->
            SyntaxModule.moduleName modDef


nodeString : Node String -> String
nodeString (Node _ s) =
    s


joinName : List String -> String
joinName =
    String.join "."


{-| A node identity key: the node's FULL range (start + end).  The START alone
is not unique (a parent node's range starts where its leftmost child's does),
which would make `++`-site matching rewrite the wrong node and loop.
-}
type alias NodeKey =
    String


keyOf : Range -> NodeKey
keyOf range =
    String.fromInt range.start.row
        ++ ":"
        ++ String.fromInt range.start.column
        ++ "-"
        ++ String.fromInt range.end.row
        ++ ":"
        ++ String.fromInt range.end.column


memberById : Int -> List VarId -> Bool
memberById id vars =
    List.any (\v -> v.id == id) vars


dedupeIds : List VarId -> List VarId
dedupeIds xs =
    List.foldl (\v acc -> if memberById v.id acc then acc else acc ++ [ v ]) [] xs


dedupeInts : List Int -> List Int
dedupeInts xs =
    List.foldl (\n acc -> if List.member n acc then acc else acc ++ [ n ]) [] xs


firstJust : List (Maybe a) -> Maybe a
firstJust xs =
    case xs of
        [] ->
            Nothing

        Just a :: _ ->
            Just a

        Nothing :: rest ->
            firstJust rest
