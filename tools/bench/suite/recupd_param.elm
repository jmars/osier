module RecUpdParam exposing (main, once)

-- SHAPE: recupd_param -- `{ r | f = v }` whose base `r` is a PARAMETER.
--
-- The contrast case to recupd_local: the base arrives from outside, so its
-- components are not known locally and Flatten cannot delete the object --
-- the update has to rebuild the assoc-list representation.  This is the
-- shape the corpus has 459 of, and it is here so the mix is honest about
-- what already works.
--
-- CORPUS CONTEXT: this shape is exactly what the compiler's own corpus is
-- made of (docs/qbe-backend.md: "Records here flow in as parameters and out
-- as results").


type alias St =
    { n : Int, acc : Int }


step : St -> St
step s =
    { s | n = s.n - 1, acc = s.acc + s.n }


run : Int -> St -> Int
run k s =
    if k <= 0 then
        s.acc

    else
        run (k - 1) (step s)


once : Int -> Int
once n =
    (step { n = n, acc = 0 }).acc


main : Int
main =
    run 400000 { n = 400000, acc = 0 }
