module DeepNonTail exposing (main, once)

-- SHAPE: deepnontail -- NON-tail recursion whose depth IS the workload.
--
-- `n + depth (n - 1)`: the addition happens AFTER the recursive call, so every
-- frame stays live all the way down.  Nothing can turn this into a loop, and
-- no accumulator can be introduced without changing the shape under test.
--
-- WHAT THIS MEASURES, AND WHY `main` STAYS AT DEPTH 50000.  The native path
-- has NO depth guard for non-tail recursion -- docs/qbe-backend.md, "What the
-- next stage must settle" item 1: "What remains is a native-depth guard for
-- NON-tail deep recursion (the AOT's nat_depth cap, which falls back to the
-- interpreter), still out of scope".  Measured here (the two backends fail in
-- OPPOSITE places, and the VM's failure is silent):
--
--   depth      elmvm (VM)                            QBE native
--   50000      1250025000  correct                   1250025000  correct
--   65525      correct AT ELMC_HEAP_MB>=2048; at this  -- (not run)
--              suite's 512MB the same run dies rc=134
--              in grow_heap (heap, not the frame cap)
--   65526      <prints a garbage lambda struct>      -- (not run)
--   65536      <same garbage>                        2147516416  correct
--   100000     <same garbage>                        5000050000  correct
--   200000     (not run)                             SIGSEGV / core dump
--
--   * the VM is WRONG from a few frames BELOW its cap, not at it: through the
--     `main` entry the FIRST BAD depth is 65526, and 65525 is still correct
--     with a large enough heap (measured at ELMC_HEAP_MB=2048 and 4096; at
--     512MB that same run is heap-bound and aborts rc=134, which is a
--     different failure).  The probe's own main/rounds/apply frames are on
--     the stack, so the exact edge moves with the entry path -- a rounds-1
--     probe stays correct to 65534.
--     Exit 0, empty stderr, a printed value that is not the answer.  The
--     cap is vendor/zinc-vm/src/gc/types.zig:205
--     `CALL_STACK_DEPTH = 65536`, and its guard is a SILENT break out of
--     the run loop -- vendor/zinc-vm/src/vm/interp.zig:873:
--     `if (frames_sp >= types.CALL_STACK_DEPTH) break :run;` (faithfully
--     ported from C:3296) -- which leaves whatever `acc` holds as the
--     result.  (Re-probing near the edge at this suite's 512 MB heap
--     confounds the measurement: 10 x these depths also outgrow the heap;
--     probe with a larger ELMC_HEAP_MB.)
--   * the native path is correct well past that and dies on the real C stack
--     instead, which is the documented missing guard.
--
--   SUPERSEDED 2026-10-09 (handoff osier-vmdepth, follow-up osier-vmfollowup):
--   the VM bullet above is HISTORY -- the boundary transcript stays as
--   measured.  The VM no longer fails SILENTLY: the CALL_STACK_DEPTH guard in
--   vendor/zinc-vm/src/vm/interp.zig (formerly the `break :run` at :873) now
--   uses the VM's own fatal idiom (std.debug.panic) -- exit status 134, a
--   `fatal: call stack depth exceeded` diagnostic on stderr, empty stdout.
--   Evidence: the `calloverflow` check in tests/elm-fixtures/run-elm-gate.sh
--   (kind `depth`), which asserts exactly that: non-zero exit, the named
--   diagnostic on stderr, NO value on stdout.  The native SIGSEGV at 200000
--   (above) is unchanged and still unreported.
--
-- A benchmark whose two backends disagree is not a measurement, so
-- tools/osier-bench.sh cross-checks the two outputs and fails the row on a
-- mismatch.  `main` therefore uses a depth that is correct on BOTH backends
-- and is the workload (10 x 50000 = 500000 live frames per run); the boundary
-- transcript above is the finding, not the timed row.
--
-- The `once` entry is the per-call unit for vmbench, not the depth probe.


depth : Int -> Int
depth n =
    if n <= 0 then
        0

    else
        n + depth (n - 1)


rounds : Int -> Int
rounds k =
    if k <= 0 then
        0

    else
        depth 50000 + rounds (k - 1)


once : Int -> Int
once n =
    depth n


main : Int
main =
    rounds 10
