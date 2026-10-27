module Recget exposing (main)

-- THE RECORD FAMILY, CLASS 2: READ (perf word-arm-records R3).
--
-- Three read ROUTES, because they are three different code paths and only one
-- of them calls the runtime:
--   * WALK  — the record expression is not a closed Var, so `rank` is Nothing
--             and `recordAccessBody` falls to `Rt.recGet`, whose word splice
--             reads the names base from the record's LAST body word and bounds
--             by `veclen - 1`;
--   * POSITIONAL — a closed, Var-based row reads `data[rank]` with no call at
--             all (NAMES LAST is what makes that read need no arm fork);
--   * PATTERN — a `{ x, y }` bind is `VField`, which routes through the SAME
--             access body as a `.field` read.
-- Each is read for a HEAP-string field AND an immediate one: a stride error
-- then shows up as the WRONG ELEMENT (a pointer-shaped number, or a string
-- where a count belongs) rather than as the right one by luck.
--
-- WHAT THIS ROW CAN AND CANNOT SEE (MEASURED, both by mutation):
--   * the names BASE is observable — reading it at `veclen(rec)` instead of
--     `veclen(rec) - 1` SEGFAULTS the word arm here (exit 139 vs 0);
--   * the names BOUND (`i >= veclen - 1` vs `i >= veclen`) is NOT — a PRESENT
--     field is always found before the walk reaches the bound, and an ABSENT
--     field cannot be written: `getZ r = r.z` applied to `{ x = 1 }` is
--     `err type error at 7:5: missing field z`.  So the halt arm behind that
--     bound is UNREACHABLE from the surface, and the bound is pinned at the
--     SOURCE level (TestMain's `Rt.recGetGo` both-splices row) — stated rather
--     than left as an implied coverage claim.

walkNum =
    { x = 1, y = 2 }.y

walkStr =
    { x = 1, y = "hi" }.y

positional =
    let
        p =
            { x = 3, y = "yo" }
    in
    p.y

callRead =
    (mk 7 8).y

mk a b =
    { x = a, y = b }

sumP { x, y } =
    x * 10 + y

pat =
    sumP { x = 5, y = 6 }

main =
    { a = walkNum, b = walkStr, c = positional, d = callRead, e = pat }
