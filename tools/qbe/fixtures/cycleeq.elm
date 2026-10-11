module CycleEq exposing (main)

-- THE deepEqual CYCLE GUARD (handoff osier-midrt-fix, capture item 4).
--
-- values.zig:346 (deepEqual) carries a DEPTH COUNTER and answers FALSE once it
-- exceeds 1000 levels, precisely so a CYCLIC structure terminates instead of
-- recursing forever.  The Mid port (Mid.RtPrims' deepEq) has NO counter: its
-- header argues the guard is unnecessary because the fused-pair
-- representation cannot produce a cycle — TRUE for cons (a cell's cdr is fixed
-- at construction), FALSE for VECTORS, which are mutable and can be made to
-- contain themselves through the ordinary `address->` (vectorSet) alias.
--
-- MEASURED (this fixture, both routes):
--   * DEFAULT (Zig rt_prim `=`): prints `false` — the depth guard answers, the
--     program exits 0;
--   * QBE_MIDCONS=1 (Rt.= / Rt.deepEq / Rt.vecEq): the recursion walks the
--     cycle until the NATIVE STACK runs out — "qbe-rt: native stack depth
--     exceeded ... 64.0 MiB limit", exit 1.
--
-- WHY IT IS COMMITTED.  It is unreachable from any TYPED differential vector
-- (the self-reference needs the mutable-vector alias), so no generated batch
-- can cover it, and after the flip the Zig bodies that answer `false` are
-- deleted — this fixture plus qbe-check's cycle-eq rows are what keep the
-- change VISIBLE and LOUD instead of silent.  Post-flip this is a BEHAVIOUR
-- CHANGE for a program that builds a cyclic vector and compares it: today it
-- prints false, after the flip it dies.  It is not a wrong ANSWER (the Mid
-- side never returns a silently incorrect value), and it is deliberately
-- pinned rather than fixed — the fix is a depth parameter threaded through
-- Mid deepEq/vecEq/assocGo, which re-shapes Rt.='s helper ABI and belongs to
-- the flip, not to an evidence-fixing step.


-- A vector that CONTAINS ITSELF (slot 0 -> the vector).  `let` is sequential,
-- so the binding is visible inside its own initializer's argument list here.
mkcyc n =
    let
        v =
            vectorMake n
    in
    vectorSet v 0 v


main =
    (mkcyc 1) == (mkcyc 1)
