module LiftStayCall exposing (main)

-- A STAYING (value) sibling calls a lifted member whose snapshots ALL PRECEDE
-- it.  Same name-collision shape as liftcapconfl: `t` is the parameter at a's
-- position and the sibling 700 at b's position.
-- Sequential truth: b 2 -> a 1 -> b 0 -> b's t = the SIBLING 700 -> 700 + 2 =
-- 702.  The snapshot for the sibling binding is declared (and therefore
-- visible) before the staying declaration `s`.
-- HEAD arm (pre-lift compiler, /tmp/headcomp): REJECTED --
--   'type error at 27:17: unknown name: b'.
-- AFTER (this pass): 702.
-- MUTANTS KILLED: R2 implemented as a blanket refusal of any staying-decl call
-- (this fixture legitimately lifts); snapshots emitted after ALL declarations
-- or not at all (then `t$snap...` is unresolvable -> 'unknown name: t$snap');
-- a capture set that threads the PARAMETER into b's base (prints 52).
-- MEASURED MUTANT AUDIT: M4c (one slot per NAME, the name-keyed model) -> 52
-- (KILLED by value -- this is the fixture that kills it, not liftcapconfl);
-- M4/M5 (slot placed at the enclosing binding / at the sibling) -> error
-- (KILLED); M1/M2/M3/M6/M7 -> 702 (NOT killed, by design).

f t =
    let
        a k =
            if k <= 0 then
                t + 1
            else
                b (k - 1)

        t =
            700

        b k =
            if k <= 0 then
                t + 2
            else
                a (k - 1)

        s =
            b 2
    in
    s


main =
    f 50
