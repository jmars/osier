module ListAgg exposing (main, sum, empty, headTail)

-- ListLit + the MEmpty/MCons match steps.  Stage 2 implemented MEmpty but
-- could not fixture it (the only nil producer, `[]`, was a ListLit - out of
-- scope then).  `sum` folds a non-empty literal with MCons + MEmpty; `empty`
-- matches a literal `[]` with MEmpty; `headTail` reads a list by head/tail.

sumList : List Int -> Int
sumList xs =
    case xs of
        x :: rest ->
            x + sumList rest

        [] ->
            0


sum : Int
sum =
    sumList [ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 ]


empty : Int
empty =
    case [] of
        [] ->
            99

        _ :: _ ->
            0


headTail : Int
headTail =
    case [ 10, 20, 30 ] of
        x :: xs ->
            case xs of
                y :: _ ->
                    x + y

                [] ->
                    0

        [] ->
            0


main =
    sum + empty + headTail
