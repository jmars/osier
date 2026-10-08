module Bool exposing (main, andShort, orShort, neq)

-- ShortAnd/ShortOr/NotEqual.  The short-circuit proof: the right side of
-- `&&`/`||` is `loop` (infinite self-recursion) — if it were evaluated the
-- native run would hang and the check script's `timeout` would fail it.

loop : Int -> Int
loop n =
    loop n


andShort : Int
andShort =
    if False && (loop 0 == 0) then
        1

    else
        2


orShort : Int
orShort =
    if True || (loop 0 == 0) then
        3

    else
        4


neq : Int
neq =
    (if 5 /= 6 then
        10

     else
        0
    )
        + (if 5 /= 5 then
            100

           else
            0
          )


main =
    andShort + orShort + neq
