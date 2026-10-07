module Mid.Arity exposing (Stats, run)

-- Mid.Arity — the middle tier's FOURTH pass: application-spine flattening
-- (the "saturation" half of the plan's arity/saturation-repair pass).
--
-- NOT A LITERAL PORT.  MLton's `xml/uncurry.fun` (which converts CURRIED
-- functions to UNCURRIED multi-arg ones, and is DISABLED upstream because
-- MLton's native backend does not need it) is the DESIGN precedent for "make
-- the VM see saturated applications", but no MLton source is present and none
-- is copied — this is a fresh rule against this IR's n-ary `App`.  No HPND/
-- MLton header, no THIRD-PARTY.md entry (f2361ed rule: "code ported
-- literally", and this is not).
--
-- ============================ THE RULE ============================
--
-- FLATTEN A LEFT-ASSOCIATIVE APPLICATION SPINE:
--
--     App { fn = App { fn = X, args = p }, args = q }   ==>   App { fn = X, args = p ++ q }
--
-- and the same at any depth (`((X p) q) r` -> `X p q r`).  WHY THIS IS ALWAYS
-- SAFE, both halves:
--
--   * SEMANTICS — application is left-associative and currying is
--     associative: `(X p) q` IS `X p q`, by definition.  The VM's arity
--     dispatch (N<A partial closure, N==A fast path, N>A peel) is a faithful
--     implementation of that application, so regrouping cannot change the
--     result — it only changes WHICH dispatch path the single `App` takes
--     (one apply with |p|+|q| args instead of two applies with |p| and |q|).
--
--   * EVALUATION ORDER — the nested form already evaluates its args in
--     "outer args, then inner args, then the callee" order (an `App` emits
--     its args RIGHT-TO-LEFT and THEN its callee — Mid.ToZinc), and the
--     flattened form emits `reverse(q) ++ reverse(p) ++ callee` — the SAME
--     order.  Nothing is re-ordered, so no argument's evaluation is moved.
--
-- THE PAYOFF (measured in instructions AND at run time):
--   * each merged App-as-callee kills ONE `Pushmark` + ONE `Apply` (2
--     instructions) and ONE apply-dispatch at run time;
--   * the common shape this targets is a KNOWN function applied partially and
--     then completed — `(f a) b` where `f` has arity 2.  Nested, that is a
--     partial-closure build (`buildPartialClosure` in
--     `vendor/zinc-vm/src/vm/interp.zig`: a FRESH INSTRUCTION-ARRAY COPY plus
--     an env-concat plus a closure — three allocations) followed by a second
--     apply; flattened, it is ONE saturated fast-path apply.  The flattened
--     form also never OVER-APPLIES a partial into a nested-vmExecEnv peel that
--     the nested form would have split differently.
--
-- WHAT IS DELIBERATELY NOT HERE (the other two arity repairs, both measured
-- as RUNTIME-only trades that the instruction-count metric cannot see, and
-- therefore left for a later runtime-driven stage):
--   * OVER-APPLICATION SPLIT — rewriting `App (GRef f) [a1..an]` with n > A
--     into `(f a1..aA) (aA+1..an)` avoids the nested-vmExecEnv peel for the
--     first A args but ADDS ~3 instructions (a second pushmark/apply pair).
--   * PARTIAL-APPLICATION ETA-EXPANSION — `f a1..ak` (k < A) used as a value
--     into `\x -> f a1..ak x`, avoiding buildPartialClosure's per-call
--     instruction-array copy, at the cost of a larger closure body.
--   Both are the same shape as Inline's measured finding: they trade emitted
--   instructions for avoided allocation, and belong with the end-to-end
--   runtime measurement, not here.
--
-- `NoTail` is respected: the spine stops at a `NoTail` (a pipe application
-- pins its emission position, so it is not a bare `App` to merge through).

import Mid.Ir exposing (Alt, Defun, Exp(..), LetBinder(..))


type alias Stats =
    { defuns : Int
    , sites : Int
    , spines : Int
    , merged : Int
    }


zero : Stats
zero =
    { defuns = 0
    , sites = 0
    , spines = 0
    , merged = 0
    }


plus : Stats -> Stats -> Stats
plus a b =
    { defuns = a.defuns + b.defuns
    , sites = a.sites + b.sites
    , spines = a.spines + b.spines
    , merged = a.merged + b.merged
    }


run : List Defun -> ( List Defun, String )
run defuns =
    let
        ( rev, stats ) =
            List.foldl arityDefun ( [], zero ) defuns
    in
    ( List.reverse rev, report stats )


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
            ++ " (kills "
            ++ String.fromInt (2 * s.merged)
            ++ " pushmark+apply instructions)"


arityDefun : Defun -> ( List Defun, Stats ) -> ( List Defun, Stats )
arityDefun defun ( acc, accStats ) =
    let
        ( value, stats ) =
            arityExp defun.value
    in
    ( { defun | value = value } :: acc
    , plus accStats { stats | defuns = 1 }
    )



-- ============================ THE WALK ============================


arityExp : Exp -> ( Exp, Stats )
arityExp exp =
    case exp of
        App app ->
            let
                ( base, args, merged ) =
                    flattenSpine app.fn app.args

                ( base1, s1 ) =
                    arityExp base

                ( args1, s2 ) =
                    arityAll args
            in
            ( App { fn = base1, args = args1 }
            , { defuns = 0
                , sites = 1
                , spines = if merged > 0 then 1 else 0
                , merged = merged
                }
                |> plus s1
                |> plus s2
            )

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
                    arityExp lam.body
            in
            ( Lam { lam | body = body }, s )

        NoTail inner ->
            let
                ( e, s ) =
                    arityExp inner
            in
            ( NoTail e, s )

        PrimApp app ->
            let
                ( args, s ) =
                    arityAll app.args
            in
            ( PrimApp { app | args = args }, s )

        Let block ->
            let
                ( binders, s1 ) =
                    arityBinders block.binders

                ( body, s2 ) =
                    arityExp block.body
            in
            ( Let { binders = binders, body = body }, plus s1 s2 )

        Case branch ->
            let
                ( scrutinee, s1 ) =
                    arityExp branch.scrutinee

                ( alts, s2 ) =
                    arityAlts branch.alts
            in
            ( Case { branch | scrutinee = scrutinee, alts = alts }, plus s1 s2 )

        Con con ->
            let
                ( args, s ) =
                    arityAll con.args
            in
            ( Con { con | args = args }, s )

        Tup es ->
            let
                ( es1, s ) =
                    arityAll es
            in
            ( Tup es1, s )

        RecordLit setters ->
            let
                ( setters1, s ) =
                    aritySetters setters
            in
            ( RecordLit setters1, s )

        RecordGet base field ->
            let
                ( b, s ) =
                    arityExp base
            in
            ( RecordGet b field, s )

        RecordUpdate upd ->
            let
                ( base, s1 ) =
                    arityExp upd.base

                ( updates, s2 ) =
                    aritySetters upd.updates
            in
            ( RecordUpdate { upd | base = base, updates = updates }, plus s1 s2 )

        ListLit es ->
            let
                ( es1, s ) =
                    arityAll es
            in
            ( ListLit es1, s )

        If block ->
            let
                ( cond, s1 ) =
                    arityExp block.cond

                ( t, s2 ) =
                    arityExp block.thenBranch

                ( f, s3 ) =
                    arityExp block.elseBranch
            in
            ( If { block | cond = cond, thenBranch = t, elseBranch = f }, plus s1 (plus s2 s3) )

        ShortAnd block ->
            let
                ( left, s1 ) =
                    arityExp block.left

                ( right, s2 ) =
                    arityExp block.right
            in
            ( ShortAnd { block | left = left, right = right }, plus s1 s2 )

        ShortOr block ->
            let
                ( left, s1 ) =
                    arityExp block.left

                ( right, s2 ) =
                    arityExp block.right
            in
            ( ShortOr { block | left = left, right = right }, plus s1 s2 )

        NotEqual block ->
            let
                ( left, s1 ) =
                    arityExp block.left

                ( right, s2 ) =
                    arityExp block.right
            in
            ( NotEqual { block | left = left, right = right }, plus s1 s2 )


arityAll : List Exp -> ( List Exp, Stats )
arityAll exps =
    case exps of
        [] ->
            ( [], zero )

        e :: rest ->
            let
                ( e1, s1 ) =
                    arityExp e

                ( rest1, s2 ) =
                    arityAll rest
            in
            ( e1 :: rest1, plus s1 s2 )


aritySetters : List ( String, Exp ) -> ( List ( String, Exp ), Stats )
aritySetters setters =
    case setters of
        [] ->
            ( [], zero )

        ( field, value ) :: rest ->
            let
                ( v1, s1 ) =
                    arityExp value

                ( rest1, s2 ) =
                    aritySetters rest
            in
            ( ( field, v1 ) :: rest1, plus s1 s2 )


arityBinders : List LetBinder -> ( List LetBinder, Stats )
arityBinders binders =
    case binders of
        [] ->
            ( [], zero )

        b :: rest ->
            let
                ( b1, s1 ) =
                    arityBinder b

                ( rest1, s2 ) =
                    arityBinders rest
            in
            ( b1 :: rest1, plus s1 s2 )


arityBinder : LetBinder -> ( LetBinder, Stats )
arityBinder b =
    case b of
        LetBind bind ->
            let
                ( v, s ) =
                    arityExp bind.value
            in
            ( LetBind { bind | value = v }, s )

        LetDestruct destruct ->
            let
                ( v, s ) =
                    arityExp destruct.value
            in
            ( LetDestruct { destruct | value = v }, s )


arityAlts : List Alt -> ( List Alt, Stats )
arityAlts alts =
    case alts of
        [] ->
            ( [], zero )

        alt :: rest ->
            let
                ( body, s1 ) =
                    arityExp alt.body

                ( rest1, s2 ) =
                    arityAlts rest
            in
            ( { alt | body = body } :: rest1, plus s1 s2 )



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
