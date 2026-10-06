module ProbeA exposing (main)


type Value
    = VStr String
    | VNum Int
    | VNil
    | VCons Value Value


tStr : String -> Value
tStr s =
    VStr s


tNum : Int -> Value
tNum n =
    VNum n


tNil : Value
tNil =
    VNil


tCons : Value -> Value -> Value
tCons h t =
    VCons h t


compare : Value -> Value -> Int
compare a b =
    case ( a, b ) of
        ( VNum x, VNum y ) ->
            if x < y then
                -1

            else if x > y then
                1

            else
                0

        ( VStr x, VStr y ) ->
            if x < y then
                -1

            else if x > y then
                1

            else
                0

        ( VNil, VNil ) ->
            0

        ( VCons _ _, VCons _ _ ) ->
            0

        _ ->
            0


main : Int
main =
    compare (tNum 1) (tNum 2)
