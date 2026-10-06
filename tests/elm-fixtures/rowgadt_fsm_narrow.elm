module RowgadtFsmNarrow exposing (main)

-- G4 negative (the narrowing OCaml's workaround cannot do, pinned rather than
-- asserted): in the Close branch the FROM-state row is { open : Int }, so the
-- branch-local refinement makes only rec.n / rec.open legal; reading rec.broken
-- must ERR. The same field IS legal in the Reset branch (from = { broken :
-- String }), so the rejection is per-branch, not per-field.

type Event from to
    = Unlock : Event {} { closed : Int }
    | Open : Event { closed : Int } { open : Int }
    | Close : Event { open : Int } { closed : Int }
    | Lock : Event { closed : Int } {}
    | Jiggle : Event { closed : Int } { closed : Int }
    | Break : Event { open : Int } { broken : String }
    | Reset : Event { broken : String } {}


readFrom : type from to. { from | n : Int } -> Event from to -> String
readFrom rec ev =
    case ev of
        Unlock ->
            "locked#" ++ String.fromInt rec.n

        Open ->
            "closed:" ++ String.fromInt rec.closed

        Close ->
            "broken:" ++ rec.broken

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
