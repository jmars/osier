module M exposing (main)

-- `Rt.=` ON TWO FIXNUMS (perf word-arm-surface, review F6).
--
-- A NUMBER-literal case alternative is the one admitted pattern shape no other
-- fixture in this row exercises: `strcase.elm` matches STRINGS (the byte
-- compare arm of `Rt.=`), while this one matches integers, so it takes the
-- FIRST arm of `Rt.=` (`tagis(a, 0) && tagis(bb, 0)` -> compare the payload
-- words) and nothing else.  That is also the arm a word-arm fixnum has to get
-- right without a payload word at all, which is why it is worth a program.
--
-- The `_` alternative is exercised in the same run (`f 3`), so the fall-through
-- past three failing compares is covered, and the three answers are put in a
-- tuple so they are compared as OUTPUT rather than as an exit code.  Both arms
-- must print `[cons "one" . [cons "two" . "many"]]`.
--
-- NOTE ON WHAT THIS FIXTURE DOES **NOT** PROVE: `Rt.=` also carries a
-- float-vs-float arm that reads `slot + 8` — the 40-byte shape — and that arm
-- is DEAD here only because a word-arm float does not exist yet (AREA 5).  See
-- the note at that emit site (`RawLoadFlt` in Mid.Qbe.Lower).
f n =
    case n of
        1 ->
            "one"

        2 ->
            "two"

        _ ->
            "many"


main =
    ( f 1, f 2, f 3 )
