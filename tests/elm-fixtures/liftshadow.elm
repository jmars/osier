module LiftShadow exposing (main)

-- Capture-set correctness: `go` captures `n`, but its body ALSO has a
-- SHADOWING binder reusing the name `n` (the inner `let n = k`).  The free-
-- variable computation must be binder-aware: the recursive call `go (k - 1)`
-- inside the shadowed region must still thread the OUTER capture, not the
-- shadow.  Answer: 3 + 2 + 1 + 7 = 13.

shadow n =
    let
        go k =
            if k <= 0 then
                n
            else
                let
                    n =
                        k
                in
                n + go (k - 1)
    in
    go 3


main =
    shadow 7
