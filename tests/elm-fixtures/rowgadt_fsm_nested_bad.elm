module RowgadtFsmNestedBad exposing (main)

-- G4 nested NEGATIVE: the nested `Open` arm narrows the current-state row to
-- { open : Int } (Open arrives at the Open state), so reading rec.broken there
-- must ERR — the refinement does not expose `broken`. The same read IS legal
-- in the nested `Break` arm (rowgadt_fsm_nested), so the rejection is
-- per-branch, not per-field: the nested refinement narrows, it does not open.

type Event from to
    = Unlock : Event {} { closed : Int }
    | Open : Event { closed : Int } { open : Int }
    | Close : Event { open : Int } { closed : Int }
    | Lock : Event { closed : Int } {}
    | Jiggle : Event { closed : Int } { closed : Int }
    | Break : Event { open : Int } { broken : String }
    | Reset : Event { broken : String } {}


type Step s
    = Start : Step {}
    | Then : Step from -> Event from to -> Step to


readCurrent : type from. { from | n : Int } -> Step from -> String
readCurrent rec step =
    case step of
        Then prev Open ->
            "broken:" ++ rec.broken

        Then prev Break ->
            "broken:" ++ rec.broken

        _ ->
            "other"


main : String
main =
    readCurrent { n = 3, open = 42 } (Then (Then Start Unlock) Open)
