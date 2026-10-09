module ListBuild exposing (main, once)

-- SHAPE: listbuild -- a list built and then folded (a list pipeline).
--
-- Each round conses a 1000-element list and folds it: 1000 `cons` cells
-- allocated and 1000 `MCons`/`MEmpty` pattern tests walked, per round.  The
-- `cons` chain is the representation Flatten can only remove when the list
-- does not escape -- here it does (it is the argument of `total`), so this is
-- the honest "list work that stays on the heap" case.
--
-- CORPUS GAP FILLED: the corpus is a compiler; it has list-shaped data but no
-- tight build-then-fold pipeline whose cost is the allocation + traversal
-- itself.  Paired with localrec (where the aggregate does NOT escape) it
-- separates "the object goes away" from "the object is walked".


build : Int -> List Int -> List Int
build n acc =
    if n <= 0 then
        acc

    else
        build (n - 1) (n :: acc)


total : List Int -> Int -> Int
total xs acc =
    case xs of
        [] ->
            acc

        y :: ys ->
            total ys (acc + y)


round : Int -> Int -> Int
round k acc =
    if k <= 0 then
        acc

    else
        round (k - 1) (acc + total (build 1000 []) 0)


once : Int -> Int
once n =
    total (build n []) 0


main : Int
main =
    round 400 0
