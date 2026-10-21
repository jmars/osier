module ArgvRoot exposing (main, probe)

-- THE VALUES TABLE IS A ROOT — the ZIGHOST Z1 fail-before fixture.
--
-- `*argv*` is a Mid-heap cons chain built by Rt.argvInstall and published into
-- the values table (globals word 3).  Until Z1 that table was registered with
-- the ZIG collector ONLY (`registerValuesTable` — a no-op on this route since
-- Z0 retired the Zig heap), so NO Mid collection marked it: the chain was
-- reclaimed by any collection that ran between boot and the read.
--
-- WHY argvrepro DID NOT CATCH IT, stated plainly: it reads *argv* ONCE, and no
-- full collect fires in its window, so the list survives by promotion and
-- timing rather than by being rooted.  This fixture reads it TWICE, with a
-- churn that provably collects in between:
--
--     a = len (Runtime.argv ())        -- read 1, before any churn
--     go 400000 []                     -- ~19 MB of cons cells: scavenges AND
--                                      -- full collects at QBE_HEAP_MB=16
--     b = len (Runtime.argv ())        -- read 2, AFTER those collections
--
-- `probe` prints a*1000000 + b, so a reclaimed (or relocated-and-not-rewritten)
-- chain changes the ANSWER, not just the data: the fail-before signature is a
-- wrong number or the collector's own loud death walking a freed body.
--
-- The accumulator is rooted by the Mid frame machinery (a `val` binder in a
-- framed defun is a registered ROOT_VALUE_ARRAY slot), so the churn itself is
-- sound — the ONLY unrooted object in the program is the one under test.

len : List String -> Int
len l =
    case l of
        _ :: rest ->
            1 + len rest

        [] ->
            0


go : Int -> List Int -> Int
go n acc =
    if n == 0 then
        len (Runtime.argv ())

    else
        go (n - 1) (n :: acc)


probe : Int
probe =
    let
        a =
            len (Runtime.argv ())
    in
    a * 1000000 + go 400000 []


main =
    probe
