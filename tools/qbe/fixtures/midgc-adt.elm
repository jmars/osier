module MidgcAdt exposing (main)

-- zigretire stage 5 — THE CROSS-HEAP PROBE for ADT construction (rt_con).
--
-- An ADT-heavy program under QBE_MIDGC=1.  `keep` is a list of ADT
-- constructors (Con): the list's cons cells are Mid-allocated (cons ->
-- RawAllocVector -> Rt.allocVector), but each element's vector is built by
-- the Con seat.  BEFORE this stage that seat is the Zig `rt_con`
-- (Lower.elm lowerCon), so the Con vectors live in the ZIG heap while the
-- list that reaches them lives in the MID heap — the cross-heap edge the
-- stage-4 review named (unsound in both directions).  AFTER the stage, Con
-- routes through the Mid defun `Rt.con`, both shapes live in the MID heap,
-- and the sum is exact.
--
-- The churn below allocates BOTH shapes (Pair Cons and the cons spine) so a
-- collection fires while `keep` is the only live data, and the total is
-- 400 * (n + (n+1)) = 400^2 + 2*400 = 160800 — a wrong number or a crash
-- when a collector frees (or moves) an object the other heap still reaches.
--
-- The fail-before/pass-after asymmetry is scripted in
-- tools/qbe/probe-midgc-adt.sh (revert ONE line in lowerCon to force the Zig
-- rt_con route, run, restore).

type Shape
    = Circle Int
    | Square Int
    | Pair Int Int

main =
    let
        keep =
            buildShapes 400

        n =
            churnDrop 200
    in
    sumShapes keep + n


buildShapes n =
    if n == 0 then
        []

    else
        Pair n (n + 1) :: buildShapes (n - 1)


churnDrop n =
    if n == 0 then
        0

    else
        let
            dropped =
                buildShapes 500
        in
        churnDrop (n - 1)


sumShapes xs =
    case xs of
        [] ->
            0

        h :: t ->
            case h of
                Circle r ->
                    r + sumShapes t

                Square s ->
                    s + sumShapes t

                Pair a b ->
                    a + b + sumShapes t
