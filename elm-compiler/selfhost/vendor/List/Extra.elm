module List.Extra exposing
    ( find
    , unique
    )

{-| Helper for List functions. find and unique taken from elm-community/list-extra.

@docs find
@docs unique

-}


{-| Remove duplicate values, keeping the first instance of each element which appears more than once.

    unique [ 0, 1, 1, 0, 1 ]
    --> [ 0, 1 ]

-}
unique : List comparable -> List comparable
unique list =
    uniqueHelp [] list []


uniqueHelp : List comparable -> List comparable -> List comparable -> List comparable
uniqueHelp existing remaining accumulator =
    case remaining of
        [] ->
            accumulator

        first :: rest ->
            if List.member first existing then
                uniqueHelp existing rest accumulator

            else
                uniqueHelp (first :: existing) rest (first :: accumulator)


find : (a -> Bool) -> List a -> Maybe a
find predicate list =
    case list of
        [] ->
            Nothing

        x :: xs ->
            if predicate x then
                Just x

            else
                find predicate xs
