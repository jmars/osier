module FficMain exposing (main)

-- cffi U4 — the DRIVER for the `fcntl` arm.  INERT INPUT, NON-INERT CALL:
-- `F_GETFL` on stdout returns promptly however the call is lowered, so this
-- golden is a smoke value (does the program run end to end with a variadic
-- libc call in it) and the load-bearing assertion is the structural one in
-- qbe-check.sh.
main =
    Ffic.flags 0
