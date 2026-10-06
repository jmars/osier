module Shadowerr exposing (main)

-- NEGATIVE fixture pinning the import-shadowing compile error: `width` is
-- imported bare from Str AND defined top-level here.  This used to resolve
-- SILENTLY to the imported (wrong-typed) function.  Real Elm rejects the
-- clash; the compiler must fail LOUDLY with the shadowing error (never reach
-- typechecking/lowering).  (Re-pointed from Viewport.update/view to Str.width
-- in withe-split Phase 3: Viewport is a parked UI lib.)

import Str exposing (width)


width : Int -> Int
width n =
    n + 1000


main =
    width 1
