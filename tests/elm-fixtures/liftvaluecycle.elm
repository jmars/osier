module LiftValueCycle exposing (main)

-- CYCLIC VALUE (a cycle through a 0-arg member): both members are VALUE
-- bindings, and `h` forward-references the later `v`.  A cycle through a value
-- is a cyclic DEFINITION -- real Elm rejects it ('CYCLIC DEFINITION'), and the
-- substrate rejects it as 'unknown name: v' (the name has no outer binding).
-- The pass must NOT lift it: the group is left untouched, so the checker
-- rejects LOUDLY at compile time (fast, no divergence).
-- HEAD arm (pre-lift compiler, /tmp/headcomp): REJECTED --
--   'type error at 23:13: unknown name: v'.
-- AFTER (this pass): BYTE-IDENTICAL rejection -- the group is not lifted.
-- MUTANT KILLED: an implementation without the cyclic-value refusal lifts the
-- group and diverges or prints nonsense (the round-4 tree ran this shape to a
-- GC heap panic).  The pinned substring is the source name, so a lifted
-- mutant that instead fails on a synthetic name cannot pass this check.
-- MEASURED MUTANT AUDIT: M2 (FIX 2 disabled) -> prints a corrupt value, not an
-- error (KILLED); M1/M3/M4/M4b/M4c/M5/M6/M7 -> the same 'unknown name: v'
-- (NOT killed, by design).

f x =
    let
        h =
            v + 1

        v =
            h + 1
    in
    v


main =
    f 5
