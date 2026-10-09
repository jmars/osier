module RecUpdLocal exposing (main, once)

-- SHAPE: recupd_local -- `{ r | f = v }` whose base `r` is a LOCAL literal.
--
-- The base of the update is born in this defun, so the updated record can be
-- flattened too: components come out of frame slots, the update rewrites the
-- slot, and no `assoc`/`snd`/`cons` chain is built or walked.
--
-- CORPUS GAP FILLED: all 459 RecordUpdate sites in the corpus have PARAMETER
-- bases (`{ state | .. }`, `{ ctx | .. }`) -- measured, docs/qbe-backend.md.
-- A local base is the case Flatten's own note names as the known gap
-- ("nested aggregates, and RecordUpdate on a flattened base").


step : Int -> Int
step n =
    let
        r =
            { a = n, b = 2 }

        r2 =
            { r | a = r.a + 1, b = r.b * 2 }
    in
    r2.a + r2.b


loop : Int -> Int -> Int
loop n acc =
    if n <= 0 then
        acc

    else
        loop (n - 1) (acc + step n)


once : Int -> Int
once n =
    step n


main : Int
main =
    loop 400000 0
