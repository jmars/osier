module RowgadtHet exposing (main)

-- Heterogeneous container (handoff-rowgadt-6 acceptance 3): a type-witness
-- GADT, an existential wrapper, a LIST of two elements with DIFFERENT witness
-- types, and a fold to String that matches each witness and uses the payload
-- at its recovered type. This is the polymorphic-array use case: the element
-- type is not recoverable from the container, only from the per-element
-- witness — the existential `a` of `Some` is RIGID, and each nested match
-- captures `a ~ Int` / `a ~ String` branch-locally (FIX 1), then the use of
-- `x : a` at the recovered type is discharged (FIX 2).

type Witness a
    = WInt : Witness Int
    | WString : Witness String


type Any
    = Some : Witness a -> a -> Any


showAny : Any -> String
showAny box =
    case box of
        Some w x ->
            case w of
                WInt ->
                    String.fromInt x

                WString ->
                    x


main : String
main =
    List.foldl (\box acc -> showAny box ++ acc) "" [ Some WInt 3, Some WString "hi" ]
