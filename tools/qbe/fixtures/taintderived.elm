module Taintderived exposing (main)

-- contract 4, a DERIVED value used locally and discarded: [t] is tainted (it
-- contains the mid result) but never reaches main's return.  STAY LEGAL.

import Tainty

main =
    let
        t =
            Tainty.make 1

        _ =
            [ t ]
    in
    42
