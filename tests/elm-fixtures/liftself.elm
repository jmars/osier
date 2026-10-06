module LiftSelf exposing (main)

-- A SELF-recursive LOCAL helper that CAPTURES an enclosing parameter (n)
-- and folds an accumulator over a list.  Sequential-only `let` rejects the
-- self-reference; the lift turns it into a top-level helper with the capture
-- threaded as a leading argument.

sumWith n xs =
    let
        go acc rest =
            case rest of
                y :: ys ->
                    go (acc + y + n) ys

                [] ->
                    acc
    in
    go 0 xs


main =
    sumWith 100 [ 1, 2, 3, 4, 5 ]
