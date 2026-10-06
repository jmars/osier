module RefutNeg exposing (main)

-- Part B pin (refutation NEGATIVE): the refutation rule must NOT over-refute.
-- `HNil : HList {}` LOOKS incompatible with a fielded row, but here the
-- scrutinee index is the OPEN row `rho` (unrefined), which MAY be `{}` — so
-- `HNil` IS a possible value and its absence is a real coverage gap. The case
-- below matches only `HCons`; it must ERROR non-exhaustive (missing HNil),
-- NOT be silently accepted as refuted.

type HList rho
    = HNil : HList {}
    | HCons : a -> HList rho -> HList { l : a | rho }


len : type rho. HList rho -> Int
len xs =
    case xs of
        HCons _ rest ->
            1 + len rest


main : Int
main =
    len HNil
