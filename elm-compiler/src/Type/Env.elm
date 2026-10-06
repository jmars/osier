module Type.Env exposing
    ( Scheme
    , Env
    , Alias
    , empty
    , collectFile
    , merge
    , insert, insertCtor, insertAlias
    , lookupValue, lookupCtor, lookupAlias
    , instantiate, instantiateRigid, instantiatePartial, instantiateExistential, expandAliases
    , generalize, generalizeAvoiding
    , freeVars, freeVarsOfScheme, freeVarsOfEnv
    , monoScheme
    )

{-| The type environment: qualified schemes, constructor schemes, and type
aliases, collected from parsed `File`s and merged into one table keyed by
qualified `"Mod.name"` (mirroring `Lower.Module.mergedGlobals`).

  - A `Scheme` is a universally-quantified type (`forall a b. body`); the
    quantified variables are the `VarId`s that `instantiate` freshens.
  - `collectFile` gathers a unit's SIGNATURES, ADT constructor argument types,
    and type aliases (unsignatured functions are NOT collected — the Infer
    pass pre-seeds them with a fresh monomorphic var and generalizes them when
    the unit finishes, exactly like Elm).
  - `generalize` quantifies every free type variable (top-level); flex-marked
    `number`/`comparable` variables are KEPT in schemes and re-instantiated
    with the same marker (so `Dict.get : comparable -> Dict comparable v ->
    Maybe v` stays a legal polymorphic scheme).  `appendable` is the zonk
    exception: it is resolved to String/List at each `++` site by the Infer
    pass BEFORE generalization, so no scheme ever carries it.
  - `generalizeAvoiding` is let-generalization: it quantifies the free
    variables of a type that are NOT free in the enclosing environment.

This module is pure Elm (elm/core + elm-syntax + Type.Representation/Unify)
and must stay free of `Lower.*` imports so it can be unit-tested in isolation
via `src/TestMain.elm`.

-}

import Dict exposing (Dict)
import Elm.Syntax.Declaration as Declaration exposing (Declaration(..))
import Elm.Syntax.Exposing as Exposing exposing (Exposing(..), TopLevelExpose(..))
import Elm.Syntax.File as File
import Elm.Syntax.Import as Import
import Elm.Syntax.Module as SyntaxModule
import Elm.Syntax.Node as Node exposing (Node(..))
import Elm.Syntax.Signature as Signature
import Elm.Syntax.Type as SyntaxType
import Elm.Syntax.TypeAlias as TypeAlias
import Elm.Syntax.TypeAnnotation as TA
import Type.Representation as Rep exposing (Flex(..), Kind(..), Row, RowTail(..), Type(..), VarId)
import Type.Unify as Uni


{-| A type scheme: a universally-quantified body type. The `quantifiers` are
the free variables of `body` (in first-appearance order); `instantiate`
replaces each with a fresh variable of the same kind and flex marker.

`bound` is the subset of `quantifiers` that must be SKOLEMIZED (rigid) while
checking the signature's own body (`instantiatePartial`); the rest are
instantiated flexibly. It holds (a) the `type <name>+ .` prefix names (locally
abstract types) PLUS (b) every quantified variable that appears as a DIRECT
type argument of a GADT constructor (`Has l t rho` / `Expr a`): such an index
is RIGID whether or not the surface binds it, because unification must never
specialize a GADT index. Ordinary (non-GADT) Elm signatures keep `bound` empty
and make every quantified variable flexible, with `Infer`'s "annotation is too
general" check restoring the soundness the flexibility would otherwise drop.
-}
type alias Scheme =
    { quantifiers : List VarId
    , body : Type
    , bound : List VarId
    }


{-| A type alias, stored as a type-level function (generics + an annotation),
expanded at use by the Infer pass. Row-kind generics are legal here
(`type alias Named r = { name : String | r }`); the kind of each generic is
inferred from its use position at expansion time.

The body is PRE-CONVERTED once at collection time, with each generic bound to a
NEGATIVE-id sentinel variable (`genericVars`, in declaration order). At
expansion, `expandAliases` builds a substitution from sentinel -> argument type
and zonks the body; a row-kind generic applied to a concrete record splices
into its tail via `Rep.zonk`'s row-splice. Negative ids can never collide with
the unification state's (non-negative) fresh ids, so the zonk is exact.
-}
type alias Alias =
    { name : String
    , generics : List String
    , annotation : TA.TypeAnnotation
    , genericVars : List VarId
    , body : Type
    }


{-| The merged type environment. Value (function) schemes and constructor
schemes live in separate tables but are both keyed by qualified `"Mod.name"`;
aliases are keyed the same way. `lookupValue` checks values then constructors.
-}
type alias Env =
    { values : Dict String Scheme
    , ctors : Dict String Scheme
    , aliases : Dict String Alias
    }


empty : Env
empty =
    { values = Dict.empty
    , ctors = Dict.empty
    , aliases = Dict.empty
    }



-- ======================= COLLECTION =======================


{-| Collect one parsed file's signatures, ADT constructors, and type aliases
into an `Env` keyed by qualified name. Unsignatured functions, ports, infix
declarations, and destructuring are ignored (the Infer pass handles them).
-}
collectFile : File.File -> Env
collectFile file =
    let
        self =
            String.join "." (moduleNameOf file)

        typeTable =
            buildTypeTable file.imports

        -- ADT generic kinds, computed up front so a signature can kind a bare
        -- row parameter (`Has l t rho`) even when the signature never spells it
        -- at a record-tail position (the HList-encoding index shape).
        typeKinds =
            collectFileTypeKinds self file.declarations

        -- Type constructors whose own declarations carry per-ctor RESULT
        -- annotations (the GADT form `Here : Has l t { l : t | rho }`): a
        -- signature generic used as one of their DIRECT arguments is RIGID
        -- (position-directed), whether or not the surface binds it.
        gadtNames =
            collectGadtNames self file.declarations
    in
    List.foldl (collectDecl self typeTable typeKinds gadtNames) empty file.declarations


