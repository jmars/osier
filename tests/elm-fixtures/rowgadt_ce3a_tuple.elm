module RowgadtCe3aTuple exposing (main)

-- NEGATIVE (CE-3 bypass (a): alias under a constructor). `get2` returns the
-- field `v` TWICE as a tuple, so the flex -> rigid alias (`a_field := a`)
-- forms inside TTuple during the result unify's structural descent — the
-- top-level zonk is (TTuple, TTuple), which `refinedTargetAliasedBy` never
-- matches. The equation `a ~ List a` is then dropped at branch end unexamined.
-- The equation lifecycle must run its occurs check (a ~ List a is an infinite
-- type) at the branch/clause result, so this ERRORS 'infinite type'.

type Box a
    = MkBox : a -> Box (List a)


get2 : type a. Box a -> ( a, a )
get2 b =
    case b of
        MkBox v ->
            ( v, v )


main : ( List Int, List Int )
main =
    get2 (MkBox 3)
