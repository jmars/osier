module LiftFwd exposing (main)

-- BLOCKER 2 probe (forward reference is NOT recursion): `h` forward-references
-- the LATER value sibling `x`, which shadows the parameter `x`.  Under the
-- compiler's SEQUENTIAL let, h's RHS sees the PARAMETER (the sibling is not
-- bound yet), so h = 5 + 1 = 6.  The lift must NOT hoist this group (there is
-- no cycle): hoisting it would rewrite h's x to the lifted sibling (1001).

f x =
    let
        h =
            x + 1

        x =
            1000
    in
    h


main =
    f 5
