module LiftEnclosing exposing (main)

-- ENCLOSING-scope collision (pins the KEPT mask): a local recursive-looking
-- helper named like the ENCLOSING PARAMETER.  The substrate's SEQUENTIAL rule
-- is retained for enclosing bindings: the self-reference resolves to the
-- PARAM (not the local), so the group is NOT lifted.  go 2 = param(1) = 100.
-- (True Elm shadowing would recurse here -- this is exactly the one place the
-- sequential priority is deliberately kept over Elm shadowing.)

f go =
    let
        go k =
            if k <= 0 then
                99
            else
                go (k - 1)
    in
    go 2


main =
    f (\n -> n * 100)
