module LiftSeqCap exposing (main)

-- DEFECT B probe (walk-side sequential free vars): a capture `x` referenced
-- in a nested decl that PRECEDES a same-named nested VALUE sibling.  The
-- capture must not be masked out of the capture set: h = capture(1) + 1 = 2,
-- the later `x = 1000` is unused, so h + acc = 2 + 0 = 2.  (A module-level
-- `x = 5` exists so a masked capture would resolve, loudly, to 5 -> 6.)

x =
    5


f x =
    let
        go acc k =
            if k <= 0 then
                let
                    h =
                        x + 1

                    x =
                        1000
                in
                h + acc
            else
                go (acc * 10) (k - 1)
    in
    go 0 1


main =
    f 1
