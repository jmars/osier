module LiftPrelude exposing (main)

-- NAME-COLLISION (Elm shadowing), Prelude name: a local self-recursive helper
-- named `identity` collides with Prelude.identity.  HEAD (pre-lift, sequential
-- delegation) printed 1 -- the self-reference resolved to Prelude.identity.
-- Elm semantics make the LOCAL binding shadow the Prelude one, so the group IS
-- lifted and recurses: identity 2 -> identity 1 -> identity 0 -> x = 7.

f x =
    let
        identity k =
            if k <= 0 then
                x
            else
                identity (k - 1)
    in
    identity 2


main =
    f 7
