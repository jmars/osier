module MidB4 exposing (main)

-- B4 (handoff-midlang-b4): THE WORKED EXAMPLE — plan Q6's loop surface
-- through the real pipeline.  `import Wloop` resolves to Wloop.mid next to
-- this file.
--
--   tools/qbe/qbe-mk.sh tools/qbe/fixtures/midb4.elm MidB4.main <outdir>
--   <outdir>/midb4 MidB4.main
--
-- Expected stdout: 15042106  (sum 15 | found 4 | oddSum 21 | tri 6)
--
-- This pair is a SIBLING of midb3.elm/Warr.mid (903091133) and
-- midb2.elm/Wext.mid (1510150899), not an extension of either: those two
-- goldens stay the earlier units' acceptance numbers, and a B4 regression
-- must not be able to move them (both are re-run and unchanged).
--
-- A .ssa structure pin is NOT a run: B6's self-copy bug emitted a plausible
-- .ssa and only RUNNING the program showed it.  These four numbers are the
-- run.
import Wloop

main =
    Wloop.run 5
