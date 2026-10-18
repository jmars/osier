module FfisMain exposing (main)

-- cffi U4 — the DRIVER for the `snprintf` arm.  The golden `"1-2"` is the two
-- variadic arguments (1, 2) formatted by the fixed ones (buf, 32, "%d-%d"); the
-- string's LENGTH is the `i32` return, so the `w` result and its `extsw` are in
-- it too.
main =
    Ffis.fmt 0
