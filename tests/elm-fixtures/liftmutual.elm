module LiftMutual exposing (main)

-- A MUTUALLY recursive pair in ONE let: `even` calls `odd` before `odd` is
-- bound, `odd` calls `even`.  The lift treats the whole block as one group.

isEven n =
    let
        even k =
            if k == 0 then
                True
            else
                odd (k - 1)

        odd k =
            if k == 0 then
                False
            else
                even (k - 1)
    in
    even n


main =
    if isEven 10 then
        if isEven 7 then
            0
        else
            42
    else
        0
