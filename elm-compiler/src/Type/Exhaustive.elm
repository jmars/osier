module Type.Exhaustive exposing (check, resolveScrutinee)

{-| Exhaustiveness AND refutation checking for `case` expressions: the
usefulness/coverage algorithm over the pattern matrix (Maranget-style), with
GADT index refinement so an arm that is IMPOSSIBLE under the branch equations
is REFUTED (its absence does not count as a coverage gap).

How refutation works. Each constructor carries its RESULT type (the GADT index,
e.g. `HNil : HList {}` vs `HCons : … -> HList {l:t|rho}`). When the coverage
check specializes a matrix on constructor `C` against a column of type `τ`, it
UNIFIES `C`'s result type with `τ`:

  * if unification FAILS, `C` is IMPOSSIBLE at `τ` — it is refuted and skipped
    (not a gap);
  * if it SUCCEEDS, the resulting substitution REFINES the remaining column
    types (`rest`) and the constructor's argument types, exactly the index
    equations the branch store `Δ` would impose.

That is the incompatibility rule: a constructor whose result index is
provably NOT unifiable with the scrutinee's (refined) index is impossible, and
`unifyPure` is the decider. The row half is the interesting one — `HList {}`
unifies with `HList rho` (an open row) but NOT with `HList {k:s|rho}` (a row
whose closed-empty index cannot absorb the field `k`); a `There` arm that
refines `rho ~ {k:s|rho'}` therefore makes the `(There _, HNil)` case refutable.

The check is PURE. A constructor scheme's quantifiers are RENAMED to fresh
negative ids (they share the 0,1,2… id space with the inference state), so
`unifyPure` can bind them without self-loops. Row-kind substitutions never
change the HEAD shape this check reads, so the row unification only needs to
decide compatibility and bind the row tails.

-}

import Dict exposing (Dict)
import Elm.Syntax.Node as Node exposing (Node)
import Elm.Syntax.Pattern as Pattern exposing (Pattern(..))
import Type.Env as Env exposing (Env)
import Type.Representation as Rep exposing (Flex(..), Kind(..), Row, RowTail(..), Type(..), VarId)


{-| A pattern reduced to what matters for coverage: its head. Sub-patterns are
carried only for the heads that have them (constructor and tuple).
-}
type Pat
    = PWild
    | PCon String (List Pat)
    | PTuple (List Pat)
    | PLit String
    | PUnit
    | PRecord


{-| The matrix of a `case`: one row per arm, one column per pattern position.
-}
type alias Matrix =
    List (List Pat)


{-| A constructor of the scrutinee type, with its (freshened) result type and
argument types.
-}
type alias Ctor =
    { name : String
    , result : Type
    , args : List Type
    }


{-| Reduce an elm-syntax pattern to a coverage `Pat`. A variable, wildcard,
`as`, and parenthesised pattern all cover everything at their column; an `as`
alias does not constrain, but its INNER pattern does, so it is followed (an
`x @ (Just y)` matches the same values as `Just y`).
-}
fromPattern : Pattern -> Pat
fromPattern pat =
    case pat of
        AllPattern ->
            PWild

        VarPattern _ ->
            PWild

        UnitPattern ->
            PUnit

        CharPattern c ->
            PLit (String.fromChar c)

        StringPattern s ->
            PLit s

        IntPattern n ->
            PLit (String.fromInt n)

        HexPattern n ->
            PLit (String.fromInt n)

        FloatPattern f ->
            PLit (String.fromFloat f)

        TuplePattern ps ->
            PTuple (List.map (\n -> fromPattern (Node.value n)) ps)

        UnConsPattern left right ->
            PCon "::" [ fromPattern (Node.value left), fromPattern (Node.value right) ]

        ListPattern ps ->
            case ps of
                [] ->
                    PCon "[]" []

                p :: rest ->
                    PCon "::" [ fromPattern (Node.value p), fromPattern (ListPattern rest) ]

        NamedPattern qref subs ->
            if List.isEmpty qref.moduleName && (qref.name == "True" || qref.name == "False") then
                PCon qref.name []

            else
                PCon qref.name (List.map (\n -> fromPattern (Node.value n)) subs)

        AsPattern inner _ ->
            fromPattern (Node.value inner)

        ParenthesizedPattern inner ->
            fromPattern (Node.value inner)

        RecordPattern _ ->
            PRecord



-- ======================= COVERAGE ALGORITHM =======================


