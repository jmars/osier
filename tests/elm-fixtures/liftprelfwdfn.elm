module LiftPrelFwdFn exposing (main)

-- FORWARD REFERENCE TO A PRELUDE-NAMED SIBLING BETWEEN TWO FUNCTIONS (the
-- discriminating companion of liftpreludefwd, whose value-member shape is
-- ALSO caught by the cyclic-value refusal and so cannot pin the outer-name
-- table on its own).
-- Sequential truth: at h's position the later `identity` is not bound, so it
-- resolves to Prelude.identity (identity n = n):
--   h 0 = x = 7;  h 1 = identity 0 + 1000 = 1000;  h 2 = identity 1 + 1000 = 1001
--   local identity 2 = h 1 = 1000 (the final expression reads the LOCAL one).
-- HEAD arm (pre-lift compiler, /tmp/headcomp): COMPILES -> 1000.
-- AFTER (this pass): 1000 (unchanged).
-- MUTANT KILLED: a forward-reference veto that consults a hand-rolled name
-- list instead of the checker's own table (round 3's hole) fabricates the
-- h <-> identity cycle here and prints 1007; likewise dropping the veto.
-- DISCOVERED WHILE AUDITING liftpreludefwd: that fixture's 0-arg member makes
-- the cyclic-value refusal mask the same mutant, so this one is the pin.
-- MEASURED MUTANT AUDIT: M1 (no forward veto) -> 1007 (KILLED); M6 (own-decls-
-- only outerNames, round 3's hole) -> 1007 (KILLED); round-4 tree -> diverges
-- (KILLED); M2/M3/M4c/M7 -> 1000 (NOT killed, by design: they touch other
-- mechanisms).

f x =
    let
        h k =
            if k <= 0 then
                x

            else
                identity (k - 1) + 1000

        identity k =
            if k <= 0 then
                x

            else
                h (k - 1)
    in
    identity 2


main =
    f 7