collectDecl : String -> TypeTable -> Dict String (List Kind) -> List String -> Node Declaration -> Env -> Env
collectDecl self typeTable typeKinds gadtNames node env =
    case node of
        Node _ (FunctionDeclaration fn) ->
            case fn.signature of
                Just (Node _ sig) ->
                    let
                        name =
                            nodeString sig.name
                    in
                    insert (self ++ "." ++ name)
                        (signatureScheme self typeTable typeKinds gadtNames sig.bound (Node.value sig.typeAnnotation))
                        env

                Nothing ->
                    env

        Node _ (CustomTypeDeclaration typeDecl) ->
            collectCtors self typeTable typeDecl env

        Node _ (AliasDeclaration aliasDecl) ->
            let
                qname =
                    self ++ "." ++ nodeString aliasDecl.name
            in
            insertAlias qname (buildAlias self qname typeTable aliasDecl) env

        _ ->
            env


collectCtors : String -> TypeTable -> SyntaxType.Type -> Env -> Env
collectCtors self typeTable typeDecl env =
    let
        typeName =
            nodeString typeDecl.name

        generics =
            List.map nodeString typeDecl.generics
    in
    List.foldl
        (\ctorNode e ->
            let
                vc =
                    Node.value ctorNode

                qname =
                    self ++ "." ++ nodeString vc.name
            in
            insertCtor qname
                (ctorScheme self typeTable typeName generics vc.arguments vc.result)
                e
        )
        env
        typeDecl.constructors


{-| Build an `Alias` from its declaration: pre-convert the body annotation with
each generic bound to a NEGATIVE-id sentinel var (kind inferred from use
position — a generic used as a row tail becomes `KRow`). `genericVars` mirrors
`generics` order so `expandAliases` can substitute positionally.
-}
buildAlias : String -> String -> TypeTable -> TypeAlias.TypeAlias -> Alias
buildAlias self qname typeTable aliasDecl =
    let
        generics =
            List.map nodeString aliasDecl.generics

        ( body, varMap ) =
            convertAliasBody self typeTable (Node.value aliasDecl.typeAnnotation)
    in
    { name = qname
    , generics = generics
    , annotation = Node.value aliasDecl.typeAnnotation
    , genericVars = List.filterMap (\g -> Dict.get g varMap) generics
    , body = body
    }


-- Convert an alias-body annotation with sentinel (negative-id) generic vars,
-- returning the body type and the generic-name -> sentinel-var map.
convertAliasBody : String -> TypeTable -> TA.TypeAnnotation -> ( Type, Dict String VarId )
convertAliasBody self typeTable ann =
    let
        ( body, ctx1 ) =
            convert { self = self, typeTable = typeTable, vars = Dict.empty, next = -1, step = -1 } ann
    in
    ( body, ctx1.vars )


-- A constructor scheme: `Just : a -> Maybe a` (result type qualified by the
-- defining module; argument types may additionally introduce FRESH type
-- variables, e.g. `TaskAndThen : (a -> Task x b) -> Task x a -> Task x b` —
-- those are quantified too, so `generalize` on the whole ctor type is exact).
--
-- `maybeResult` is the ctor's optional per-ctor RESULT annotation (the GADT
-- form `Here : Has l t { l : t | rho }`), parsed after the argument list. When
-- present it is converted with the SAME ctx as the args, so it may reference
-- the ADT's generics AND introduce fresh existential variables (quantified
-- by `generalize`, exactly like fresh arg variables). When absent the scheme
-- falls back to the default `TCon typeName generics` result.
ctorScheme : String -> TypeTable -> String -> List String -> List (Node TA.TypeAnnotation) -> Maybe (Node TA.TypeAnnotation) -> Scheme
ctorScheme self typeTable typeName generics argAnnos maybeResult =
    let
        -- Same row-tail prescan as `signatureScheme`: a generic used at a
        -- record-tail position anywhere in the ctor's annotations is KRow,
        -- whatever the first-use order says.
        rowTailNames =
            List.foldl (\a acc -> collectRowTailNames (Node.value a) acc)
                (case maybeResult of
                    Just (Node _ resultAnn) ->
                        collectRowTailNames resultAnn []

                    Nothing ->
                        []
                )
                argAnnos

        ctx0 =
            List.foldl (\n c -> Tuple.second (typeVar KRow n c))
                { self = self, typeTable = typeTable, vars = Dict.empty, next = 0, step = 1 }
                rowTailNames

        ( argTypes, ctx1 ) =
            convertList ctx0 argAnnos

        resultType =
            case maybeResult of
                Just (Node _ resultAnn) ->
                    convert ctx1 resultAnn
                        |> Tuple.first

                Nothing ->
                    -- Default result `TCon name generics`: every ADT
                    -- generic at its (type-level) position. Generics
                    -- the annotations never mention still need a var.
                    let
                        ( genVars, ctx2 ) =
                            List.foldl makeGeneric ( [], ctx1 ) generics
                    in
                    TCon (self ++ "." ++ typeName) (List.map TVar genVars)
    in
    generalize (List.foldr TFun resultType argTypes)


makeGeneric : String -> ( List VarId, Ctx ) -> ( List VarId, Ctx )
makeGeneric name ( acc, ctx ) =
    let
        ( v, ctx2 ) =
            typeVar KType name ctx
    in
    ( acc ++ [ v ], ctx2 )


