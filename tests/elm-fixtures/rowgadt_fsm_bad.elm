module RowgadtFsmBad exposing (main)

-- G4 negative: the ILLEGAL transition for the door machine. `Open` departs
-- the Closed state (from = { closed : Int }), but `Start` is the Locked state
-- ({}): the chain `Then Start Open` is rejected at compile time. The witness
-- GADT is the transition relation, so an illegal transition cannot be built.

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


bad : Step {}
bad =
    Then Start Open


main : Int
main =
    0