{-| Public entry: is the `case` (scrutinee `Type`, one pattern per arm)
exhaustive?  `Err witness` names one uncovered case (a constructor, or `_`).
-}
check : Env -> Type -> List (Node Pattern) -> Result String ()
check env scrutinee pats =
    complete env (-1) (List.map (\n -> [ fromPattern (Node.value n) ]) pats) [ scrutinee ]


{-| Resolve a scrutinee type whose flexible variables are not yet bound (the
branch-local lift captures the binding as a rolled-back equation) by UNIFYING
it with the clauses' inferred pattern types. Returns the zonked result, or the
original type if the patterns are mutually incompatible (a GADT scrutinee whose
abstract index the arms refine to DIFFERENT concrete types — `Expr Int`,
`Expr Bool`, `Expr (a,b)` — so the original abstract index is the right type).
-}
resolveScrutinee : Type -> List Type -> Type
resolveScrutinee stZ pts =
    resolveScrutineeHelp stZ stZ (-1000) pts


{-| The recursive fold `resolveScrutinee` needs, hoisted to the TOP LEVEL:
the substrate's compiler supports only a sequential (non-recursive) local
`let`, so a local helper cannot call itself. Threading `stZ` (the `Nothing`
fallback) through closes over what the local `tryResolve` used to capture.
-}
resolveScrutineeHelp : Type -> Type -> Int -> List Type -> Type
resolveScrutineeHelp stZ acc next remaining =
    case remaining of
        [] ->
            acc

        p :: rest ->
            case unifyPure next acc p of
                Just ( subst, next2 ) ->
                    resolveScrutineeHelp stZ (Rep.zonk subst acc) next2 rest

                Nothing ->
                    stZ


{-| `complete matrix types` holds iff every value-vector whose column types are
`types` is matched by some row of `matrix`.  `Err _` is an uncovered witness
(the caller reconstructs the constructor name at the failure site). `next` is
the freshening counter (negative ids, shared so constructor quantifiers never
collide with each other or with the inference state).
-}
complete : Env -> Int -> Matrix -> List Type -> Result String ()
complete env next matrix types =
    if List.isEmpty matrix then
        -- No row matches anything. The match is only (vacuously) covered if
        -- the FIRST column type is uninhabited (`Never`); otherwise a gap.
        -- Short-circuiting here also stops a recursive ADT constructor
        -- argument (`type T = A T | B`) from recursing forever through the
        -- (empty) matrix.
        case types of
            (TCon "Never" _) :: _ ->
                Ok ()

            _ ->
                Err "_"

    else
        case types of
            [] ->
                Ok ()

            tau :: rest ->
                if List.any (List.all isWild) matrix then
                    Ok ()

                else if List.all headIsWild matrix then
                    -- Every row matches EVERY value of the first column (its
                    -- head is a wildcard), so the column is saturated and
                    -- irrelevant to coverage: drop it. Without this, a
                    -- RECURSIVE constructor argument (`Then : Step from ->
                    -- ... -> Step to`, matched `Then prev _` with `prev`
                    -- wildcard) would re-expand the wildcard through the
                    -- recursive type forever.
                    complete env next (List.map dropHead matrix) rest

                else
                    case tau of
                        TCon _ _ ->
                            completeCon env next tau matrix rest

                        TTuple ts ->
                            complete env next (specializeTuple matrix (List.length ts)) (ts ++ rest)

                        TRecord _ ->
                            complete env next (specializeRecord matrix) rest

                        TVar _ ->
                            -- A variable of unknown shape: only a wildcard covers it.
                            complete env next (specializeWild matrix) rest

                        TFun _ _ ->
                            -- Unreachable: a function value cannot be matched.
                            Ok ()


completeCon : Env -> Int -> Type -> Matrix -> List Type -> Result String ()
completeCon env next tau matrix rest =
    case tau of
        TCon name _ ->
            if name == "Int" || name == "Float" || name == "String" || name == "Char" then
                -- An atom type: infinitely many literal values, only a wildcard covers.
                complete env next (specializeWild matrix) rest

            else if name == "()" then
                -- The single unit value: a unit or wildcard pattern covers it.
                complete env next (specializeUnit matrix) rest

            else
                let
                    ( ctors, next2 ) =
                        ctorsOf env next tau
                in
                case ctors of
                    [] ->
                        -- Uninhabited (e.g. `Never`) or an opaque type with no
                        -- registered constructors: nothing to cover.
                        Ok ()

                    _ ->
                        firstUncovered env next2 ctors tau matrix rest

        _ ->
            -- Reached only via a non-TCon head (handled by `complete`).
            Ok ()