-- A signature scheme: every `GenericType` leaf is quantified (with `number`/
-- `comparable`/`appendable` leaves given their flex marker); the row-kind of a
-- generic used as a row tail is inferred from its use position. `bound` (the
-- `type <name>+ .` prefix names) marks the subset that is SKOLEMIZED when the
-- signature's own body is checked; the rest stay flexible at the body.
--
-- POSITION-DIRECTED RIGIDITY: a generic used as a DIRECT argument of a GADT
-- type constructor (`gadtNames`) is added to `bound` even when the surface
-- binds nothing — a GADT index must never be specialized by unification, so it
-- is rigid exactly like a locally abstract type. Variables of PLAIN
-- constructors (`List a`, `Maybe a`) stay flexible.
signatureScheme : String -> TypeTable -> Dict String (List Kind) -> List String -> List (Node String) -> TA.TypeAnnotation -> Scheme
signatureScheme self typeTable typeKinds gadtNames bound ann =
    let
        -- Kinds are inferred from FIRST USE, but a generic mentioned at BOTH
        -- a type position (`Has l t rho`) and a record-tail position
        -- (`{ rho | m : t }`) is a ROW variable: the tail use is
        -- authoritative. Pre-bind every row-tail name so the first-use order
        -- inside the annotation cannot mis-kind it. A generic used as a BARE
        -- argument to a row-parameter ADT (`Has l t rho` / `HList rho`) is
        -- likewise a row variable even though the signature never spells it at
        -- a record-tail position — that spelling is exactly the HList encoding
        -- of a record index.
        rowNames =
            collectRowNames typeTable self typeKinds ann []

        ctx0 =
            List.foldl (\n c -> Tuple.second (typeVar KRow n c))
                { self = self, typeTable = typeTable, vars = Dict.empty, next = 0, step = 1 }
                rowNames

        ( t, finalCtx ) =
            convert ctx0 ann

        -- The bound names map to their converted VarIds (a bound name MUST
        -- appear in the annotation as a generic; the filterMap silently drops
        -- a bound name with no annotation occurrence — a malformed prefix).
        boundIds =
            List.filterMap (\nameNode -> Dict.get (nodeString nameNode) finalCtx.vars) bound

        -- Position-directed rigidity: every quantified variable that is a
        -- DIRECT argument of a GADT constructor is rigid too (unioned with the
        -- prefix set, in first-appearance order).
        rigidIds =
            List.foldl
                (\v acc ->
                    if List.any (\u -> u.id == v.id) acc then
                        acc

                    else
                        acc ++ [ v ]
                )
                boundIds
                (gadtIndexVars gadtNames t)
    in
    { quantifiers = freeVars t, body = t, bound = rigidIds }


{-| The quantified variables of a signature type that sit at a DIRECT argument
position of a GADT type constructor (`gadtNames`): `Has l t rho` contributes
`l t rho`, `Expr a` contributes `a`. Nested occurrences count only where the
GADT constructor itself is applied to a variable (`List (Has l t rho)` still
contributes `l t rho`); a variable under a PLAIN constructor (`List a`) does
not. Only the converted `Type` is walked — the result is a list of VarIds.
-}
gadtIndexVars : List String -> Type -> List VarId
gadtIndexVars gadtNames t =
    case t of
        TVar _ ->
            []

        TCon name args ->
            let
                direct =
                    if List.member name gadtNames then
                        List.filterMap isTVarId args

                    else
                        []
            in
            direct ++ List.concatMap (gadtIndexVars gadtNames) args

        TFun a b ->
            gadtIndexVars gadtNames a ++ gadtIndexVars gadtNames b

        TTuple ts ->
            List.concatMap (gadtIndexVars gadtNames) ts

        TRecord row ->
            List.concatMap (\( _, ft ) -> gadtIndexVars gadtNames ft) row.fields


isTVarId : Type -> Maybe VarId
isTVarId t =
    case t of
        TVar v ->
            Just v

        _ ->
            Nothing


{-| Every generic name that must be bound `KRow` in a signature: the record-tail
names (the existing prescan) PLUS bare generic names used as an argument to a
known ADT whose parameter at that position is a row. The second clause is the
HList-encoding index shape (`Has l t rho` / `HList rho`): `rho` is the ADT's
row parameter, but the signature spells it bare, with no record-tail position
to reveal its kind.
-}
collectRowNames : TypeTable -> String -> Dict String (List Kind) -> TA.TypeAnnotation -> List String -> List String
collectRowNames typeTable self typeKinds ann acc =
    case ann of
        TA.GenericType _ ->
            acc

        TA.Typed (Node _ ( modName, name )) args ->
            let
                qname =
                    qualifyTypeName typeTable self modName name

                kinds =
                    Maybe.withDefault [] (Dict.get qname typeKinds)

                argAnnos =
                    List.map Node.value args

                paramKinds =
                    kinds ++ List.repeat (max 0 (List.length argAnnos - List.length kinds)) KType

                rowArgNames =
                    List.filterMap
                        (\( a, k ) ->
                            case ( a, k ) of
                                ( TA.GenericType gname, KRow ) ->
                                    Just gname

                                _ ->
                                    Nothing
                        )
                        (List.map2 Tuple.pair argAnnos paramKinds)

                acc2 =
                    List.foldl (\n a2 -> if List.member n a2 then a2 else a2 ++ [ n ]) acc rowArgNames
            in
            List.foldl (\a acc3 -> collectRowNames typeTable self typeKinds (Node.value a) acc3) acc2 args

        TA.Unit ->
            acc

        TA.Tupled ts ->
            List.foldl (\a acc2 -> collectRowNames typeTable self typeKinds (Node.value a) acc2) acc ts

        TA.Record fields ->
            List.foldl (\f acc2 -> collectRowNames typeTable self typeKinds (Node.value (Tuple.second (Node.value f))) acc2) acc fields

        TA.GenericRecord (Node _ tailName) (Node _ recordDef) ->
            List.foldl (\f acc2 -> collectRowNames typeTable self typeKinds (Node.value (Tuple.second (Node.value f))) acc2)
                (if List.member tailName acc then acc else acc ++ [ tailName ])
                recordDef

        TA.FunctionTypeAnnotation left right ->
            collectRowNames typeTable self typeKinds (Node.value left) acc
                |> collectRowNames typeTable self typeKinds (Node.value right)


