module LiftCycShadows exposing (main)

-- THE SHADOWING CENSUS MUST COVER THE CYCLE, NOT THE BLOCK.  This is
-- liftdelegmut (a mutually recursive local pair whose names both shadow
-- top-level bindings) with ONE unrelated value sibling added.  `zz` shadows
-- nothing and is not on the cycle, so it must not flip the group back to the
-- sequential reading -- a semantically irrelevant declaration may not change
-- the answer.
-- Ratified Elm-shadowing answer (what liftdelegmut pins): even 4 -> odd 3 ->
-- even 2 -> odd 1 -> even 0 -> 0.
-- HEAD arm (pre-lift compiler, /tmp/headcomp): COMPILES -> 888 (sequential:
-- even's `odd` resolves to the top-level odd) -- the round-4 policy decision
-- deliberately takes the Elm answer instead.
-- AFTER (this pass): 0.  Before this fixture the census covered EVERY block
-- declaration, so `zz = 42` alone reverted the group to 888.
-- MUTANTS KILLED: a census over all block declarations (the w11 regression:
-- 888); M80/no-cycle-census variants.  liftdelegmut (0) is the same pin
-- without the unrelated sibling; this one adds the stability requirement.

even : Int -> Int
even k =
    777


odd : Int -> Int
odd k =
    888


f x =
    let
        even k =
            if k <= 0 then
                0

            else
                odd (k - 1)

        odd k =
            if k <= 0 then
                1

            else
                even (k - 1)

        zz =
            42
    in
    even 4


main =
    f 5
