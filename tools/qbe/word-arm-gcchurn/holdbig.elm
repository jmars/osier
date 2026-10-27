module M exposing (main)

-- THE SAME SHAPE AS `hold`, SIZED FOR THE DEFAULT KNOBS (perf word-arm-closures,
-- review BLOCKER).  This row exists because the defect was NOT only a
-- small-heap artefact: at the default 64 MiB heap the trigger is 16 MiB, and
-- 250,000 closures allocate ~32 MB of capture blocks plus bodies, so the
-- collection happens at DEFAULT SETTINGS too.
--
-- MEASURED before the fix, default knobs, no QBE_HEAP_MB: the val arm answers
-- 31250125000 and the word arm answered 31252390090 — rc=0, EMPTY STDERR.  That
-- is the whole reason this class is a blocker: nothing in the tree noticed.
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
    sum (\c -> c 0) (build 250000 []) 0
