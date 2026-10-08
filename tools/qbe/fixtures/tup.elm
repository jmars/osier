module Tup exposing (main, nested, roundtrip)

-- Tup: a right-nested cons chain (Mid.ToZinc Tup — `(a,b,c)` = cons a (cons b
-- c)), round-tripped through a destructuring let and a tuple pattern.

add3 : ( Int, Int, Int ) -> Int
add3 t =
    let
        (a, b, c) = t
    in
    a + b + c


-- a 2-tuple is `cons a b` (the SECOND element is the tail, NOT nil); snd of a
-- 2-tuple is a plain value, so fst/snd must chase the right fields.
roundtrip : Int
roundtrip =
    let
        (x, y) = (40, 2)
    in
    x + y


nested : Int
nested =
    let
        ( a, (b, c) ) = (1, (2, 3))
    in
    a + b + c


main =
    add3 (5, 6, 7) + roundtrip + nested
