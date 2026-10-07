module Mid.Inline exposing (run)

-- Mid.Inline — the middle tier's THIRD pass: inlining small top-level defuns
-- at their FULL-ARITY call sites.
--
-- NOT A LITERAL PORT.  MLton's `ssa/inline.fun` (thresholds small=60 /
-- product=320) and `xml/polyvariance.fun` (duplicate a let-bound function at
-- each reference when the cost is below threshold) are the DESIGN source, and
-- the threshold is configurable for the same reason MLton's is (the right
-- number depends on the cost model).  But the target here is a CURRIED
-- CLOSURE VM, not MLton's SSA, so the driver is fresh: no MLton source is
-- present, no threshold machinery is copied, and there is therefore no
-- HPND/MLton header and no THIRD-PARTY.md entry (the f2361ed rule is "code
-- ported literally", and this is not).
--
-- WHY INLINE AT ALL ON THIS VM — READ THIS BEFORE JUDGING THE MEASUREMENT.
-- A full-arity call is NOT cheap here even though it takes the VM's "fast
-- path": `vendor/zinc-vm/src/vm/interp.zig`'s `.apply` arm, at N==A, pushes a
-- NEW C frame (`frame_stack`), ALLOCATES a fresh env array
-- (`g.allocArray`), and COPIES the closure env + args into it — every call.
-- Inlining moves the body into the CALLER's frame, where the parameters
-- become ordinary `Let_` env slots (amortized env growth) or, better, vanish
-- entirely (the direct-substitution path below).  That runtime win is NOT
-- visible in the emitted instruction count — the raw count can even go UP a
-- little, because one `p`/`t` apply (3 instructions: pushmark + global +
-- apply) becomes a body plus a `Let_`/`Endlet` pair per parameter.  The
-- instruction-count delta reported per pass is therefore expected to be small
-- and possibly negative in sign; the payoff this pass exists for is the
-- per-call frame/env allocation, which shows only in the end-to-end timing.
--
-- ============================ THE RULES ============================
--
-- The only shape rewritten is `App { fn = GRef { key, force = False }, args }`
-- — a top-level defun applied to its arguments — and it is rewritten only
-- when ALL of:
--
--   I1. the key names a defun in the program (arity A, body `Lam`),
--   I2. the site is FULL-ARITY (List.length args == A, A >= 1),
--   I3. the defun is NOT recursive (its body never references its own key;
--       inlining a recursive body still leaves the self-call as a global, so
--       it duplicates instructions without eliminating the defun), and
--   I4. the defun's body cost is <= the threshold (`MIDTIER_INLINE_THRESHOLD`,
--       default 30, plan pass 3's size budget).
--
-- THE REWRITE IS DIRECT SUBSTITUTION ONLY: every arg must be a `Var` or a
-- `Lit` (a value that evaluates to itself with no side effect and no
-- divergence), and the body is substituted with each parameter replaced by
-- its argument — NO `Let`/`Endlet` is introduced.  This is the ONLY form that
-- can CUT instructions, and it is also the only form whose argument evaluation
-- is order-safe: a `Var`/`Lit` arg has no evaluation to re-order.
--
--   WHY THERE IS NO `Let`-BINDING FALLBACK (the order trap applies twice).
--   Binding args through a `Let` reorders their evaluation (an `App` emits its
--   args RIGHT-TO-LEFT, a `Let` LEFT-TO-RIGHT — Shrink's header), so it would
--   be legal only for ORDER-INSENSITIVE args; and it always ADDS a `Let_`/
--   `Endlet` pair per parameter, so it can never reduce the emitted
--   instruction count — it trades instruction count for the runtime frame
--   allocation, which is exactly the trade the brief's instruction-count
--   metric cannot see.  Measured on this corpus (before it was dropped) the
--   let-binding fallback was a pure instruction-count regression, so a
--   non-atomic argument leaves the site alone rather than be rewritten.
--
-- ALPHA-RENAMING IS DONE ONCE, UP FRONT, BY OFFSETTING.  Binder ids are
-- unique only WITHIN one defun (`Mid.Ir`), so a naive cross-defun
-- substitution would let defun K's `Var 5` resolve to defun T's binder 5.
-- Rather than rename per inline site, the pass first gives every defun a
-- DISJOINT id range (a cumulative offset), after which any substitution is
-- capture-free.  A defun's body references only its own binders (params +
-- internal lets/lambdas) plus globals, so an inlined copy is SELF-CONTAINED:
-- duplicated at two call sites it shares ids with its sibling copy, but the
-- emitter's functional env threading (nearest-binder wins, by lexical
-- nesting) resolves every `Var` to its own copy's binder, exactly as it did
-- in the un-inlined defun.  (The walk below also never descends into a body
-- it just substituted — single pass — so two copies of one defun in one
-- target are always disjoint subtrees.)
--
-- WHY THE THRESHOLD IS A SIZE BUDGET, NOT A CALL-COUNT: inlining duplicates
-- the body at every call site, so the only thing that bounds the total size
-- is how big each copy is.  A small function called 100 times is exactly what
-- should be inlined (it removes 100 frame allocations); a big function called
-- once is exactly what should not.  On the instruction-count metric the
-- threshold is what keeps the pass NET-NEGATIVE: only a body whose emitted
-- size is under the ~3-instruction call overhead it replaces can shrink the
-- stream, so the default below is deliberately far below MLton's native
-- thresholds (see the measured commit message).

