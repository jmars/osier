module RowgadtNoescape exposing (main)

-- NEGATIVE (handoff-rowgadt-6 acceptance 4): the payload of an existential is
-- the constructor's EXISTENTIAL `a`, recoverable only by matching its witness.
-- Returning the payload where a String is expected must be REJECTED — the
-- rigid existential cannot escape its branch, so `x : a` cannot be a String
-- (no witness match here has refined `a`). An over-eager discharge would
-- wrongly accept this and let an Int payload out at type String.

type Witness a
    = WInt : Witness Int
    | WString : Witness String


type Any
    = Some : Witness a -> a -> Any


bad : Any -> String
bad box =
    case box of
        Some w x ->
            x


main : String
main =
    bad (Some WInt 3)
