module Interleave exposing (main)

-- INTERLEAVE — the two-arity-interleaved frame-reuse probe (stage-6 B0, R2's
-- oracle).  `small` holds NO extra value across its tail call (a lean frame);
-- `big` holds SIX live cons chains across ITS tail call (a fat frame — the
-- unboxing pass cannot remove a cons).  They are mutually TAIL-recursive, so
-- the Zig bounce loop enters and leaves their frames in alternating sizes,
-- pooling both: after warmup the freelist holds one lean block and one fat
-- block, and every hop pops the size it asked for.  A WRONG freelist index
-- cross-reuses the two sizes — the fat frame's six conses get written into a
-- lean block (heap corruption) or the lean block's stale slots survive a
-- collection (a wrong answer under churn).  The result is deterministic:
-- each small hop adds 1, each big hop adds 1 + 100+200+300+400+500+600 = 2101
-- (big 0 is the base case), so 20000 small hops + 19999 big hops =
-- 20000 + 19999*2101 = 42037899.

small : Int -> Int -> Int
small n acc =
    if n == 0 then
        acc

    else
        big (n - 1) (acc + 1)


big : Int -> Int -> Int
big n acc =
    if n == 0 then
        acc

    else
        let
            a =
                100 :: []

            b =
                200 :: a

            c =
                300 :: b

            d =
                400 :: c

            e =
                500 :: d

            f =
                600 :: e
        in
        small n (acc + 1 + headOf a + headOf b + headOf c + headOf d + headOf e + headOf f)


headOf : List Int -> Int
headOf l =
    case l of
        x :: _ ->
            x

        [] ->
            0


main =
    small 20000 0
