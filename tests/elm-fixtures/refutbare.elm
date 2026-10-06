module RefutBare exposing (main)

-- Part B pin (refutation NEGATIVE at a BARE index): `a` in `Tag a` is NOT
-- bound by `type a.`, so it is a FLEXIBLE variable. `f` may be applied at
-- `Tag String`, where `B : Tag String` IS a possible value, so a `case`
-- matching only `A` is PARTIAL. The check must ERROR "missing B" — it must
-- NOT refute `B` against the single clause's concrete index `Tag Int`.

type Tag a
    = A : Tag Int
    | B : Tag String


f : Tag a -> Int
f t =
    case t of
        A ->
            1


main : Int
main =
    f A
