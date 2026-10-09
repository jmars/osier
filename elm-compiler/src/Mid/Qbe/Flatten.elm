module Mid.Qbe.Flatten exposing (run)

-- Mid.Qbe.Flatten — defun-local, escape-safe FLATTENING of aggregates into
-- pooled frame slots (handoff-qbe-flatten; the ONE middle-tier pass the
-- midpass profile supports).
--
-- THE PROBLEM (measured, handoff-midpass-profile-improve): the emitted native
-- code has 13,830 static `rt_prim` sites of which ~9,368 are
-- aggregate-REPRESENTATION prims — `cons`, `@p`, `emptylist`, `assoc`, `snd`
-- and `rt_con`.  A record field read is `snd (assoc (sym f) rec)`: an O(n)
-- list walk with a `deepEqual` per field; tuples and lists are cons chains;
-- every update rebuilds one.  Each of those sites is also an allocation
-- (`rt_prim`'s staging array + the cell), feeding the measured ~2.2GB/s of
-- allocation churn.
--
-- THE PASS: an aggregate (`Con`, `RecordLit`, `Tup`, `ListLit`) that is
-- consumed ONLY LOCALLY — by a `RecordGet`, a `Case` match, a `LetDestruct`
-- or a `VField` in the same Lam body, with the aggregate never escaping —
-- need not exist as a heap object.  Its COMPONENTS are bound to ordinary Mid
-- binders and the consumers read those directly, deleting the
-- `rt_con`/`cons`/`@p`/`assoc`/`snd` sequence and its allocations.
--
-- *** WHY THIS IS A MID REWRITE AND NOT A LOWER CHANGE ***
-- Every Mid binder ALREADY lowers into a POOLED FRAME SLOT: `Lower.lowerVal`
-- writes into a `freshSlot` of the `rt_frame_enter` block, and `Var` is
-- nothing but a 40-byte blit between two such slots.  So "put the components
-- in pooled frame slots" is exactly what replacing the aggregate with its
-- components DOES — this pass changes one file and touches neither `Lower`,
-- `tools/qbe/rt.zig`, nor ZINC.  Two consequences, both load-bearing:
--
--   1. `Value` BOXING STAYS UNIFORM — only the heap OBJECT goes.  No field is
--      unboxed, so nothing needs a type and the `Type/*` exposure barrier
--      (types are unreachable from Mid) stays closed.  Poly-equal needs
--      nothing because the representation of every SURVIVING value is
--      unchanged; GC rooting is unchanged because frame slots are already
--      rooted as one ROOT_VALUE_ARRAY.
--   2. It is QBE-SIDE ONLY (`Mid/Qbe/*`), so the ZINC corpus stays
--      BYTE-IDENTICAL — the free and strong oracle `tools/osier-numbers.sh`.
--
-- ============================ SOUNDNESS ============================
-- THIS IS A SILENT-WRONG-ANSWER CLASS.  A flattened aggregate has NO SLOT AT
-- ALL, so any surviving reference to it reads a stale or nonexistent frame
-- slot.  Two independent defences, and both are needed:
--
--   (a) DENY BY DEFAULT.  `usesOK` scans the whole remaining scope for
--       occurrences of the candidate binder and returns False — no
--       flattening — unless EVERY occurrence is a consumer position the
--       rewrite can resolve.  A bare `Var` is a denial anywhere it appears,
--       including inside a nested `Lam` body (closure capture) and inside
--       another aggregate (storing it into something that may escape).  The
--       escape routes therefore all fall out of one rule: anything that is
--       not a resolved consumer IS an escape.  Named explicitly, the routes
--       that DENY are: returning it (an ordinary `Var` in tail position),
--       passing it as a call argument or callee (`App`), capturing it in a
--       closure (`Lam`), storing it into another aggregate
--       (`Con`/`Tup`/`RecordLit`/`ListLit`/`RecordUpdate`), and any flow
--       through a `GRef`/`StreamRef` (there is none FROM a local binder, but
--       the scan is total over the tree so it costs nothing to be sure).
--
--   (b) FAIL LOUD, NEVER SILENT.  The rewrite is a separate function from the
--       scan, so the two could in principle disagree.  `rw` therefore
--       ERRORS — a loud compile failure, never a wrong program — if a `Var`
--       of a flattened binder ever reaches it.  The ZINC path never runs this
--       module, so a bug here cannot move the corpus.
--
-- WHAT IS DELIBERATELY NOT FLATTENED (a smaller correct pass is the success
-- mode; each of these was considered and EXCLUDED rather than done
-- optimistically):
--
--   * A consumer whose `ValuePath` lands on a SUB-AGGREGATE rather than a
--     single value — e.g. the `ys` of `case xs of y::ys` where `xs` is a
--     flattened `ListLit`.  The tail is not a value, and materialising it
--     would rebuild the cons chain this pass exists to delete.  `resolveSteps`
--     yields `SubShape` there and every bind site requires `SubVal`.
--   * `RecordUpdate` (`{ r | f = v }`) — even on a flattened base.  The result
--     is a NEW record whose other fields are known only if the base's are, and
--     threading that through a let-chain makes one binder's flattenability
--     depend on a LATER binder's.  Excluded; an update still rebuilds its
--     `@p`/`cons` prefix exactly as before.
--   * An aggregate reached through an ALIAS (`let a = r in a.f`) — `shapeOf`
--     does not follow `Var`, for the same reason.
--   * A case whose alts are not all statically decidable from the shape: an
--     undecidable EARLIER alt might have matched at run time, so the whole
--     rewrite is denied (`casePlan` -> `Nothing`).
--
-- *** MEASURED LIMIT: THE `Con` HALF CANNOT FIRE FROM Elm SOURCE TODAY ***
-- `Mid.Ir.Con` has exactly ONE producer in this compiler: `Mid.Module.ctorDefun`
-- — the constructor DEFUN, whose `Lam` body IS the `Con`, i.e. the vector is
-- the defun's return value and therefore ALWAYS escapes (a source-level
-- `Wrap 21` lowers to `App (GRef Flatten.Wrap)` and calls that defun).  So the
-- `KindCon` arms below (including the `MVector`/`MTagEq` decisions and the
-- `IdxStep 0` = tag rule) are CORRECT BUT CURRENTLY UNREACHABLE, and the
-- `rt_con` sites the profile counted are not movable by this pass in its
-- present shape.  They are kept because the shape resolution is total over
-- Mid.Ir's constructors and because the `Tup`/`ListLit`/`RecordLit` machinery
-- is shared with them; the fixtures prove the DENIAL direction, not the
-- flattening of a `Con`.  Flattening constructors would need either a
-- `Con`-producing FromAst or interprocedural recognition of the ctor defun —
-- neither is done here.
--
-- ============================ SWITCH ============================
-- `QBE_NOFLATTEN=1` disables the pass (run.js -> Main.elm -> Mid.QbeModule).
-- tools/qbe/qbe-check.sh compiles fixtures BOTH ways so the structural gate is
-- an A/B on identical source: the aggregate prims must be GONE in one build
-- and PRESENT in the other.  The ZINC paths never reach this module, so the
-- switch cannot move the corpus.
--
-- ============================ WHAT MAKES A CONSUMER RESOLVABLE =============
-- A shape records the aggregate's static structure (`Shape`/`Kind` below).
-- `Step`s from a match or a `ValuePath` are resolved SYMBOLICALLY against it
-- (`resolveSteps`), and every residue of the VM representation is decided
-- statically:
--
--   FstStep/HdStep -> the first element of a cons chain; SndStep/TlStep -> the
--   tail; IdxStep j -> element j of an ADT vector (j = 0 is the tag symbol,
--   which `rt_con` stores there — tools/qbe/rt.zig rt_con + Lower.lowerStep).
--   MCons/MEmpty/MVector become a TAG COMPARISON on the shape (cons = 4,
--   nil = 5, vector = 10; Lower's tagCons/tagNil/tagVector), and
--   MTagEq/MLitEq become a value comparison — each `Just True`/`Just False`,
--   or `Nothing` = UNDECIDABLE = DENY.

import Dict exposing (Dict)
import Mid.Ir exposing (Alt, Binder, Defun, Exp(..), LetBinder(..), Lit(..), Match(..), Step(..), ValuePath(..))


-- ============================ SHAPES ============================
-- A locally-known aggregate.  `parts` are the COMPONENTS in source order and
-- are always duplicable (a `Var` of a frame slot, or a `Lit`) — see
-- `componentize`.


type alias Shape =
    { kind : Kind
    , parts : List Exp
    }


type Kind
    = KindRecord (List String) -- field names, source order
    | KindCon String -- ctor tag (the ADT vector's element 0)
    | KindList -- a cons chain of length (List.length parts)


type Sub
    = SubShape Shape
    | SubVal Exp


type alias Env =
    Dict Int Shape


run : List Defun -> List Defun
run defuns =
    List.map flattenDefun defuns


-- A Defun's value is always a Lam (Mid.Ir's contract); `rw` seeds the env
-- EMPTY, so a flattened binder can never cross a closure boundary.
flattenDefun : Defun -> Defun
flattenDefun defun =
    case rw Dict.empty (maxId defun.value + 1) defun.value of
        Ok ( out, _ ) ->
            { defun | value = out }

        Err msg ->
            { defun | value = Debug.todo msg }


-- ============================ WALK ============================


rw : Env -> Int -> Exp -> Result String ( Exp, Int )
rw env gen exp =
    case exp of
        Lit _ ->
            Ok ( exp, gen )

        Var id ->
            if Dict.member id env then
                Err (leak id)

            else
                Ok ( exp, gen )

        GRef _ ->
            Ok ( exp, gen )

        StreamRef _ ->
            Ok ( exp, gen )

        NoTail inner ->
            map1 NoTail (rw env gen inner)

        Lam lam ->
            -- A fresh scope: the env does NOT cross a closure boundary.
            rw Dict.empty gen lam.body
                |> Result.map (\( body, g ) -> ( Lam { lam | body = body }, g ))

        App app ->
            rw env gen app.fn
                |> Result.andThen
                    (\( f, g ) ->
                        rwList env g app.args
                            |> Result.map (\( args, g2 ) -> ( App { app | fn = f, args = args }, g2 ))
                    )

        PrimApp app ->
            rwList env gen app.args
                |> Result.map (\( args, g ) -> ( PrimApp { app | args = args }, g ))

        Let block ->
            rwBinders env gen [] block.binders block.body

        Case branch ->
            rwCase env gen branch.scrutinee branch.scrutId branch.alts branch.endLabel

        Con con ->
            rwList env gen con.args
                |> Result.map (\( args, g ) -> ( Con { con | args = args }, g ))

        Tup es ->
            rwList env gen es
                |> Result.map (\( es2, g ) -> ( Tup es2, g ))

        RecordLit setters ->
            rwSetters env gen setters
                |> Result.map (\( ss, g ) -> ( RecordLit ss, g ))

        RecordGet rec field ->
            -- A flattened record's field read IS its component: the `assoc` +
            -- `snd` pair (and the whole assoc list behind it) never happens.
            case rec of
                Var id ->
                    case Dict.get id env of
                        Just shape ->
                            case recordField shape field of
                                Just e ->
                                    Ok ( e, gen )

                                Nothing ->
                                    -- Uses are gated on the field existing;
                                    -- reaching here is a pass bug, not a
                                    -- program bug.
                                    Err (leak id)

                        Nothing ->
                            Ok ( exp, gen )

                _ ->
                    rw env gen rec
                        |> Result.map (\( r, g ) -> ( RecordGet r field, g ))

        RecordUpdate update ->
            rw env gen update.base
                |> Result.andThen
                    (\( base, g ) ->
                        rwSetters env g update.updates
                            |> Result.map (\( us, g2 ) -> ( RecordUpdate { base = base, updates = us }, g2 ))
                    )

        ListLit es ->
            rwList env gen es
                |> Result.map (\( es2, g ) -> ( ListLit es2, g ))

        If block ->
            rw env gen block.cond
                |> Result.andThen
                    (\( c, g ) ->
                        rw env g block.thenBranch
                            |> Result.andThen
                                (\( t, g1 ) ->
                                    rw env g1 block.elseBranch
                                        |> Result.map
                                            (\( e, g2 ) ->
                                                ( If { block | cond = c, thenBranch = t, elseBranch = e }, g2 )
                                            )
                                )
                    )

        ShortAnd block ->
            rw2 (\l r -> ShortAnd { block | left = l, right = r }) env gen block.left block.right

        ShortOr block ->
            rw2 (\l r -> ShortOr { block | left = l, right = r }) env gen block.left block.right

        NotEqual block ->
            rw2 (\l r -> NotEqual { block | left = l, right = r }) env gen block.left block.right


rw2 : (Exp -> Exp -> Exp) -> Env -> Int -> Exp -> Exp -> Result String ( Exp, Int )
rw2 build env gen a b =
    rw env gen a
        |> Result.andThen
            (\( a2, g ) ->
                rw env g b |> Result.map (\( b2, g2 ) -> ( build a2 b2, g2 ))
            )


map1 : (Exp -> Exp) -> Result String ( Exp, Int ) -> Result String ( Exp, Int )
map1 f r =
    Result.map (\( e, g ) -> ( f e, g )) r


rwList : Env -> Int -> List Exp -> Result String ( List Exp, Int )
rwList env gen es =
    case es of
        [] ->
            Ok ( [], gen )

        e :: rest ->
            rw env gen e
                |> Result.andThen
                    (\( e2, g ) ->
                        rwList env g rest |> Result.map (\( r, g2 ) -> ( e2 :: r, g2 ))
                    )


rwSetters : Env -> Int -> List ( String, Exp ) -> Result String ( List ( String, Exp ), Int )
rwSetters env gen setters =
    case setters of
        [] ->
            Ok ( [], gen )

        ( f, e ) :: rest ->
            rw env gen e
                |> Result.andThen
                    (\( e2, g ) ->
                        rwSetters env g rest |> Result.map (\( r, g2 ) -> ( ( f, e2 ) :: r, g2 ))
                    )


-- ============================ LET ============================
-- Binders are sequential.  For each one we ask whether its value is an
-- aggregate (`shapeOf`) and, if so, whether EVERY later use of its binder is a
-- resolvable consumer (`usesOK`).  If yes the binder is DROPPED — it has no
-- heap object and no slot — its shape is recorded, and its non-trivial
-- components are bound in its place.  If no, it is emitted unchanged and
-- forgotten.


rwBinders : Env -> Int -> List LetBinder -> List LetBinder -> Exp -> Result String ( Exp, Int )
rwBinders env gen acc pending body =
    case pending of
        [] ->
            rw env gen body |> Result.map (\( b, g ) -> ( mkLet acc b, g ))

        b :: rest ->
            case b of
                LetBind { binder, value } ->
                    rwCandidate env gen value
                        |> Result.andThen
                            (\( v, mshape, g ) ->
                                case mshape of
                                    Nothing ->
                                        rwBinders env g (acc ++ [ LetBind { binder = binder, value = v } ]) rest body

                                    Just raw ->
                                        let
                                            ( shape, g1, comps ) =
                                                componentize raw g
                                        in
                                        if usesOK env binder.id shape (mkLet rest body) then
                                            rwBinders (Dict.insert binder.id shape env) g1 (acc ++ comps) rest body

                                        else
                                            rwBinders env g
                                                (acc ++ [ LetBind { binder = binder, value = v } ])
                                                rest
                                                body
                            )

                LetDestruct destruct ->
                    rwCandidate env gen destruct.value
                        |> Result.andThen
                            (\( v, mshape, g ) ->
                                case Maybe.andThen (\sh -> destructPlan sh destruct.matches destruct.binds) mshape of
                                    Just bs ->
                                        rwBinders env g (acc ++ bs) rest body

                                    Nothing ->
                                        if inEnv env v then
                                            Err (leakOf v)

                                        else
                                            rwBinders env g
                                                (acc ++ [ LetDestruct { destruct | value = v } ])
                                                rest
                                                body
                            )


{-| Rewrite a let value and, if it names a locally-known aggregate, hand back
its SHAPE.  A `Var` of an already-flattened binder must NOT go through `rw`
(it has no slot, and `rw`'s `Var` arm is the loud leak detector), so it is
handled before the walk.
-}
rwCandidate : Env -> Int -> Exp -> Result String ( Exp, Maybe Shape, Int )
rwCandidate env gen value =
    case value of
        Var id ->
            Ok ( value, Dict.get id env, gen )

        _ ->
            rw env gen value
                |> Result.map (\( v, g ) -> ( v, shapeOf v, g ))


inEnv : Env -> Exp -> Bool
inEnv env v =
    case v of
        Var id ->
            Dict.member id env

        _ ->
            False


leakOf : Exp -> String
leakOf v =
    case v of
        Var id ->
            leak id

        _ ->
            "qbe-flatten: internal error — a flattened aggregate value survived"


mkLet : List LetBinder -> Exp -> Exp
mkLet binders body =
    case binders of
        [] ->
            body

        _ ->
            Let { binders = binders, body = body }


-- ============================ SHAPE CONSTRUCTION ============================
-- A component that is not already duplicable (a frame-slot `Var` or a `Lit`)
-- gets its own binder, which also pins its EVALUATION to the aggregate's own
-- position and order: hoisting an arbitrary expression to its use site would
-- move it into (or out of) a `Case` arm.  Duplicable parts are shared, not
-- copied — a slot read has no effect to reorder.


componentize : Shape -> Int -> ( Shape, Int, List LetBinder )
componentize shape gen =
    List.foldl
        (\part ( sh, g, bs ) ->
            if duplicable part then
                ( { sh | parts = sh.parts ++ [ part ] }, g, bs )

            else
                ( { sh | parts = sh.parts ++ [ Var g ] }
                , g + 1
                , bs ++ [ LetBind { binder = { id = g, name = "$flat" }, value = part } ]
                )
        )
        ( { shape | parts = [] }, gen, [] )
        shape.parts


duplicable : Exp -> Bool
duplicable exp =
    case exp of
        Var _ ->
            True

        Lit _ ->
            True

        _ ->
            False


-- The shape of a LET VALUE: a `Var` of an already-flattened binder keeps that
-- binder's shape (the value has no heap object to alias, and the gate has
-- already proved every use of the source binder is a consumer).
shapeOfEnv : Env -> Exp -> Maybe Shape
shapeOfEnv env exp =
    case exp of
        Var id ->
            Dict.get id env

        _ ->
            shapeOf exp


-- The shape of an expression, when this pass can know it WITHOUT a heap
-- object.  Deliberately does NOT follow `Var` (a bare alias must go through
-- `shapeOfEnv` above, so the gate at the binder it aliases still applies).
shapeOf : Exp -> Maybe Shape
shapeOf exp =
    case exp of
        RecordLit setters ->
            Just
                { kind = KindRecord (List.map Tuple.first setters)
                , parts = List.map Tuple.second setters
                }

        Con con ->
            Just { kind = KindCon con.tag, parts = con.args }

        Tup es ->
            case es of
                [] ->
                    -- `buildTuple [] = Lit (LNumber 0)` (Lower), NOT nil.
                    Nothing

                [ only ] ->
                    -- `buildTuple [ x ] = x` (Lower), so a 1-tuple IS x.
                    shapeOf only

                _ ->
                    Just { kind = KindList, parts = es }

        ListLit es ->
            Just { kind = KindList, parts = es }

        _ ->
            Nothing


recordField : Shape -> String -> Maybe Exp
recordField shape field =
    case shape.kind of
        KindRecord names ->
            Maybe.andThen (\i -> nth i shape.parts) (indexOf field names)

        _ ->
            Nothing


-- ============================ PATH RESOLUTION ============================
-- `Step`s chase the VM representation (Lower.readSteps / lowerStep:
-- FstStep = +8, SndStep = +16, IdxStep j = +8+40j).  Resolved against a shape
-- they yield either a COMPONENT (a single value) or a SHAPE (a sub-aggregate —
-- usable as a match test, never as a binding target).


resolveSteps : Shape -> List Step -> Maybe Sub
resolveSteps shape steps =
    case steps of
        [] ->
            Just (SubShape shape)

        step :: rest ->
            case step of
                FstStep ->
                    firstPart shape rest

                HdStep ->
                    firstPart shape rest

                SndStep ->
                    tailShape shape rest

                TlStep ->
                    tailShape shape rest

                IdxStep j ->
                    case shape.kind of
                        KindCon tag ->
                            if j == 0 then
                                valAt (Lit (LSymbol tag)) rest

                            else
                                Maybe.andThen (\e -> valAt e rest) (nth (j - 1) shape.parts)

                        _ ->
                            Nothing


firstPart : Shape -> List Step -> Maybe Sub
firstPart shape rest =
    case shape.kind of
        KindList ->
            Maybe.andThen (\e -> valAt e rest) (List.head shape.parts)

        _ ->
            Nothing


tailShape : Shape -> List Step -> Maybe Sub
tailShape shape rest =
    case shape.kind of
        KindList ->
            case shape.parts of
                _ :: t ->
                    resolveSteps { shape | parts = t } rest

                [] ->
                    Nothing

        _ ->
            Nothing


valAt : Exp -> List Step -> Maybe Sub
valAt e rest =
    if List.isEmpty rest then
        Just (SubVal e)

    else
        Nothing


-- ============================ MATCH DECISIONS ============================
-- `Just True` = the test passes for every runtime value of the shape;
-- `Just False` = it fails; `Nothing` = UNDECIDABLE, which denies the whole
-- flattening (deny by default).


decideMatches : Shape -> List Match -> Maybe Bool
decideMatches shape matches =
    List.foldl (\m acc -> Maybe.map2 (&&) acc (decideMatch shape m)) (Just True) matches


decideMatch : Shape -> Match -> Maybe Bool
decideMatch shape match =
    case match of
        MCons steps ->
            Maybe.map isConsSub (resolveSteps shape steps)

        MEmpty steps ->
            Maybe.map isNilSub (resolveSteps shape steps)

        MVector steps ->
            Maybe.map isVectorSub (resolveSteps shape steps)

        MTagEq steps tag ->
            case resolveSteps shape steps of
                Just (SubVal (Lit (LSymbol s))) ->
                    Just (s == tag)

                _ ->
                    Nothing

        MLitEq steps lit ->
            case resolveSteps shape steps of
                Just (SubVal (Lit l)) ->
                    Just (l == lit)

                _ ->
                    Nothing


-- An ADT vector is tag 10; a cons chain is tag 4 and its nil end is tag 5.
isConsSub : Sub -> Bool
isConsSub sub =
    case sub of
        SubShape shape ->
            shape.kind == KindList && not (List.isEmpty shape.parts)

        SubVal _ ->
            False


isNilSub : Sub -> Bool
isNilSub sub =
    case sub of
        SubShape shape ->
            shape.kind == KindList && List.isEmpty shape.parts

        SubVal _ ->
            False


isVectorSub : Sub -> Bool
isVectorSub sub =
    case sub of
        SubShape shape ->
            case shape.kind of
                KindCon _ ->
                    True

                _ ->
                    False

        SubVal _ ->
            False


-- ============================ CASE ============================
-- A case over a known shape becomes a straight line: the FIRST alt all of
-- whose tests pass statically is the only one that can run; the alts that fail
-- statically are dead exactly as they were behind their failed jump, and their
-- bodies (never executed in the original either) are dropped.  An undecidable
-- test anywhere denies the rewrite — it might have matched.


casePlan : Shape -> List Alt -> Maybe Alt
casePlan shape alts =
    case alts of
        [] ->
            Nothing

        alt :: rest ->
            case decideMatches shape alt.matches of
                Just True ->
                    Just alt

                Just False ->
                    casePlan shape rest

                Nothing ->
                    Nothing


-- A case is FLATTENABLE only if some alt's tests all decide TRUE *and* that
-- alt's bindings all resolve to components.  Both halves are required, and
-- both are checked by the gate (`usesOK`) and by the rewrite, so a divergence
-- between them cannot silently pick a different alt.
caseSolution : Shape -> List Alt -> Maybe ( Alt, List LetBinder )
caseSolution shape alts =
    Maybe.andThen (\alt -> Maybe.map (\bs -> ( alt, bs )) (bindsPlan shape alt.binds)) (casePlan shape alts)


rwCase : Env -> Int -> Exp -> Binder -> List Alt -> String -> Result String ( Exp, Int )
rwCase env gen scrut scrutId alts endLabel =
    case scrut of
        Var id ->
            case Dict.get id env of
                Just shape ->
                    -- Gated: `usesOK` only allowed this Case because a
                    -- solution exists, so a missing one here is a pass bug.
                    case caseSolution shape alts of
                        Just ( alt, bs ) ->
                            bindAlt env gen bs alt

                        Nothing ->
                            Err "qbe-flatten: internal error — case over a known shape with no statically matching alt"

                Nothing ->
                    plainCase env gen scrut scrutId alts endLabel

        _ ->
            rw env gen scrut
                |> Result.andThen
                    (\( s, g ) ->
                        case shapeOf s of
                            Just raw ->
                                let
                                    ( shape, g1, comps ) =
                                        componentize raw g
                                in
                                case caseSolution shape alts of
                                    Just ( alt, bs ) ->
                                        bindAlt env g1 bs alt
                                            |> Result.map (\( e, g2 ) -> ( mkLet comps e, g2 ))

                                    Nothing ->
                                        plainCase env g s scrutId alts endLabel

                            Nothing ->
                                plainCase env g s scrutId alts endLabel
                    )


bindAlt : Env -> Int -> List LetBinder -> Alt -> Result String ( Exp, Int )
bindAlt env gen bs alt =
    -- The alt body is rewritten with the SAME env; a reference to the
    -- flattened scrutinee inside it reaches `rw`'s `Var` arm and fails loudly
    -- (`usesOK` already refused to allow it).
    rw env gen alt.body
        |> Result.map (\( b, g ) -> ( mkLet bs b, g ))


plainCase : Env -> Int -> Exp -> Binder -> List Alt -> String -> Result String ( Exp, Int )
plainCase env gen scrut scrutId alts endLabel =
    rwAlts env gen alts
        |> Result.map
            (\( alts2, g ) ->
                ( Case { scrutinee = scrut, scrutId = scrutId, alts = alts2, endLabel = endLabel }, g )
            )


rwAlts : Env -> Int -> List Alt -> Result String ( List Alt, Int )
rwAlts env gen alts =
    case alts of
        [] ->
            Ok ( [], gen )

        alt :: rest ->
            rw env gen alt.body
                |> Result.andThen
                    (\( b, g ) ->
                        rwAlts env g rest
                            |> Result.map (\( r, g2 ) -> ( { alt | body = b } :: r, g2 ))
                    )


-- ============================ BINDS ============================
-- Each pattern variable is bound by reading its `ValuePath` out of the
-- scrutinee; against a shape that read is a direct component reference.  A
-- path landing on a SUB-AGGREGATE is refused (`SubShape`) — materialising it
-- would rebuild the cons chain this pass deletes.


destructPlan : Shape -> List Match -> List ( Binder, ValuePath ) -> Maybe (List LetBinder)
destructPlan shape matches binds =
    if decideMatches shape matches == Just True then
        bindsPlan shape binds

    else
        Nothing


bindsPlan : Shape -> List ( Binder, ValuePath ) -> Maybe (List LetBinder)
bindsPlan shape binds =
    case binds of
        [] ->
            Just []

        ( binder, path ) :: rest ->
            Maybe.map2
                (\e bs -> LetBind { binder = binder, value = e } :: bs)
                (bindValue shape path)
                (bindsPlan shape rest)


bindValue : Shape -> ValuePath -> Maybe Exp
bindValue shape path =
    case path of
        VPath steps ->
            case resolveSteps shape steps of
                Just (SubVal e) ->
                    Just e

                _ ->
                    Nothing

        VField steps field ->
            case resolveSteps shape steps of
                Just (SubShape sub) ->
                    recordField sub field

                _ ->
                    Nothing


-- ============================ USE SCAN ============================
-- THE GATE.  Every occurrence of binder `x` in `exp` must be a consumer the
-- rewrite resolves; a bare `Var x` anywhere is a denial.  Kept structurally
-- parallel with `rw` — a divergence between them is caught by `rw`'s loud
-- `leak` error, never by a wrong program.


usesOK : Env -> Int -> Shape -> Exp -> Bool
usesOK env x shape exp =
    case exp of
        Lit _ ->
            True

        Var id ->
            id /= x

        GRef _ ->
            True

        StreamRef _ ->
            True

        NoTail inner ->
            usesOK env x shape inner

        Lam lam ->
            -- A capture is an escape.
            not (occurs x lam.body)

        App app ->
            usesOK env x shape app.fn && List.all (usesOK env x shape) app.args

        PrimApp app ->
            List.all (usesOK env x shape) app.args

        Let block ->
            usesOkBinders env x shape block.binders && usesOK env x shape block.body

        Case branch ->
            case branch.scrutinee of
                Var id ->
                    if id == x then
                        Maybe.map (\( alt, _ ) -> not (occurs x alt.body)) (caseSolution shape branch.alts)
                            |> Maybe.withDefault False

                    else
                        List.all (usesOK env x shape << .body) branch.alts

                _ ->
                    usesOK env x shape branch.scrutinee
                        && List.all (usesOK env x shape << .body) branch.alts

        Con con ->
            List.all (usesOK env x shape) con.args

        Tup es ->
            List.all (usesOK env x shape) es

        RecordLit setters ->
            List.all (usesOK env x shape << Tuple.second) setters

        RecordGet rec field ->
            case rec of
                Var id ->
                    id /= x || recordField shape field /= Nothing

                _ ->
                    usesOK env x shape rec

        RecordUpdate update ->
            usesOK env x shape update.base
                && List.all (usesOK env x shape << Tuple.second) update.updates

        ListLit es ->
            List.all (usesOK env x shape) es

        If block ->
            usesOK env x shape block.cond
                && usesOK env x shape block.thenBranch
                && usesOK env x shape block.elseBranch

        ShortAnd block ->
            usesOK env x shape block.left && usesOK env x shape block.right

        ShortOr block ->
            usesOK env x shape block.left && usesOK env x shape block.right

        NotEqual block ->
            usesOK env x shape block.left && usesOK env x shape block.right


usesOkBinders : Env -> Int -> Shape -> List LetBinder -> Bool
usesOkBinders env x shape binders =
    case binders of
        [] ->
            True

        b :: rest ->
            (case b of
                LetBind { value } ->
                    usesOK env x shape value

                LetDestruct destruct ->
                    case destruct.value of
                        Var id ->
                            id /= x || (destructPlan shape destruct.matches destruct.binds /= Nothing)

                        _ ->
                            usesOK env x shape destruct.value
            )
                && usesOkBinders env x shape rest


occurs : Int -> Exp -> Bool
occurs x exp =
    case exp of
        Var id ->
            id == x

        Lit _ ->
            False

        GRef _ ->
            False

        StreamRef _ ->
            False

        NoTail inner ->
            occurs x inner

        Lam lam ->
            occurs x lam.body

        App app ->
            occurs x app.fn || List.any (occurs x) app.args

        PrimApp app ->
            List.any (occurs x) app.args

        Let block ->
            List.any (occursBinder x) block.binders || occurs x block.body

        Case branch ->
            occurs x branch.scrutinee || List.any (occurs x << .body) branch.alts

        Con con ->
            List.any (occurs x) con.args

        Tup es ->
            List.any (occurs x) es

        RecordLit setters ->
            List.any (occurs x << Tuple.second) setters

        RecordGet rec _ ->
            occurs x rec

        RecordUpdate update ->
            occurs x update.base || List.any (occurs x << Tuple.second) update.updates

        ListLit es ->
            List.any (occurs x) es

        If block ->
            occurs x block.cond || occurs x block.thenBranch || occurs x block.elseBranch

        ShortAnd block ->
            occurs x block.left || occurs x block.right

        ShortOr block ->
            occurs x block.left || occurs x block.right

        NotEqual block ->
            occurs x block.left || occurs x block.right


occursBinder : Int -> LetBinder -> Bool
occursBinder x b =
    case b of
        LetBind { value } ->
            occurs x value

        LetDestruct destruct ->
            occurs x destruct.value


-- ============================ HELPERS ============================


leak : Int -> String
leak id =
    "qbe-flatten: internal error — flattened binder " ++ String.fromInt id ++ " is still referenced"


nth : Int -> List a -> Maybe a
nth i list =
    case list of
        [] ->
            Nothing

        x :: rest ->
            if i <= 0 then
                Just x

            else
                nth (i - 1) rest


indexOf : String -> List String -> Maybe Int
indexOf target list =
    case list of
        [] ->
            Nothing

        x :: rest ->
            if x == target then
                Just 0

            else
                Maybe.map ((+) 1) (indexOf target rest)


-- Binder ids are unique WITHIN ONE Defun (Mid.Ir's contract), so the fresh-id
-- supply starts just above the highest id in the defun.
maxId : Exp -> Int
maxId exp =
    case exp of
        Lit _ ->
            0

        Var id ->
            id

        GRef _ ->
            0

        StreamRef _ ->
            0

        NoTail inner ->
            maxId inner

        Lam lam ->
            List.foldl (\p acc -> Basics.max acc p.id) (maxId lam.body) lam.params

        App app ->
            Basics.max (maxId app.fn) (maxIds app.args)

        PrimApp app ->
            maxIds app.args

        Let block ->
            List.foldl (\b acc -> Basics.max acc (maxIdBinder b)) (maxId block.body) block.binders

        Case branch ->
            Basics.max (maxId branch.scrutinee)
                (Basics.max branch.scrutId.id
                    (List.foldl (\alt acc -> Basics.max acc (maxIdAlt alt)) 0 branch.alts)
                )

        Con con ->
            maxIds con.args

        Tup es ->
            maxIds es

        RecordLit setters ->
            List.foldl (\( _, e ) acc -> Basics.max acc (maxId e)) 0 setters

        RecordGet rec _ ->
            maxId rec

        RecordUpdate update ->
            List.foldl (\( _, e ) acc -> Basics.max acc (maxId e)) (maxId update.base) update.updates

        ListLit es ->
            maxIds es

        If block ->
            Basics.max (maxId block.cond) (Basics.max (maxId block.thenBranch) (maxId block.elseBranch))

        ShortAnd block ->
            Basics.max (maxId block.left) (maxId block.right)

        ShortOr block ->
            Basics.max (maxId block.left) (maxId block.right)

        NotEqual block ->
            Basics.max (maxId block.left) (maxId block.right)


maxIds : List Exp -> Int
maxIds es =
    List.foldl (\e acc -> Basics.max acc (maxId e)) 0 es


maxIdAlt : Alt -> Int
maxIdAlt alt =
    List.foldl (\p acc -> Basics.max acc p.id) (maxId alt.body) (List.map Tuple.first alt.binds)


maxIdBinder : LetBinder -> Int
maxIdBinder b =
    case b of
        LetBind { binder, value } ->
            Basics.max binder.id (maxId value)

        LetDestruct destruct ->
            Basics.max destruct.scrutId.id
                (Basics.max (maxId destruct.value)
                    (List.foldl (\p acc -> Basics.max acc p.id) 0 (List.map Tuple.first destruct.binds))
                )