firstUncovered : Env -> Int -> List Ctor -> Type -> Matrix -> List Type -> Result String ()
firstUncovered env next ctors tau matrix rest =
    case ctors of
        [] ->
            Ok ()

        c :: more ->
            case unifyPure next c.result tau of
                Nothing ->
                    -- REFUTED: c's result index cannot unify with the (refined)
                    -- scrutinee column type, so no value of that type is c.
                    firstUncovered env next more tau matrix rest

                Just ( subst, next2 ) ->
                    let
                        argC =
                            List.map (Rep.zonk subst) c.args

                        restRefined =
                            List.map (Rep.zonk subst) rest
                    in
                    case complete env next2 (specialize matrix ( c.name, argC )) (argC ++ restRefined) of
                        Ok () ->
                            firstUncovered env next more tau matrix rest

                        Err _ ->
                            Err (describeCtor c.name argC)


{-| Human name of one missing constructor arm: `C` (nullary) or `C _ .. _`.
-}
describeCtor : String -> List Type -> String
describeCtor cname ctorArgs =
    if List.isEmpty ctorArgs then
        cname

    else
        cname ++ " " ++ String.join " " (List.map (\_ -> "_") ctorArgs)



-- ======================= MATRIX OPERATIONS =======================


isWild : Pat -> Bool
isWild p =
    case p of
        PWild ->
            True

        _ ->
            False


{-| Is the first pattern of a row a wildcard?
-}
headIsWild : List Pat -> Bool
headIsWild row =
    case row of
        PWild :: _ ->
            True

        _ ->
            False


{-| Drop the first pattern of a (non-empty) row.
-}
dropHead : List Pat -> List Pat
dropHead row =
    case row of
        _ :: tail ->
            tail

        [] ->
            []


{-| Specialize a matrix on one constructor: keep rows headed by that
constructor (sub-patterns become the new leading columns) or by a wildcard
(expanded to `n` wildcards); drop everything else.
-}
specialize : Matrix -> ( String, List Type ) -> Matrix
specialize matrix ( cname, ctorArgs ) =
    let
        n =
            List.length ctorArgs
    in
    List.concatMap
        (\row ->
            case row of
                (PCon nm subs) :: tail ->
                    if nm == cname then
                        [ subs ++ tail ]

                    else
                        []

                PWild :: tail ->
                    [ List.repeat n PWild ++ tail ]

                _ ->
                    []
        )
        matrix


specializeTuple : Matrix -> Int -> Matrix
specializeTuple matrix n =
    List.concatMap
        (\row ->
            case row of
                (PTuple subs) :: tail ->
                    if List.length subs == n then
                        [ subs ++ tail ]

                    else
                        []

                PWild :: tail ->
                    [ List.repeat n PWild ++ tail ]

                _ ->
                    []
        )
        matrix


specializeRecord : Matrix -> Matrix
specializeRecord matrix =
    List.filterMap
        (\row ->
            case row of
                PRecord :: tail ->
                    Just tail

                PWild :: tail ->
                    Just tail

                _ ->
                    Nothing
        )
        matrix


specializeUnit : Matrix -> Matrix
specializeUnit matrix =
    List.filterMap
        (\row ->
            case row of
                PUnit :: tail ->
                    Just tail

                PWild :: tail ->
                    Just tail

                _ ->
                    Nothing
        )
        matrix


{-| Drop every row whose head is not a wildcard (a literal/constructor/tuple/
record/unit head never covers an atom type or a type variable).
-}
specializeWild : Matrix -> Matrix
specializeWild matrix =
    List.filterMap
        (\row ->
            case row of
                PWild :: tail ->
                    Just tail

                _ ->
                    Nothing
        )
        matrix



-- ======================= CONSTRUCTOR TABLE =======================


{-| The constructors of a scrutinee type, as freshened `Ctor`s. `Bool` and
`List` are builtins with no registered schemes; every other ADT's constructors
are found by scanning the environment for schemes whose result type has the
scrutinee's name.
-}
ctorsOf : Env -> Int -> Type -> ( List Ctor, Int )
ctorsOf env next scrutinee =
    case scrutinee of
        TCon name args ->
            if name == "Bool" then
                ( [ { name = "True", result = Rep.tBool, args = [] }, { name = "False", result = Rep.tBool, args = [] } ], next )

            else if name == "List" then
                let
                    elem =
                        case args of
                            a :: _ ->
                                a

                            [] ->
                                dummyHead
                in
                ( [ { name = "[]", result = Rep.tList elem, args = [] }, { name = "::", result = Rep.tList elem, args = [ elem, Rep.tList elem ] } ], next )

            else
                Dict.foldl
                    (\qname scheme ( acc, n ) ->
                        case peelResult scheme.body of
                            TCon rname _ ->
                                if rname == name then
                                    let
                                        ( body, n2, _ ) =
                                            freshenVars n Dict.empty scheme.body
                                    in
                                    ( { name = bareName qname, result = peelResult body, args = argTypes body } :: acc, n2 )

                                else
                                    ( acc, n )

                            _ ->
                                ( acc, n )
                    )
                    ( [], next )
                    env.ctors

        _ ->
            ( [], next )


