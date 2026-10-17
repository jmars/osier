module Tainttrans exposing (main)

-- contract 4, transitive (the fixpoint row): helper's RESULT is tainted, and
-- main returns helper's result — resultTaint(helper) must propagate.  REJECT.

import Tainty

helper x =
    Tainty.make x

main =
    helper 1
