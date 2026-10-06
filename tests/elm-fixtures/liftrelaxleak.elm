module LiftRelaxLeak exposing (main)

-- RELAXATION OVER-REACH (review5 BLOCKER B, the HEAD-compiling silent wrong
-- value): a fully-shadowing cycle {even,odd} (both names top-level) whose member
-- `even` FORWARD-references a LATER NON-CYCLE sibling `m` that is ALSO
-- module-named.  The round-5 forwardAllowed relaxed the veto by REFERRER
-- membership alone, so even's forward `m` leaked to the LOCAL `m` (555) where
-- the declared divergence says it must resolve to the MODULE `m` (999).
--
-- Derivation (per-SCC rule): even/odd are mutually recursive, both shadow
-- top-level bindings -> they lift (the Elm-shadowing divergence, same as
-- liftdelegmut).  even's forward `odd` is on even's own cycle -> relaxed ->
-- LOCAL odd.  even's forward `m` is NOT on even's cycle (m is a leaf) -> the
-- veto holds -> MODULE m.  So even 4 -> odd 3 -> even 2 -> odd 1 -> even 0 ->
-- m 1 = 999.
--
-- HEAD arm (pre-lift, /tmp/headcomp): COMPILES -> 888.  Note HEAD's 888 comes
-- from even's forward `odd` resolving to the TOP-LEVEL odd = 888 under the
-- substrate's sequential rule; the fix deliberately changes that (the ratified
-- Elm-shadowing divergence, exactly as liftdelegmut 888 -> 0 and the no-local-m
-- control n33b 888 -> 999).  The value this fixture pins is even's forward `m`,
-- which must be the MODULE m = 999.
--
-- MEASURED: HEAD 888; round-5 (leak) 555; AFTER 999 (= n33b, the no-local-m
-- control -- the local m is correctly dead).
--
-- MUTANTS KILLED: any relaxation keyed by referrer membership alone (the
-- round-5 forwardAllowed -> 555); the relaxation applied to a non-cycle target.
-- NOT killed: a mutant that removes the relaxation entirely would give 888
-- (HEAD), which is also wrong but is pinned by liftdelegmut (0) and n33b (999).

even : Int -> Int
even k =
    777


odd : Int -> Int
odd k =
    888


m : Int -> Int
m k =
    999


f x =
    let
        even k =
            if k <= 0 then
                m 1

            else
                odd (k - 1)

        odd k =
            if k <= 0 then
                1

            else
                even (k - 1)

        m k =
            555
    in
    even 4


main =
    f 5
