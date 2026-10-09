module NumLoop exposing (main, once)

-- SHAPE: numloop -- an integer loop with a GENUINE LOOP-INVARIANT computation
-- inside the body.
--
-- `inv` is loop-invariant: it is not touched by the recursive call, so every
-- iteration recomputes `k = inv * 3 + 7` and `j = k * k + inv` from scratch.
-- Removing them is exactly what loop-invariant code motion does.
--
-- CORPUS GAP FILLED: there is NO loop optimisation anywhere in this stack --
-- QBE's `fillloop` only computes loop depth for register-allocation cost, and
-- Mid has no loop pass at all.  The corpus has no numeric loops, so nothing
-- has ever measured whether one is worth having.  `inv` is a parameter (not a
-- literal) so the recomputation cannot be constant-folded away.


loop : Int -> Int -> Int -> Int
loop n inv acc =
    if n <= 0 then
        acc

    else
        let
            k =
                inv * 3 + 7

            j =
                k * k + inv
        in
        loop (n - 1) inv (acc + j)


once : Int -> Int
once inv =
    let
        k =
            inv * 3 + 7
    in
    k * k + inv


main : Int
main =
    loop 1000000 17 0