import Dict exposing (Dict)
import Mid.Ir exposing (Alt, Binder, Defun, Exp(..), Lambda, LetBinder(..))
import Mid.Shrink as Shrink


type alias Stats =
    { defuns : Int
    , sites : Int
    , fullArity : Int
    , inlined : Int
    , refusedCost : Int
    , refusedRecursive : Int
    , refusedArgOrder : Int
    , candidates : Int
    }


zero : Stats
zero =
    { defuns = 0
    , sites = 0
    , fullArity = 0
    , inlined = 0
    , refusedCost = 0
    , refusedRecursive = 0
    , refusedArgOrder = 0
    , candidates = 0
    }


plus : Stats -> Stats -> Stats
plus a b =
    { defuns = a.defuns + b.defuns
    , sites = a.sites + b.sites
    , fullArity = a.fullArity + b.fullArity
    , inlined = a.inlined + b.inlined
    , refusedCost = a.refusedCost + b.refusedCost
    , refusedRecursive = a.refusedRecursive + b.refusedRecursive
    , refusedArgOrder = a.refusedArgOrder + b.refusedArgOrder
    , candidates = a.candidates + b.candidates
    }


run : Int -> List Defun -> ( List Defun, String )
run threshold defuns =
    let
        offsets =
            scanOffsets defuns

        offsetDefuns =
            List.map2 offsetDefun offsets defuns

        infos =
            List.foldl (\d acc -> Dict.insert d.key (infoOf d.key d.value) acc) Dict.empty offsetDefuns

        ctx =
            { infos = infos, threshold = threshold }

        ( rev, wstate ) =
            List.foldl (inlineDefun ctx) ( [], { stats = zero, fresh = 0 } ) offsetDefuns

        stats0 =
            wstate.stats

        stats =
            { stats0 | defuns = List.length defuns, candidates = List.length (List.filter (isCandidate ctx) offsetDefuns) }
    in
    ( List.reverse rev, report stats )


report : Stats -> String
report s =
    if s.sites == 0 && s.candidates == 0 then
        ""

    else
        "inline: defuns="
            ++ String.fromInt s.defuns
            ++ " candidates="
            ++ String.fromInt s.candidates
            ++ " sites="
            ++ String.fromInt s.sites
            ++ " fullArity="
            ++ String.fromInt s.fullArity
            ++ " inlined="
            ++ String.fromInt s.inlined
            ++ " | left: cost="
            ++ String.fromInt s.refusedCost
            ++ " recursive="
            ++ String.fromInt s.refusedRecursive
            ++ " argOrder="
            ++ String.fromInt s.refusedArgOrder



-- ============================ PHASE 1: OFFSETS ============================
-- Each defun i's binder ids become `offset_i + id`, where offsets are
-- cumulative so every defun owns a disjoint id range.  This is the whole
-- alpha-renaming story (see the header) and makes the substitution below
-- capture-free.


scanOffsets : List Defun -> List Int
scanOffsets defuns =
    Tuple.second
        (List.foldl
            (\d ( next, acc ) -> ( next + maxIdOf d.value + 1, next :: acc ))
            ( 0, [] )
            defuns
        )
        |> List.reverse


offsetDefun : Int -> Defun -> Defun
offsetDefun off defun =
    { defun | value = offsetExp off defun.value }


