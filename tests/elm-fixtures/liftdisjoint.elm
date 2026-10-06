module LiftDisjoint exposing (main)

-- TWO DISJOINT RECURSIVE CYCLES IN ONE BLOCK: { p, q } captures a0 and
-- { r, s } captures b0.  One block is one candidate group, so both cycles are
-- lifted together with the UNION snapshot set, and each member must keep its
-- OWN captures.
-- Sequential truth (both groups are genuine cycles with no outer-name
-- collision, so this is the pass's charter): p 2 -> q 1 -> p 0 -> base
-- a0 + 1 = 11; r 1 -> s 0 -> base b0 + 4 = 24; total 35.
-- HEAD arm (pre-lift compiler, /tmp/headcomp): REJECTED --
--   'type error at 27:17: unknown name: q'.
-- AFTER (this pass): 35.
-- MUTANTS KILLED: an implementation that lifts only ONE component (the second
-- cycle's reference stays ambiguous -> 'unknown name' or a wrong value); a
-- capture set built from the first component only (b0 unresolvable); a
-- per-component arity mismatch between a lifted body and its call sites.
-- MEASURED MUTANT AUDIT: M7 (lift only the first two cycle members) ->
-- 'unknown name: s' (KILLED); M5 (slot placed at the sibling) -> 'unknown
-- name: a0$snap0' (KILLED); M1/M2/M3/M4c/M6 -> 35 (NOT killed, by design).

f a0 b0 =
    let
        p k =
            if k <= 0 then
                a0 + 1
            else
                q (k - 1)

        q k =
            if k <= 0 then
                a0 + 2
            else
                p (k - 1)

        r k =
            if k <= 0 then
                b0 + 3
            else
                s (k - 1)

        s k =
            if k <= 0 then
                b0 + 4
            else
                r (k - 1)
    in
    (p 2) + (r 1)


main =
    f 10 20
