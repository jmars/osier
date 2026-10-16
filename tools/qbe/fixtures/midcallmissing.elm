module MidCallMissing exposing (main)

-- M3fix-4 (b): the emit-level INVERSE of the user-mid cross-module row.  This
-- Osier module reaches the .mid defun `MissingTarget.bad` (midcallmissing.mid)
-- by qualified name; that defun `call`s an EXPORTED runtime key.  Run with
-- QBE_NOMIDRT=1 the key has no defun in the program, so the compile must be
-- refused loudly (see the row's comment in qbe-check.sh).
main =
    MissingTarget.bad 0
