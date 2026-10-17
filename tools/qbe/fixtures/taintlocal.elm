module Taintlocal exposing (main)

-- contract 4, local use unrestricted: `t` is bound and used (discarded), but
-- the return is the clean 42.  STAY LEGAL.

import Tainty

main =
    let
        t =
            Tainty.make 1

        _ =
            t
    in
    42
