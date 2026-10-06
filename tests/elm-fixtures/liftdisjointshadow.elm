module LiftDisjointShadow exposing (main)

-- DISJOINT-CYCLE CENSUS (review5 BLOCKER A): the shadowing census must be
-- PER-SCC, not the union of all cycles in the block.  A fully-shadowing mutual
-- pair {even,odd} (both names top-level) sits beside an UNRELATED self-recursive
-- helper `zz2` that shadows nothing (its name has no outer binding).  The
-- round-5 planGroup censused the UNION {even,odd,zz2}, saw zz2 not in outerNames,
-- and dropped the relaxation for the whole block -> even/odd reverted to the
-- sequential reading (888).  Per-SCC, the pair's own cycle {even,odd} still
-- shadows, so it lifts independently.
--
-- Derivation: even/odd mutual, both shadow -> lift -> even 4 = 0.  zz2 is a
-- plain self-recursive helper (no outer name, so the veto never applies to it)
-- -> lifts on its own -> zz2 0 = 3.  Total = 0 + 3 = 3.
--
-- HEAD arm (pre-lift, /tmp/headcomp): REJECTED --
--   'type error at 37:17: unknown name: zz2' (sequential let cannot self-recurse).
--
-- MEASURED: HEAD err; round-5 (union census) 891 (= 888 + 3, the pair reverted
-- to the sequential reading); AFTER 3.
--
-- Control n26 (identical but zz2 NON-recursive) is 3 in both the round-5 and
-- round-6 trees -- proving the flip is caused solely by the union census, not by
-- zz2's presence.
--
-- MUTANTS KILLED: a census over the union of all block cycles (round-5 planGroup
-- -> 891); liftcycshadows pins the VALUE-sibling variant of the same instability
-- (an unrelated `zz = 42` VALUE beside a shadowing pair).  NOT killed: a mutant
-- whose census is per-cycle (this fixture's whole point).

even : Int -> Int
even k =
    777


odd : Int -> Int
odd k =
    888


f x =
    let
        even k =
            if k <= 0 then
                0

            else
                odd (k - 1)

        odd k =
            if k <= 0 then
                1

            else
                even (k - 1)

        zz2 k =
            if k <= 0 then
                3

            else
                zz2 (k - 1)
    in
    even 4 + zz2 0


main =
    f 5
