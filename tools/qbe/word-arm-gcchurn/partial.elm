module M exposing (main)

-- SURVIVING PARTIAL APPLICATIONS ACROSS A COLLECTION (perf word-arm-closures,
-- review BLOCKER, the SECOND site).  Each `p2 i` is an UNDER-applied global
-- head, i.e. `Rt.applyPartGo`, whose word twin allocates the capture block
-- (`allocvec(total)`) and THEN the closure body — with the capture block held
-- in a raw word across that second safepoint.
--
-- MEASURED before the fix, at QBE_HEAP_MB=1: the val arm answers 18633000 and
-- the word arm answered 20363304.  It is a SEPARATE fixture from `hold` because
-- it is a separate defun with its own allocation window; a fix in one does not
-- cover the other.
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
    sum (\c -> c 5) (build 6000 []) 0
