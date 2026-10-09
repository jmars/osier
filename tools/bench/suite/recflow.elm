module RecFlow exposing (main, once)

-- SHAPE: recflow -- records passed IN as arguments and returned AS results.
--
-- Every record here is a full RecordLit that escapes its defun (it is the
-- result, and it is the argument of the next call), so Flatten must change
-- NOTHING: no literal is ever born and consumed inside one defun.
--
-- CORPUS CONTEXT: this IS the corpus shape -- 667 record literals, all
-- returned/passed/stored (docs/qbe-backend.md).  It is in the suite so the
-- workload mix is honest about what the existing measurements DID cover,
-- and as the negative control for any representation change: a pass that
-- speeds up localrec must not slow this down.


type alias St =
    { n : Int, acc : Int }


step : St -> St
step s =
    { n = s.n - 1, acc = s.acc + s.n }


run : St -> Int
run s =
    if s.n <= 0 then
        s.acc

    else
        run (step s)


once : Int -> Int
once n =
    (step { n = n, acc = 0 }).acc


main : Int
main =
    run { n = 400000, acc = 0 }
