module Type.Unify exposing
    ( UnifyError(..)
    , State
    , Equation
    , emptyState
    , freshVar
    , markRigid
    , unmarkRigid
    , isRigid
    , pushEq
    , dropEqsFrom
    , snapshotEqs
    , unify
    , unifyBranch
    , dischargeRow
    , dischargeType
    , pendingTypeOccurs
    , typeOccursIn
    , describe
    )

{-| Row/type unification: Robinson unification (the paper's Fig-2) extended
with the row-rewrite relation (Fig-3) for Leijen-style extensible records with
scoped labels.

Records are unified by `uni-row`: to unify `Row(l :: t | r)` with `s`, the
right-hand row `s` is *rewritten* (Fig-3) to expose `l` at its head, then the
field types and tails are unified. The rewrite has three cases: `row-head`
(the label is already first), `row-swap` (bubble `l` to the front, only across
a prefix of DISTINCT labels — Fig-1's `eq-swap`), and `row-var` (the tail is a
variable `a`, which binds to `Row(l :: fresh-gamma | fresh-beta)`). The
`row-var` case is guarded by the paper's side condition `a /= tail(r)` — the
LEFT row's tail variable is passed down as `forbidden` — which is what makes
unification terminate for the classic `\r -> if True then {x=2|r} else {y=2|r}`
program (that program is then a type error, not a loop).

This module is pure Elm (elm/core + Type.Representation) and must stay free of
`Lower.*` imports so it can be unit-tested in isolation via `src/TestMain.elm`.

-}

import Set exposing (Set)
import Type.Representation as Rep exposing (Flex(..), Kind(..), Row, RowTail(..), Subst, Type(..), VarId)


{-| A unification failure. `describe` renders it as a human-readable message;
the Infer pass attaches a source range before reporting it.
-}
type UnifyError
    = MissingField String
    | CannotUnify Type Type
    | InfiniteType VarId Type
    | FlexConflict Flex Type
    | RigidVar VarId Type


{-| Unification state: the accumulated kinded substitution, the next fresh
variable id, and the set of RIGID (skolem) variable ids. Fresh ids are globally
unique across kinds (see `freshVar`).

A rigid variable is a signature's universally-quantified variable while its
body is being checked. It may be aliased BY a flexible variable (the common
`f : a -> a / f x = x` case binds the pattern's fresh var TO the skolem), but
it may never itself be bound to anything — so the body cannot specialize it.
-}
type alias State =
    { subst : Subst
    , fresh : Int
    , rigid : Set Int
    , eqs : List Equation
    }


{-| A DELAYED unification obligation (the row-GADT refinement store). Written
by `unifyBranch` when a rigid variable's binding is captured instead of
solved, read by the discharge sites (record select/update) inside the
refining branch, and dropped wholesale at branch end. Never read by the
global `unify` path.
-}
type alias Equation =
    { target : VarId
    , body : Type
    }


emptyState : State
emptyState =
    { subst = Rep.emptySubst, fresh = 0, rigid = Set.empty, eqs = [] }


{-| Push a delayed equation onto the store (most recent first).
-}
pushEq : Equation -> State -> State
pushEq eq state =
    { state | eqs = eq :: state.eqs }


{-| Drop every equation pushed after the given snapshot (the branch-end
restore: the store is rolled back to its state at the snapshot point).
-}
dropEqsFrom : List Equation -> State -> State
dropEqsFrom snapshot state =
    { state | eqs = snapshot }


{-| Mark a variable id as rigid (a skolem).
-}
markRigid : VarId -> State -> State
markRigid v state =
    { state | rigid = Set.insert v.id state.rigid }


{-| Un-mark a variable id (branch scope exit: a constructor-introduced
existential is rigid only WITHIN its case branch — see `inferCaseClause`).
-}
unmarkRigid : VarId -> State -> State
unmarkRigid v state =
    { state | rigid = Set.remove v.id state.rigid }


{-| Is a variable id rigid (a skolem)?
-}
isRigid : State -> VarId -> Bool
isRigid state v =
    Set.member v.id state.rigid


{-| DISCHARGE (the calculus's TYPE-equation half of the result rule): consult
the equation store for a TYPE equation on the (rigid) variable `a` — a
KType-kinded equation body, NOT a row (`TRecord` bodies are row equations and
are never discharged at results; their escape check stays). Returns the
equation's TARGET and its zonked body WITHOUT binding anything. `Nothing` =
no usable type equation (the caller keeps its historical failure).
-}
dischargeType : State -> VarId -> Maybe ( VarId, Type )
dischargeType state a =
    findEq state.eqs a
        |> Maybe.andThen
            (\eq ->
                case Rep.zonk state.subst eq.body of
                    TRecord _ ->
                        -- A row equation (rho ~ {l:t|rho'}): never discharged
                        -- at a result — discharging it would let a row's DOMAIN
                        -- change escape its branch (rowgadt_escape).
                        Nothing

                    body ->
                        Just ( eq.target, body )
            )


{-| The equation lifecycle's occurs check: is any pending KType equation
refuting — its ZONKED body contains its own target? A captured refinement
`a ~ List a_field` turns into `a ~ List a` (an infinite type) once the branch
aliases the determined field variable `a_field` to the rigid index `a`
(`unifyVarVar`'s flex → rigid alias), and that refutation must be caught
before the equation is discarded or a result is accepted. Row equations are
excluded: their tail-vs-head escape is the domain check's job. Returns the
refuting (target, body) pair, most recent first.
-}
pendingTypeOccurs : State -> Maybe ( VarId, Type )
pendingTypeOccurs state =
    typeOccursIn (ktypeEqs state.eqs) state


{-| `pendingTypeOccurs` over an explicit list of `(target, body)` KType
equations (the clause's surviving refined-equation set — see
`Infer.refinedTypeEqs`), so the check runs on the clause's result
substitution even after `restoreEqsM` dropped the live store.
-}
typeOccursIn : List ( VarId, Type ) -> State -> Maybe ( VarId, Type )
typeOccursIn eqs state =
    List.filterMap
        (\( target, body ) ->
            let
                z =
                    Rep.zonk state.subst body
            in
            if Rep.occurs target z then
                Just ( target, z )

            else
                Nothing
        )
        eqs
        |> List.head


ktypeEqs : List Equation -> List ( VarId, Type )
ktypeEqs eqs =
    List.filterMap
        (\eq ->
            if eq.target.kind == KType then
                Just ( eq.target, eq.body )

            else
                Nothing
        )
        eqs



{-| Allocate a fresh type variable of the given kind and flex marker.
-}
freshVar : Kind -> Flex -> State -> ( VarId, State )
freshVar kind flex state =
    ( Rep.var state.fresh kind flex, { state | fresh = state.fresh + 1 } )



{-| DISCHARGE (the calculus's row-discharge rule): consult the equation
store for an equation on the (rigid) row variable `a` whose row, after ONE
zonk, exposes label `l`. Returns the exposed field type and the remainder
row — WITHOUT binding anything. `Nothing` = no usable equation (the caller
keeps its historical failure). This is the only reader of the store.
-}
dischargeRow : State -> VarId -> String -> Maybe ( Type, Row )
dischargeRow state a l =
    findEq state.eqs a
        |> Maybe.andThen
            (\eq ->
                case Rep.zonk state.subst eq.body of
                    TRecord row ->
                        case row.fields of
                            ( l2, t ) :: rest ->
                                if l2 == l then
                                    Just ( t, { fields = rest, tail = row.tail } )

                                else
                                    -- The equation's head label differs: the
                                    -- refinement does not expose `l`.
                                    Nothing

                            [] ->
                                Nothing

                    _ ->
                        Nothing
            )


findEq : List Equation -> VarId -> Maybe Equation
findEq eqs a =
    case eqs of
        [] ->
            Nothing

        eq :: rest ->
            if eq.target.id == a.id then
                Just eq

            else
                findEq rest a


{-| The equation-store snapshot: the identity of the store at snapshot time.
Restore by `dropEqsFrom`. (The list IS the prefix; restoring truncates every
equation pushed after the snapshot point, however deeply nested the branch.)
-}
snapshotEqs : State -> List Equation
snapshotEqs state =
    state.eqs



-- Unification.


{-| Unify two types under the current substitution, returning the extended
substitution (kinded: row variables only ever bind to `TRecord` values).

GLOBAL discipline: a rigid (skolem) variable is never bound — the guards in
`unifyVarVar`/`bindVar`/`bindRowVar`/`rewrite` fail with `RigidVar`. `unify`
is `unifyGeneral False`; every decision on that path is unchanged.
-}
unify : State -> Type -> Type -> Result UnifyError State
unify =
    unifyGeneral False


{-| BRANCH-LOCAL unification (the GADT refinement path). Like `unify`, except
that a would-be binding of a RIGID variable is CAPTURED as a delayed
`Equation` on the store (the rigid var stays unbound) and unification
continues. The caller snapshots `eqs` first and restores at branch end, so
nothing global is ever bound by these equations. All other failures — kind
mismatch, occurs, flex markers, missing fields, shared tails — behave exactly
like the global path.
-}
unifyBranch : State -> Type -> Type -> Result UnifyError ( State, List Equation )
unifyBranch state t1 t2 =
    unifyGeneral True state t1 t2
        |> Result.map (\st -> ( st, st.eqs ))


unifyGeneral : Bool -> State -> Type -> Type -> Result UnifyError State
unifyGeneral branch state t1 t2 =
    let
        z1 =
            Rep.zonk state.subst t1

        z2 =
            Rep.zonk state.subst t2
    in
    case ( z1, z2 ) of
        ( TVar v1, TVar v2 ) ->
            unifyVarVar branch state v1 v2

        ( TVar v, TRecord row ) ->
            if v.kind == KRow && rowIsSameVar v row then
                -- `rho ~ { | rho }`: the bare-var-vs-record identity. The
                -- flex-alias path in `bindRowVar` binds a flex var to the
                -- RECORD wrapper `{|rigid}`, which resurfaces here when the
                -- rigid var meets its own alias (previously a spurious
                -- CannotUnify on a legal program).
                Ok state

            else if branch && v.kind == KRow then
                bindRowVar branch state v row

            else
                bindVar branch state v (TRecord row)

        ( TVar v, t ) ->
            -- A bare KRow variable against a NON-record type: only the
            -- GADT index shapes reach here with a record; anything else is
            -- the historical kind-mismatch error.
            if branch && v.kind == KRow then
                case t of
                    TRecord row ->
                        bindRowVar branch state v row

                    _ ->
                        bindVar branch state v t

            else
                bindVar branch state v t

        ( t, TVar v ) ->
            if v.kind == KRow then
                case t of
                    TRecord row ->
                        if rowIsSameVar v row then
                            Ok state

                        else
                            bindRowVar branch state v row

                    _ ->
                        bindVar branch state v t

            else
                bindVar branch state v t

        ( TCon n1 a1, TCon n2 a2 ) ->
            if n1 /= n2 then
                Err (CannotUnify z1 z2)

            else if List.length a1 /= List.length a2 then
                Err (CannotUnify z1 z2)

            else
                unifyList branch state a1 a2

        ( TFun p1 q1, TFun p2 q2 ) ->
            unifyGeneral branch state p1 p2 |> Result.andThen (\s -> unifyGeneral branch s q1 q2)

        ( TTuple ts1, TTuple ts2 ) ->
            if List.length ts1 == List.length ts2 then
                unifyList branch state ts1 ts2

            else
                Err (CannotUnify z1 z2)

        ( TRecord r1, TRecord r2 ) ->
            unifyRow branch state r1 r2

        _ ->
            Err (CannotUnify z1 z2)


unifyList : Bool -> State -> List Type -> List Type -> Result UnifyError State
unifyList branch state ts1 ts2 =
    case ( ts1, ts2 ) of
        ( [], [] ) ->
            Ok state

        ( t1 :: r1, t2 :: r2 ) ->
            unifyGeneral branch state t1 t2 |> Result.andThen (\s -> unifyList branch s r1 r2)

        -- Unreachable: callers pre-check that the two lists have equal length.
        _ ->
            Err (CannotUnify (TTuple ts1) (TTuple ts2))


unifyVarVar : Bool -> State -> VarId -> VarId -> Result UnifyError State
unifyVarVar branch state v1 v2 =
    if v1.id == v2.id then
        Ok state

    else if v1.kind == KRow && v2.kind == KRow then
        -- Two bare ROW variables (the GADT index shape: the tail of one row
        -- refinement meeting the tail of another — `hget`'s recursive call
        -- unifies `rho' ~ rho1` with both sides bare KRow vars). Alias them
        -- through the row-variable path, which already carries the rigid/flex
        -- discipline (a rigid tail may only be aliased BY a flex var, never
        -- bound; two rigid tails stay an error, or a captured equation in
        -- branch mode). This was previously an unreachable-seeming
        -- `CannotUnify`; it is in fact reachable and legitimate.
        bindRowVar branch state v1 { fields = [], tail = RVar v2 }

    else if v1.kind /= KType || v2.kind /= KType then
        Err (CannotUnify (TVar v1) (TVar v2))

    else if isRigid state v1 && isRigid state v2 then
        -- Two distinct skolems cannot be identified (e.g. `f : a -> b -> a`
        -- with a body that returns its second argument). In branch mode the
        -- identification is only the branch's local refinement: capture it.
        if branch then
            Ok (pushEq { target = v1, body = TVar v2 } state)

        else
            Err (RigidVar v1 (TVar v2))

    else if isRigid state v1 then
        -- v1 is a skolem: it may not be bound, so alias the FLEX v2 to it —
        -- unless v2 carries a `number`/`comparable`/`appendable` constraint
        -- the signature does not promise (`f : a -> a / f x = x + 1`).
        case v2.flex of
            FNone ->
                Ok (addSubst state v2 (TVar v1))

            flex ->
                Err (FlexConflict flex (TVar v1))

    else if isRigid state v2 then
        case v1.flex of
            FNone ->
                Ok (addSubst state v1 (TVar v2))

            flex ->
                Err (FlexConflict flex (TVar v2))

    else
        case ( v1.flex, v2.flex ) of
            ( FNone, _ ) ->
                Ok (addSubst state v1 (TVar v2))

            ( _, FNone ) ->
                Ok (addSubst state v2 (TVar v1))

            -- numbers are comparable, so the more specific marker wins.
            ( FNumber, FComparable ) ->
                Ok (addSubst state v2 (TVar v1))

            ( FComparable, FNumber ) ->
                Ok (addSubst state v1 (TVar v2))

            ( f1, f2 ) ->
                if f1 == f2 then
                    Ok (addSubst state v1 (TVar v2))

                else
                    Err (FlexConflict f1 (TVar v2))


{-| Bind a type variable `v` to type `t` (already zonked). Enforces the occurs
check and the flex-marker constraint, propagating the marker through `List`
and `Tuple` structure (e.g. `comparable ~ List a` marks `a` comparable).
-}
bindVar : Bool -> State -> VarId -> Type -> Result UnifyError State
bindVar branch state v t =
    if v.kind /= KType then
        Err (CannotUnify (TVar v) t)

    else if isRigid state v then
        -- A skolem cannot be specialized to a concrete type (e.g.
        -- `f : a -> a / f x = "hello"` binds the skolem to String). In
        -- branch mode the specialization is the branch's local refinement
        -- (the row-GADT equation, e.g. rho^ ~ {l:t|rho'}): capture it and
        -- leave the skolem unbound.
        if branch then
            Ok (pushEq { target = v, body = t } state)

        else
            Err (RigidVar v t)

    else if Rep.occurs v t then
        Err (InfiniteType v t)

    else
        case v.flex of
            FNone ->
                Ok (addSubst state v t)

            flex ->
                propagate flex t state
                    |> Result.map (\( t2, st ) -> addSubst st v t2)



-- Row unification (the paper's `uni-row` + Fig-3 rewrite).


unifyRow : Bool -> State -> Row -> Row -> Result UnifyError State
unifyRow branch state r1 r2 =
    case r1.fields of
        ( l, t ) :: rest1 ->
            case rewrite branch state (tailVar r1) r2 l of
                Err (MissingFieldE l2) ->
                    Err (MissingField l2)

                Err (SharedTailE _) ->
                    Err (CannotUnify (TRecord r1) (TRecord r2))

                Err (RigidRowE a) ->
                    Err (RigidVar a (TRecord r2))

                Ok ( t2, s2, state1 ) ->
                    unifyGeneral branch state1 t t2
                        |> Result.andThen
                            (\state2 ->
                                unifyRow branch state2
                                    (Rep.zonkRow state2.subst { fields = rest1, tail = r1.tail })
                                    (Rep.zonkRow state2.subst s2)
                            )

        [] ->
            unifyTail branch state r1.tail r2


unifyTail : Bool -> State -> RowTail -> Row -> Result UnifyError State
unifyTail branch state tail r2 =
    case tail of
        REmpty ->
            case r2.fields of
                [] ->
                    case r2.tail of
                        REmpty ->
                            Ok state

                        RVar b ->
                            bindRowVar branch state b { fields = [], tail = REmpty }

                ( l, _ ) :: _ ->
                    Err (MissingField l)

        RVar a ->
            bindRowVar branch state a r2


bindRowVar : Bool -> State -> VarId -> Row -> Result UnifyError State
bindRowVar branch state a row =
    if a.kind /= KRow then
        Err (CannotUnify (TVar a) (TRecord row))

    else if rowIsSameVar a row then
        Ok state

    else if isRigid state a then
        -- A rigid row tail may only be ALIASED to another (flex) row variable
        -- (the row analogue of the flex -> skolem alias in `unifyVarVar`):
        -- binding it to a closed, fielded, or extended row specializes the
        -- signature's row variable.  `rowIsSameVar` above already handled the
        -- `a ~ a` no-op, so `b` here is a DIFFERENT variable.  In branch mode
        -- the specialization is the branch's local row equation
        -- (rho^ ~ {l:t|rho'}): capture it, leave the rigid tail unbound.
        if branch then
            case ( row.fields, row.tail ) of
                ( [], RVar b ) ->
                    if isRigid state b then
                        Ok (pushEq { target = a, body = TRecord row } state)

                    else
                        -- The flex alias is legal globally; no equation needed.
                        Ok (addSubst state b (TRecord { fields = [], tail = RVar a }))

                _ ->
                    Ok (pushEq { target = a, body = TRecord row } state)

        else
            case ( row.fields, row.tail ) of
                ( [], RVar b ) ->
                    if isRigid state b then
                        Err (RigidVar a (TRecord row))

                    else
                        Ok (addSubst state b (TRecord { fields = [], tail = RVar a }))

                _ ->
                    Err (RigidVar a (TRecord row))

    else if Rep.occurs a (TRecord row) then
        Err (InfiniteType a (TRecord row))

    else
        Ok (addSubst state a (TRecord row))


rowIsSameVar : VarId -> Row -> Bool
rowIsSameVar a row =
    case ( row.fields, row.tail ) of
        ( [], RVar b ) ->
            b.id == a.id

        _ ->
            False


tailVar : Row -> Maybe VarId
tailVar row =
    case row.tail of
        REmpty ->
            Nothing

        RVar a ->
            Just a


type RewriteError
    = MissingFieldE String
    | SharedTailE String
    | RigidRowE VarId


{-| Rewrite a row to expose `l` at its head (Fig-3), returning the exposed
field type, the remainder row, and the extended state.

`forbidden` is the tail variable of the LEFT row (`tail(r)`): if the rewrite
reaches a row variable equal to it, instantiation is rejected (the paper's
side condition), turning the divergent common-tail program into an error.
-}
rewrite : Bool -> State -> Maybe VarId -> Row -> String -> Result RewriteError ( Type, Row, State )
rewrite branch state forbidden row l =
    let
        zrow =
            Rep.zonkRow state.subst row
    in
    case zrow.fields of
        ( l2, t ) :: rest ->
            if l2 == l then
                -- row-head: l is already first; the FIRST occurrence is the
                -- selectable one (scoped labels).
                Ok ( t, { fields = rest, tail = zrow.tail }, state )

            else
                -- row-swap: recurse into the tail, then prepend this field back.
                rewrite branch state forbidden { fields = rest, tail = zrow.tail } l
                    |> Result.map
                        (\( t2, s2, st ) ->
                            ( t2, { fields = ( l2, t ) :: s2.fields, tail = s2.tail }, st )
                        )

        [] ->
            case zrow.tail of
                REmpty ->
                    -- tail-Empty and l absent: cannot expose l.
                    Err (MissingFieldE l)

                RVar a ->
                    if forbidden == Just a then
                        -- Paper side condition a /= tail(r): reject instantiating
                        -- the LEFT row's tail, or unification would loop.
                        Err (SharedTailE l)

                    else if isRigid state a then
                        -- A rigid (skolemized) row tail must not be EXTENDED
                        -- with a new field `l`: that would specialize the
                        -- signature's row variable (the row analogue of the
                        -- KType skolem guard).  In branch mode the extension is
                        -- the branch's local row equation: capture it, still
                        -- hand out the fresh-field view, bind nothing.
                        if branch then
                            let
                                ( gamma, st1 ) =
                                    freshVar KType FNone state

                                ( beta, st2 ) =
                                    freshVar KRow FNone st1
                            in
                            Ok
                                ( TVar gamma
                                , { fields = [], tail = RVar beta }
                                , pushEq { target = a, body = TRecord { fields = [ ( l, TVar gamma ) ], tail = RVar beta } } st2
                                )

                        else
                            Err (RigidRowE a)

                    else
                        let
                            ( gamma, st1 ) =
                                freshVar KType FNone state

                            ( beta, st2 ) =
                                freshVar KRow FNone st1
                        in
                        Ok
                            ( TVar gamma
                            , { fields = [], tail = RVar beta }
                            , addSubst st2 a (TRecord { fields = [ ( l, TVar gamma ) ], tail = RVar beta })
                            )



-- Flex-marker propagation (Elm 0.19's number/comparable/appendable supers).


propagate : Flex -> Type -> State -> Result UnifyError ( Type, State )
propagate flex t state =
    case flex of
        FNone ->
            Ok ( t, state )

        FNumber ->
            if isInt t || isFloat t then
                Ok ( t, state )

            else
                Err (FlexConflict flex t)

        FAppendable ->
            if isString t then
                Ok ( t, state )

            else
                case t of
                    -- List of ANY element is appendable; no element constraint.
                    TCon "List" [ _ ] ->
                        Ok ( t, state )

                    _ ->
                        Err (FlexConflict flex t)

        FComparable ->
            comparableType t state


comparableType : Type -> State -> Result UnifyError ( Type, State )
comparableType t state =
    case t of
        TCon "Int" [] ->
            Ok ( t, state )

        TCon "Float" [] ->
            Ok ( t, state )

        TCon "Char" [] ->
            Ok ( t, state )

        TCon "String" [] ->
            Ok ( t, state )

        TCon "List" [ e ] ->
            comparableType e state |> Result.map (\( e2, st ) -> ( TCon "List" [ e2 ], st ))

        TTuple ts ->
            mapAccumState comparableType ts state |> Result.map (\( ts2, st ) -> ( TTuple ts2, st ))

        TVar e ->
            comparableVar e state

        _ ->
            Err (FlexConflict FComparable t)


comparableVar : VarId -> State -> Result UnifyError ( Type, State )
comparableVar e state =
    if isRigid state e then
        -- A skolem must not be re-marked comparable (re-marking binds it to a
        -- fresh comparable variable): the body imposes a constraint the
        -- signature does not promise.
        Err (FlexConflict FComparable (TVar e))

    else
        case e.flex of
            FComparable ->
                Ok ( TVar e, state )

            -- numbers are comparable; keep the more specific marker.
            FNumber ->
                Ok ( TVar e, state )

            FNone ->
                -- Redirect e to a FRESH comparable variable (a distinct id, never a
                -- same-id re-mark: the substitution is keyed by id, so binding e to
                -- a same-id var would be a self-cycle that makes zonk diverge).
                let
                    ( marked, st ) =
                        freshVar KType FComparable state
                in
                Ok ( TVar marked, addSubst st e (TVar marked) )

            FAppendable ->
                Err (FlexConflict FComparable (TVar e))


mapAccumState : (a -> State -> Result e ( b, State )) -> List a -> State -> Result e ( List b, State )
mapAccumState f xs state =
    case xs of
        [] ->
            Ok ( [], state )

        x :: rest ->
            case f x state of
                Err err ->
                    Err err

                Ok ( b, st ) ->
                    mapAccumState f rest st
                        |> Result.map (\( bs, st2 ) -> ( b :: bs, st2 ))


isInt : Type -> Bool
isInt t =
    case t of
        TCon "Int" [] ->
            True

        _ ->
            False


isFloat : Type -> Bool
isFloat t =
    case t of
        TCon "Float" [] ->
            True

        _ ->
            False


isString : Type -> Bool
isString t =
    case t of
        TCon "String" [] ->
            True

        _ ->
            False



-- Substitution helpers.


addSubst : State -> VarId -> Type -> State
addSubst state v t =
    { state | subst = Rep.extend v t state.subst }



-- Error rendering.


describe : UnifyError -> String
describe err =
    case err of
        MissingField l ->
            "missing field " ++ l

        CannotUnify t1 t2 ->
            "cannot unify " ++ Rep.pretty t1 ++ " with " ++ Rep.pretty t2

        InfiniteType v t ->
            "infinite type: " ++ Rep.pretty (TVar v) ++ " = " ++ Rep.pretty t

        FlexConflict flex t ->
            "cannot unify " ++ flexName flex ++ " with " ++ Rep.pretty t

        RigidVar v t ->
            "type variable " ++ Rep.pretty (TVar v) ++ " is rigid (from the signature) and cannot be unified with " ++ Rep.pretty t


flexName : Flex -> String
flexName flex =
    case flex of
        FNone ->
            "type variable"

        FNumber ->
            "number"

        FComparable ->
            "comparable"

        FAppendable ->
            "appendable"
