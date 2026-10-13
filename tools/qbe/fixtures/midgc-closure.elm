module MidgcClosure exposing (main)

-- zigretire stage 5 PART 2 — THE CROSS-HEAP PROBE for closure construction
-- (rt_make_closure -> Rt.closure).
--
-- A closure-heavy program under QBE_MIDGC=1.  `keep` is a Mid-allocated cons
-- list whose elements are CLOSURES WITH A CAPTURE (`makeAdder n` = \y -> n + y):
-- the list's cons cells are Mid-allocated (cons -> RawAllocVector ->
-- Rt.allocVector), and each closure's ENV array is built by the closure seat.
-- BEFORE this unit that seat is the Zig `rt_make_closure` -> values.valLambda ->
-- `g.allocArray`, so the env arrays live in the ZIG heap while the list that
-- reaches them lives in the MID heap — the cross-heap edge the stage-4 review
-- named.  The churn below builds MORE closures (dropped) so the Zig scavenger
-- runs while `keep` is the only thing reaching the kept env arrays: it frees
-- them (it cannot see through the Mid list), and `sumClos` then reads freed
-- captures -> a WRONG SUM (MEASURED 49900) or a crash, never 22100.  AFTER the
-- unit the closure seat is the Mid defun `Rt.closure`, both shapes live in the
-- MID heap, and the sum is exact.
--
-- The sum is 200 * (n + 10) = 20100 + 2000 = 22100 — the value any correct
-- collector must print.  The churn is sized to exceed the Zig nursery
-- (NURSERY_BYTES = 8MB) with ~200k one-Value env arrays so a scavenge is
-- GUARANTEED, not hoped for.
--
-- The fail-before/pass-after asymmetry is scripted in
-- tools/qbe/probe-midgc-closure.sh (revert ONE line in lowerClosure to force
-- the Zig rt_make_closure route, rebuild, run, restore).

makeAdder x =
    \y -> x + y


main =
    let
        keep =
            buildClos 200

        n =
            churnDrop 400
    in
    sumClos keep + n


buildClos n =
    if n == 0 then
        []

    else
        makeAdder n :: buildClos (n - 1)


churnDrop n =
    if n == 0 then
        0

    else
        let
            dropped =
                buildClos 500
        in
        churnDrop (n - 1)


sumClos xs =
    case xs of
        [] ->
            0

        f :: rest ->
            f 10 + sumClos rest
