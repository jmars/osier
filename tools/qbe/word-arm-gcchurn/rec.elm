module M exposing (main)

-- RECORD INSERTION ACROSS COLLECTIONS, ON THE WORD ARM (perf word-arm-records
-- R4).  The word-arm sibling of tools/qbe/fixtures/recinschurn.elm, and the
-- collecting oracle for the UPDATE family's ONE new allocation window.
--
-- WHAT IT PINS THAT THE VAL ARM'S ROW CANNOT.  `Rt.recAppend`'s word twin
-- allocates the record block, then the NAMES BLOCK, and the names block's base
-- is written into the record's LAST body word TAGGED before the block is
-- filled.  Two things can go wrong there and only a collection can show either:
--   * the base stored UNTAGGED — `gcScavValue`'s tag test reads 0, does
--     NOTHING, the block is reclaimed and the record keeps a dangling names
--     base (silent: the data words are still correct, so a field read that
--     never consults the names — a closed positional read — answers fine);
--   * the names word read WITHOUT the mask (`nw - (nw & 7)`), which is only
--     correct while the base happens to be untagged — i.e. until the first
--     promotion moves it.
-- The comparison is a WHOLE-RECORD `==`, so it walks the DATA words; the
-- CONTENT check that reaches the names side is the field read in `build`'s
-- sibling below — `ins` inserts `x`, and `check` reads `x` back through the
-- WALK (`Rt.recGet`, names array) on the record the runtime built.
--
-- OUTPUT is `examined/matched/mismatched`; expected 6000/6000/0 at every heap
-- size, on both arms.
--
-- STATUS: **WIRED, AND RED AT h1.**  This row is in
-- `tools/qbe/word-arm-gcchurn.sh` (h1 + default) so the defect cannot go
-- unmentioned again.  MEASURED (perf word-arm-records R4, after the review's
-- blockers 1-2 and three attempts at this one): val `6000/6000/0` at BOTH heaps;
-- word `6000/6000/0` at DEFAULT knobs and SEGFAULT (rc 139) at QBE_HEAP_MB=1.
-- Fixed on the way here: the record-then-names allocation order (an old-to-young
-- names store with no barrier) and a rooted-but-unfilled body word promoted as
-- garbage.  The remaining window is neither the fill order nor the allocation
-- order nor the scan bit (a SCANNED names block segfaults for its own reason).

ins r i =
    { r | x <- i }



-- The names-side read: `.x` on a record the RUNTIME built (its names array is
-- this unit's allocation, not a static blob), so a reclaimed or stale names
-- base answers a wrong value or dies here rather than at the print.
readX r =
    r.x


build i =
    ins { y = 7, z = 8 } i


buildAll i acc =
    if i == 0 then
        acc
    else
        buildAll (i - 1) (build i :: acc)


check xs i examined matched mismatched =
    case xs of
        [] ->
            String.append (String.fromInt examined)
                (String.append "/"
                    (String.append (String.fromInt matched) (String.append "/" (String.fromInt mismatched)))
                )

        r :: rest ->
            if readX r == i then
                if r == build i then
                    check rest (i + 1) (examined + 1) (matched + 1) mismatched
                else
                    check rest (i + 1) (examined + 1) matched (mismatched + 1)
            else
                check rest (i + 1) (examined + 1) matched (mismatched + 1)


main =
    check (buildAll 6000 []) 1 0 0 0
