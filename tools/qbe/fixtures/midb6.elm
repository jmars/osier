module MidB6 exposing (main)

-- B6 (handoff-midlang-b6): THE WORKED EXAMPLE — plan Q7's derived ABI, a
-- struct parameter by value, and the raw-Var close, through the real pipeline.
-- `import Wsum` resolves to Wsum.mid next to this file.
--
--   tools/qbe/qbe-mk.sh tools/qbe/fixtures/midb6.elm MidB6.main <outdir>
--   <outdir>/midb6 MidB6.main
--
-- Expected stdout: 1126125010
--   = Wsum.add's result (1125) | a SECOND call's result (1125 — the callee's
--     entry copy is fresh) | the caller's g.p.x (10 — the callee's field
--     write did NOT escape).
--
-- THE OSIER SIDE CROSSES THROUGH THE EXPORT BLOCK exactly as before
-- (`export Wsum.run : val -> val`): the export block's grammar is unchanged
-- by B6 (val/float/word-opaque - a struct does not cross as a TYPE), so the
-- word-ABI defun is reached from a value-ABI `run` that Osier can call.  The
-- WORD ABI itself is exercised INSIDE the module, where the `.mid` is the
-- only thing that needs to know the register shape.
--
-- This pair is a SIBLING of midb2.elm/Wext.mid (1510150899) and
-- midb3.elm/Warr.mid (903091133), not an extension: both goldens stay their
-- own units' acceptance numbers, and a B6 regression cannot move them.
import Wsum

main =
    Wsum.run 5
