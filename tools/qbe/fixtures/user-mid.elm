module UserMidRun exposing (main)

-- M3: the FIRST user .mid end-to-end — this Osier module calls the mid-c
-- defun `UserMid.answer` (user-mid.mid) by qualified name.  The driver runs
-- `main`, which returns the boxed sum the mid function built.
main =
    UserMid.answer 6 7
