module Ffiw32uMain exposing (main)

-- cffi U2 — the DRIVER for the width family's `u32` arm.  Golden: `false`
-- (zero-extended 4294967295 is positive; a sign-extending lowering would
-- print `true`).
main =
    Ffwi32u.neg 0
