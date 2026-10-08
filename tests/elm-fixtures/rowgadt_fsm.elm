module RowgadtFsm exposing (main)

-- G4 external example: the discuss.ocaml.org t/13718 FSM pattern (a door
-- machine) in Osier. States are ROWS (type-level records), the transition
-- relation is a GADT witness, and the reducers read state-specific fields
-- under branch-local row refinement (the narrowing OCaml cannot refute).
-- Must compile CLEAN; the illegal transition is pinned in rowgadt_fsm_bad.

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


cycle : Step {}
cycle =
    Then (Then (Then (Then Start Unlock) Open) Close) Lock


count : type s. Step s -> Int
count step =
    case step of
        Start ->
            0

        Then prev ev ->
            1 + count prev


type Has l t rho
    = Here : Has l t { l : t | rho }
    | There : Has l t rho -> Has l t { k : s | rho }


read : type l t rho. Has l t rho -> { rho | n : Int } -> t
read w rec =
    case w of
        Here ->
            rec.l

        There rest ->
            read rest rec


readFrom : type from to. { from | n : Int } -> Event from to -> String
readFrom rec ev =
    case ev of
        Unlock ->
            "locked#" ++ String.fromInt rec.n

        Open ->
            "closed:" ++ String.fromInt rec.closed

        Close ->
            "open:" ++ String.fromInt rec.open

        Lock ->
            "closed:" ++ String.fromInt rec.closed

        Jiggle ->
            "closed:" ++ String.fromInt rec.closed

        Break ->
            "open:" ++ String.fromInt rec.open

        Reset ->
            "broken:" ++ rec.broken


main : String
main =
    readFrom { n = 3, open = 42 } Close
