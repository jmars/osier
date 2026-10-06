module LiftCapConfl2 exposing (main)

-- CAPTURE CONFLATION through a DESTRUCTURING sibling (the round-3 blocker, a8
-- shape): the colliding name is bound by a `let ( t, u ) = ...` declaration.
-- Sequential truth: even's `t` is a FORWARD reference over the destructuring,
-- so it resolves to the enclosing PARAM 50 -> even's base = 51; odd's `t` is a
-- BACKWARD reference to the destructured sibling 900 -> odd's base = 902.
-- The trace hits even's base: odd 5 -> even 4 -> odd 3 -> even 2 -> odd 1 ->
-- even 0 = 50 + 1 = 51.
-- HEAD arm (pre-lift compiler, /tmp/headcomp): REJECTED --
--   'type error at 26:17: unknown name: odd'.
-- AFTER (this pass): 51.
-- Hand-hoisted HEAD oracle (/tmp/lr3/src/a8h.elm, threading 900 into oddL and
-- 50 into evenL): 51.  Before this fixture the pass printed 901.
-- MEASURED MUTANT AUDIT: round-4 tree -> 901 (KILLED); M5 (slot placed at the
-- sibling) -> error (KILLED); M4c (one slot per NAME, matched by name) -> 51
-- (NOT killed: like liftcapconfl, the entry reaches even's base = the
-- parameter; the destructuring SIBLING slot is pinned by liftstaycall).

f t =
    let
        even k =
            if k <= 0 then
                t + 1
            else
                odd (k - 1)

        ( t, u ) =
            ( 900, 1 )

        odd k =
            if k <= 0 then
                t + 2
            else
                even (k - 1)
    in
    odd 5


main =
    f 50
