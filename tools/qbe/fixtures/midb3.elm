module MidB3 exposing (main)

-- B3 (handoff-midlang-b3): THE WORKED EXAMPLE — plan Q5's array surface
-- through the real pipeline.  `import Warr` resolves to Warr.mid next to
-- this file.
--
--   tools/qbe/qbe-mk.sh tools/qbe/fixtures/midb3.elm MidB3.main <outdir>
--   <outdir>/midb3 MidB3.main
--
-- Expected stdout: 903091133
--   = a[2](8) | Warr.bump's p[1](102) | m[2][1](109) | xs[0].tag(11) |
--     xs[1].inner.k(33)
--
-- This pair is a SIBLING of midb2.elm/Wext.mid (B2's struct-value example),
-- not an extension of it: that pair's golden (1510150899) stays the B2
-- acceptance number, and a B3 regression must not be able to move it.
-- It is NOT registered as a qbe-check.sh row (midb2.elm is not either): the
-- shapes it emits are pinned in TestMain's B3 section, and this pair is run
-- by hand through qbe-mk.sh.
import Warr

main =
    Warr.run 5
