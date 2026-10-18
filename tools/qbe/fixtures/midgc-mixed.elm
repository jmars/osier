module MidgcMixed exposing (main)

-- perf-gc1 — THE MIXED-SIZE PROBE for the Mid collector's free list
-- (plan.md §2.2, stage-4 review finding 3: the free list is EXACT-MATCH-ONLY).
--
-- The stage-4 collector kept ONE free list and accepted a block only when its
-- EXACT size matched (`2 + (fcount + 4*fcount*fkind) == total` in
-- Rt.gcAllocGo).  A program that allocates two different shapes therefore
-- cannot recycle one shape's freed blocks for the other: the second shape
-- BUMPS past the free list and, once the bump cursor is exhausted, dies
-- `qbe-rt: midgc: out of memory` WITH the first shape's blocks still free.
-- Every earlier fixture is a uniform 12-word cons array, so nothing caught it.
--
-- THIS FIXTURE constructs the shape three ways at once:
--   * `keep` interleaves THREE sizes (S2/S3/S4 — 12/17/22-word Con vectors)
--     and is the only data the answer reads; its sum is 0+1+...+299 = 44850.
--   * `churn13` builds and DROPS 13-field records (67 words), the freed
--     blocks the second phase must recycle.  It is a tail-recursive loop
--     (`let _ = build13 200 in churn13 (n-1)`), so each dropped list really
--     becomes garbage — the slot is overwritten, not kept rooted.
--   * `big = build14 21000` is a LIVE list of 14-field records (72 words).
--
-- THE ASYMMETRY.  13-field records are 67 words and 14-field records are 72
-- words: DIFFERENT exact sizes, but BOTH round to size-class 9 (72 words).
--   * FAIL-BEFORE (exact match): build14's 72-word records cannot reuse the
--     freed 67-word blocks, so the live list bumps ~21000 x 576 bytes ≈ 12 MB
--     on top of the churn's ~4 MB cursor — over the 16 MB heap -> OOM.
--   * PASS-AFTER (size classes): both sizes are class 9, so build14 recycles
--     the churn's freed blocks and the run prints the answer below.
--
-- The answer is 44850 (keep) + sum 1..21000 (big) = 44850 + 220510500
-- = 220555350 — the value any correct collector must print.
--
-- The fail-before/pass-after asymmetry is scripted in
-- tools/qbe/probe-midgc-mixed.sh (revert the perf-gc1 allocator to the
-- pre-fix tree, rebuild, run, restore).

type Shape
    = S2 Int Int
    | S3 Int Int Int
    | S4 Int Int Int Int


mkShape i =
    if modBy 3 i == 0 then
        S4 i (i + 1) (i + 2) (i + 3)

    else if modBy 3 i == 1 then
        S3 i (i + 1) (i + 2)

    else
        S2 i (i + 1)


buildShapes n =
    buildShapesGo n 0


buildShapesGo n i =
    if n == 0 then
        []

    else
        mkShape i :: buildShapesGo (n - 1) (i + 1)


sumShapes xs =
    case xs of
        [] ->
            0

        h :: t ->
            case h of
                S2 a _ ->
                    a + sumShapes t

                S3 a _ _ ->
                    a + sumShapes t

                S4 a _ _ _ ->
                    a + sumShapes t


mk13 x =
    { a = x, b = x + 1, c = x + 2, d = x + 3, e = x + 4, f = x + 5, g = x + 6, h = x + 7, i = x + 8, j = x + 9, k = x + 10, l = x + 11, m = x + 12 }


mk14 x =
    { a = x, b = x + 1, c = x + 2, d = x + 3, e = x + 4, f = x + 5, g = x + 6, h = x + 7, i = x + 8, j = x + 9, k = x + 10, l = x + 11, m = x + 12, n = x + 13 }


build13 n =
    if n == 0 then
        []

    else
        mk13 n :: build13 (n - 1)


build14 n =
    if n == 0 then
        []

    else
        mk14 n :: build14 (n - 1)


churn13 n =
    if n == 0 then
        0

    else
        let
            _ =
                build13 200
        in
        churn13 (n - 1)


sum14 xs =
    case xs of
        [] ->
            0

        r :: rest ->
            r.a + sum14 rest


main =
    let
        keep =
            buildShapes 300

        _ =
            churn13 200

        big =
            build14 21000
    in
    sumShapes keep + sum14 big
