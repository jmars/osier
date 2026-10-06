module Shadowtyperr exposing (main)

-- NEGATIVE fixture pinning the TYPE-NAME half of the import-shadowing check:
-- `Array` is imported bare from Array AND declared here as a type alias (an
-- ADT `type Array = ..` behaves identically).  A bare exposing row hides the
-- local type exactly like it hides a same-named function — real Elm rejects
-- the clash; the compiler must fail LOUDLY before typechecking/lowering.
-- (Re-pointed from Spinner.Model to Array.Array in withe-split Phase 3:
-- Spinner is a parked UI lib.)

import Array exposing (Array)


type alias Array =
    { n : Int }


main =
    0
