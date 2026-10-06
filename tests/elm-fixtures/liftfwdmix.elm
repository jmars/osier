module LiftFwdMix exposing (main)

-- BLOCKER 2 probe, mixed group: a SELF-recursive helper `go` beside a
-- NON-recursive value `h` that forward-references the LATER value sibling `x`
-- (which shadows the parameter).  The cycle-component lift hoists ONLY `go`;
-- `h` and `x` stay sequential, so h's x is still the PARAMETER (5) and the
-- sibling x = 1000 is unused.  h + go 2 = (5 + 1) + 5 = 11.

f x =
    let
        h =
            x + 1

        go k =
            if k <= 0 then
                x
            else
                go (k - 1)

        x =
            1000
    in
    h + go 2


main =
    f 5
