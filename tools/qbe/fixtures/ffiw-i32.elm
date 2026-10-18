module Ffiw32Main exposing (main)

-- cffi U2 — the DRIVER for the width pair's `i32` arm.  The load-bearing
-- code is in ffiw-i32.mid (the declared `access` extern); this module only
-- runs it and hands the resulting BOOLEAN to the runtime's printer, so the
-- golden is `true` or `false` and nothing else.
--
-- The group is (this file, ffiw-i32.mid): qbe-check.sh's `run_midshape` row
-- compiles both together, runs `Ffiw32Main.main`, and then pins the EMITTED
-- .ssa shape (`=w call $access` followed by an `extsw` of that temp).
main =
    Ffwi32.neg 0
