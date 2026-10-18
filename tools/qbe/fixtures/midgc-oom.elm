module MidgcOom exposing (main)

-- perf-gc1 FOLLOW-UP — THE OVERSIZED SINGLE REQUEST (the class-table bound).
--
-- The Mid collector's free lists are indexed by a size CLASS derived from the
-- requested total (`Rt.gcAlloc`: cls = classOf(total), for ANY count), and the
-- table has numClasses = 1 + classOf(heapWords) entries — it only covers
-- requests that can FIT the heap.  Before the fix `Rt.gcAllocGo` indexed it
-- with the class of ANY request and had no bounds check, so a single request
-- larger than the whole heap loaded (and, once the word past the table was
-- nonzero, STORED) past the end of the table: silent corruption in the general
-- case — the pop arm's wstore(head, -2/-1) rewrites a live block's flags/count
-- and hands its body to the caller — and a crash when that word happened to be
-- a small block header.
--
-- THIS FIXTURE CONSTRUCTS the boundary request.  `warm` (200 cons cells) makes
-- the heap's FIRST block real, so the word just past the table is a live block
-- header rather than a zero.  Then ONE allocation of 419840 vector slots —
-- 2 + 5 * 419840 = 2097502 words, MORE than a 16 MB heap's 2097152-word
-- capacity — whose class index is exactly numClasses.  The arithmetic, taken
-- from the runtime's own formulas (runtime.mid: Rt.gcInit / Rt.gcAlloc /
-- classOf):
--
--     maxTotal   = heapBytes / 8                    = 2097152   (16 MB)
--     numClasses = 1 + classOf(maxTotal)            = 1024
--     total      = 2 + count + 4 * count  (kind 1)  = 2097502   (count 419840)
--     classOf(total)                                = 1024  == numClasses
--
--   * AFTER the fix (gcAllocGo returns 0 for cls >= numClasses) the request
--     funnels into Rt.gcAlloc's bump path, whose `cursor + phys * 8 < heapEnd`
--     test cannot pass, so collect -> retry (0 again) -> the loud
--     `qbe-rt: midgc: out of memory` die (exit 1).  At QBE_HEAP_MB=32 the SAME
--     request FITS (class 1024 < numClasses 1537) and the program completes
--     and prints 200 — the dying is caused by the request EXCEEDING the heap,
--     not by its size as such, and the guard does not refuse a request that
--     fits.
--   * BEFORE the fix the same run SIGSEGVs: table[numClasses] is the first
--     block's FLAGS word (kind * 2 + cls * 4 — small, nonzero), which the pop
--     arm then dereferences as a pointer.
--
-- Both arms are scripted (MEASURED) in tools/qbe/probe-midgc-oom.sh.
--
-- `vectorMake` is the JsArray substitute's own name for the vector-make prim
-- (core-libs/JsArray.elm: `vectorMake n` is a fresh n-slot VM vector — the
-- wrapper global `absvector.curried`), and it is the only surface route to a
-- SINGLE allocation this large: the string prims build byte cons lists (5
-- words per byte, so a 16 MB string needs 640 MB of cells), and every
-- Array.elm call site caps a JsArray at 33 slots.


build : Int -> List Int
build n =
    if n <= 0 then
        []
    else
        n :: build (n - 1)


main =
    let
        warm =
            build 200

        _ =
            vectorMake 419840
    in
    List.length warm
