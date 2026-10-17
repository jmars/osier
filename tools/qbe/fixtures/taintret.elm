module Taintret exposing (main)

-- contract 4, DIRECT violation: main's result IS the mid result.  REJECT.

import Tainty

main =
    Tainty.make 1
