module ImportBad exposing (main)

-- M4 (goal 2): the LOUD class-misuse fixture.  This Osier module imports
-- Midmath (resolved to Midmath.mid by the reader) and calls its `float -> val`
-- export `doubleIt` with a String — the declared type says Float, so the
-- compile must be REFUSED loudly (an Osier call is checked against the
-- DECLARED types, not just arity).
import Midmath

main =
    Midmath.doubleIt "hello"
