module M exposing (main)

-- `partial` SIZED FOR THE DEFAULT KNOBS (perf word-arm-closures, review
-- BLOCKER, second site).  Same argument as `holdbig`: the applyPartGo window is
-- a DEFAULT-settings window, not a small-heap one.
p2 a b =
    a + b + 100

sum f xs acc =
    case xs of
        [] ->
            acc

        y :: ys ->
            sum f ys (f y + acc)

build i acc =
    if i == 0 then
        acc
    else
        build (i - 1) (p2 i :: acc)

main =
    sum (\c -> c 5) (build 250000 []) 0
