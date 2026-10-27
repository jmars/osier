module M exposing (main)

-- `==` ON RECORDS — THE FIXTURE THAT WAS UNWRITABLE UNTIL `=` WAS PORTED
-- (perf word-arm-records R4, blocked on perf word-arm-arith).
--
-- `Rt.recEqGo` shipped in word-arm-records R2 and `Rt.recGetGo`'s length
-- splice with it, and BOTH were CORRECT BUT UNEXECUTED: the `=` prim's inline
-- tag/payload arm was AREA 2/4, so a program that compared two records refused
-- to compile and nothing ever entered the deep-equality path on this arm.  This
-- fixture is the loop closing: the same three comparisons run on both
-- representations and must print the same bytes.
--
-- WHAT IT EXERCISES, and why each case is here:
--   * EQUAL records — `Rt.=` -> `Rt.deepEq` -> its `tagis(a, 14) && tagis(bb,
--     14)` arm -> `Rt.recEqGo`, which walks the DATA words against the
--     `veclen - 1` bound (the names word is not a field).  A wrong bound reads
--     the names pointer as a value; a wrong stride reads the wrong field.
--   * UNEQUAL records, differing in the SECOND field — so a walk that stopped
--     after one word would answer true.
--   * UNEQUAL records, differing in the SECOND field's BYTES — a heap STRING
--     field, so the comparison recurses into `Rt.deepEq`'s string arm and a
--     pointer compare instead of a byte compare would answer true.
--   * A record compared against ITSELF through the same function, so the
--     argument path (a record value crossing a call as one word) is covered
--     too.
--
-- THE NAMES ARRAYS ARE DELIBERATELY NOT COMPARED, and this fixture is why that
-- is the right decision rather than a shortcut: `{ x = 1, y = "hi" }` written
-- twice compiles to the SAME static content-keyed names blob (so a names
-- compare would answer true here by luck), while an appended record's names
-- array is a runtime-built one — equality must not depend on provenance.
eq a b =
    a == b


main =
    ( eq { x = 1, y = "hi" } { x = 1, y = "hi" }
    , eq { x = 1, y = "hi" } { x = 2, y = "hi" }
    , eq { x = 1, y = "hi" } { x = 1, y = "bye" }
    )
