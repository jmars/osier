module MidgcTail exposing (main)

-- zigretire stage 5 PART 5 — THE OTHER HALF of the census refusal: a PURE
-- program churning a >3-arg MUTUAL tail recursion at QBE_MIDGC=1 must NOT
-- corrupt.  This is the probe that distinguishes THE TRIGGER from THE HOLE.
--
-- rt_tail_known's nargs>3 fallback (rt.zig:817) allocates a fresh g.allocArray
-- in the ZIG nursery per iteration, so `churnA`/`churnB` (4-arg mutual tail
-- recursion; a self-tail would lower to an in-frame loop and allocate nothing)
-- forces a ZIG scavenge.  But the transient tail array is NOT live across any
-- safepoint (the bounce chase copies its args before any allocation), so it is
-- an ordinary scavenge TRIGGER, not a soundness hazard — the hole only exists
-- when a host-IO program's Zig-nursery string/conses are ALSO referenced from
-- a Mid object.
--
-- THIS FIXTURE CONSTRUCTS the pure case: `keep` is a Mid cons holding a
-- MID-allocated string (the `++` chain lowers to the `cn` prim -> Rt.cn ->
-- RawAllocRaw -> Rt.allocRaw, i.e. data in the MID region, not the Zig
-- nursery).  `keep` is a MAIN-LOCAL let-binding, so the Mid lowering builds it
-- EAGERLY into a frame slot BEFORE the churn (let-bindings lower in order).
-- The mutual-tail churn then fires the Zig scavenge ~3M times
-- (tail_gcarray=3,000,000, verified by QBE_RT_COUNTS) without touching the Mid
-- region: the kept string's data survives because it is NOT reclaimable by the
-- Zig collector.  The content equality holds -> "100|150".
--
-- If the "transient tail array is not live" invariant ever broke (someone made
-- the staging buffer live across a safepoint, or re-rooted it), this fixture
-- goes red — it is the falsifiable pin for the pure-program half of the
-- corrected-criterion audit (plan.md §2.2).


churnA : Int -> Int -> Int -> Int -> Int
churnA n a b c =
    if n == 0 then
        a + b + c

    else
        churnB (n - 1) (a + 1) b c


churnB : Int -> Int -> Int -> Int -> Int
churnB n a b c =
    if n == 0 then
        a + b + c

    else
        churnA (n - 1) a (b + 1) c


main =
    let
        -- A Mid-allocated string (++ -> cn -> Rt.cn -> Mid raw alloc), kept in
        -- a Mid cons; built EAGERLY into a frame slot before the churn below.
        keep =
            [ "abcdefghij" ++ "abcdefghij" ++ "abcdefghij" ++ "abcdefghij" ++ "abcdefghij" ++ "abcdefghij" ++ "abcdefghij" ++ "abcdefghij" ++ "abcdefghij" ++ "abcdefghij" ++ "abcdefghij" ++ "abcdefghij" ++ "abcdefghij" ++ "abcdefghij" ++ "abcdefghij" ]

        _ =
            churnA 3000000 0 0 0

        eq =
            case keep of
                x :: _ ->
                    if x == "abcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghij" then
                        100

                    else
                        0

                [] ->
                    0

        ln =
            case keep of
                x :: _ ->
                    String.length x

                [] ->
                    -1
    in
    String.fromInt eq ++ "|" ++ String.fromInt ln