maxIdOf : Exp -> Int
maxIdOf exp =
    case exp of
        Var id ->
            id

        Lit _ ->
            0

        GRef _ ->
            0

        StreamRef _ ->
            0

        Lam lam ->
            max (maxBinderId lam.params) (maxIdOf lam.body)

        NoTail inner ->
            maxIdOf inner

        App app ->
            max (maxIdOf app.fn) (maxIdOfAll app.args)

        PrimApp app ->
            maxIdOfAll app.args

        Let block ->
            max (maxIdOfBinderList block.binders) (maxIdOf block.body)

        Case branch ->
            max branch.scrutId.id
                (max (maxIdOf branch.scrutinee)
                    (maxIdOfAltList branch.alts)
                )

        Con con ->
            maxIdOfAll con.args

        Tup es ->
            maxIdOfAll es

        RecordLit setters ->
            maxIdOfSetterList setters

        RecordGet base _ ->
            maxIdOf base

        RecordUpdate upd ->
            max (maxIdOf upd.base) (maxIdOfSetterList upd.updates)

        ListLit es ->
            maxIdOfAll es

        If block ->
            max (maxIdOf block.cond) (max (maxIdOf block.thenBranch) (maxIdOf block.elseBranch))

        ShortAnd block ->
            max (maxIdOf block.left) (maxIdOf block.right)

        ShortOr block ->
            max (maxIdOf block.left) (maxIdOf block.right)

        NotEqual block ->
            max (maxIdOf block.left) (maxIdOf block.right)


maxIdOfAll : List Exp -> Int
maxIdOfAll exps =
    List.foldl (\e acc -> max acc (maxIdOf e)) 0 exps


maxIdOfSetterList : List ( String, Exp ) -> Int
maxIdOfSetterList setters =
    List.foldl (\( _, e ) acc -> max acc (maxIdOf e)) 0 setters


maxIdOfBinderList : List LetBinder -> Int
maxIdOfBinderList binders =
    List.foldl (\b acc -> max acc (maxIdOfBinder b)) 0 binders


maxIdOfBinder : LetBinder -> Int
maxIdOfBinder b =
    case b of
        LetBind bind ->
            max bind.binder.id (maxIdOf bind.value)

        LetDestruct destruct ->
            max destruct.scrutId.id
                (max (maxIdOf destruct.value)
                    (List.foldl (\( binder, _ ) acc -> max acc binder.id) 0 destruct.binds)
                )


maxIdOfAltList : List Alt -> Int
maxIdOfAltList alts =
    List.foldl (\a acc -> max acc (maxIdOfAlt a)) 0 alts


maxIdOfAlt : Alt -> Int
maxIdOfAlt alt =
    max (maxIdOf alt.body)
        (List.foldl (\( binder, _ ) acc -> max acc binder.id) 0 alt.binds)


maxBinderId : List Binder -> Int
maxBinderId binders =
    List.foldl (\b acc -> max acc b.id) 0 binders


offsetExp : Int -> Exp -> Exp
offsetExp off exp =
    case exp of
        Var id ->
            Var (id + off)

        Lit _ ->
            exp

        GRef _ ->
            exp

        StreamRef _ ->
            exp

        Lam lam ->
            Lam { params = List.map (offsetBinder off) lam.params, body = offsetExp off lam.body }

        NoTail inner ->
            NoTail (offsetExp off inner)

        App app ->
            App { fn = offsetExp off app.fn, args = List.map (offsetExp off) app.args }

        PrimApp app ->
            PrimApp { app | args = List.map (offsetExp off) app.args }

        Let block ->
            Let { binders = List.map (offsetBinderLet off) block.binders, body = offsetExp off block.body }

        Case branch ->
            Case
                { branch
                    | scrutinee = offsetExp off branch.scrutinee
                    , scrutId = offsetBinder off branch.scrutId
                    , alts = List.map (offsetAlt off) branch.alts
                }

        Con con ->
            Con { con | args = List.map (offsetExp off) con.args }

        Tup es ->
            Tup (List.map (offsetExp off) es)

        RecordLit setters ->
            RecordLit (List.map (offsetSetter off) setters)

        RecordGet base field ->
            RecordGet (offsetExp off base) field

        RecordUpdate upd ->
            RecordUpdate
                { upd
                    | base = offsetExp off upd.base
                    , updates = List.map (offsetSetter off) upd.updates
                }

        ListLit es ->
            ListLit (List.map (offsetExp off) es)

        If block ->
            If
                { block
                    | cond = offsetExp off block.cond
                    , thenBranch = offsetExp off block.thenBranch
                    , elseBranch = offsetExp off block.elseBranch
                }

        ShortAnd block ->
            ShortAnd { block | left = offsetExp off block.left, right = offsetExp off block.right }

        ShortOr block ->
            ShortOr { block | left = offsetExp off block.left, right = offsetExp off block.right }

        NotEqual block ->
            NotEqual { block | left = offsetExp off block.left, right = offsetExp off block.right }


offsetBinder : Int -> Binder -> Binder
offsetBinder off b =
    { b | id = b.id + off }


offsetSetter : Int -> ( String, Exp ) -> ( String, Exp )
offsetSetter off ( field, e ) =
    ( field, offsetExp off e )


