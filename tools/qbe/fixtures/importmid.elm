module ImportMid exposing (main)

-- M4: the WORKED END-TO-END EXAMPLE — this Osier module imports a mid-c module
-- BY NAME (`import Midmath`) and calls its exported defun by qualified name.
-- The reader (run.js / NativeMain) resolves the import to Midmath.mid, next to
-- THIS file; the .mid is NOT passed on the command line.  `main` prints the
-- boxed sum Midmath.answer built in its raw-word lane: 6 + 7 + 1 = 14.
import Midmath

main =
    Midmath.answer 6 7
