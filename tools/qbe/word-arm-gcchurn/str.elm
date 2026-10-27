module M exposing (main)

-- RUNTIME-BUILT STRING BYTES ACROSS A COLLECTION (perf word-arm-rawroot,
-- item 1).  The string twin of `hold`: 6000 fresh `String.join` strings are
-- kept REACHABLE through a cons chain, and every one is CONTENT-compared at
-- the end against the string it should be.
--
-- WHY THE COMPARISON IS `s == build i` AND NOT A LENGTH: a word-arm string's
-- LENGTH lives in the cell (body unit 1) while its BYTES lived in a separate
-- young block, so a collection that reclaimed the bytes left the length intact
-- and only the CONTENT wrong.  A length check (or a count of survivors) would
-- read the cell and answer 6000 no matter what the byte pointer names.  The
-- `==` walks the bytes, which is the only read that can see this defect.
--
-- MEASURED at QBE_HEAP_MB=1 before the fix: the val arm answers 6000/0 and the
-- word arm answered 597/5403 — silently, rc=0, empty stderr.  The count is a
-- function of the heap size (597/1745/1515/3039 at 1/2/4/8 MiB), which is what
-- makes it collection-correlated rather than a bad string op.
build i =
    String.join "-" [ String.fromInt i, "abcdefgh" ]

buildAll i acc =
    if i == 0 then
        acc
    else
        buildAll (i - 1) (build i :: acc)

check xs i good bad =
    case xs of
        [] ->
            String.append (String.fromInt good) (String.append "/" (String.fromInt bad))

        s :: rest ->
            if s == build i then
                check rest (i + 1) (good + 1) bad
            else
                check rest (i + 1) good (bad + 1)

main =
    check (buildAll 6000 []) 1 0 0
