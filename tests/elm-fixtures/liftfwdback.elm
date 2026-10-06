module LiftFwdBack exposing (main)

-- FIXTURE GAP probe: the forward-reference shape STRENGTHENED so the later
-- sibling also references the earlier one.  Sequential: h = param(5) + 1 = 6;
-- x = h * 1000 = 6000 (unused); answer h = 6.  A bound-filter regression
-- fabricates a cycle h <-> x and miscompiles, so this pins the filter.

f x =
    let
        h =
            x + 1

        x =
            h * 1000
    in
    h


main =
    f 5
