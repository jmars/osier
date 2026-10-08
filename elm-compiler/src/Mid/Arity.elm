module Mid.Arity exposing (Stats, run)

-- Mid.Arity — the middle tier's FOURTH pass: SATURATION REPAIR, the plan's
-- designated REPRESENTATION pass for a curried-closure VM.
--
-- NOT A LITERAL PORT.  MLton's `xml/uncurry.fun` (which converts CURRIED
-- functions to UNCURRIED multi-arg ones, and is DISABLED upstream because
-- MLton's native backend does not need it while a curried-closure VM does) is
-- the DESIGN precedent for "make the VM see the cheapest application shape",
-- but no MLton source is present and none is copied — this is a fresh rule
-- against this IR's n-ary `App`.  No HPND/MLton header, no THIRD-PARTY.md
-- entry (f2361ed rule: "code ported literally", and this is not).
--
-- ============================ THE THREE RULES ============================
--
-- R-ARITY-1 FLATTEN A LEFT-ASSOCIATIVE APPLICATION SPINE:
--
--     App { fn = App { fn = X, args = p }, args = q }   ==>   App { fn = X, args = p ++ q }
--
-- and the same at any depth.  This is the shape Shrink's copy-propagation
-- leaves behind when it substitutes a partial application `f a` for a bound
-- name used as a callee (`let g = f a in g b` -> `(f a) b`).  SAFE both
-- halves: application is left-associative and currying is associative
-- (`(X p) q` IS `X p q`), and the nested form already emits args in
-- "outer, then inner, then callee" order — the flattened form emits the SAME
-- order.  Payoff: one merged App-as-callee kills a pushmark+apply pair.
--
-- R-ARITY-2 OVER-APPLICATION SPLIT (the first dropped repair, now built):
--
--     App { fn = GRef { key, force = False }, args = a1..an }   (n > A)
--         ==>  App { fn = App { fn = GRef key, args = a1..aA }, args = aA+1..an }
--
-- A curried function of arity A whose BODY RETURNS another function is, in
-- source, applied to more than A args WITHOUT parentheses — `makeAdder 5 3`
-- where `makeAdder x = \y -> x + y` is arity 1.  Elm's application is n-ary,
-- so FromAst produces the FLAT `App (GRef makeAdder) [5, 3]`, and the VM's
-- apply dispatches N>A to `peelOverArgs` (`vendor/zinc-vm/src/vm/interp.zig`):
-- it runs the callee body through a NESTED `vmExecEnv`, which allocates a
-- FRESH FRAME STACK (~3 MB old-gen, see the interp.zig note) PER PEEL LEVEL,
-- plus an env-concat array.  Splitting at the arity boundary turns that into
-- one clean N==A fast-path apply (`makeAdder 5`, one frame + one env) followed
-- by one clean apply of the returned closure.  This ADDS ~3 emitted
-- instructions (a second pushmark+apply) — the exact shape the
-- instruction-count metric rejected, and the exact shape that removes the
-- dominant runtime cost.  It is the INVERSE of R-ARITY-1, applied only when
-- flattening a spine would have over-applied a known-arity callee.
--
-- R-ARITY-3 PARTIAL-APPLICATION ETA-EXPANSION (the second dropped repair):
--
--     App { fn = GRef { key, force = False }, args = a1..ak }   (0 < k < A)
--         ==>  Lam { params = xk+1..xA, body = f a1..ak xk+1..xA }
--
-- A partial application `f a1..ak` USED AS A VALUE builds a closure via
-- `buildPartialClosure` (interp.zig): an O(code_len) INSTRUCTION-ARRAY COPY
-- plus a jump-target rebase pass, an env-concat array, and a closure — three
-- allocations every time the partial application is evaluated.  Eta-expanding
-- to `\x -> f a1..ak x` replaces that with a SINGLE closure allocation (the
-- `Cur`) and turns the eventual call into a full-arity N==A fast path.  The
-- closure body grows, so the emitted instruction count goes UP — again the
-- metric rejected it.  GUARD (the re-evaluation trap): the args a1..ak become
-- FREE VARIABLES of the new closure, re-read from the captured env at CALL
-- time, so this is safe only when each arg is a `Var`, `Lit`, or non-force
-- `GRef` — an already-evaluated value whose re-read is unobservable.  A
-- complex arg (an `App`/`PrimApp`/`Con`/…) would be RE-EVALUATED per call, so
-- the site is left alone.  `NoTail` is also respected: a pipe-pinned partial
-- application stays a partial application (the pass never builds a `Lam` under
-- `NoTail`, which pins an `App`'s emission position).
--
-- ALL THREE ARE JUDGED BY RUNTIME, NOT INSTRUCTION COUNT (see
-- tools/midtier-runtime.sh): R-ARITY-2 and R-ARITY-3 deliberately grow the
-- stream while removing a per-call allocation, which is the VM's dominant
-- cost (docs/vm-perf-plan.md).  The instruction-count delta is still REPORTED
-- alongside (it is informative), but it is not the acceptance criterion.

import Dict exposing (Dict)
import Mid.Ir exposing (Alt, Binder, Defun, Exp(..), LetBinder(..))


type alias Stats =
    { defuns : Int
    , sites : Int
    , spines : Int
    , merged : Int
    , overSplit : Int
    , etaExpanded : Int
    }


zero : Stats
zero =
    { defuns = 0
    , sites = 0
    , spines = 0
    , merged = 0
    , overSplit = 0
    , etaExpanded = 0
    }


type alias Ctx =
    { arities : Dict String Int
    }


type alias WState =
    { stats : Stats
    , fresh : Int
    }


run : List Defun -> ( List Defun, String )
run defuns =
    let
        arities =
            List.foldl (\d acc -> Dict.insert d.key (arityOf d.value) acc) Dict.empty defuns

        ctx =
            { arities = arities }

        ( rev, wstate ) =
            List.foldl (arityDefun ctx) ( [], { stats = zero, fresh = 0 } ) defuns
    in
    ( List.reverse rev, report wstate.stats )


report : Stats -> String
report s =
    if s.sites == 0 then
        ""

    else
        "arity: defuns="
            ++ String.fromInt s.defuns
            ++ " sites="
            ++ String.fromInt s.sites
            ++ " spines="
            ++ String.fromInt s.spines
            ++ " merged="
            ++ String.fromInt s.merged
            ++ " overSplit="
            ++ String.fromInt s.overSplit
            ++ " etaExpanded="
            ++ String.fromInt s.etaExpanded
            ++ " (runtime-only trades: overSplit avoids the nested-vmExecEnv frame stack,"
            ++ " etaExpanded avoids buildPartialClosure's instruction-array copy)"


arityDefun : Ctx -> Defun -> ( List Defun, WState ) -> ( List Defun, WState )
arityDefun ctx defun ( acc, wstate ) =
    let
        -- Fresh binder ids are unique WITHIN one defun; seed the supply above
        -- this defun's highest existing id so eta-expansion params never
        -- collide with a binder a `Var` already refers to.
        fresh0 =
            maxIdOf defun.value + 1

        ( value, w1 ) =
            arityExp ctx False defun.value { wstate | fresh = fresh0 }
    in
    ( { defun | value = value } :: acc
    , { w1 | stats = bumpDefun w1.stats }
    )



-- ============================ THE WALK ============================
-- `inNoTail` is True inside a `NoTail` (a pipe application pins its emission
-- position): flattening and the over-application split are still legal there
-- (their result is still an `App`), but eta-expansion is NOT (its result is a
-- `Lam`, which a `NoTail` cannot pin).


arityExp : Ctx -> Bool -> Exp -> WState -> ( Exp, WState )
arityExp ctx inNoTail exp wstate =
    case exp of
        App app ->
            let
                ( base, args, merged ) =
                    flattenSpine app.fn app.args
            in
            case base of
                GRef ref ->
                    if not ref.force then
                        knownCall ctx inNoTail ref.key args merged wstate

                    else
                        plainApp ctx base args merged wstate

                _ ->
                    plainApp ctx base args merged wstate

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
                    arityExp ctx inNoTail lam.body wstate
            in
            ( Lam { lam | body = body }, w1 )

        NoTail inner ->
            let
                ( e, w1 ) =
                    arityExp ctx True inner wstate
            in
            ( NoTail e, w1 )

        PrimApp app ->
            let
                ( args, w1 ) =
                    arityAll ctx inNoTail app.args wstate
            in
            ( PrimApp { app | args = args }, w1 )

        Let block ->
            let
                ( binders, w1 ) =
                    arityBinders ctx inNoTail block.binders wstate

                ( body, w2 ) =
                    arityExp ctx inNoTail block.body w1
            in
            ( Let { binders = binders, body = body }, w2 )

        Case branch ->
            let
                ( scrutinee, w1 ) =
                    arityExp ctx inNoTail branch.scrutinee wstate

                ( alts, w2 ) =
                    arityAlts ctx inNoTail branch.alts w1
            in
            ( Case { branch | scrutinee = scrutinee, alts = alts }, w2 )

        Con con ->
            let
                ( args, w1 ) =
                    arityAll ctx inNoTail con.args wstate
            in
            ( Con { con | args = args }, w1 )

        Tup es ->
            let
                ( es1, w1 ) =
                    arityAll ctx inNoTail es wstate
            in
            ( Tup es1, w1 )

        RecordLit setters ->
            let
                ( setters1, w1 ) =
                    aritySetters ctx inNoTail setters wstate
            in
            ( RecordLit setters1, w1 )

        RecordGet base field ->
            let
                ( b, w1 ) =
                    arityExp ctx inNoTail base wstate
            in
            ( RecordGet b field, w1 )

        RecordUpdate upd ->
            let
                ( base, w1 ) =
                    arityExp ctx inNoTail upd.base wstate

                ( updates, w2 ) =
                    aritySetters ctx inNoTail upd.updates w1
            in
            ( RecordUpdate { upd | base = base, updates = updates }, w2 )

        ListLit es ->
            let
                ( es1, w1 ) =
                    arityAll ctx inNoTail es wstate
            in
            ( ListLit es1, w1 )

        If block ->
            let
                ( cond, w1 ) =
                    arityExp ctx inNoTail block.cond wstate

                ( t, w2 ) =
                    arityExp ctx inNoTail block.thenBranch w1

                ( f, w3 ) =
                    arityExp ctx inNoTail block.elseBranch w2
            in
            ( If { block | cond = cond, thenBranch = t, elseBranch = f }, w3 )

        ShortAnd block ->
            let
                ( left, w1 ) =
                    arityExp ctx inNoTail block.left wstate

                ( right, w2 ) =
                    arityExp ctx inNoTail block.right w1
            in
            ( ShortAnd { block | left = left, right = right }, w2 )

        ShortOr block ->
            let
                ( left, w1 ) =
                    arityExp ctx inNoTail block.left wstate

                ( right, w2 ) =
                    arityExp ctx inNoTail block.right w1
            in
            ( ShortOr { block | left = left, right = right }, w2 )

        NotEqual block ->
            let
                ( left, w1 ) =
                    arityExp ctx inNoTail block.left wstate

                ( right, w2 ) =
                    arityExp ctx inNoTail block.right w1
            in
            ( NotEqual { block | left = left, right = right }, w2 )



-- A flattened spine whose callee is a KNOWN-arity non-force global: the three
-- saturation-repair decisions.  `args` are in SOURCE order after flattening.
-- n == A leaves the (already cheap) fast path alone; n > A splits off the
-- nested peel; 0 < n < A eta-expands the partial application into a closure —
-- but never under `NoTail`, and never for a non-atomic arg.


knownCall : Ctx -> Bool -> String -> List Exp -> Int -> WState -> ( Exp, WState )
knownCall ctx inNoTail key args merged wstate =
    case Dict.get key ctx.arities of
        Just arity ->
            let
                n =
                    List.length args

                siteCounted =
                    bumpSite merged wstate
            in
            if arity >= 1 && n > arity then
                splitOver ctx key args arity siteCounted

            else if arity >= 1 && n > 0 && n < arity && not inNoTail && List.all isAtomicArg args then
                etaExpand ctx key args arity siteCounted

            else
                -- n == A (fast path), a 0-arg callee, a non-atomic partial, or
                -- a pipe-pinned partial: recurse into the args and leave the
                -- (already saturated or deliberately pinned) shape alone.
                let
                    ( args1, w1 ) =
                        arityAll ctx inNoTail args siteCounted
                in
                ( App { fn = GRef { key = key, force = False }, args = args1 }, w1 )

        Nothing ->
            -- Unknown key: recurse and leave.  (Every GRef resolves to a defun
            -- in practice; this is the same conservative arm Inline takes.)
            plainApp ctx (GRef { key = key, force = False }) args merged wstate


plainApp : Ctx -> Exp -> List Exp -> Int -> WState -> ( Exp, WState )
plainApp ctx base args merged wstate =
    let
        ( base1, w1 ) =
            arityExp ctx False base (bumpSite merged wstate)

        ( args1, w2 ) =
            arityAll ctx False args w1
    in
    ( App { fn = base1, args = args1 }, w2 )


splitOver : Ctx -> String -> List Exp -> Int -> WState -> ( Exp, WState )
splitOver ctx key args arity wstate =
    let
        first =
            List.take arity args

        rest =
            List.drop arity args

        ( first1, w1 ) =
            arityAll ctx False first wstate

        ( rest1, w2 ) =
            arityAll ctx False rest w1
    in
    -- The inner App is EXACTLY saturated (arity args) — constructed here, not
    -- re-walked, so the spine is not flattened back together.  Evaluation order
    -- is preserved: outer args RTL, then inner args RTL, then the callee — the
    -- same order the flat App emitted.
    ( App
        { fn = App { fn = GRef { key = key, force = False }, args = first1 }
        , args = rest1
        }
    , { w2 | stats = bumpOverSplit w2.stats }
    )


etaExpand : Ctx -> String -> List Exp -> Int -> WState -> ( Exp, WState )
etaExpand ctx key args arity wstate =
    let
        ( args1, w1 ) =
            arityAll ctx False args wstate

        missing =
            arity - List.length args1

        ( params, w2 ) =
            genBinders missing w1

        paramVars =
            List.map (\b -> Var b.id) params

        body =
            App { fn = GRef { key = key, force = False }, args = args1 ++ paramVars }
    in
    ( Lam { params = params, body = body }, { w2 | stats = bumpEta w2.stats } )


genBinders : Int -> WState -> ( List Binder, WState )
genBinders n wstate =
    if n <= 0 then
        ( [], wstate )

    else
        let
            id =
                wstate.fresh

            binder =
                { id = id, name = "ar$eta" ++ String.fromInt id }
        in
        let
            ( rest, w1 ) =
                genBinders (n - 1) { wstate | fresh = id + 1 }
        in
        ( binder :: rest, w1 )


isAtomicArg : Exp -> Bool
isAtomicArg exp =
    case exp of
        Var _ ->
            True

        Lit _ ->
            True

        GRef ref ->
            not ref.force

        _ ->
            False


arityAll : Ctx -> Bool -> List Exp -> WState -> ( List Exp, WState )
arityAll ctx inNoTail exps wstate =
    case exps of
        [] ->
            ( [], wstate )

        e :: rest ->
            let
                ( e1, w1 ) =
                    arityExp ctx inNoTail e wstate

                ( rest1, w2 ) =
                    arityAll ctx inNoTail rest w1
            in
            ( e1 :: rest1, w2 )


aritySetters : Ctx -> Bool -> List ( String, Exp ) -> WState -> ( List ( String, Exp ), WState )
aritySetters ctx inNoTail setters wstate =
    case setters of
        [] ->
            ( [], wstate )

        ( field, value ) :: rest ->
            let
                ( v1, w1 ) =
                    arityExp ctx inNoTail value wstate

                ( rest1, w2 ) =
                    aritySetters ctx inNoTail rest w1
            in
            ( ( field, v1 ) :: rest1, w2 )


arityBinders : Ctx -> Bool -> List LetBinder -> WState -> ( List LetBinder, WState )
arityBinders ctx inNoTail binders wstate =
    case binders of
        [] ->
            ( [], wstate )

        b :: rest ->
            let
                ( b1, w1 ) =
                    arityBinder ctx inNoTail b wstate

                ( rest1, w2 ) =
                    arityBinders ctx inNoTail rest w1
            in
            ( b1 :: rest1, w2 )


arityBinder : Ctx -> Bool -> LetBinder -> WState -> ( LetBinder, WState )
arityBinder ctx inNoTail b wstate =
    case b of
        LetBind bind ->
            let
                ( v, w1 ) =
                    arityExp ctx inNoTail bind.value wstate
            in
            ( LetBind { bind | value = v }, w1 )

        LetDestruct destruct ->
            let
                ( v, w1 ) =
                    arityExp ctx inNoTail destruct.value wstate
            in
            ( LetDestruct { destruct | value = v }, w1 )


arityAlts : Ctx -> Bool -> List Alt -> WState -> ( List Alt, WState )
arityAlts ctx inNoTail alts wstate =
    case alts of
        [] ->
            ( [], wstate )

        alt :: rest ->
            let
                ( body, w1 ) =
                    arityExp ctx inNoTail alt.body wstate

                ( rest1, w2 ) =
                    arityAlts ctx inNoTail rest w1
            in
            ( { alt | body = body } :: rest1, w2 )



-- ============================ THE SPINE ============================
-- Walk the `fn` spine of a left-associative application chain, collecting the
-- non-App base callee and all the arguments in SOURCE order, and count how
-- many App-as-callee nodes were merged.  `acc` holds the args seen so far in
-- source order (outer args are appended AFTER inner args, so the innermost
-- contributes first).


flattenSpine : Exp -> List Exp -> ( Exp, List Exp, Int )
flattenSpine fn acc =
    case fn of
        App inner ->
            let
                ( base, args, n ) =
                    flattenSpine inner.fn (inner.args ++ acc)
            in
            ( base, args, n + 1 )

        _ ->
            ( fn, acc, 0 )



-- ============================ BINDER SUPPLY ============================
-- The highest binder id in a defun's value.  Eta-expansion params start above
-- it, so a fresh `Var` can never collide with an existing binder id within the
-- same defun (ids are unique only WITHIN a defun — Mid.Ir).


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


arityOf : Exp -> Int
arityOf value =
    case value of
        Lam lam ->
            List.length lam.params

        _ ->
            0


bumpDefun : Stats -> Stats
bumpDefun s =
    { s | defuns = s.defuns + 1 }


bumpSite : Int -> WState -> WState
bumpSite merged w =
    { w
        | stats =
            (\s ->
                { s
                    | sites = s.sites + 1
                    , spines = s.spines + (if merged > 0 then 1 else 0)
                    , merged = s.merged + merged
                }
            )
                w.stats
    }


bumpOverSplit : Stats -> Stats
bumpOverSplit s =
    { s | overSplit = s.overSplit + 1 }


bumpEta : Stats -> Stats
bumpEta s =
    { s | etaExpanded = s.etaExpanded + 1 }
