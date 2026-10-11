module ConsList exposing (a)

-- The cons-STRUCTURE-printing fixture (osier-consspike): unlike churn/flatten
-- whose printed RESULTS are numbers, this entry's result IS a nested list, so
-- the driver's printValue renders every cons cell the program built — a wrong
-- tag, a stale interior pointer or a mis-sized payload in ANY cons
-- implementation changes the printed bytes.  Run twice by the gate: once with
-- the default (Zig rt_prim_cons) route, once with QBE_MIDCONS=1 (every ::
-- below routes through the Mid-implemented Rt.cons) — the golden is frozen
-- from the DEFAULT build and the Mid row must match it byte-for-byte, the
-- in-gate twin of tools/qbe/consdiff/consdiff.sh's generated-vector
-- differential (this fixture is small, committed and readable; the fuzz
-- harness is the wide net).
--
-- MEASURED while sizing the rows: with a deliberately corrupted Rt.cons
-- (payload tag 4 -> 0), the churn/flatten goldens still passed (their printed
-- results never traverse a cons) while this fixture printed a pointer-sized
-- number — the row that can fail is the one worth freezing.


plain =
    1 :: [ 2, 3 ]


flts =
    [ 1.5, -2.25 ] :: [ [ 3.0 ] ]


strs =
    "head" :: [ "b", "" ]


bools =
    True :: [ False, True ]


nested =
    [ plain, [ 7 ] ] :: [ [ [ 1 ] ] ]


deep n =
    if n == 0 then
        []

    else
        n :: deep (n - 1)


a =
    { i = plain
    , f = flts
    , s = strs
    , b = bools
    , n = nested
    , d = deep 60
    }