{-| The generic kinds of every ADT declared in the file, keyed by qualified
type name. An ADT generic is `KRow` iff its name appears at a record-tail
position in ANY of the type's constructor annotations (the same test
`ctorScheme` uses to kind the ADT's own generics).
-}
collectFileTypeKinds : String -> List (Node Declaration) -> Dict String (List Kind)
collectFileTypeKinds self decls =
    List.foldl (collectTypeKind self) Dict.empty decls


collectTypeKind : String -> Node Declaration -> Dict String (List Kind) -> Dict String (List Kind)
collectTypeKind self (Node _ decl) acc =
    case decl of
        CustomTypeDeclaration typeDecl ->
            let
                qname =
                    self ++ "." ++ nodeString typeDecl.name

                generics =
                    List.map nodeString typeDecl.generics

                rowNames =
                    List.foldl
                        (\ctorNode names ->
                            let
                                vc =
                                    Node.value ctorNode

                                names2 =
                                    List.foldl (\a ns -> collectRowTailNames (Node.value a) ns) names vc.arguments
                            in
                            case vc.result of
                                Just (Node _ resultAnn) ->
                                    collectRowTailNames resultAnn names2

                                Nothing ->
                                    names2
                        )
                        []
                        typeDecl.constructors

                kinds =
                    List.map (\g -> if List.member g rowNames then KRow else KType) generics
            in
            Dict.insert qname kinds acc

        _ ->
            acc


{-| The qualified names of the file's own GADT type constructors: an ADT with
at least one constructor carrying a per-ctor RESULT annotation (the
`Here : Has l t { l : t | rho }` form). These are exactly the constructors
whose type indices a signature must treat as RIGID (`signatureScheme`).
-}
collectGadtNames : String -> List (Node Declaration) -> List String
collectGadtNames self decls =
    List.concatMap (gadtNameOf self) decls


gadtNameOf : String -> Node Declaration -> List String
gadtNameOf self (Node _ decl) =
    case decl of
        CustomTypeDeclaration typeDecl ->
            if List.any (\ctorNode -> isGadtCtor (Node.value ctorNode)) typeDecl.constructors then
                [ self ++ "." ++ nodeString typeDecl.name ]

            else
                []

        _ ->
            []


isGadtCtor : SyntaxType.ValueConstructor -> Bool
isGadtCtor vc =
    case vc.result of
        Just _ ->
            True

        Nothing ->
            False


collectRowTailNames : TA.TypeAnnotation -> List String -> List String
collectRowTailNames ann acc =
    case ann of
        TA.GenericType _ ->
            acc

        TA.Typed _ args ->
            List.foldl (\a acc2 -> collectRowTailNames (Node.value a) acc2) acc args

        TA.Unit ->
            acc

        TA.Tupled ts ->
            List.foldl (\a acc2 -> collectRowTailNames (Node.value a) acc2) acc ts

        TA.Record fields ->
            List.foldl (\f acc2 -> collectRowTailNames (Node.value (Tuple.second (Node.value f))) acc2) acc fields

        TA.GenericRecord (Node _ tailName) (Node _ recordDef) ->
            List.foldl (\f acc2 -> collectRowTailNames (Node.value (Tuple.second (Node.value f))) acc2)
                (if List.member tailName acc then acc else acc ++ [ tailName ])
                recordDef

        TA.FunctionTypeAnnotation left right ->
            collectRowTailNames (Node.value left) acc
                |> collectRowTailNames (Node.value right)


moduleNameOf : File.File -> List String
moduleNameOf file =
    case file.moduleDefinition of
        Node _ modDef ->
            SyntaxModule.moduleName modDef



-- ======================= MERGING / LOOKUP =======================


merge : Env -> Env -> Env
merge a b =
    { values = Dict.union a.values b.values
    , ctors = Dict.union a.ctors b.ctors
    , aliases = Dict.union a.aliases b.aliases
    }


insert : String -> Scheme -> Env -> Env
insert name scheme env =
    { env | values = Dict.insert name scheme env.values }


insertCtor : String -> Scheme -> Env -> Env
insertCtor name scheme env =
    { env | ctors = Dict.insert name scheme env.ctors }


insertAlias : String -> Alias -> Env -> Env
insertAlias name alias env =
    { env | aliases = Dict.insert name alias env.aliases }


lookupValue : String -> Env -> Maybe Scheme
lookupValue name env =
    case Dict.get name env.values of
        Just scheme ->
            Just scheme

        Nothing ->
            Dict.get name env.ctors


lookupCtor : String -> Env -> Maybe Scheme
lookupCtor name env =
    Dict.get name env.ctors


lookupAlias : String -> Env -> Maybe Alias
lookupAlias name env =
    Dict.get name env.aliases



-- ======================= INSTANTIATION =======================


{-| Instantiate a scheme: replace each quantified variable with a FRESH
variable of the same kind and flex marker, threading the unification state's
fresh-id counter. `instantiate` is how `Dict.get : comparable -> ...` becomes a
call-site monomorphic type with a fresh `comparable` variable.
-}
instantiate : Scheme -> Uni.State -> ( Type, Uni.State )
instantiate scheme state =
    let
        ( renames, st ) =
            List.foldl freshQuant ( Dict.empty, state ) scheme.quantifiers
    in
    ( rename renames scheme.body, st )


freshQuant : VarId -> ( Dict Int VarId, Uni.State ) -> ( Dict Int VarId, Uni.State )
freshQuant q ( renames, state ) =
    let
        ( f, st ) =
            Uni.freshVar q.kind q.flex state
    in
    ( Dict.insert q.id f renames, st )


