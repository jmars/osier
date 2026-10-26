module LapProbe exposing (main)

-- THE U2 LAP PROBE (handoff-apply-chain-u2-review BLOCKER 1; the row is
-- qbe-check.sh's `lap-apply`).  It pins the property that the F-site staging
-- block must be in NON-GC memory, and it FAILS on the allocvec version.
--
-- THE SHAPE.  `g` is arity 1 and is applied to TWO args in TAIL position, so
-- the site is lowerApp's over-applied GRef arm -> rtApply isTail ->
-- Rt.stage-apply + `tcall Rt.apply-tail`.  Hop 1 (rem > nargs) runs
-- `rt_call2r` — g's WHOLE BODY, which builds a ~12 MB list — and `recur`s;
-- hop 2 then reads the staged arg (32) through `sp->args`, an INTERIOR
-- pointer into the staged block.  So the window between staging and the
-- block's LAST READ CONTAINS USER CODE, and its allocation volume is
-- user-controlled.
--
-- WHY THAT MATTERS: with the block allocated by allocvec it is YOUNG, and the
-- kind-2 registration never promotes it (gcScavRoots walks the cells and never
-- calls gcScavPtr on the base) while gcScavenge resets youngCursor — so the
-- block's storage is reusable as soon as a scavenge ends, and the callee above
-- is exactly what laps the nursery.  MEASURED on 2f58bfe: "qbe-rt: midgc:
-- unknown value tag in mark walk", rc 1, at the DEFAULT 4 MB nursery, at
-- QBE_MIDGC_YOUNG_MB=1 and under QBE_MIDGC_VERIFY=1; with ONLY the site
-- reverted to the pre-U2 shape the same binary prints 300042.  It fails LOUDLY
-- here only because the usurping cells made an invalid tag — the same lap with
-- valid-looking Values is a SILENT wrong answer, which is why the row asserts
-- the VALUE and not just the exit code.
--
-- 300042 = 32 + 10 + 300000: the applied arg, g's first arg, and the list
-- length.  Any other number, or a non-zero exit, is the lap.

alloc n acc =
    if n <= 0 then
        acc
    else
        alloc (n - 1) (n :: acc)


g x =
    let
        big =
            alloc 300000 []

        s =
            Prelude.length big
    in
    \y -> y + x + s


main =
    g 10 32
