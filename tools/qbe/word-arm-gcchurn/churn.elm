module M exposing (main)

-- CREATE-CREATE-THEN-READ (perf word-arm-closures, review BLOCKER).  `pairadd`
-- forces two closure creations to complete BEFORE either is applied, so a
-- capture block freed by the second creation's allocation is read by the first
-- closure's own capture read.  This is the smallest shape that makes the
-- rooting defect produce a wrong NUMBER rather than merely a stale pointer.
--
-- It differs from `hold` in the other direction: `hold` keeps the closures
-- ALIVE across many later collections (a rooting defect on the way OUT), while
-- this one exercises the interleaving WITHIN one expression (a rooting defect
-- between two sibling allocations).
mk n =
    \v -> v + n

pairadd x y =
    x 0 + y 0

main =
    let
        loop i acc =
            if i == 0 then
                acc
            else
                loop (i - 1) (pairadd (mk i) (mk (i + 100)) + acc)
    in
    loop 20000 0