{-| Instantiate a scheme with EVERY `FNone` quantifier (both `KType` and
`KRow`) marked RIGID (a skolem). This is the FULL-skolem instantiation, used
by `Infer.annotationNotTooGeneral`'s skolem check (the declared scheme is
skolemized against the body's flex-instantiated generalized type) — NOT by the
body check itself, which uses `instantiatePartial`.

`number`/`comparable`/`appendable` quantifiers stay FLEX (they are constrained
supers, and rigid-marking them would break `Dict`/`Set`/comparison call sites).
Row variables are always `FNone` (row tails carry no flex marker), so every
`KRow` quantifier is skolemized; `Unify.rewrite`'s row-var instantiation and
`Unify.bindRowVar` both reject binding a rigid row tail.
-}
instantiateRigid : Scheme -> Uni.State -> ( Type, Uni.State )
instantiateRigid scheme state =
    let
        ( renames, st ) =
            List.foldl freshRigid ( Dict.empty, state ) scheme.quantifiers
    in
    ( rename renames scheme.body, st )


freshRigid : VarId -> ( Dict Int VarId, Uni.State ) -> ( Dict Int VarId, Uni.State )
freshRigid q ( renames, state ) =
    let
        ( f, st ) =
            Uni.freshVar q.kind q.flex state

        st2 =
            if q.flex == FNone then
                Uni.markRigid f st

            else
                st
    in
    ( Dict.insert q.id f renames, st2 )


{-| Instantiate a scheme for checking its OWN signatured body: a `FNone`
quantifier in `scheme.bound` (the `type <name>+ .` prefix names PLUS every
GADT-index variable, see `signatureScheme`) is marked RIGID (a skolem,
unchanged from `instantiateRigid`), and every OTHER quantifier is instantiated
FLEXIBLY (ordinary HM). Reference sites keep using `instantiate` (flexible);
`Infer` re-checks the "not more general" property afterwards.
-}
instantiatePartial : Scheme -> Uni.State -> ( Type, Uni.State )
instantiatePartial scheme state =
    let
        ( renames, st ) =
            List.foldl (freshPartial scheme.bound) ( Dict.empty, state ) scheme.quantifiers
    in
    ( rename renames scheme.body, st )


freshPartial : List VarId -> VarId -> ( Dict Int VarId, Uni.State ) -> ( Dict Int VarId, Uni.State )
freshPartial bound q ( renames, state ) =
    let
        ( f, st ) =
            Uni.freshVar q.kind q.flex state

        st2 =
            if q.flex == FNone && memberById q.id bound then
                Uni.markRigid f st

            else
                st
    in
    ( Dict.insert q.id f renames, st2 )


