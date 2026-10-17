module Taintsafe exposing (main)

-- contract 4, the OWNER'S SAFE CASE: a mid result bound in a `let` and captured
-- by a self-recursive lambda that is INVOKED, not returned.  `t` sits in `go`'s
-- closure (captureTaint(go) = True) but `go`'s RESULT is the clean base case,
-- so `go 5` is untainted and main returns 42.  MUST STAY LEGAL (golden 42).

import Tainty

main =
    let
        t =
            Tainty.make 1

        go n =
            if n == 0 then
                42

            else
                let
                    _ =
                        t
                in
                go (n - 1)
    in
    go 5
