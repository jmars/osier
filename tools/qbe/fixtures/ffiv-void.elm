module FfivMain exposing (main)

-- cffi U3 — the DRIVER for the `void` fixture.  See ffiv-void.mid for why the
-- golden is only a smoke value: a `void` result has nothing to get wrong
-- behaviourally, and the load-bearing assertion is the emitted SHAPE
-- (qbe-check.sh's run_midshape row, empty extension op).
main =
    Ffiv.run 0
