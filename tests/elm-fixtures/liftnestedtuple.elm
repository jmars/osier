module LiftNestedTuple exposing (main)

-- BLOCKER 1 probe, tuple-destructuring sibling: inside the lifted helper a
-- nested `( x, y ) = ( 1000, 7 )` shadows the capture x; the LATER sibling
-- `h = x + 1` must see the destructured x (1000), so h = 1001.  go 0 2 ->
-- go 1 1 -> go 2 0 (acc accumulates the capture x = 1 twice), answer
-- 1001 + 2 = 1003.

f x =
    let
        go acc k =
            if k <= 0 then
                let
                    ( x, y ) =
                        ( 1000, 7 )

                    h =
                        x + 1
                in
                h + acc
            else
                go (acc + x) (k - 1)
    in
    go 0 2


main =
    f 1
