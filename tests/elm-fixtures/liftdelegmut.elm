module LiftDelegMut exposing (main)

-- NAME-COLLISION, mutual variant (Elm shadowing): local `even`/`odd` whose
-- names collide with TOP-LEVEL `even`/`odd`.  HEAD (pre-lift, sequential
-- delegation) printed 888 -- even's `odd` resolved to the top-level odd.  Elm
-- semantics make the LOCAL pair shadow the module ones, so the group IS lifted
-- and recurses: even 4 -> odd 3 -> even 2 -> odd 1 -> even 0 -> 0.

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
    in
    even 4


main =
    f 5