offsetBinderLet : Int -> LetBinder -> LetBinder
offsetBinderLet off b =
    case b of
        LetBind bind ->
            LetBind { bind | binder = offsetBinder off bind.binder, value = offsetExp off bind.value }

        LetDestruct destruct ->
            LetDestruct
                { destruct
                    | scrutId = offsetBinder off destruct.scrutId
                    , value = offsetExp off destruct.value
                    , binds = List.map (\( binder, path ) -> ( offsetBinder off binder, path )) destruct.binds
                }


offsetAlt : Int -> Alt -> Alt
offsetAlt off alt =
    { alt
        | body = offsetExp off alt.body
        , binds = List.map (\( binder, path ) -> ( offsetBinder off binder, path )) alt.binds
    }



-- ============================ PHASE 2: INFO ============================
-- What the inline decision needs to know about a defun: its arity, its body's
-- cost (size), and whether it references itself (recursive).  The arity is
-- the Lam's param count; the cost and recursion are computed from the body.


type alias Info =
    { arity : Int
    , cost : Int
    , recursive : Bool
    , body : Maybe Lambda
    }


infoOf : String -> Exp -> Info
infoOf key value =
    case value of
        Lam lam ->
            { arity = List.length lam.params
            , cost = costOf lam.body
            , recursive = refsKey key lam.body
            , body = Just lam
            }

        _ ->
            -- Defun values are always Lam (Mid.Ir); a non-Lam here is a
            -- compiler bug, and the Nothing body makes the site ineligible.
            { arity = 0, cost = 0, recursive = True, body = Nothing }


costOf : Exp -> Int
costOf exp =
    1
        + (case exp of
            Lit _ ->
                0

            Var _ ->
                0

            GRef _ ->
                0

            StreamRef _ ->
                0

            Lam lam ->
                costOf lam.body

            NoTail inner ->
                costOf inner

            App app ->
                costOf app.fn + List.sum (List.map costOf app.args)

            PrimApp app ->
                List.sum (List.map costOf app.args)

            Let block ->
                List.sum (List.map costOfBinder block.binders) + costOf block.body

            Case branch ->
                costOf branch.scrutinee + List.sum (List.map (\a -> costOf a.body) branch.alts)

            Con con ->
                List.sum (List.map costOf con.args)

            Tup es ->
                List.sum (List.map costOf es)

            RecordLit setters ->
                List.sum (List.map (\( _, e ) -> costOf e) setters)

            RecordGet base _ ->
                costOf base

            RecordUpdate upd ->
                costOf upd.base + List.sum (List.map (\( _, e ) -> costOf e) upd.updates)

            ListLit es ->
                List.sum (List.map costOf es)

            If block ->
                costOf block.cond + costOf block.thenBranch + costOf block.elseBranch

            ShortAnd block ->
                costOf block.left + costOf block.right

            ShortOr block ->
                costOf block.left + costOf block.right

            NotEqual block ->
                costOf block.left + costOf block.right
          )


costOfBinder : LetBinder -> Int
costOfBinder b =
    case b of
        LetBind bind ->
            costOf bind.value

        LetDestruct destruct ->
            costOf destruct.value


refsKey : String -> Exp -> Bool
refsKey key exp =
    case exp of
        GRef ref ->
            ref.key == key

        Var _ ->
            False

        Lit _ ->
            False

        StreamRef _ ->
            False

        Lam lam ->
            refsKey key lam.body

        NoTail inner ->
            refsKey key inner

        App app ->
            refsKey key app.fn || List.any (refsKey key) app.args

        PrimApp app ->
            List.any (refsKey key) app.args

        Let block ->
            List.any (refsKeyBinder key) block.binders || refsKey key block.body

        Case branch ->
            refsKey key branch.scrutinee || List.any (\a -> refsKey key a.body) branch.alts

        Con con ->
            List.any (refsKey key) con.args

        Tup es ->
            List.any (refsKey key) es

        RecordLit setters ->
            List.any (\( _, e ) -> refsKey key e) setters

        RecordGet base _ ->
            refsKey key base

        RecordUpdate upd ->
            refsKey key upd.base || List.any (\( _, e ) -> refsKey key e) upd.updates

        ListLit es ->
            List.any (refsKey key) es

        If block ->
            refsKey key block.cond || refsKey key block.thenBranch || refsKey key block.elseBranch

        ShortAnd block ->
            refsKey key block.left || refsKey key block.right

        ShortOr block ->
            refsKey key block.left || refsKey key block.right

        NotEqual block ->
            refsKey key block.left || refsKey key block.right


refsKeyBinder : String -> LetBinder -> Bool
refsKeyBinder key b =
    case b of
        LetBind bind ->
            refsKey key bind.value

        LetDestruct destruct ->
            refsKey key destruct.value



