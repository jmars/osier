module LiftRefuse exposing (main)

-- R2 REFUSAL (loud, never a silent wrong value): the staying VALUE sibling `s`
-- is declared BEFORE the sibling snapshot it would have to spell (the
-- snapshot of `t = 700` sits after declaration 2, `s` is declaration 0), so
-- the pass refuses the whole group and leaves the block untouched.  The
-- checker then rejects loudly, exactly as HEAD does (HEAD's own reason is the
-- forward reference itself).
-- HEAD arm (pre-lift compiler, /tmp/headcomp): REJECTED --
--   'type error at 26:13: unknown name: a'.
-- AFTER (this pass): BYTE-IDENTICAL rejection ('type error at 26:13: unknown
-- name: a') -- the refusal leaves the block exactly as HEAD sees it.
-- The pinned substring is a SOURCE name ('unknown name: a'), so a mutant that
-- lifts anyway and only then fails on a synthetic name ('unknown name:
-- t$snap...') cannot pass this check.
-- MUTANT KILLED: an implementation with no ordering check (it rewrites `s` to
-- a call spelling a not-yet-declared snapshot).
-- MEASURED MUTANT AUDIT: M3 (R2 disabled) -> 'unknown name: t$snap1'
-- (KILLED); M4c (name-keyed slots, which also drops the sibling slot the
-- refusal exists for) -> 52, i.e. it compiles (KILLED); M1/M2/M6/M7 -> the
-- same refusal (NOT killed, by design).

f t =
    let
        s =
            a 1

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
    s


main =
    f 50