{-| Rename every type-variable id to a fresh id drawn from `next` (memoized per
raw id), isolating a constructor scheme's quantifiers from the 0,1,2… id space
the inference state uses (a raw match would otherwise bind `0 := 0` and zonk
forever). `next` is shared across constructors, so two schemes' quantifiers can
never collide with each other.
-}
freshenVars : Int -> Dict Int VarId -> Type -> ( Type, Int, Dict Int VarId )
freshenVars next ren t =
    case t of
        TVar v ->
            case Dict.get v.id ren of
                Just v2 ->
                    ( TVar v2, next, ren )

                Nothing ->
                    let
                        v2 =
                            Rep.var next v.kind v.flex
                    in
                    ( TVar v2, next - 1, Dict.insert v.id v2 ren )

        TCon n args ->
            let
                ( args2, n2, ren2 ) =
                    freshenList next ren args
            in
            ( TCon n args2, n2, ren2 )

        TFun a b ->
            let
                ( a2, n2, ren2 ) =
                    freshenVars next ren a
            in
            let
                ( b2, n3, ren3 ) =
                    freshenVars n2 ren2 b
            in
            ( TFun a2 b2, n3, ren3 )

        TTuple ts ->
            let
                ( ts2, n2, ren2 ) =
                    freshenList next ren ts
            in
            ( TTuple ts2, n2, ren2 )

        TRecord row ->
            let
                ( fields2, n2, ren2 ) =
                    freshenFields next ren row.fields
            in
            case row.tail of
                REmpty ->
                    ( TRecord { fields = fields2, tail = REmpty }, n2, ren2 )

                RVar v ->
                    case Dict.get v.id ren2 of
                        Just v2 ->
                            ( TRecord { fields = fields2, tail = RVar v2 }, n2, ren2 )

                        Nothing ->
                            let
                                v2 =
                                    Rep.var n2 v.kind v.flex
                            in
                            ( TRecord { fields = fields2, tail = RVar v2 }, n2 - 1, Dict.insert v.id v2 ren2 )


freshenList : Int -> Dict Int VarId -> List Type -> ( List Type, Int, Dict Int VarId )
freshenList next ren ts =
    case ts of
        [] ->
            ( [], next, ren )

        t :: rest ->
            let
                ( t2, n2, ren2 ) =
                    freshenVars next ren t
            in
            let
                ( rest2, n3, ren3 ) =
                    freshenList n2 ren2 rest
            in
            ( t2 :: rest2, n3, ren3 )


freshenFields : Int -> Dict Int VarId -> List ( String, Type ) -> ( List ( String, Type ), Int, Dict Int VarId )
freshenFields next ren fields =
    case fields of
        [] ->
            ( [], next, ren )

        ( n, t ) :: rest ->
            let
                ( t2, n2, ren2 ) =
                    freshenVars next ren t
            in
            let
                ( rest2, n3, ren3 ) =
                    freshenFields n2 ren2 rest
            in
            ( ( n, t2 ) :: rest2, n3, ren3 )



-- ======================= PURE UNIFICATION (refutation) =======================


{-| Unify two index types, binding variables as needed. `Nothing` = the types
are INCOMPATIBLE (the refutation verdict); `Just subst` carries the bindings to
refine the other column types and the constructor's arguments. `next` is the
freshening counter, advanced by any fresh row tail the row rewrite introduces.
-}
unifyPure : Int -> Type -> Type -> Maybe ( Dict Int Type, Int )
unifyPure next a b =
    case ( a, b ) of
        ( TVar v, TVar w ) ->
            if v.id == w.id then
                Just ( Dict.empty, next )

            else
                bindVar next v (TVar w)

        ( TVar v, t ) ->
            bindVar next v t

        ( t, TVar v ) ->
            bindVar next v t

        ( TCon n1 a1, TCon n2 a2 ) ->
            if n1 == n2 && List.length a1 == List.length a2 then
                unifyList next a1 a2

            else
                Nothing

        ( TTuple t1, TTuple t2 ) ->
            if List.length t1 == List.length t2 then
                unifyList next t1 t2

            else
                Nothing

        ( TRecord r1, TRecord r2 ) ->
            unifyRow next r1 r2

        _ ->
            Nothing


