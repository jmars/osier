module LiftModFwd exposing (main)

-- FORWARD REFERENCE TO A MODULE-NAMED SIBLING (round-3 blocker 2, b13 shape):
-- `h` forward-references a LATER sibling whose name also exists at module
-- level.  The substrate resolves it OUTWARD (sequential reading): h m =
-- top-level helper m = 999.  Lifting would fabricate a mutual cycle and print
-- 5000.
-- HEAD arm (pre-lift compiler, /tmp/headcomp): COMPILES -> 999.
-- AFTER (this pass): 999 (unchanged); the round-4 pass printed 5000.
-- DELIBERATE DIVERGENCE FROM TRUE ELM (documented in the pass docstring): real
-- Elm's letrec would make the local `helper` shadow the top-level one and
-- print 5000.  The pass keeps the SUBSTRATE's sequential answer (999) because
-- it must not change the meaning of a program that already compiles.
-- MUTANTS KILLED: the round-4 edge rule (module names never block an edge) ->
-- 5000; any rule that keys the forward-reference veto on nothing.
-- MEASURED MUTANT AUDIT: round-4 tree -> 5000 (KILLED); M1 (no forward veto)
-- -> 5000 (KILLED); M6 (own-decls-only outerNames) -> 999 (NOT killed -- the
-- colliding name is the file's own top-level decl; liftprelfwdfn.elm is the
-- pin for that hole); M3/M4/M4c -> 999 (NOT killed).

helper : Int -> Int
helper k =
    999


f x =
    let
        h m =
            helper m

        helper k =
            if k > 0 then
                h (k - 1)

            else
                5000
    in
    helper 1


main =
    f 5