{-| Instantiate a CONSTRUCTOR scheme for a PATTERN position (the GADT
existential rule): a quantifier that is NOT free in the constructor's result
type (the `determined` argument is the list of quantifier ids that ARE free in
it) is a TRUE EXISTENTIAL — the variable the constructor binds, visible only
through its arguments. It is instantiated RIGID (a branch-scoped skolem,
exactly OutsideIn's touchables): a nested match on a witness may then only
REFINE it branch-locally (the equation is captured by branch unification
instead of binding globally), so sibling branches may refine it differently.

Quantifiers that ARE free in the result (the index the scrutinee fixes)
stay FLEXIBLE exactly like `instantiate` — their value is determined by the
branch unify against the scrutinee type, not by the body.
-}
instantiateExistential : List VarId -> Scheme -> Uni.State -> ( Type, Uni.State )
instantiateExistential determined scheme state =
    let
        ( renames, st ) =
            List.foldl (freshExistential determined) ( Dict.empty, state ) scheme.quantifiers
    in
    ( rename renames scheme.body, st )


freshExistential : List VarId -> VarId -> ( Dict Int VarId, Uni.State ) -> ( Dict Int VarId, Uni.State )
freshExistential determined q ( renames, state ) =
    let
        ( f, st ) =
            Uni.freshVar q.kind q.flex state

        st2 =
            if q.flex == FNone && not (memberById q.id determined) then
                Uni.markRigid f st

            else
                st
    in
    ( Dict.insert q.id f renames, st2 )



-- ======================= ALIAS EXPANSION =======================


{-| Expand every registered type alias in a type, recursively. A `TCon` whose
name is a registered alias is rewritten to its body with the alias's generics
substituted for the `TCon`'s arguments (a row-kind generic applied to a
concrete record splices into the body's row tail via `Rep.zonk`). Nested
aliases and aliases inside argument/field types are expanded too.

Applying an alias to the WRONG number of type arguments is an error
(`Err <msg>`), reported at the alias-application site: a 1-generic alias used
with zero arguments would otherwise leave its sentinel(s) unbound (silently
accepting anything), and an alias given too many arguments has no meaning.
The arity check fires here, at expansion, so the Infer pass can attach the use
site's source range to the message.

Any NEGATIVE-id sentinel that survives a legal expansion (a row-kind generic
applied to a BARE type variable — its row tail is not a concrete record, so
`Rep.zonk`'s row-splice does not fire) is FRESHENED to a fresh non-negative id
drawn from the unification state's counter. This keeps sentinel ids out of the
shared substitution: `unify` can never bind one, so a later independent use of
the same alias can never observe an earlier use's binding through the same
negative key.
-}
expandAliases : Env -> Type -> Uni.State -> Result String ( Type, Uni.State )
expandAliases env t state =
    case t of
        TVar v ->
            Ok ( TVar v, state )

        TCon name args ->
            case lookupAlias name env of
                Just alias ->
                    if List.length args /= List.length alias.generics then
                        Err (arityMessage alias (List.length args))

                    else
                        expandAliasesList env args state
                            |> Result.andThen
                                (\( args2, st1 ) ->
                                    let
                                        ( body, st2 ) =
                                            expandAliasBody alias args2 st1
                                    in
                                    expandAliases env body st2
                                )

                Nothing ->
                    expandAliasesList env args state
                        |> Result.map (\( args2, st1 ) -> ( TCon name args2, st1 ))

        TFun a b ->
            expandAliases env a state
                |> Result.andThen
                    (\( a2, st1 ) ->
                        expandAliases env b st1
                            |> Result.map (\( b2, st2 ) -> ( TFun a2 b2, st2 ))
                    )

        TTuple ts ->
            expandAliasesList env ts state
                |> Result.map (\( ts2, st1 ) -> ( TTuple ts2, st1 ))

        TRecord row ->
            expandAliasesRow env row state
                |> Result.map (\( row2, st1 ) -> ( TRecord row2, st1 ))


expandAliasesList : Env -> List Type -> Uni.State -> Result String ( List Type, Uni.State )
expandAliasesList env ts state =
    case ts of
        [] ->
            Ok ( [], state )

        t :: rest ->
            expandAliases env t state
                |> Result.andThen
                    (\( t2, st1 ) ->
                        expandAliasesList env rest st1
                            |> Result.map (\( ts2, st2 ) -> ( t2 :: ts2, st2 ))
                    )


expandAliasBody : Alias -> List Type -> Uni.State -> ( Type, Uni.State )
expandAliasBody alias args state =
    let
        subst =
            List.foldl
                (\( gv, arg ) s -> Rep.extend gv arg s)
                Rep.emptySubst
                (List.map2 Tuple.pair alias.genericVars args)
    in
    freshenSentinels (Rep.zonk subst alias.body) state


expandAliasesRow : Env -> Row -> Uni.State -> Result String ( Row, Uni.State )
expandAliasesRow env row state =
    expandAliasesFields env row.fields state
        |> Result.map (\( fields2, st1 ) -> ( { fields = fields2, tail = row.tail }, st1 ))


expandAliasesFields : Env -> List ( String, Type ) -> Uni.State -> Result String ( List ( String, Type ), Uni.State )
expandAliasesFields env fields state =
    case fields of
        [] ->
            Ok ( [], state )

        ( n, t ) :: rest ->
            expandAliases env t state
                |> Result.andThen
                    (\( t2, st1 ) ->
                        expandAliasesFields env rest st1
                            |> Result.map (\( rest2, st2 ) -> ( ( n, t2 ) :: rest2, st2 ))
                    )


arityMessage : Alias -> Int -> String
arityMessage alias actual =
    let
        expected =
            List.length alias.generics
    in
    "type alias "
        ++ alias.name
        ++ " expects "
        ++ String.fromInt expected
        ++ " type argument"
        ++ (if expected == 1 then "" else "s")
        ++ " but got "
        ++ String.fromInt actual


{-| Replace every NEGATIVE-id sentinel left in an expanded alias body with a
fresh non-negative variable of the same kind and flex. The mapping is memoized
per expansion so a sentinel appearing in several positions (a row generic used
as two row tails) stays a single shared variable.

A sentinel is only left by `expandAliasBody` when a row-kind generic is applied
to a BARE type variable (e.g. signature `f : Named r -> String` with
`type alias Named r = { name : String | r }`): `Rep.zonk` splices a row generic
only when its argument is a concrete `TRecord`, so a bare-var argument leaves
the `KRow` sentinel in the tail. Freshening it here to a fresh row var is what
makes `f` POLYMORPHIC in its row tail (`forall r'. { name : String | r' } ->
String`), which matches real Elm's reading of the signature.

LIMITATION (kind inference, not a leak): the bare `r` in the signature is
converted as `KType` (signatures do not know an alias's generic kinds at
conversion time), so it does NOT survive into the expanded type — the fresh row
var replaces it. For the common `Named r -> String` shape this is exactly right,
but a signature that ALSO uses the SAME variable at a `KType` position
(`f : Named r -> r -> String`) is ill-kinded and is silently accepted with the
two occurrences DISCONNECTED (the row occurrence becomes an independent row var,
the value occurrence stays `KType`). Rejecting it would need a full kind check
over type variables, which this kindless HM variant deliberately omits; it is
not reachable in the corpus/fixtures.
-}
freshenSentinels : Type -> Uni.State -> ( Type, Uni.State )
freshenSentinels t state =
    let
        ( t2, _, st ) =
            freshen Dict.empty t state
    in
    ( t2, st )


freshen : Dict Int VarId -> Type -> Uni.State -> ( Type, Dict Int VarId, Uni.State )
freshen renames t state =
    case t of
        TVar v ->
            let
                ( v2, r2, st2 ) =
                    freshenId renames v state
            in
            ( TVar v2, r2, st2 )

        TCon name args ->
            let
                ( args2, r2, st2 ) =
                    freshenList renames args state
            in
            ( TCon name args2, r2, st2 )

        TFun a b ->
            let
                ( a2, r1, st1 ) =
                    freshen renames a state

                ( b2, r2, st2 ) =
                    freshen r1 b st1
            in
            ( TFun a2 b2, r2, st2 )

        TTuple ts ->
            let
                ( ts2, r2, st2 ) =
                    freshenList renames ts state
            in
            ( TTuple ts2, r2, st2 )

        TRecord row ->
            let
                ( fields2, r1, st1 ) =
                    freshenFields renames row.fields state
            in
            case row.tail of
                REmpty ->
                    ( TRecord { fields = fields2, tail = REmpty }, r1, st1 )

                RVar v ->
                    let
                        ( v2, r2, st2 ) =
                            freshenId r1 v st1
                    in
                    ( TRecord { fields = fields2, tail = RVar v2 }, r2, st2 )


freshenId : Dict Int VarId -> VarId -> Uni.State -> ( VarId, Dict Int VarId, Uni.State )
freshenId renames v state =
    if v.id < 0 then
        case Dict.get v.id renames of
            Just f ->
                ( f, renames, state )

            Nothing ->
                let
                    ( f, st ) =
                        Uni.freshVar v.kind v.flex state
                in
                ( f, Dict.insert v.id f renames, st )

    else
        ( v, renames, state )


freshenList : Dict Int VarId -> List Type -> Uni.State -> ( List Type, Dict Int VarId, Uni.State )
freshenList renames ts state =
    case ts of
        [] ->
            ( [], renames, state )

        t :: rest ->
            let
                ( t2, r1, st1 ) =
                    freshen renames t state

                ( rest2, r2, st2 ) =
                    freshenList r1 rest st1
            in
            ( t2 :: rest2, r2, st2 )


freshenFields : Dict Int VarId -> List ( String, Type ) -> Uni.State -> ( List ( String, Type ), Dict Int VarId, Uni.State )
freshenFields renames fields state =
    case fields of
        [] ->
            ( [], renames, state )

        ( n, t ) :: rest ->
            let
                ( t2, r1, st1 ) =
                    freshen renames t state

                ( rest2, r2, st2 ) =
                    freshenFields r1 rest st1
            in
            ( ( n, t2 ) :: rest2, r2, st2 )



-- ======================= GENERALIZATION =======================


{-| Top-level generalization: quantify every free variable of the type. Flex
markers are preserved (a `FComparable` variable is quantified as-is).
-}
generalize : Type -> Scheme
generalize t =
    { quantifiers = freeVars t, body = t, bound = [] }


{-| Let-generalization: quantify the free variables of `t` that are NOT in the
`rigid` set (the free variables of the enclosing environment).
-}
generalizeAvoiding : List VarId -> Type -> Scheme
generalizeAvoiding rigid t =
    { quantifiers =
        List.filter (\v -> not (memberById v.id rigid)) (freeVars t)
    , body = t
    , bound = []
    }


{-| A monomorphic scheme (no quantifiers) — the shape used for lambda-bound and
pattern-bound variables, and for builtin monomorphic schemes.
-}
monoScheme : Type -> Scheme
monoScheme t =
    { quantifiers = [], body = t, bound = [] }



-- ======================= FREE VARIABLES =======================


{-| The free variables of a type, in first-appearance order, INCLUDING
flex-marked variables (unlike `Rep.collectVars`, which skips them for the
pretty-printer's letter assignment).
-}
freeVars : Type -> List VarId
freeVars t =
    dedupeById (collect t [])


freeVarsOfScheme : Scheme -> List VarId
freeVarsOfScheme scheme =
    List.filter (\v -> not (memberById v.id scheme.quantifiers)) (freeVars scheme.body)


freeVarsOfEnv : Env -> List VarId
freeVarsOfEnv env =
    dedupeById
        (List.concatMap freeVarsOfScheme (Dict.values env.values ++ Dict.values env.ctors))


collect : Type -> List VarId -> List VarId
collect t acc =
    case t of
        TVar v ->
            v :: acc

        TCon _ args ->
            List.foldl collect acc args

        TFun a b ->
            -- Left-to-right (argument then result), matching Rep.collectVars.
            collect b (collect a acc)

        TTuple ts ->
            List.foldl collect acc ts

        TRecord row ->
            collectRow row acc


collectRow : Row -> List VarId -> List VarId
collectRow row acc =
    let
        accFields =
            List.foldl (\( _, t ) a -> collect t a) acc row.fields
    in
    case row.tail of
        REmpty ->
            accFields

        RVar v ->
            v :: accFields



-- ======================= ANNOTATION -> TYPE =======================


-- Conversion context: the current (qualified) module for self-type
-- qualification, the generic-name -> var mapping (lazily built), the next
-- fresh var id (ids reflect first-appearance order), and the import-derived
-- type-resolution table (bare type names + module aliases).
type alias Ctx =
    { self : String
    , vars : Dict String VarId
    , next : Int
    , step : Int
    , typeTable : TypeTable
    }


{-| Import-derived type-name resolution: `bareTypes` maps a bare type name
exposed by an import (`import Dict exposing (Dict)`) to its defining module's
dotted name; `aliases` maps an import-alias spelling (`import X as Y`) to the
real module segments.  Used by `qualifyTypeName` so unqualified/aliased type
names resolve to the module that DEFINES them instead of self-qualifying.
-}
type alias TypeTable =
    { bareTypes : Dict String String
    , aliases : List ( String, List String )
    }


buildTypeTable : List (Node Import.Import) -> TypeTable
buildTypeTable imports =
    List.foldl addImportType { bareTypes = Dict.empty, aliases = [] } imports


addImportType : Node Import.Import -> TypeTable -> TypeTable
addImportType (Node _ imp) table =
    let
        mod =
            Node.value imp.moduleName

        modStr =
            String.join "." mod

        aliases =
            case imp.moduleAlias of
                Just (Node _ aliasSegs) ->
                    ( String.join "." aliasSegs, mod ) :: table.aliases

                Nothing ->
                    table.aliases

        bareTypes =
            case imp.exposingList of
                Just (Node _ exp) ->
                    exposeTypes modStr exp table.bareTypes

                Nothing ->
                    table.bareTypes
    in
    { bareTypes = bareTypes, aliases = aliases }


exposeTypes : String -> Exposing -> Dict String String -> Dict String String
exposeTypes modStr exp acc =
    case exp of
        All _ ->
            -- Cannot enumerate an `exposing (..)` module's types without a
            -- cross-module export pass (same limitation as the alias table).
            acc

        Explicit items ->
            List.foldl (exposeType modStr) acc items


exposeType : String -> Node TopLevelExpose -> Dict String String -> Dict String String
exposeType modStr (Node _ item) acc =
    case item of
        TypeOrAliasExpose n ->
            Dict.insert n modStr acc

        TypeExpose { name } ->
            Dict.insert name modStr acc

        _ ->
            acc


convert : Ctx -> TA.TypeAnnotation -> ( Type, Ctx )
convert ctx ann =
    case ann of
        TA.GenericType name ->
            let
                ( v, ctx2 ) =
                    typeVar KType name ctx
            in
            ( TVar v, ctx2 )

        TA.Typed (Node _ ( modName, name )) args ->
            let
                ( argTs, ctx2 ) =
                    convertList ctx args
            in
            ( TCon (qualifyTypeName ctx.typeTable ctx.self modName name) argTs, ctx2 )

        TA.Unit ->
            ( Rep.tUnit, ctx )

        TA.Tupled ts ->
            let
                ( ts2, ctx2 ) =
                    convertList ctx ts
            in
            ( TTuple ts2, ctx2 )

        TA.Record fields ->
            let
                ( fs, ctx2 ) =
                    convertFields ctx fields
            in
            ( TRecord { fields = fs, tail = REmpty }, ctx2 )

        TA.GenericRecord (Node _ tailName) (Node _ recordDef) ->
            let
                ( tv, ctx1 ) =
                    typeVar KRow tailName ctx

                ( fs, ctx2 ) =
                    convertFields ctx1 recordDef
            in
            ( TRecord { fields = fs, tail = RVar tv }, ctx2 )

        TA.FunctionTypeAnnotation left right ->
            let
                ( lt, ctx1 ) =
                    convert ctx (Node.value left)

                ( rt, ctx2 ) =
                    convert ctx1 (Node.value right)
            in
            ( TFun lt rt, ctx2 )


convertList : Ctx -> List (Node TA.TypeAnnotation) -> ( List Type, Ctx )
convertList ctx annos =
    case annos of
        [] ->
            ( [], ctx )

        (Node _ ann) :: rest ->
            let
                ( t, ctx1 ) =
                    convert ctx ann

                ( ts, ctx2 ) =
                    convertList ctx1 rest
            in
            ( t :: ts, ctx2 )


convertFields : Ctx -> List (Node TA.RecordField) -> ( List ( String, Type ), Ctx )
convertFields ctx fields =
    case fields of
        [] ->
            ( [], ctx )

        (Node _ ( nameNode, typeNode )) :: rest ->
            let
                ( t, ctx1 ) =
                    convert ctx (Node.value typeNode)

                ( fs, ctx2 ) =
                    convertFields ctx1 rest
            in
            ( ( nodeString nameNode, t ) :: fs, ctx2 )


-- Resolve a (possibly unqualified) type name to its qualified form. Builtin
-- value types keep their bare spelling; the Prelude ADTs (Maybe/Result/Order)
-- get the "Prelude." prefix; a bare name exposed by an import resolves to the
-- module that DEFINES it (`import Dict exposing (Dict)` -> "Dict.Dict");
-- anything else unqualified is the current module's own type.
qualifyTypeName : TypeTable -> String -> List String -> String -> String
qualifyTypeName typeTable self modName name =
    if not (List.isEmpty modName) then
        String.join "." (resolveTypeModule typeTable modName ++ [ name ])

    else
        case name of
            "Int" ->
                "Int"

            "Float" ->
                "Float"

            "Bool" ->
                "Bool"

            "Char" ->
                "Char"

            "String" ->
                "String"

            "List" ->
                "List"

            "Never" ->
                "Never"

            "Maybe" ->
                "Prelude.Maybe"

            "Result" ->
                "Prelude.Result"

            "Order" ->
                "Prelude.Order"

            _ ->
                case Dict.get name typeTable.bareTypes of
                    Just modStr ->
                        modStr ++ "." ++ name

                    Nothing ->
                        self ++ "." ++ name


-- Rewrite a qualified type reference's module prefix through import aliases:
-- `import Elm.Syntax.Node as Node` makes the type spelling `Node.Node` resolve
-- to `Elm.Syntax.Node.Node`.
resolveTypeModule : TypeTable -> List String -> List String
resolveTypeModule typeTable modName =
    case typeTable.aliases of
        [] ->
            modName

        ( aliasSpelling, real ) :: rest ->
            if String.join "." modName == aliasSpelling then
                real

            else
                resolveTypeModule { typeTable | aliases = rest } modName


-- Lazily create (or fetch) the var for a generic name. `kind` is the use
-- position's kind (KRow only for a GenericRecord tail); first use wins if a
-- name is somehow used at two kinds.
typeVar : Kind -> String -> Ctx -> ( VarId, Ctx )
typeVar kind name ctx =
    case Dict.get name ctx.vars of
        Just v ->
            ( v, ctx )

        Nothing ->
            let
                v =
                    Rep.var ctx.next kind (specialFlex name)
            in
            ( v, { ctx | vars = Dict.insert name v ctx.vars, next = ctx.next + ctx.step } )


specialFlex : String -> Flex
specialFlex name =
    if name == "number" then
        FNumber

    else if name == "appendable" then
        FAppendable

    else if String.startsWith "comparable" name then
        FComparable

    else
        FNone



-- ======================= RENAMING =======================


-- Substitute fresh variables for quantified ones. Hand-written (not
-- `Rep.zonk`) because zonk does not rename a ROW variable bound to a TVar — it
-- only splices `TRecord` bindings — and scheme instantiation must rename row
-- tails (e.g. `forall r. { x : Int | r }`).
rename : Dict Int VarId -> Type -> Type
rename m t =
    case t of
        TVar v ->
            case Dict.get v.id m of
                Just f ->
                    TVar f

                Nothing ->
                    TVar v

        TCon name args ->
            TCon name (List.map (rename m) args)

        TFun a b ->
            TFun (rename m a) (rename m b)

        TTuple ts ->
            TTuple (List.map (rename m) ts)

        TRecord row ->
            TRecord (renameRow m row)


renameRow : Dict Int VarId -> Row -> Row
renameRow m row =
    { fields = List.map (\( n, t ) -> ( n, rename m t )) row.fields
    , tail =
        case row.tail of
            REmpty ->
                REmpty

            RVar v ->
                case Dict.get v.id m of
                    Just f ->
                        RVar f

                    Nothing ->
                        RVar v
    }



-- ======================= HELPERS =======================


nodeString : Node String -> String
nodeString (Node _ s) =
    s


memberById : Int -> List VarId -> Bool
memberById id vars =
    List.any (\v -> v.id == id) vars


dedupeById : List VarId -> List VarId
dedupeById xs =
    List.foldl
        (\v acc ->
            if memberById v.id acc then
                acc

            else
                acc ++ [ v ]
        )
        []
        xs
