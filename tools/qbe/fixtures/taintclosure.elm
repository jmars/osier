module Taintclosure exposing (main)

-- contract 4, via a returned closure's captures: main returns a lambda that
-- CAPTURES tainted `t`.  REJECT.

import Tainty

main =
    let
        t =
            Tainty.make 1
    in
    \y -> t
