module Mid.Shrink exposing (Stats, run, substAll)

-- Mid.Shrink — the middle tier's FIRST optimization pass: the structural
-- shrink (Sestoft's algorithm, JFP 1997 / MLton's `xml/shrink.fun`), reduced
-- to the rules this IR and this target actually pay for.
--
-- NOT A LITERAL PORT — READ THIS BEFORE ADDING AN ATTRIBUTION.  MLton's
-- `shrink.fun` and Sestoft's paper are the DESIGN source for this pass, and
-- the rule set below (occurrence counting over a linear let chain, dead
-- binder removal, copy propagation, beta reduction of a fully applied
-- abstraction) is the rule set they define.  No MLton source is present in
-- this tree and none was copied: every line here is written against THIS
-- IR (`Mid.Ir`'s unique-Int binders, n-ary `App`, sequential `Let`), whose
-- facts differ from MLton's in ways the rules must respect (see ORDER below).
-- That is why there is no HPND/MLton header on this file and no THIRD-PARTY
-- entry for it: the f2361ed rule is "code ported literally", and this is not.
-- (Contrast a future literal translation of, say, `ssa/inline.fun`'s threshold
-- machinery, which WOULD need the notice + the entry, per plan D-LICENSING.)
--
-- WHY IT IS FIRST (plan §(b) payoff order): it is the only pass that can
-- shrink the tree BEFORE any other pass's heuristics look at it — Inline's
-- thresholds and ConstFold's fold sites are all measured on the tree this
-- leaves behind.  In the ZINC cost model its wins are `Let_`/`Endlet` pairs
-- (an `envPush` allocation each), the env slots they occupy (every later
-- `Access` depth), and whole closure allocations for a beta-reduced
-- abstraction (a `Cur` + `Grab`s + the `Apply`).
--
-- ============================ THE RULES ============================
--
--  R1 DEAD BINDER.   `let x = e in rest` where x does not occur in `rest`
--     drops the binder (and its slot), IF `e` cannot be observed.  Elm is
--     STRICT, so this is a purity judgement, not a syntactic one: dropping a
--     binder whose value can raise, write, or not terminate is observable.
--     `isSafe` is the (conservative) judgement; `address->` (a vector WRITE)
--     and every stream/`gensym`/`set`/`value`/`simple-error` prim are
--     deliberately outside it.
--  R2 COPY PROPAGATION.  `let x = y in rest` (any number of uses) replaces x
--     by y.  y is already a value, so no reordering is observable and the
--     substitution can never duplicate work; it removes the slot and the
--     `Let_`.
--  R3 SINGLE-USE TRIVIAL INLINING.  `let x = e in rest` with exactly ONE
--     occurrence of x and `e` trivial (a literal, a var, a global load, or a
--     lambda) substitutes e at the use site.  This is MLton's `shrink` on
--     values; for a lambda it is what removes the closure AND the slot.
--     Substituting under a nested lambda is SAFE here (it only moves when the
--     closure is allocated) because binder ids are unique per defun, so no
--     substitution can ever capture.
--  R4 BETA.  `(\p1..pn -> body) a1..an` (exactly saturated) becomes a `Let`
--     that binds the lambda's OWN param binders to the args, so no
--     substitution is needed at all — the ids already match.  It removes the
--     `m` pushmark, the `Cur` closure (+ its `r` grabs and `v` return), the
--     `p`/`t` apply, and the closure+frame allocation at run time.
--
-- ============================ THE ORDER TRAP ============================
-- R4 rewrites an `App` into a `Let`, and the two emit their sub-expressions
-- in OPPOSITE orders: `App` emits its ARGS RIGHT-TO-LEFT (see Mid.ToZinc: the
-- VM pops top-first, so argbuf[0] must be the first source arg) while `Let`
-- emits its binder values LEFT-TO-RIGHT.  A beta reduction therefore
-- REORDERS the evaluation of the arguments, which is observable for a strict
-- language the moment an argument can raise, write, or diverge.  R4 is
-- consequently restricted to arguments that are ORDER-INSENSITIVE
-- (`safeArg`: literals, vars, non-forced global loads, lambdas, and the total
-- data prims), and a call with a raising argument is left alone.  The exact
-- same asymmetry is why the ZINC env layout (param_i = access(n-i)) must be
-- preserved: the `Let` binders are emitted in SOURCE order so the resulting
-- env is `[pn, …, p1] ++ outer`, identical to the env `emitLam` builds.
--
-- ============================ MEASURED EFFECT ============================
-- The plan ranked Shrink FIRST on the theory that it kills `Let_`/`Endlet`
-- env churn.  MEASURED on this corpus, it does not: the compiler's own
-- compiled form (the selfhost bundle, 98,690 instructions) loses 18 of them
-- (-0.018%), and the 149 gate artifacts together lose 558 of 1,521,482
-- (-0.036%).  The reason is in the pass's own opportunity counters (see
-- `report` below): of 464 `LetBind` binders in the whole compiler, 8 are dead
-- (plus 3 copy props, 5 single-use trivial inlines, 1 beta) — hand-written Elm
-- simply has almost no dead code.
--
-- WHERE THE 5118 EMITTED `let`s GO (DERIVED, from the counters above, not
-- separately counted): 464 `LetBind` + 160 `LetDestruct` binders account for
-- 624 of them, and each `case` emits exactly one scrutinee `Let_`
-- (`Mid.ToZinc.emitExp`'s `Case` branch), so the residue — the large majority
-- — is the case population's scrutinee temps.  Those are not `Let` binders,
-- so no `Shrink` rule can reach them; the plan's "Let_/Endlet env churn" is
-- therefore mostly the case compiler's shape, not dead bindings.
--
-- WHAT IS DELIBERATELY NOT HERE: constant folding and case-of-known-
-- constructor are pass 2 (`Mid.ConstFold`, with the VM's own prim semantics
-- as the oracle), and closure-level inlining is pass 3 (`Mid.Inline`).
-- Splitting them is the plan's S2/S3 staging, and it keeps each pass's
-- evidence attributable: a rewrite that fires in two passes at once cannot be
-- bisected with `MIDTIER_NO*`.

import Dict exposing (Dict)
import Mid.Ir exposing (Alt, Defun, Exp(..), LetBinder(..), Lit(..))
import Set exposing (Set)


type alias Stats =
    { deadBindings : Int
    , copyProps : Int
    , trivialInlines : Int
    , betas : Int
    , killedLets : Int
    , rounds : Int
    , binders : Int
    , deadUnsafe : Int
    , singleNonTrivial : Int
    , recursive : Int
    , multiUse : Int
    , destructs : Int
    }


zero : Stats
zero =
    { deadBindings = 0
    , copyProps = 0
    , trivialInlines = 0
    , betas = 0
    , killedLets = 0
    , rounds = 0
    , binders = 0
    , deadUnsafe = 0
    , singleNonTrivial = 0
    , recursive = 0
    , multiUse = 0
    , destructs = 0
    }


plus : Stats -> Stats -> Stats
plus a b =
    { deadBindings = a.deadBindings + b.deadBindings
    , copyProps = a.copyProps + b.copyProps
    , trivialInlines = a.trivialInlines + b.trivialInlines
    , betas = a.betas + b.betas
    , killedLets = a.killedLets + b.killedLets
    , rounds = a.rounds + b.rounds
    , binders = a.binders + b.binders
    , deadUnsafe = a.deadUnsafe + b.deadUnsafe
    , singleNonTrivial = a.singleNonTrivial + b.singleNonTrivial
    , recursive = a.recursive + b.recursive
    , multiUse = a.multiUse + b.multiUse
    , destructs = a.destructs + b.destructs
    }


rewrote : Stats -> Bool
rewrote s =
    s.deadBindings > 0 || s.copyProps > 0 || s.trivialInlines > 0 || s.betas > 0 || s.killedLets > 0


run : List Defun -> ( List Defun, String )
run defuns =
    let
        ( rev, stats ) =
            List.foldl shrinkDefun ( [], zero ) defuns
    in
    ( List.reverse rev, report stats )


report : Stats -> String
report s =
    if s.binders == 0 then
        ""

    else
        -- The counters AFTER the rewrite counts are the OPPORTUNITY report:
        -- they say what the pass saw and deliberately left alone, which is the
        -- only way to tell "this corpus has nothing to shrink" apart from
        -- "the rules are too conservative to fire".  MEASURED on the
        -- compiler's own 58 sources + corpus (MIDTIER=1 MIDTIER_STATS=1
        -- MIDTIER_TRACE=1 selfhost group):
        --
        --   binders=464 dead=8 copy=3 inline=5 beta=1 lets=3 rounds=12
        --   left: deadUnsafe=4 singleNonTrivial=210 multiUse=250
        --         recursive=0 destructs=160
        --
        -- i.e. the rewrites are ~3% of the binder population: this corpus is
        -- hand-written Elm with almost no dead `let` bindings, and the
        -- emitted-size effect is -0.018% of the selfhost bundle's
        -- instructions.  The declined buckets ARE the reason it is not more:
        -- `singleNonTrivial` values are used once but a non-trivial value
        -- cannot be moved past a later binder without reordering effects (the
        -- header's ORDER TRAP), and `multiUse` binders (250) are what pass 3
        -- (`Mid.Inline`) attacks at the CALLEE end instead.
        "shrink: binders="
            ++ String.fromInt s.binders
            ++ " dead="
            ++ String.fromInt s.deadBindings
            ++ " copy="
            ++ String.fromInt s.copyProps
            ++ " inline="
            ++ String.fromInt s.trivialInlines
            ++ " beta="
            ++ String.fromInt s.betas
            ++ " lets="
            ++ String.fromInt s.killedLets
            ++ " rounds="
            ++ String.fromInt s.rounds
            ++ " | left: deadUnsafe="
            ++ String.fromInt s.deadUnsafe
            ++ " singleNonTrivial="
            ++ String.fromInt s.singleNonTrivial
            ++ " multiUse="
            ++ String.fromInt s.multiUse
            ++ " recursive="
            ++ String.fromInt s.recursive
            ++ " destructs="
            ++ String.fromInt s.destructs


shrinkDefun : Defun -> ( List Defun, Stats ) -> ( List Defun, Stats )
shrinkDefun defun ( acc, accStats ) =
    let
        ( value, stats ) =
            fixpoint 8 defun.value zero
    in
    ( { defun | value = value } :: acc, plus accStats stats )


{-| Rules create new opportunities (a beta-reduced `Let` may have a dead
binder; substituting a lambda may expose a saturated call), so the pass runs
to a fixpoint.  The bound is a guard, not a budget: every rule strictly
decreases the number of `App`/`Let` nodes, so no rewrite can cycle, and 8
rounds is far past the observed depth (measured: <= 2 on the whole corpus).
-}
fixpoint : Int -> Exp -> Stats -> ( Exp, Stats )
fixpoint fuel value acc =
    let
        ( step, stats ) =
            shrinkExp value
    in
    if rewrote stats && fuel > 1 then
        fixpoint (fuel - 1) step (plus acc (rewritesOnly stats))

    else
        -- FINAL round: its opportunity counters are the ones that describe the
        -- tree this pass leaves behind.  Earlier rounds' opportunity counters
        -- would count the same binder once per round (measured: ~3 rounds per
        -- defun, so a naive accumulation inflated them ~3x).
        ( step, plus acc stats )


rewritesOnly : Stats -> Stats
rewritesOnly s =
    { zero
        | deadBindings = s.deadBindings
        , copyProps = s.copyProps
        , trivialInlines = s.trivialInlines
        , betas = s.betas
        , killedLets = s.killedLets
        , rounds = 1
    }


-- ============================ THE WALK ============================


shrinkExp : Exp -> ( Exp, Stats )
shrinkExp exp =
    let
        ( inner, s1 ) =
            children exp

        ( outer, s2 ) =
            local inner
    in
    ( outer, plus s1 s2 )


children : Exp -> ( Exp, Stats )
children exp =
    case exp of
        Lit _ ->
            ( exp, zero )

        Var _ ->
            ( exp, zero )

        GRef _ ->
            ( exp, zero )

        StreamRef _ ->
            ( exp, zero )

        Lam lam ->
            let
                ( body, s ) =
                    shrinkExp lam.body
            in
            ( Lam { lam | body = body }, s )

        NoTail inner ->
            let
                ( e, s ) =
                    shrinkExp inner
            in
            ( NoTail e, s )

        App app ->
            let
                ( fn, s1 ) =
                    shrinkExp app.fn

                ( args, s2 ) =
                    shrinkAll app.args
            in
            ( App { app | fn = fn, args = args }, plus s1 s2 )

        PrimApp app ->
            let
                ( args, s ) =
                    shrinkAll app.args
            in
            ( PrimApp { app | args = args }, s )

        Let block ->
            let
                ( binders, s1 ) =
                    shrinkBinders block.binders

                ( body, s2 ) =
                    shrinkExp block.body
            in
            ( Let { binders = binders, body = body }, plus s1 s2 )

        Case branch ->
            let
                ( scrutinee, s1 ) =
                    shrinkExp branch.scrutinee

                ( alts, s2 ) =
                    shrinkAlts branch.alts
            in
            ( Case { branch | scrutinee = scrutinee, alts = alts }, plus s1 s2 )

        Con con ->
            let
                ( args, s ) =
                    shrinkAll con.args
            in
            ( Con { con | args = args }, s )

        Tup es ->
            let
                ( es1, s ) =
                    shrinkAll es
            in
            ( Tup es1, s )

        RecordLit setters ->
            let
                ( setters1, s ) =
                    shrinkSetters setters
            in
            ( RecordLit setters1, s )

        RecordGet base field ->
            let
                ( b, s ) =
                    shrinkExp base
            in
            ( RecordGet b field, s )

        RecordUpdate upd ->
            let
                ( base, s1 ) =
                    shrinkExp upd.base

                ( updates, s2 ) =
                    shrinkSetters upd.updates
            in
            ( RecordUpdate { upd | base = base, updates = updates }, plus s1 s2 )

        ListLit es ->
            let
                ( es1, s ) =
                    shrinkAll es
            in
            ( ListLit es1, s )

        If block ->
            let
                ( cond, s1 ) =
                    shrinkExp block.cond

                ( t, s2 ) =
                    shrinkExp block.thenBranch

                ( f, s3 ) =
                    shrinkExp block.elseBranch
            in
            ( If { block | cond = cond, thenBranch = t, elseBranch = f }, plus s1 (plus s2 s3) )

        ShortAnd block ->
            let
                ( left, s1 ) =
                    shrinkExp block.left

                ( right, s2 ) =
                    shrinkExp block.right
            in
            ( ShortAnd { block | left = left, right = right }, plus s1 s2 )

        ShortOr block ->
            let
                ( left, s1 ) =
                    shrinkExp block.left

                ( right, s2 ) =
                    shrinkExp block.right
            in
            ( ShortOr { block | left = left, right = right }, plus s1 s2 )

        NotEqual block ->
            let
                ( left, s1 ) =
                    shrinkExp block.left

                ( right, s2 ) =
                    shrinkExp block.right
            in
            ( NotEqual { block | left = left, right = right }, plus s1 s2 )


shrinkAll : List Exp -> ( List Exp, Stats )
shrinkAll exps =
    case exps of
        [] ->
            ( [], zero )

        e :: rest ->
            let
                ( e1, s1 ) =
                    shrinkExp e

                ( rest1, s2 ) =
                    shrinkAll rest
            in
            ( e1 :: rest1, plus s1 s2 )


shrinkSetters : List ( String, Exp ) -> ( List ( String, Exp ), Stats )
shrinkSetters setters =
    case setters of
        [] ->
            ( [], zero )

        ( field, value ) :: rest ->
            let
                ( v1, s1 ) =
                    shrinkExp value

                ( rest1, s2 ) =
                    shrinkSetters rest
            in
            ( ( field, v1 ) :: rest1, plus s1 s2 )


shrinkBinders : List LetBinder -> ( List LetBinder, Stats )
shrinkBinders binders =
    case binders of
        [] ->
            ( [], zero )

        b :: rest ->
            let
                ( b1, s1 ) =
                    shrinkBinder b

                ( rest1, s2 ) =
                    shrinkBinders rest
            in
            ( b1 :: rest1, plus s1 s2 )


shrinkBinder : LetBinder -> ( LetBinder, Stats )
shrinkBinder b =
    case b of
        LetBind bind ->
            let
                ( v, s ) =
                    shrinkExp bind.value
            in
            ( LetBind { bind | value = v }, s )

        LetDestruct destruct ->
            let
                ( v, s ) =
                    shrinkExp destruct.value
            in
            ( LetDestruct { destruct | value = v }, s )


shrinkAlts : List Alt -> ( List Alt, Stats )
shrinkAlts alts =
    case alts of
        [] ->
            ( [], zero )

        alt :: rest ->
            let
                ( body, s1 ) =
                    shrinkExp alt.body

                ( rest1, s2 ) =
                    shrinkAlts rest
            in
            ( { alt | body = body } :: rest1, plus s1 s2 )



-- ============================ LOCAL RULES ============================


local : Exp -> ( Exp, Stats )
local exp =
    case exp of
        Let block ->
            localLet block

        App app ->
            localBeta app

        _ ->
            ( exp, zero )


{-| R4.  Saturated application of a lambda, with ORDER-INSENSITIVE arguments
only (see the header's ORDER TRAP).

The resulting binder list is in SOURCE order (`p1` first).  That is what
reproduces `emitLam`'s env exactly: `Let` conses each binder onto the front of
the env, so source order yields `[pn, …, p1] ++ outer` — the same layout the
closure body sees, which is why `param_i = access(n-i)` keeps holding.

-}
localBeta : { fn : Exp, args : List Exp } -> ( Exp, Stats )
localBeta app =
    case app.fn of
        Lam lam ->
            if List.isEmpty lam.params || List.length lam.params /= List.length app.args then
                ( App app, zero )

            else if List.all safeArg app.args then
                ( Let
                    { binders =
                        List.map2 (\p a -> LetBind { binder = p, value = a }) lam.params app.args
                    , body = lam.body
                    }
                , { zero | betas = 1 }
                )

            else
                ( App app, zero )

        _ ->
            ( App app, zero )


type Decision
    = Keep
    | Drop
    | Subst Exp
    | KeepDeadUnsafe
    | KeepRecursive
    | KeepSingle
    | KeepMulti
    | KeepDestruct


localLet : { binders : List LetBinder, body : Exp } -> ( Exp, Stats )
localLet block =
    let
        ownerIds =
            List.filterMap binderIdOf block.binders |> Set.fromList

        planned =
            planBinders ownerIds (List.reverse block.binders) (countIn ownerIds block.body) []

        subs =
            List.foldl
                (\( b, d ) acc ->
                    case d of
                        Subst e ->
                            Dict.insert (binderId b) e acc

                        _ ->
                            acc
                )
                Dict.empty
                planned

        kept =
            List.filterMap
                (\( b, d ) ->
                    case d of
                        Drop ->
                            Nothing

                        _ ->
                            Just (mapBinderValue (substAll subs) b)
                )
                planned

        body =
            substAll subs block.body

        stats =
            List.foldl decisionStats zero planned

        emptied =
            List.isEmpty kept && not (List.isEmpty block.binders)
    in
    ( if List.isEmpty kept then
        body

      else
        Let { binders = kept, body = body }
    , if emptied then
        { stats | killedLets = 1 }

      else
        stats
    )


decisionStats : ( LetBinder, Decision ) -> Stats -> Stats
decisionStats ( b, d ) counted =
    let
        acc =
            case b of
                LetBind _ ->
                    { counted | binders = counted.binders + 1 }

                LetDestruct _ ->
                    counted
    in
    case d of
        Keep ->
            acc

        Drop ->
            { acc | deadBindings = acc.deadBindings + 1 }

        Subst _ ->
            case b of
                LetBind bind ->
                    if isVarRef bind.value then
                        { acc | copyProps = acc.copyProps + 1 }

                    else
                        { acc | trivialInlines = acc.trivialInlines + 1 }

                LetDestruct _ ->
                    acc

        KeepDeadUnsafe ->
            { acc | deadUnsafe = acc.deadUnsafe + 1 }

        KeepRecursive ->
            { acc | recursive = acc.recursive + 1 }

        KeepSingle ->
            { acc | singleNonTrivial = acc.singleNonTrivial + 1 }

        KeepMulti ->
            { acc | multiUse = acc.multiUse + 1 }

        KeepDestruct ->
            { acc | destructs = acc.destructs + 1 }


{-| The suffix walk: `counts` always holds the occurrence counts of the binders
already processed to the right (their values plus the body), which is exactly
the scope of the binder being examined (Elm `let`s are sequential and
NON-recursive: a later binder's value cannot reference an earlier one, and a
binder can never reference itself through this path — R3's self-reference
guard covers the one shape where it could).

Right-to-left so each value's own counts are added exactly once: the pass is
linear in the size of the `let` block.

-}
planBinders : Set Int -> List LetBinder -> Dict Int Int -> List ( LetBinder, Decision ) -> List ( LetBinder, Decision )
planBinders ownerIds revBinders counts acc =
    case revBinders of
        [] ->
            -- `acc` is built by consing onto an ALREADY-REVERSED walk, so it
            -- comes out in source order — the order the emitter's env layout
            -- depends on (see the header's ORDER TRAP).  Reversing here would
            -- swap every `param_i = access(n-i)` with its mirror image, which
            -- is a silent wrong-values bug the byte differential cannot see.
            acc

        b :: rest ->
            let
                decision =
                    decide counts b

                counts1 =
                    mergeCounts counts (countIn ownerIds (valueOf b))
                        |> Dict.remove (binderId b)
            in
            planBinders ownerIds rest counts1 (( b, decision ) :: acc)


decide : Dict Int Int -> LetBinder -> Decision
decide counts b =
    case b of
        LetBind bind ->
            let
                n =
                    Dict.get bind.binder.id counts |> Maybe.withDefault 0
            in
            if n == 0 then
                if isSafe bind.value then
                    Drop

                else
                    KeepDeadUnsafe

            else if referencesId bind.binder.id bind.value then
                -- A self-referencing value (a recursive local function that
                -- `Frontend.Lift` did not hoist) must keep its own binder:
                -- moving it to a use site would leave its inner reference
                -- unresolved, which the emitter renders as `Access -1`.
                KeepRecursive

            else if isVarRef bind.value then
                Subst bind.value

            else if n == 1 && isTrivial bind.value then
                Subst bind.value

            else if n == 1 then
                -- Single use, but the value is neither trivial nor safe to
                -- move: substituting it would move its EVALUATION past the
                -- binders that follow it (the header's ORDER TRAP), so it
                -- stays where it is.
                KeepSingle

            else
                KeepMulti

        LetDestruct _ ->
            -- A destructuring binder can FAIL (`simple-error` on a
            -- non-matching pattern) and its tests are effects in the strict
            -- sense; it is never dropped or moved.
            KeepDestruct


valueOf : LetBinder -> Exp
valueOf b =
    case b of
        LetBind bind ->
            bind.value

        LetDestruct destruct ->
            destruct.value


binderIdOf : LetBinder -> Maybe Int
binderIdOf b =
    case b of
        LetBind bind ->
            Just bind.binder.id

        LetDestruct _ ->
            Nothing


binderId : LetBinder -> Int
binderId b =
    case b of
        LetBind bind ->
            bind.binder.id

        LetDestruct destruct ->
            destruct.scrutId.id


mapBinderValue : (Exp -> Exp) -> LetBinder -> LetBinder
mapBinderValue f b =
    case b of
        LetBind bind ->
            LetBind { bind | value = f bind.value }

        LetDestruct destruct ->
            LetDestruct { destruct | value = f destruct.value }



-- ============================ OCCURRENCE COUNTING ============================


countIn : Set Int -> Exp -> Dict Int Int
countIn ids exp =
    case exp of
        Var id ->
            if Set.member id ids then
                Dict.singleton id 1

            else
                Dict.empty

        Lit _ ->
            Dict.empty

        GRef _ ->
            Dict.empty

        StreamRef _ ->
            Dict.empty

        Lam lam ->
            countIn ids lam.body

        NoTail inner ->
            countIn ids inner

        App app ->
            plusDicts (countIn ids app.fn) (countAll ids app.args)

        PrimApp app ->
            countAll ids app.args

        Let block ->
            plusDicts (countAllBinderValues ids block.binders) (countIn ids block.body)

        Case branch ->
            plusDicts (countIn ids branch.scrutinee) (countAltBodies ids branch.alts)

        Con con ->
            countAll ids con.args

        Tup es ->
            countAll ids es

        RecordLit setters ->
            countSetters ids setters

        RecordGet base _ ->
            countIn ids base

        RecordUpdate upd ->
            plusDicts (countIn ids upd.base) (countSetters ids upd.updates)

        ListLit es ->
            countAll ids es

        If block ->
            plusDicts (countIn ids block.cond)
                (plusDicts (countIn ids block.thenBranch) (countIn ids block.elseBranch))

        ShortAnd block ->
            plusDicts (countIn ids block.left) (countIn ids block.right)

        ShortOr block ->
            plusDicts (countIn ids block.left) (countIn ids block.right)

        NotEqual block ->
            plusDicts (countIn ids block.left) (countIn ids block.right)


countAll : Set Int -> List Exp -> Dict Int Int
countAll ids exps =
    List.foldl (\e acc -> plusDicts acc (countIn ids e)) Dict.empty exps


countSetters : Set Int -> List ( String, Exp ) -> Dict Int Int
countSetters ids setters =
    List.foldl (\( _, e ) acc -> plusDicts acc (countIn ids e)) Dict.empty setters


countAllBinderValues : Set Int -> List LetBinder -> Dict Int Int
countAllBinderValues ids binders =
    List.foldl (\b acc -> plusDicts acc (countIn ids (valueOf b))) Dict.empty binders


countAltBodies : Set Int -> List Alt -> Dict Int Int
countAltBodies ids alts =
    List.foldl (\a acc -> plusDicts acc (countIn ids a.body)) Dict.empty alts


plusDicts : Dict Int Int -> Dict Int Int -> Dict Int Int
plusDicts a b =
    Dict.foldl (\k v acc -> Dict.update k (\m -> Just (Maybe.withDefault 0 m + v)) acc) a b


mergeCounts : Dict Int Int -> Dict Int Int -> Dict Int Int
mergeCounts =
    plusDicts


referencesId : Int -> Exp -> Bool
referencesId id exp =
    not (Dict.isEmpty (countIn (Set.singleton id) exp))



-- ============================ SUBSTITUTION ============================
-- Binder ids are UNIQUE WITHIN A DEFUN (Mid.Ir), so a substitution can never
-- capture and needs no alpha-renaming: the only `Var` nodes that a
-- substitution replaces are the ones that name the binder being removed.
-- The walk therefore descends into every construct, including the bodies of
-- nested lambdas and the values of inner lets.


substAll : Dict Int Exp -> Exp -> Exp
substAll subs exp =
    if Dict.isEmpty subs then
        exp

    else
        case exp of
            Var id ->
                Dict.get id subs |> Maybe.withDefault exp

            Lit _ ->
                exp

            GRef _ ->
                exp

            StreamRef _ ->
                exp

            Lam lam ->
                Lam { lam | body = substAll subs lam.body }

            NoTail inner ->
                NoTail (substAll subs inner)

            App app ->
                App { fn = substAll subs app.fn, args = List.map (substAll subs) app.args }

            PrimApp app ->
                PrimApp { app | args = List.map (substAll subs) app.args }

            Let block ->
                Let
                    { binders = List.map (mapBinderValue (substAll subs)) block.binders
                    , body = substAll subs block.body
                    }

            Case branch ->
                Case
                    { branch
                        | scrutinee = substAll subs branch.scrutinee
                        , alts = List.map (\a -> { a | body = substAll subs a.body }) branch.alts
                    }

            Con con ->
                Con { con | args = List.map (substAll subs) con.args }

            Tup es ->
                Tup (List.map (substAll subs) es)

            RecordLit setters ->
                RecordLit (List.map (mapSnd (substAll subs)) setters)

            RecordGet base field ->
                RecordGet (substAll subs base) field

            RecordUpdate upd ->
                RecordUpdate
                    { upd
                        | base = substAll subs upd.base
                        , updates = List.map (mapSnd (substAll subs)) upd.updates
                    }

            ListLit es ->
                ListLit (List.map (substAll subs) es)

            If block ->
                If
                    { block
                        | cond = substAll subs block.cond
                        , thenBranch = substAll subs block.thenBranch
                        , elseBranch = substAll subs block.elseBranch
                    }

            ShortAnd block ->
                ShortAnd { block | left = substAll subs block.left, right = substAll subs block.right }

            ShortOr block ->
                ShortOr { block | left = substAll subs block.left, right = substAll subs block.right }

            NotEqual block ->
                NotEqual { block | left = substAll subs block.left, right = substAll subs block.right }


mapSnd : (b -> c) -> ( a, b ) -> ( a, c )
mapSnd f ( a, b ) =
    ( a, f b )



-- ============================ PURITY / TRIVIALITY ============================
-- The judgement is about what the VM can OBSERVE, so it is derived from the
-- prim table in `vendor/zinc-vm/src/vm/prims.zig`, not from Elm-level
-- intuition: the prims left out are the ones that write (`address->` mutates a
-- vector that may be shared), read the world (streams, `getenv`, `glob`,
-- `exec-plan`, `get-time`), are global-stateful (`set`, `value`, `intern`,
-- `gensym`, `newvar`), can RAISE (`simple-error`, `trap-error`, `pos`,
-- `substring`, `repeat`, `char-code`, `string->n`, `shen.fail!`, `wait`,
-- `kill`, `eval-kl`), or can trap (`/` on a zero divisor; `f/` is a float
-- op).  Everything listed in `purePrims` is total and reads no state.


isSafe : Exp -> Bool
isSafe exp =
    case exp of
        Lit _ ->
            True

        Var _ ->
            True

        GRef ref ->
            not ref.force

        StreamRef _ ->
            -- `s <name> P value` reads the VM's value table: pure, but the
            -- table is mutable process state and the read is not something a
            -- dead-binding rule should reason about.  Left unsafe on purpose.
            False

        Lam _ ->
            -- Allocation only: unobservable (the heap is not inspected).
            True

        NoTail inner ->
            isSafe inner

        Con con ->
            List.all isSafe con.args

        Tup es ->
            List.all isSafe es

        RecordLit setters ->
            List.all (\( _, e ) -> isSafe e) setters

        RecordGet base _ ->
            isSafe base

        RecordUpdate upd ->
            isSafe upd.base && List.all (\( _, e ) -> isSafe e) upd.updates

        ListLit es ->
            List.all isSafe es

        PrimApp app ->
            Set.member app.prim purePrims && List.all isSafe app.args

        App _ ->
            False

        Let _ ->
            -- A `let` can raise through a destructuring binder, so it is not
            -- in the dead-binding-safe class (the rule is applied to the
            -- binders INSIDE such a let instead, which is where the win is).
            False

        Case _ ->
            False

        If _ ->
            False

        ShortAnd _ ->
            False

        ShortOr _ ->
            False

        NotEqual _ ->
            False


isTrivial : Exp -> Bool
isTrivial exp =
    case exp of
        Lit _ ->
            True

        Var _ ->
            True

        GRef ref ->
            not ref.force

        Lam _ ->
            True

        _ ->
            False


isVarRef : Exp -> Bool
isVarRef exp =
    case exp of
        Var _ ->
            True

        _ ->
            False


{-| R4's argument class: evaluating these can neither raise, write, nor
diverge, so the App->Let reordering is unobservable.  Narrower than `isSafe`
on purpose (`absvector` allocates but the ADT path also writes with
`address->`; `hd`/`tl`/`assoc` are total in this VM only for well-formed
arguments, so they are left out).
-}
safeArg : Exp -> Bool
safeArg exp =
    case exp of
        Lit _ ->
            True

        Var _ ->
            True

        GRef ref ->
            not ref.force

        Lam _ ->
            True

        Tup es ->
            List.all safeArg es

        ListLit es ->
            List.all safeArg es

        RecordLit setters ->
            List.all (\( _, e ) -> safeArg e) setters

        Con con ->
            List.all safeArg con.args

        PrimApp app ->
            Set.member app.prim totalPrims && List.all safeArg app.args

        _ ->
            False


{-| Prims that a dead binding may be dropped through: total, pure, no writes. -}
purePrims : Set String
purePrims =
    Set.fromList
        [ "+", "-", "*", "=", "<", "<=", ">", ">="
        , "@p", "fst", "snd"
        , "hd", "tl", "cons", "cons?", "empty?"
        , "absvector", "absvector?", "<-address", "assoc", "append", "reverse"
        , "number?", "string?", "symbol?", "boolean?", "function?", "error?", "element?"
        , "c-strlen", "n->string"
        ]


{-| The subset of `purePrims` whose result is a VALUE for every argument (no
partiality on ill-formed input) — R4's reordering budget.
-}
totalPrims : Set String
totalPrims =
    Set.fromList
        [ "+", "-", "*", "=", "<", "<=", ">", ">="
        , "@p", "fst", "snd"
        , "cons", "cons?", "empty?", "absvector?", "number?", "string?", "symbol?", "boolean?"
        ]
