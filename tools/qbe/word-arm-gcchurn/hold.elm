module M exposing (main)

-- SURVIVING CLOSURES ACROSS A COLLECTION (perf word-arm-closures, review
-- BLOCKER).  Closures are built into a list — so they stay REACHABLE through
-- the cons chain — and only applied at the END, after thousands more
-- allocations have lapped the young space.
--
-- WHY THIS FIXTURE EXISTS AND NO OTHER WORD-ARM FIXTURE WOULD DO: every
-- word-arm fixture in the tree allocates far below one GC trigger, so none of
-- them ever collects, and a ROOTING defect is invisible without a collection.
-- MEASURED before the fix, at QBE_HEAP_MB=1: the val arm answers 18003000 and
-- the word arm answered 19709031 — silently, rc=0, empty stderr.
--
-- WHAT IT PINS: `Rt.closure`'s word twin allocates TWICE (the capture block,
-- then the closure body) and the first result is a RAW WORD.  A scavenge
-- landing on the second allocation used to free the capture block and hand its
-- memory to the body, so the closure's body word 2 named the body itself and
-- the capture read back whatever reused the block.  The read at the end is what
-- turns that into a wrong NUMBER rather than a crash.
mk n =
    \v -> v + n

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
        build (i - 1) (mk i :: acc)

main =
    sum (\c -> c 0) (build 6000 []) 0
