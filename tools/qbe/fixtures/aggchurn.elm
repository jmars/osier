module AggChurn exposing (main)

-- A ListLit whose ELEMENTS are each large lists, so building element 2+
-- allocates ~2.6MB while element 1 is already live in a rooted slot: the
-- moving collector runs DURING the outer list's construction (the brief's
-- "long list that forces collection mid-construction" hazard).  Under the
-- check script's CHURN_MB=16 the 8MB nursery is crossed mid-build, so the
-- rooted elements and the accumulator must survive scavenges.  The result is
-- the sum of the four heads (4), a small observable that a stale pointer
-- would change.
-- `build` is TAIL-recursive (constant VM/native stack) so the GC pressure is
-- all allocation, not 4 x 30000-deep frames.

build : Int -> List Int -> List Int
build n acc =
    if n == 0 then
        acc

    else
        build (n - 1) (n :: acc)


headOf : List Int -> Int
headOf l =
    case l of
        x :: _ ->
            x

        [] ->
            0


main =
    case
        [ build 30000 [], build 30000 [], build 30000 [], build 30000 [] ]
    of
        a :: b :: c :: d :: _ ->
            headOf a + headOf b + headOf c + headOf d

        _ ->
            0
