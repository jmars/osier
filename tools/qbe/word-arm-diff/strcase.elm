module M exposing (main)

-- TWO `payload32` READS IN ONE DEFUN (perf word-arm-surface).
--
-- A string-literal `case` alternative lowers to the REAL `=` primitive
-- (`Rt.=`), whose byte compare reads `payload32` of the string length — and the
-- case body reads it again.  `wordPayloadField32`'s fixnum arm allocated its
-- `w` temp in a `let` whose state it then DISCARDED, so the second read in the
-- same defun was handed the SAME temp number; because that arm defines it `l`
-- (`sar`) and then `w` (`and`), qbe rejected the whole module with "invalid
-- type for first operand %t250 in and".  One `payload32` per defun never showed
-- it — every fixture in this row had at most one.
--
-- Both alternatives are exercised (`"hi"` matches, `"no"` falls to `_`) so the
-- compare is taken in both directions, and the result is a tuple so the two
-- answers are compared as output rather than as exit code.  Both arms must
-- print `[cons "matched" . "other"]`.
f s =
    case s of
        "hi" ->
            "matched"

        _ ->
            "other"


main =
    ( f "hi", f "no" )
