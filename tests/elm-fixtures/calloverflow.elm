module CallOverflow exposing (deep, main)

-- NON-TAIL recursion driven PAST the VM's call-frame cap (CALL_STACK_DEPTH =
-- 65536, vendor/osier-rt/src/gc/types.zig:205).  This fixture pins the VM's
-- OUT-OF-FRAMES failure MODE, not a value: a user must never get a wrong
-- answer with a success status.
--
-- SHAPE.  `n + deep (n - 1)` is the same shape as
-- tools/bench/suite/deepnontail.elm: the addition happens AFTER the recursive
-- call, so every frame stays live all the way down and no accumulator can be
-- introduced without changing what is under test.  `deep` is a genuine
-- recur (OP_APPLY pushing a CallFrame per level), not a tail call — that is
-- what the DEPTH argument decides, so the caller (run-elm-gate.sh, check kind
-- `runfail`) passes CALL_STACK_DEPTH + a margin read from the constant
-- itself, instead of baking in a depth that would silently stop exercising
-- the cap if the cap ever moves.
--
-- WHAT `deep` MUST BE ABLE TO RETURN, AND WHAT IT MUST NOT.  The depth this
-- fixture is run at is deliberately past the cap, so there is NO correct
-- answer to compare against: the ONLY legal outcomes are a LOUD failure.  The
-- failure had to stop being silent measure: before the fix the VM printed a
-- value that is not the answer, wrote nothing to stderr and exited 0.  The
-- heap is set by the check (ELMC_HEAP_MB=2048): the frame cap must be reached
-- BEFORE the heap runs out, or the run aborts in grow_heap instead, which is
-- a DIFFERENT failure and would make this row vacuous.
--
-- `main` takes the depth from argv so the check owns the number; the `deep`
-- entry stays callable by hand at a legal depth (deep 1000 == 500500) as the
-- control that the same source is fine below the cap.


deep : Int -> Int
deep n =
    if n <= 0 then
        0

    else
        n + deep (n - 1)


main : Int -> Int
main n =
    deep n
