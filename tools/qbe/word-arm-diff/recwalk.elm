module M exposing (main)

-- THE RECORD FAMILY, CLASS 5: A WALK READ OF A RUNTIME-BUILT RECORD (perf
-- word-arm-records R4, added by the R3/R4 review's SHOULD-FIX 2).
--
-- Every other read fixture walks a LITERAL record, whose names array is a STATIC
-- blob — an address the names-base mask is the IDENTITY on.  So none of them
-- could see a names base that is stored TAGGED, which is what a record the
-- runtime BUILT carries.  This fixture reads fields out of an inserted record
-- through the WALK route (the record expression is not a closed Var, so `rank`
-- is Nothing and `Rt.recGet` runs), i.e. through the names array `Rt.recAppend`
-- allocated.
--
-- MEASURED, before the mask was retrofitted into `Rt.recGetGo` (the review's
-- BLOCKER 2): the val arm printed `[cons 1 . 7]` and the word arm died
-- `qbe-rt: word arm: mknum overflow` — the base was one byte off, so the loaded
-- word did not fit the i61 fixnum.  The POSITIONAL read of the SAME record
-- passes both arms, which is what isolated the defect to this route.
ins r =
    { r | z <- 7 }


main =
    ( (ins { x = 1, y = 2 }).x, (ins { x = 1, y = 2 }).z )
