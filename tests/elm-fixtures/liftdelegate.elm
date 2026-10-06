module LiftDelegate exposing (main)

-- NAME-COLLISION (Elm shadowing): a local self-recursive helper whose name
-- collides with a TOP-LEVEL `helper`.  HEAD (pre-lift, sequential delegation)
-- printed 999 -- the self-reference resolved to the top-level helper.  Elm
-- semantics (user decision 2026-10-06) make the LOCAL binding shadow the
-- module one, so the group IS lifted and recurses: helper 2 -> helper 1 ->
-- helper 0 -> x = 5.

helper : Int -> Int
helper k =
    999


f x =
    let
        helper k =
            if k <= 0 then
                x
            else
                helper (k - 1)
    in
    helper 2


main =
    f 5
