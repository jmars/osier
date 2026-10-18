module FfidMain exposing (main)

-- cffi U3 — the DRIVER for the `f64` fixture.  The boundary is crossed inside
-- ffid-f64.mid (the declared `strfromd`); this module only prints the string
-- val that call produced, so the golden is `"1.50"` and nothing else — the
-- `i32` return (the length) and the `f64` argument (the 1.50) are both in it.
main =
    Ffid.fmt 0
