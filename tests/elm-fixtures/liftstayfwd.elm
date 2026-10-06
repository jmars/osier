module LiftStayFwd exposing (main)

-- A STAYING declaration's FORWARD reference to a module-named sibling must keep
-- the MODULE binding (the declared divergence).  The cycle here is the
-- self-recursive local `helper` alone; `g` is not on it, so `g`'s forward
-- reference is not part of the recursive wiring and `forwardAllowed` keeps the
-- outward resolution -- the same answer the substrate gives.
-- Sequential/HEAD truth: g 1 -> the TOP-LEVEL helper 1 = 999.
--   (the local `helper` is declared after `g`, so it is not bound at g's
--    position; g would only see it under Elm letrec, which the declared
--    divergence does not take for forward references)
-- HEAD arm (pre-lift compiler, /tmp/headcomp): COMPILES -> 999.
-- AFTER (this pass): 999.  Before this fixture the STAYING-decl rewrite was
-- POSITION-BLIND and rewrote g's `helper` to the lifted local member -> 5000.
-- MUTANTS KILLED: any implementation whose staying-declaration rewrite does not
-- go through the positional resolver (the position-blind rewriteNodeRefs: 5000);
-- M_relaxall (relaxing the forward veto for every member instead of only for
-- cycle members) -> 5000; M_noveto (no forward veto at all) -> 5000.
-- NOT killed: mutants that leave the lazy/top-level structure alone.

helper : Int -> Int
helper k =
    999


f x =
    let
        g v =
            helper v

        helper k =
            if k > 0 then
                helper (k - 1)

            else
                5000
    in
    g 1


main =
    f 5
