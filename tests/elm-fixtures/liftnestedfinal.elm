module LiftNestedFinal exposing (main)

-- BLOCKER 1 probe, final-expression variant: a nested tuple-destructuring
-- sibling referenced in the nested let's FINAL expression.  `( x, y ) =
-- ( 1000, 7 )` then `x + acc` must read the destructured x (1000), not the
-- capture; go 0 2 -> go 2 0 -> 1000 + 2 = 1002.

f x =
    let
        go acc k =
            if k <= 0 then
                let
                    ( x, y ) =
                        ( 1000, 7 )
                in
                x + acc
            else
                go (acc + x) (k - 1)
    in
    go 0 2


main =
    f 1
