module RowgadtCe3bPrealias exposing (main)

-- NEGATIVE (CE-3 bypass (b): pre-alias in the body). `choose True v x` forces
-- `v ~ x` (the field var against the rigid index) BEFORE the result unify, so
-- both sides zonk to the SAME var and `refinedTargetAliasedBy`'s id test
-- misses. The equation `a ~ List a` is dropped unexamined; the occurs check
-- must fire. Must ERR 'infinite type'.

type Box a
    = MkBox : a -> Box (List a)


choose : Bool -> a -> a -> a
choose c x y =
    if c then x else y


get : type a. Box a -> a -> a
get b x =
    case b of
        MkBox v ->
            choose True v x


main : List Int
main =
    get (MkBox 3) []