-- ============================ PHASE 3: THE WALK ============================


type alias Ctx =
    { infos : Dict String Info
    , threshold : Int
    }


-- The walk threads `fresh`, a label counter.  Inlining COPIES a body into a
-- target defun, and the body's label NAMES (Case.endLabel, Alt.nextLabel,
-- If/Short*/NotEqual falseLabel/endLabel, LetDestruct badLabel/okLabel) are
-- resolved BY NAME in `Zinc.Emit.resolve` — a flat name->pc map.  Two copies
-- of one body in one defun therefore carry the SAME label names and their
-- jumps cross-wire (the boolcase gate failure this comment exists to prevent:
-- `sign True + sign False` inlined `sign` twice and `f 21` in the first copy
-- jumped into the SECOND copy's alt).  Each inline site renames every label in
-- its copy to a fresh unique name (`inl<n>`), so resolve can never conflate
-- them.  Binder ids need no per-site work: the offset prepass already gave
-- every defun a disjoint id range (see the header).
type alias WState =
    { stats : Stats
    , fresh : Int
    }


inlineDefun : Ctx -> Defun -> ( List Defun, WState ) -> ( List Defun, WState )
inlineDefun ctx defun ( acc, wstate ) =
    let
        ( value, wstate1 ) =
            inlineExp ctx defun.value wstate
    in
    ( { defun | value = value } :: acc, wstate1 )


-- A defun is an inline CANDIDATE (eligible to be inlined into a caller) when
-- it is non-recursive, full-arity-callable (arity >= 1), and under the size
-- budget.  Counted once, here, not per site.
isCandidate : Ctx -> Defun -> Bool
isCandidate ctx defun =
    case Dict.get defun.key ctx.infos of
        Just info ->
            not info.recursive && info.arity >= 1 && info.cost <= ctx.threshold

        Nothing ->
            False


inlineExp : Ctx -> Exp -> WState -> ( Exp, WState )
inlineExp ctx exp wstate =
    case exp of
        App app ->
            let
                ( fn, w1 ) =
                    inlineExp ctx app.fn wstate

                ( args, w2 ) =
                    inlineAll ctx app.args w1
            in
            case fn of
                GRef ref ->
                    if not ref.force then
                        decideSite ctx ref.key args w2

                    else
                        ( App { fn = fn, args = args }, w2 )

                _ ->
                    ( App { fn = fn, args = args }, w2 )

        Lit _ ->
            ( exp, wstate )

        Var _ ->
            ( exp, wstate )

        GRef _ ->
            ( exp, wstate )

        StreamRef _ ->
            ( exp, wstate )

        Lam lam ->
            let
                ( body, w1 ) =
                    inlineExp ctx lam.body wstate
            in
            ( Lam { lam | body = body }, w1 )

        NoTail inner ->
            let
                ( e, w1 ) =
                    inlineExp ctx inner wstate
            in
            ( NoTail e, w1 )

        PrimApp app ->
            let
                ( args, w1 ) =
                    inlineAll ctx app.args wstate
            in
            ( PrimApp { app | args = args }, w1 )

        Let block ->
            let
                ( binders, w1 ) =
                    inlineBinders ctx block.binders wstate

                ( body, w2 ) =
                    inlineExp ctx block.body w1
            in
            ( Let { binders = binders, body = body }, w2 )

        Case branch ->
            let
                ( scrutinee, w1 ) =
                    inlineExp ctx branch.scrutinee wstate

                ( alts, w2 ) =
                    inlineAlts ctx branch.alts w1
            in
            ( Case { branch | scrutinee = scrutinee, alts = alts }, w2 )

        Con con ->
            let
                ( args, w1 ) =
                    inlineAll ctx con.args wstate
            in
            ( Con { con | args = args }, w1 )

        Tup es ->
            let
                ( es1, w1 ) =
                    inlineAll ctx es wstate
            in
            ( Tup es1, w1 )

        RecordLit setters ->
            let
                ( setters1, w1 ) =
                    inlineSetters ctx setters wstate
            in
            ( RecordLit setters1, w1 )

        RecordGet base field ->
            let
                ( b, w1 ) =
                    inlineExp ctx base wstate
            in
            ( RecordGet b field, w1 )

        RecordUpdate upd ->
            let
                ( base, w1 ) =
                    inlineExp ctx upd.base wstate

                ( updates, w2 ) =
                    inlineSetters ctx upd.updates w1
            in
            ( RecordUpdate { upd | base = base, updates = updates }, w2 )

        ListLit es ->
            let
                ( es1, w1 ) =
                    inlineAll ctx es wstate
            in
            ( ListLit es1, w1 )

        If block ->
            let
                ( cond, w1 ) =
                    inlineExp ctx block.cond wstate

                ( t, w2 ) =
                    inlineExp ctx block.thenBranch w1

                ( f, w3 ) =
                    inlineExp ctx block.elseBranch w2
            in
            ( If { block | cond = cond, thenBranch = t, elseBranch = f }, w3 )

        ShortAnd block ->
            let
                ( left, w1 ) =
                    inlineExp ctx block.left wstate

                ( right, w2 ) =
                    inlineExp ctx block.right w1
            in
            ( ShortAnd { block | left = left, right = right }, w2 )

        ShortOr block ->
            let
                ( left, w1 ) =
                    inlineExp ctx block.left wstate

                ( right, w2 ) =
                    inlineExp ctx block.right w1
            in
            ( ShortOr { block | left = left, right = right }, w2 )

        NotEqual block ->
            let
                ( left, w1 ) =
                    inlineExp ctx block.left wstate

                ( right, w2 ) =
                    inlineExp ctx block.right w1
            in
            ( NotEqual { block | left = left, right = right }, w2 )


inlineAll : Ctx -> List Exp -> WState -> ( List Exp, WState )
inlineAll ctx exps wstate =
    case exps of
        [] ->
            ( [], wstate )

        e :: rest ->
            let
                ( e1, w1 ) =
                    inlineExp ctx e wstate

                ( rest1, w2 ) =
                    inlineAll ctx rest w1
            in
            ( e1 :: rest1, w2 )


inlineSetters : Ctx -> List ( String, Exp ) -> WState -> ( List ( String, Exp ), WState )
inlineSetters ctx setters wstate =
    case setters of
        [] ->
            ( [], wstate )

        ( field, value ) :: rest ->
            let
                ( v1, w1 ) =
                    inlineExp ctx value wstate

                ( rest1, w2 ) =
                    inlineSetters ctx rest w1
            in
            ( ( field, v1 ) :: rest1, w2 )


inlineBinders : Ctx -> List LetBinder -> WState -> ( List LetBinder, WState )
inlineBinders ctx binders wstate =
    case binders of
        [] ->
            ( [], wstate )

        b :: rest ->
            let
                ( b1, w1 ) =
                    inlineBinder ctx b wstate

                ( rest1, w2 ) =
                    inlineBinders ctx rest w1
            in
            ( b1 :: rest1, w2 )


inlineBinder : Ctx -> LetBinder -> WState -> ( LetBinder, WState )
inlineBinder ctx b wstate =
    case b of
        LetBind bind ->
            let
                ( v, w1 ) =
                    inlineExp ctx bind.value wstate
            in
            ( LetBind { bind | value = v }, w1 )

        LetDestruct destruct ->
            let
                ( v, w1 ) =
                    inlineExp ctx destruct.value wstate
            in
            ( LetDestruct { destruct | value = v }, w1 )


inlineAlts : Ctx -> List Alt -> WState -> ( List Alt, WState )
inlineAlts ctx alts wstate =
    case alts of
        [] ->
            ( [], wstate )

        alt :: rest ->
            let
                ( body, w1 ) =
                    inlineExp ctx alt.body wstate

                ( rest1, w2 ) =
                    inlineAlts ctx rest w1
            in
            ( { alt | body = body } :: rest1, w2 )



-- ============================ LABEL FRESHENING ============================
-- Applied to a body at each inline site.  Labels are dropped by the emitter
-- but resolved by NAME, so a copied body must carry label names unique within
-- the target defun.  `relabel` assigns a fresh `inl<n>` name per label field
-- (the original name is irrelevant — it never reaches the bytes); the `inl`
-- prefix cannot collide with a FromAst label (`tag_row_col`).


freshenLabels : Int -> Exp -> ( Exp, Int )
freshenLabels fresh exp =
    case exp of
        Case branch ->
            let
                ( scrut, f1 ) =
                    freshenLabels fresh branch.scrutinee

                ( alts, f2 ) =
                    freshenAltLabels f1 branch.alts

                ( endLabel, f3 ) =
                    relabel f2
            in
            ( Case { branch | scrutinee = scrut, alts = alts, endLabel = endLabel }, f3 )

        If block ->
            let
                ( cond, f1 ) =
                    freshenLabels fresh block.cond

                ( t, f2 ) =
                    freshenLabels f1 block.thenBranch

                ( e, f3 ) =
                    freshenLabels f2 block.elseBranch

                ( fl, f4 ) =
                    relabel f3

                ( el, f5 ) =
                    relabel f4
            in
            ( If { block | cond = cond, thenBranch = t, elseBranch = e, falseLabel = fl, endLabel = el }, f5 )

        ShortAnd block ->
            let
                ( left, f1 ) =
                    freshenLabels fresh block.left

                ( right, f2 ) =
                    freshenLabels f1 block.right

                ( fl, f3 ) =
                    relabel f2

                ( el, f4 ) =
                    relabel f3
            in
            ( ShortAnd { block | left = left, right = right, falseLabel = fl, endLabel = el }, f4 )

        ShortOr block ->
            let
                ( left, f1 ) =
                    freshenLabels fresh block.left

                ( right, f2 ) =
                    freshenLabels f1 block.right

                ( fl, f3 ) =
                    relabel f2

                ( el, f4 ) =
                    relabel f3
            in
            ( ShortOr { block | left = left, right = right, falseLabel = fl, endLabel = el }, f4 )

        NotEqual block ->
            let
                ( left, f1 ) =
                    freshenLabels fresh block.left

                ( right, f2 ) =
                    freshenLabels f1 block.right

                ( fl, f3 ) =
                    relabel f2

                ( el, f4 ) =
                    relabel f3
            in
            ( NotEqual { block | left = left, right = right, falseLabel = fl, endLabel = el }, f4 )

        Let block ->
            let
                ( binders, f1 ) =
                    freshenBinderLabels fresh block.binders

                ( body, f2 ) =
                    freshenLabels f1 block.body
            in
            ( Let { binders = binders, body = body }, f2 )

        Lam lam ->
            let
                ( body, f1 ) =
                    freshenLabels fresh lam.body
            in
            ( Lam { lam | body = body }, f1 )

        NoTail inner ->
            let
                ( e, f1 ) =
                    freshenLabels fresh inner
            in
            ( NoTail e, f1 )

        App app ->
            let
                ( fn, f1 ) =
                    freshenLabels fresh app.fn

                ( args, f2 ) =
                    freshenLabelsAll f1 app.args
            in
            ( App { fn = fn, args = args }, f2 )

        PrimApp app ->
            let
                ( args, f1 ) =
                    freshenLabelsAll fresh app.args
            in
            ( PrimApp { app | args = args }, f1 )

        Con con ->
            let
                ( args, f1 ) =
                    freshenLabelsAll fresh con.args
            in
            ( Con { con | args = args }, f1 )

        Tup es ->
            let
                ( es1, f1 ) =
                    freshenLabelsAll fresh es
            in
            ( Tup es1, f1 )

        RecordLit setters ->
            let
                ( s1, f1 ) =
                    freshenLabelSetters fresh setters
            in
            ( RecordLit s1, f1 )

        RecordGet base field ->
            let
                ( b, f1 ) =
                    freshenLabels fresh base
            in
            ( RecordGet b field, f1 )

        RecordUpdate upd ->
            let
                ( base, f1 ) =
                    freshenLabels fresh upd.base

                ( updates, f2 ) =
                    freshenLabelSetters f1 upd.updates
            in
            ( RecordUpdate { upd | base = base, updates = updates }, f2 )

        ListLit es ->
            let
                ( es1, f1 ) =
                    freshenLabelsAll fresh es
            in
            ( ListLit es1, f1 )

        Lit _ ->
            ( exp, fresh )

        Var _ ->
            ( exp, fresh )

        GRef _ ->
            ( exp, fresh )

        StreamRef _ ->
            ( exp, fresh )


freshenLabelsAll : Int -> List Exp -> ( List Exp, Int )
freshenLabelsAll fresh exps =
    case exps of
        [] ->
            ( [], fresh )

        e :: rest ->
            let
                ( e1, f1 ) =
                    freshenLabels fresh e

                ( rest1, f2 ) =
                    freshenLabelsAll f1 rest
            in
            ( e1 :: rest1, f2 )


freshenLabelSetters : Int -> List ( String, Exp ) -> ( List ( String, Exp ), Int )
freshenLabelSetters fresh setters =
    case setters of
        [] ->
            ( [], fresh )

        ( field, value ) :: rest ->
            let
                ( v1, f1 ) =
                    freshenLabels fresh value

                ( rest1, f2 ) =
                    freshenLabelSetters f1 rest
            in
            ( ( field, v1 ) :: rest1, f2 )


freshenBinderLabels : Int -> List LetBinder -> ( List LetBinder, Int )
freshenBinderLabels fresh binders =
    case binders of
        [] ->
            ( [], fresh )

        b :: rest ->
            let
                ( b1, f1 ) =
                    freshenBinderLabel fresh b

                ( rest1, f2 ) =
                    freshenBinderLabels f1 rest
            in
            ( b1 :: rest1, f2 )


freshenBinderLabel : Int -> LetBinder -> ( LetBinder, Int )
freshenBinderLabel fresh b =
    case b of
        LetBind bind ->
            let
                ( v, f1 ) =
                    freshenLabels fresh bind.value
            in
            ( LetBind { bind | value = v }, f1 )

        LetDestruct destruct ->
            let
                ( v, f1 ) =
                    freshenLabels fresh destruct.value

                ( badLabel, f2 ) =
                    relabel f1

                ( okLabel, f3 ) =
                    relabel f2
            in
            ( LetDestruct { destruct | value = v, badLabel = badLabel, okLabel = okLabel }, f3 )


freshenAltLabels : Int -> List Alt -> ( List Alt, Int )
freshenAltLabels fresh alts =
    case alts of
        [] ->
            ( [], fresh )

        alt :: rest ->
            let
                ( body, f1 ) =
                    freshenLabels fresh alt.body

                ( nextLabel, f2 ) =
                    relabel f1

                ( rest1, f3 ) =
                    freshenAltLabels f2 rest
            in
            ( { alt | body = body, nextLabel = nextLabel } :: rest1, f3 )


relabel : Int -> ( String, Int )
relabel fresh =
    ( "inl" ++ String.fromInt fresh, fresh + 1 )



-- ============================ THE DECISION ============================


type SiteResult
    = Inlined Exp
    | RefusedCost
    | RefusedRecursive
    | RefusedArity
    | RefusedArgOrder
    | RefusedUnknown


decideSite : Ctx -> String -> List Exp -> WState -> ( Exp, WState )
decideSite ctx key args wstate =
    let
        siteCounted =
            { wstate | stats = bumpSites wstate.stats }
    in
    case Dict.get key ctx.infos of
        Nothing ->
            ( rebuildApp key args, siteCounted )

        Just info ->
            let
                ( result, fresh1 ) =
                    classify ctx info args siteCounted.fresh
            in
            case result of
                Inlined exp ->
                    ( exp, bumpInlined { siteCounted | fresh = fresh1 } )

                RefusedCost ->
                    ( rebuildApp key args, bumpFullArity (bumpRefusedCost siteCounted) )

                RefusedRecursive ->
                    ( rebuildApp key args, bumpRefusedRecursive siteCounted )

                RefusedArity ->
                    ( rebuildApp key args, siteCounted )

                RefusedArgOrder ->
                    ( rebuildApp key args, bumpFullArity (bumpRefusedArgOrder siteCounted) )

                RefusedUnknown ->
                    ( rebuildApp key args, siteCounted )


rebuildApp : String -> List Exp -> Exp
rebuildApp key args =
    App { fn = GRef { key = key, force = False }, args = args }


bumpSites : Stats -> Stats
bumpSites s =
    { s | sites = s.sites + 1 }


bumpFullArity : WState -> WState
bumpFullArity w =
    { w | stats = (\s -> { s | fullArity = s.fullArity + 1 }) w.stats }


bumpRefusedCost : WState -> WState
bumpRefusedCost w =
    { w | stats = (\s -> { s | refusedCost = s.refusedCost + 1 }) w.stats }


bumpRefusedRecursive : WState -> WState
bumpRefusedRecursive w =
    { w | stats = (\s -> { s | refusedRecursive = s.refusedRecursive + 1 }) w.stats }


bumpRefusedArgOrder : WState -> WState
bumpRefusedArgOrder w =
    { w | stats = (\s -> { s | refusedArgOrder = s.refusedArgOrder + 1 }) w.stats }


bumpInlined : WState -> WState
bumpInlined w =
    { w
        | stats =
            (\s ->
                { s
                    | fullArity = s.fullArity + 1
                    , inlined = s.inlined + 1
                }
            )
                w.stats
    }


classify : Ctx -> Info -> List Exp -> Int -> ( SiteResult, Int )
classify ctx info args fresh =
    if info.recursive then
        ( RefusedRecursive, fresh )

    else if List.length args /= info.arity || info.arity < 1 then
        ( RefusedArity, fresh )

    else if info.cost > ctx.threshold then
        ( RefusedCost, fresh )

    else
        case info.body of
            Nothing ->
                ( RefusedUnknown, fresh )

            Just lam ->
                if List.all isAtomic args then
                    let
                        ( body, f1 ) =
                            freshenLabels fresh lam.body
                    in
                    ( Inlined (Shrink.substAll (directSubs lam.params args) body), f1 )

                else
                    ( RefusedArgOrder, fresh )


isAtomic : Exp -> Bool
isAtomic exp =
    case exp of
        Var _ ->
            True

        Lit _ ->
            True

        _ ->
            False


directSubs : List Binder -> List Exp -> Dict Int Exp
directSubs params args =
    Dict.fromList (List.map2 (\p a -> ( p.id, a )) params args)
