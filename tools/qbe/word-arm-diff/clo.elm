module M exposing (main)

-- THE FIRST HIGHER-ORDER PROGRAM ON THE WORD ARM (perf word-arm-closures).
--
-- Until this fixture the surface lane refused `Lam` and `GRef` at its
-- classifier, so no word-arm program could hold a function as a VALUE: every
-- call this arm had ever made was a saturated direct call to a known global.
-- That left the whole closure machinery — the capture array, the closure CELL,
-- the global-closure CACHE and the generic APPLY chain — textually twinned by
-- earlier units and NEVER EXECUTED, which is the failure mode this row exists
-- to close: `Rt.globalClosure`'s word-arm twin was measurably wrong (a
-- fixnum-shaped closure, and a header written eight bytes off) and every pin
-- in the tree was green over it.
--
-- WHAT IT EXERCISES, and why each line is here rather than in a second fixture:
--
--   * `add` reached as a VALUE (`h = add`) — `Rt.globalClosure`, i.e. the
--     descriptor, the C-heap cell and the `desc.cache` fast path.  Called
--     TWICE so the second call takes the cache hit (the first fills it), which
--     is the branch a `vecload(cache, 0)` left un-twinned answers wrongly.
--   * `\x -> x + k` with `k` a local — a REAL capture, so the closure's env
--     array is allocated, filled by `captureBlits`, read back by the entry's
--     `capBlitsPro`, and TAGGED in body word 2 (the apply chain untags it).
--   * `mk 10` / `mk 20` — curried, so the same lambda is created TWICE with
--     different captures; a shared env or a mis-sized capture stride makes the
--     two disagree.
--   * `twice` applies its argument to a function VALUE it was handed, i.e. an
--     apply whose head is a `Var` — `Rt.apply` -> `Rt.applyGo` ->
--     `rt_call2r`, the whole generic chain.
--   * `part 1` then `(part 1) 2` — an UNDER-applied closure, which is
--     `Rt.applyPartGo` and its three-range interleave
--     (`captures ++ applied ++ new`).  A mixed stride there writes one range
--     over the next, so the closure reads an argument as a capture.
--   * the result is a NESTED TUPLE, so the values the closure returns are read
--     back through the printer rather than through arithmetic alone.  It is
--     nested rather than flat because THIS LANGUAGE'S PARSER ACCEPTS AT MOST
--     THREE TUPLE ELEMENTS (MEASURED: `(1,2,3)` emits, `(1,2,3,4)` is "parse
--     error: expected `)`") — a pre-existing limit, not this unit's.
--
-- The output is compared BYTE-FOR-BYTE against the val arm by
-- `tools/qbe/word-arm-diff.sh`; the SOURCE half of the pair is the TestMain row
-- on `wordArmUnported`.
add a b =
    a + b

twice f x =
    f (f x)

part a b =
    a + b + 100

main =
    let
        h =
            add

        k =
            10

        mk n =
            \v -> v + n

        a =
            mk 10

        b =
            mk 20

        under =
            part 1

        t1 =
            h 1 2

        t2 =
            h 3 4

        t3 =
            twice (\v -> v + k) 5

        t4 =
            a 1
    in
    ( t1, t2, ( t3, ( t4, ( b 2, under 2 ) ) ) )
