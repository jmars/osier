module ImportMis exposing (main)

-- M4 (goal 1): the LOUD header-mismatch fixture.  `import Mismatch` resolves
-- to Mismatch.mid (this file's directory); that .mid declares `module
-- Othername`, so the reader refuses loudly: the import name and the .mid's
-- module header disagree.
import Mismatch

main =
    Mismatch.answer 6 7
