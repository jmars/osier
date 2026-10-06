module LiftNestedRec exposing (main)

-- CONTROL: a MUTUALLY recursive pair (still lifted after the cycle-component
-- fix) whose `even` base branch has a nested value sibling `x` shadowing the
-- CAPTURE x.  even 4 -> odd 3 -> even 2 -> odd 1 -> even 0 -> nested x = 100.
-- Proves BLOCKER 1's fix (nested sibling threaded) does not refuse to lift,
-- and BLOCKER 2's fix still lifts a genuine cycle.

f x =
    let
        even k =
            if k <= 0 then
                let
                    x =
                        100
                in
                x
            else
                odd (k - 1)

        odd k =
            if k <= 0 then
                let
                    x =
                        0
                in
                x
            else
                even (k - 1)
    in
    even 4


main =
    f 7
