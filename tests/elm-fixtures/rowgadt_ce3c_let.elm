module RowgadtCe3cLet exposing (main)

-- NEGATIVE (CE-3 bypass (c): let-mediated). `let u = v in (u, u)` launders
-- the field var through a `let`-binding, which let-generalization quantified
-- away from the equation `a ~ List a_field`. The lifecycle fix keeps the
-- equation body's free variables rigid against let-generalization (the KType
-- mirror of the row-tail laundering guard) and runs the occurs check. Must
-- ERR 'infinite type'.

type Box a
    = MkBox : a -> Box (List a)


get2 : type a. Box a -> ( a, a )
get2 b =
    case b of
        MkBox v ->
            let
                u = v
            in
            ( u, u )


main : ( List Int, List Int )
main =
    get2 (MkBox 3)
