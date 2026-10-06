module RowgadtL3iii exposing (main)

-- L3 principality boundary (iii): PLAIN row access with no GADT and no
-- signature. `f rec = rec.x` infers the principal type `{ r | x : a } -> a`
-- (ordinary row polymorphism). MEASURED: ACCEPTED.

f rec =
    rec.x


main : Int
main =
    f { x = 1 }
