module M exposing (main)

-- RECORD INSERTION ACROSS COLLECTIONS (perf word-arm-rawroot item 3 FIX, review
-- BLOCKER 1).  The VAL ARM's collecting oracle for `Rt.recAppend` — and the
-- loudest defect this arc has found: a DEFAULT-ARM SEGFAULT reachable from a
-- committed-fixture construct.
--
-- WHY `<-` AND NOT `=`: `ins` is ROW-POLYMORPHIC (`{ r | x <- i }` with a free
-- row extension, Type/Infer.elm's InsertionValue arm), so at the call site the
-- update's base is not a closed-row Var and the emitter takes the WALK arm —
-- `Rt.recInsert`, whose MISS arm (the field is absent from the base's names) is
-- `Rt.recAppend`.  The `=` UPDATE syntax on a missing field is a TYPE ERROR in
-- this surface, which is why an earlier probe of this defect measured only the
-- `=` form and wrongly concluded the append was unreachable.
--
-- THE DEFECT IT PINS (runtime.mid's `Rt.recAppend`, both halves):
--   (1) the data array was a RAW WORD across the names array's `allocvec` — and
--       `mknum(nd)` does NOT root it, because a fixnum is not relocated;
--   (2) once rooted, the array was still promoted BEFORE it was filled (the
--       fills came last), so the promoted copy carried the allocator's garbage
--       — a forwarded young body's word 0 is the POISON 15 — and the drain
--       walked it as Values.
-- MEASURED before the fix, 6000 insertions kept reachable and CONTENT-compared
-- (`r == build i`, a whole-record deep compare, because a field read cannot see
-- a stale data/names base): QBE_HEAP_MB=1 SEGFAULT (rc 139), h2 SEGFAULT
-- (rc 139), h4 5999 of 6000, h8 5999 of 6000, default 6000 of 6000.  After:
-- 6000 of 6000 at every heap size.
--
-- THE CONTROL that isolates it (and why this row is not just "records are
-- broken"): the same churn with `y <- i` on an EXISTING field always HITs
-- (`Rt.recUpd`, ONE allocvec, no window) and answers 6000 of 6000 at h1 and h2.
--
-- OUTPUT is `examined/matched/mismatched`, so a wrong count is a visible number
-- rather than a crash: the expected value is 6000/6000/0.
ins r i =
    { r | x <- i }


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
            if r == build i then
                check rest (i + 1) (examined + 1) (matched + 1) mismatched
            else
                check rest (i + 1) (examined + 1) matched (mismatched + 1)


main =
    check (buildAll 6000 []) 1 0 0 0
