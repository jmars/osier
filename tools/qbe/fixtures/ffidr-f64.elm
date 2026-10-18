module FfidrMain exposing (main)

-- cffi U3 — the DRIVER for the `f64`-RESULT fixture.  It prints the float val
-- `mkflt(rawcall atof(..))` builds, so the golden (`2.5`) is the value that
-- crossed the boundary in an `xmm` register.
main =
    Ffidr.run 0
