module M exposing (main)

-- THE FIRST HIGHER-ORDER PROGRAM ON THE WORD ARM (perf word-arm-closures).
--
-- Until this fixture the surface lane refused `Lam` at its classifier, so no
-- word-arm program could hold a function as a VALUE: every call this arm had
-- ever made was a saturated direct call to a known global.  That left the whole
-- closure machinery — the capture array, the closure CELL and the generic APPLY
-- chain — textually twinned by earlier units and NEVER EXECUTED, which is the
-- failure mode this row exists to close: a twin that is only read is a twin
-- nobody has tested.
--
-- WHAT IT EXERCISES, and why each binding is here rather than in a second
-- fixture:
--
--   * `\x -> x + 1` — the smallest closure: NO captures, so the closure's env
--     word is the tag alone and the apply chain's `env == 0` path is taken.
--   * `\x -> x + k` with `k` a local — a REAL capture, so the closure's env
--     array is allocated by `Rt.closure`, filled by `captureBlits`, read back
--     by the entry's `capBlitsPro` at `valSizeBytes * j`, and stored TAGGED in
--     body word 2 (the apply chain untags it).
--   * `mk 10` / `mk 20` — curried, so the same lambda is created TWICE with
--     different captures; a shared env or a mis-sized capture stride makes the
--     two disagree, and both are printed.
--   * `twice` applies a function VALUE it was handed, i.e. an apply whose head
--     is a `Var` — `Rt.apply` -> `Rt.applyGo` -> `rt_call2r`, the whole generic
--     chain, whose argument staging is the stride this unit twinned.
--   * `part 1` then `(part 1) 2` — an UNDER-applied closure, which is
--     `Rt.applyPartGo` and its three-range interleave
--     (`captures ++ applied ++ new`).  A mixed stride there writes one range
--     over the next, so the closure reads an argument as a capture.
--
-- The output is compared BYTE-FOR-BYTE against the val arm by
-- `tools/qbe/word-arm-diff.sh`; the SOURCE half of the pair is the TestMain row
-- on `wordArmUnported`.
--
-- NESTED TUPLES, NOT A FLAT ONE: this language's parser accepts at most THREE
-- tuple elements (MEASURED: `(1,2,3)` emits, `(1,2,3,4)` is "parse error:
-- expected `)`") — a pre-existing limit, not this unit's.
part a b =
    a + b + 100

twice f x =
    f (f x)

main =
    let
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
            (\x -> x + 1) 41

        t2 =
            twice (\v -> v + k) 5

        t3 =
            a 1

        t4 =
            under 2
    in
    ( t1, t2, ( t3, ( t4, b 2 ) ) )
