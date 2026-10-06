module RowgadtCe3Fieldalias exposing (main)

-- NEGATIVE (CE-3, field-vs-index conflation): a GADT whose index WRAPS its
-- field (`MkBox : a -> Box (List a)`) and a function returning the FIELD at
-- the INDEX type. The branch equation is `a ~ List a`; the body's bare
-- variable `v : a` (the field) aliased the rigid index and DROPPED the
-- equation, so `get (MkBox 3)` was accepted at `List Int` while its value is
-- `3` (a runtime wrong-typed value of the same class as escape_*). The result
-- unify must reject the flex -> rigid alias of a variable to a refined target.

type Box a
    = MkBox : a -> Box (List a)


get : type a. Box a -> a
get b =
    case b of
        MkBox v ->
            v


main : List Int
main =
    get (MkBox 3)
