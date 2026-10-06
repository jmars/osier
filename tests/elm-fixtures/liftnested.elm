module LiftNested exposing (main)

-- BLOCKER 1 probe: a SELF-recursive helper whose base branch has a nested
-- VALUE sibling `x` that shadows the CAPTURE x.  Sequential semantics: the
-- nested `x = 1000` binds before `h = x + 1`, so h = 1001 (NOT the capture 1).
-- go 0 1 -> go 1 0 (acc accumulates the capture x = 1), so the answer is
-- 1001 + 1 = 1002.

f x =
    let
        go acc k =
            if k <= 0 then
                let
                    x =
                        1000

                    h =
                        x + 1
                in
                h + acc
            else
                go (acc + x) (k - 1)
    in
    go 0 1


main =
    f 1
