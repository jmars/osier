module LiftCapConfl exposing (main)

-- CAPTURE CONFLATION (the round-3 blocker): one source name denotes two
-- DIFFERENT bindings at two member positions.  `t` is the enclosing PARAMETER
-- at `a`'s position (the sibling `t` is declared later, so under the
-- substrate's sequential `let` it is not yet bound) and the SIBLING `t = 700`
-- at `b`'s position (declared before `b`, so it shadows the parameter).
-- Sequential truth: b 1 -> a 0 -> a's t = the PARAM 50 -> 50 + 1 = 51.
-- The non-recursive control (same file family, tools/withe-numbers + the
-- review's /tmp/lr3/src/c3.elm) proves the substrate's reading: a=51, b=52,
-- c=703 -> 806.
-- HEAD arm (pre-lift compiler, /tmp/headcomp): REJECTED --
--   'type error at 35:17: unknown name: b'.
-- AFTER (this pass): 51.  The round-4 pass printed 701 (b's call re-threaded
-- b's own capture value into a's slot).
-- MUTANTS KILLED: any implementation with ONE capture list per group (caller-
-- threaded captures; round-4 tree -> 701), or one slot per source NAME that
-- DROPS the distinct sibling slot (m4/m4b/m5: 'unknown name: t').  NOT killed:
-- m4c (name-keyed MATCHING -- the sibling conflated to the parameter) -- that
-- direction is pinned by liftstaycall (702 vs 52) and liftrefuse, not here.
-- ALSO DISCRIMINATING: an implementation that takes the SIBLING value for
-- a's `t` as well prints 703.
-- MEASURED MUTANT AUDIT: round-4 tree -> 701 (KILLED); M1 (no forward veto),
-- M2 (no cyclic-value refusal), M3 (no R2), M6 (own-decls-only outerNames),
-- M7 (lift only the first cycle) -> 51 (NOT killed); M5 (one slot per name
-- placed at the sibling) -> error (KILLED).  M4c (one slot per NAME) -> 51:
-- this fixture does NOT pin the slot KEY on its own because the entry `b 1`
-- reaches a's base (the parameter slot); liftstaycall.elm pins the sibling
-- slot's value (702 vs 52) and is what kills M4c.

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
    in
    b 1


main =
    f 50
