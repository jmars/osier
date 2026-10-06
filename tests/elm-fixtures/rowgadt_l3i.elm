module RowgadtL3i exposing (main)

-- L3 principality boundary (i): the WITNESS-ENCODED access with NO type
-- signature. `showAny` (existential `Any` + nested witness match) is inferred
-- — the recovered element type is used branch-locally via discharge, and the
-- result is a plain String, so a principal type `Any -> String` is inferred.
-- MEASURED: ACCEPTED.

type Witness a
    = WInt : Witness Int
    | WString : Witness String


type Any
    = Some : Witness a -> a -> Any


showAny box =
    case box of
        Some w x ->
            case w of
                WInt ->
                    String.fromInt x

                WString ->
                    x


main =
    showAny (Some WInt 3)
