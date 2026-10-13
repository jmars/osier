module MidgcPartial exposing (main)

-- zigretire stage 5 PART 2 — THE CROSS-HEAP PROBE for partial application
-- (applyGo's `rem > nargs` arm).
--
-- A partial-application-heavy program under QBE_MIDGC=1.  `keep` is a
-- Mid-allocated cons list whose elements are PARTIALS (`add n` = the 1-of-2
-- application of `add`): the list's cons cells are Mid-allocated (cons ->
-- RawAllocVector -> Rt.allocVector), and each partial's ENV array is built by
-- rt_apply -> applyGo's partial arm.  BEFORE this unit that arm calls Zig
-- `g.allocArray(Value, total)` (tools/qbe/rt.zig:677), so the env arrays live
-- in the ZIG heap while the list that reaches them lives in the MID heap — the
-- exact cross-heap edge the stage-5 review found BY EMISSION (a partial consed
-- onto a Mid-allocated list).  The churn builds MORE partials (dropped) so the
-- Zig scavenger runs while `keep` is the only thing reaching the kept env
-- arrays: it frees them (it cannot see through the Mid list), and `sumApply`
-- reads freed captures -> a WRONG SUM (MEASURED 49900) or a crash, never
-- 22100.  AFTER the unit the partial env array is Mid-allocated through the
-- exported Rt.allocVector seat (the weak-extern bridge in rt.zig), both shapes
-- live in the MID heap, and the sum is exact.
--
-- The sum is 200 * (n + 10) = 20100 + 2000 = 22100 — the value any correct
-- collector must print.  The churn is sized to exceed the Zig nursery
-- (NURSERY_BYTES = 8MB) with ~200k one-Value env arrays so a scavenge is
-- GUARANTEED, not hoped for.
--
-- The fail-before/pass-after asymmetry is scripted in
-- tools/qbe/probe-midgc-partial.sh (revert ONE line in tools/qbe/rt.zig to
-- restore the Zig g.allocArray route, rebuild rt.o, run, restore).

add a b =
    a + b


main =
    let
        keep =
            buildPartials 200

        n =
            churnDrop 400
    in
    sumApply keep + n


buildPartials n =
    if n == 0 then
        []

    else
        add n :: buildPartials (n - 1)


churnDrop n =
    if n == 0 then
        0

    else
        let
            dropped =
                buildPartials 500
        in
        churnDrop (n - 1)


sumApply xs =
    case xs of
        [] ->
            0

        f :: rest ->
            f 10 + sumApply rest
