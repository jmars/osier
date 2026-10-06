module ProbeANeg exposing (main)


type Value
    = VStr String
    | VNum Int
    | VNil
    | VCons Value Value


compare : Value -> Value -> Int
compare a b =
    case ( a, b ) of
        ( VNum x, VNum y ) ->
            if x < y then
                "wrong"

            else
                0

        _ ->
            0


main : Int
main =
    compare (VNum 1) (VNum 2)
