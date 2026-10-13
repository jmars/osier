module MidgcRecord exposing (main)

-- zigretire stage 5 PART 3 — THE CROSS-HEAP PROBE for RECORD construction
-- (lowerRecordLitPos / lowerRecordUpdateClosed: Zig `rt_vec_alloc` + the
-- barrier `rt_vec_store` -> Mid `Rt.allocVector` + the plain store).
--
-- A record-heavy program under QBE_MIDGC=1.  `keep` is a Mid-allocated cons
-- list whose elements are positional records `{ n, m }`: the list's cons
-- cells are Mid-allocated (cons -> RawAllocVector -> Rt.allocVector), and each
-- record's DATA array is built by the record seat.  BEFORE this unit that seat
-- is the Zig `rt_vec_alloc` (Lower.elm lowerRecordLitPos, emitted UNCONDITIONALLY
-- with no midGc branch), so the data arrays live in the ZIG heap while the
-- list that reaches them lives in the MID heap — the cross-heap edge the
-- stage-4 review named (the LAST live pointer-bearing Zig allocation).  The
-- churn below builds MORE records (dropped) so a collection runs while `keep`
-- is the only thing reaching the kept data arrays: it frees them (it cannot
-- see through the Mid list), and `sumRec` then reads freed data -> a WRONG SUM
-- or a crash, never 60209.  AFTER the unit the data arrays are Mid-allocated,
-- both shapes live in the MID heap, and the sum is exact.
--
-- The fixture ALSO constructs the two record operations the brief requires,
-- not just literals:
--   * `addTag r = { r | tag <- 7 }` is an OPEN-row insertion, which lowers to
--     the WALK form (Rt.recInsert -> Rt.recAppend): recAppend builds the
--     dynamic NAMES array at run time via RawAllocVector.  That path was the
--     stage-3 use-after-free site; it is already Mid-allocated under the
--     hatch (RawAllocVector routes to Rt.allocVector), and this fixture pins
--     that by EMISSION (no `rt_vec_alloc` in the insert's recAppend).
--   * `Record.remove "m" r0` exercises Rt.recToChain (positional -> assoc
--     chain) so the record-remove route stays covered.
--
-- The sum is (sum n + sum(n+100)) over n=1..200, plus inserted.tag (7),
-- inserted.n (1) and removed.n (1) = 60200 + 9 = 60209 — the value any
-- correct collector must print.  The churn is 400 x 500 = 200k records
-- (data array + cons cell each) — over the QBE_HEAP_MB=16 quarter-heap
-- threshold AND the heap size itself, so the Mid collector runs repeatedly
-- and reuses the free list (the mixed-size free-list cycle this unit also
-- fixed in Rt.collect is exercised: recAppend's 3-element arrays are a
-- different size from the 2-element data arrays/cons cells).
--
-- The fail-before/pass-after asymmetry is scripted in
-- tools/qbe/probe-midgc-record.sh (revert ONE line in lowerRecordLitPos to
-- force the Zig rt_vec_alloc route, rebuild, run, restore).

buildRec n =
    if n == 0 then
        []

    else
        { n = n, m = n + 100 } :: buildRec (n - 1)


addTag r =
    { r | tag <- 7 }


sumRec xs =
    case xs of
        [] ->
            0

        r :: rest ->
            r.n + r.m + sumRec rest


churnDrop n =
    if n == 0 then
        0

    else
        let
            _ =
                buildRec 500
        in
        churnDrop (n - 1)


main =
    let
        keep =
            buildRec 200

        dropped =
            churnDrop 400

        r0 =
            { n = 1, m = 101 }

        inserted =
            addTag r0

        removed =
            Record.remove "m" r0
    in
    sumRec keep + inserted.tag + inserted.n + removed.n + dropped
