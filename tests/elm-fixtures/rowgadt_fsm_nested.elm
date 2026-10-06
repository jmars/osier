module RowgadtFsmNested exposing (main)

-- G4 nested form (the source's ACTUAL match shape, previously the flattened
-- boundary): a reducer over the event CHAIN that matches the Event constructor
-- NESTED INSIDE the Then pattern (`Then prev Break`), with the per-state
-- narrowing happening AT THE NESTED LEVEL — the nested Event's result index
-- refines the chain's current-state row branch-locally, so `rec.broken` is
-- legal only in the arm whose nested event ARRIVES at the Broken state.
-- Must compile CLEAN; the wrong-field negative is rowgadt_fsm_nested_bad.

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


-- Read the state the chain is CURRENTLY in (the nested event's `to` index):
-- each arm narrows `from` to the arrival state, so the read is per-branch.
readCurrent : type from. { from | n : Int } -> Step from -> String
readCurrent rec step =
    case step of
        Start ->
            "locked#" ++ String.fromInt rec.n

        Then prev Unlock ->
            "closed:" ++ String.fromInt rec.closed

        Then prev Open ->
            "open:" ++ String.fromInt rec.open

        Then prev Close ->
            "closed:" ++ String.fromInt rec.closed

        Then prev Lock ->
            "locked#" ++ String.fromInt rec.n

        Then prev Jiggle ->
            "closed:" ++ String.fromInt rec.closed

        Then prev Break ->
            "broken:" ++ rec.broken

        Then prev Reset ->
            "locked#" ++ String.fromInt rec.n


-- The source's match shape also nests one chain constructor inside another;
-- the same branch-local capture licenses it (this arm is purely structural,
-- proving two-level nesting is not a special case).
label : type s. Step s -> String
label step =
    case step of
        Then (Then prev ev) Lock ->
            "ends-locked"

        _ ->
            "other"


main : String
main =
    readCurrent { n = 3, open = 42 } (Then (Then Start Unlock) Open)
