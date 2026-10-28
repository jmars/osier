module M exposing (main)

-- RECORD UPDATE (HIT PATH) ACROSS COLLECTIONS, ON THE WORD ARM (perf
-- word-arm-records H1 FIX).  The sibling of `rec.elm`, and the ladder rung for
-- the update family's own allocation window.
--
-- WHY IT IS A SEPARATE FIXTURE FROM `rec.elm`: `{ r | y <- i }` on an EXISTING
-- field HITs, so it never reaches `Rt.recAppend`/`recInsert` — it goes straight
-- to `Rt.recUpd`, which allocates ONE code-14 block through `Rt.allocRecord`
-- while holding `rec` (the base) and the new value across that call.  The
-- diagnosis measured this path green at 6000 iterations and SEGFAULTING at
-- 60000 at QBE_HEAP_MB=1: it allocates less per iteration, so the young trigger
-- is crossed later.  The iteration count here is 20000 and the rungs are the
-- full ladder for that reason.
--
-- WHAT IT PINS: `Rt.recUpd` must be classified ALLOCATING (`runtime.allocating`
-- via `allocSeatDeps`) so its frame is registered and `rec` is relocated when
-- `Rt.allocRecord`'s `gcAlloc` scavenges.  Before that fix its frame was an
-- unrooted `alloc8` and `rec` went stale — silently at default knobs, where no
-- scavenge runs.
--
-- OUTPUT is `examined/matched/mismatched`; expected 20000/20000/0 at every heap.
upd r i =
    { r | y <- i }


build i =
    upd { x = 1, y = 0 } i


buildAll i acc =
    if i == 0 then
        acc
    else
        buildAll (i - 1) (build i :: acc)


check xs i examined matched mismatched =
    case xs of
        [] ->
            String.append (String.fromInt examined)
                (String.append "/"
                    (String.append (String.fromInt matched) (String.append "/" (String.fromInt mismatched)))
                )

        r :: rest ->
            if r == build i then
                check rest (i + 1) (examined + 1) (matched + 1) mismatched
            else
                check rest (i + 1) (examined + 1) matched (mismatched + 1)


main =
    check (buildAll 20000 []) 1 0 0 0
