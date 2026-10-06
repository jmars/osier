module LiftPreludeFwd exposing (main)

-- FORWARD REFERENCE TO A PRELUDE-NAMED SIBLING (b11 shape): the colliding name
-- is a PRELUDE name (`identity`), and the reference is FORWARD.
-- Sequential truth: at `h`'s position `identity` is not yet bound, so it
-- resolves to Prelude.identity -> h = identity 1 = 1; the local `identity 0`
-- is then h + 1 = 2.
-- HEAD arm (pre-lift compiler, /tmp/headcomp): COMPILES -> 2.
-- AFTER (this pass): 2 (unchanged); the round-4 pass diverged (heap panic).
-- MUTANTS KILLED: a hand-rolled outerNames list that forgets the Prelude table
-- (round 3's hole) fabricates a cycle here and diverges (heap exhaustion);
-- likewise any rule that only consults the file's own declarations.
-- CONTRAST: liftprelude.elm pins the SELF-reference case, where the local name
-- DOES shadow Prelude.identity (7).
-- MEASURED MUTANT AUDIT: round-4 tree -> diverges (KILLED); M1 (no forward
-- veto) -> 2 (NOT killed) and M6 (own-decls-only outerNames) -> 2 (NOT
-- killed): this fixture's 0-arg member makes the CYCLIC-VALUE refusal mask
-- both.  It is still a real pin against the round-4 behaviour (which had
-- neither mechanism), and liftprelfwdfn.elm is the fixture that kills M1/M6
-- on the Prelude table alone.

f x =
    let
        h =
            identity 1

        identity k =
            h + 1
    in
    identity 0


main =
    f 5
