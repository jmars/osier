module Ffiw64Main exposing (main)

-- cffi U2 — the DRIVER for the width pair's `i64` arm.  See ffiw-i32.elm;
-- the only difference between the two arms is the declared result width in
-- the `.mid` beside them.
--
-- Golden: `false` (no extension, so `access`'s 32-bit `-1` reads as the
-- positive 4294967295).
main =
    Ffwi64.neg 0