bindVar : Int -> VarId -> Type -> Maybe ( Dict Int Type, Int )
bindVar next v t =
    if Rep.occurs v t then
        Nothing

    else
        Just ( Dict.singleton v.id t, next )


unifyList : Int -> List Type -> List Type -> Maybe ( Dict Int Type, Int )
unifyList next a b =
    case ( a, b ) of
        ( [], [] ) ->
            Just ( Dict.empty, next )

        ( x :: xs, y :: ys ) ->
            case unifyPure next x y of
                Nothing ->
                    Nothing

                Just ( s1, n1 ) ->
                    case unifyList n1 xs ys of
                        Nothing ->
                            Nothing

                        Just ( s2, n2 ) ->
                            Just ( Dict.union s1 s2, n2 )

        _ ->
            Nothing


{-| Unify two rows. A field present in one row but absent from the other must
be absorbable by the other's tail: a CLOSED tail (`REmpty`) cannot absorb a new
field, which is exactly the `HList {}` vs `HList {k:s|rho}` incompatibility the
refutation hinges on.
-}
unifyRow : Int -> Row -> Row -> Maybe ( Dict Int Type, Int )
unifyRow next r1 r2 =
    case r1.fields of
        ( l, t ) :: rest1 ->
            case removeField l r2 of
                Just ( t2, r2rest ) ->
                    case unifyPure next t t2 of
                        Nothing ->
                            Nothing

                        Just ( s1, n1 ) ->
                            case unifyRow n1 { fields = rest1, tail = r1.tail } r2rest of
                                Nothing ->
                                    Nothing

                                Just ( s2, n2 ) ->
                                    Just ( Dict.union s1 s2, n2 )

                Nothing ->
                    -- `l` only in r1: absorb it into r2's tail if it is open.
                    case r2.tail of
                        REmpty ->
                            Nothing

                        RVar a ->
                            let
                                beta =
                                    Rep.var next KRow FNone
                            in
                            case
                                unifyRow (next - 1)
                                    { fields = rest1, tail = r1.tail }
                                    { fields = r2.fields, tail = RVar beta }
                            of
                                Nothing ->
                                    Nothing

                                Just ( s2, n2 ) ->
                                    Just
                                        ( Dict.insert a.id (TRecord { fields = [ ( l, t ) ], tail = RVar beta }) s2
                                        , n2
                                        )

        [] ->
            unifyTail next r1.tail r2


unifyTail : Int -> RowTail -> Row -> Maybe ( Dict Int Type, Int )
unifyTail next tail r2 =
    case tail of
        REmpty ->
            case r2.fields of
                [] ->
                    case r2.tail of
                        REmpty ->
                            Just ( Dict.empty, next )

                        RVar a ->
                            bindVar next a (TRecord { fields = [], tail = REmpty })

                _ ->
                    -- A closed empty row cannot absorb r2's fields.
                    Nothing

        RVar a ->
            bindVar next a (TRecord r2)


{-| Find and remove the FIRST occurrence of a field label from a row.
-}
removeField : String -> Row -> Maybe ( Type, Row )
removeField l row =
    case row.fields of
        [] ->
            Nothing

        ( l2, t ) :: rest ->
            if l2 == l then
                Just ( t, { fields = rest, tail = row.tail } )

            else
                Maybe.map
                    (\( t2, r ) -> ( t2, { fields = ( l2, t ) :: r.fields, tail = r.tail } ))
                    (removeField l { fields = rest, tail = row.tail })



-- ======================= HELPERS =======================


dummyHead : Type
dummyHead =
    TVar (Rep.var (-1000000) KType FNone)


peelResult : Type -> Type
peelResult t =
    case t of
        TFun _ res ->
            peelResult res

        _ ->
            t


argTypes : Type -> List Type
argTypes t =
    case t of
        TFun a b ->
            a :: argTypes b

        _ ->
            []


bareName : String -> String
bareName qname =
    String.fromList (List.reverse (takeUntilDot (List.reverse (String.toList qname))))


takeUntilDot : List Char -> List Char
takeUntilDot chars =
    case chars of
        [] ->
            []

        c :: rest ->
            if c == '.' then
                []

            else
                c :: takeUntilDot rest
