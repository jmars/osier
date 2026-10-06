module RowgadtDupRebuild exposing (main)

-- H1 DUPLICATE-LABEL PROBE, POSITIVE ARM (handoff-rowgadt plan Step 5): a
-- DUPLICATE label under an ACTIVE branch-local refinement, REBUILT in full.
-- The `HDupCons` match refines `rho ~ { x : Int, x : String | rho' }` — the
-- equation body carries a duplicate label `x` (legal scoped labels; the FIRST
-- occurrence `x : Int` is the selected one). The branch returns the scrutinee
-- rebuilt with BOTH duplicate occurrences:
-- `HDupCons i s rest : HDup { x : Int, x : String | rho' }`, which matches the
-- equation body exactly. The domain-based escape rule's REBUILD arm
-- (`rebuildMatches`, Type/Infer.elm) accepts it: the identification IS the
-- equation itself, no domain change, nothing binds. Must compile CLEAN — this
-- is the probe that proves the rebuild arm handles duplicate-label equation
-- bodies (the half of H1 the earlier single-label probes never exercised).

type HDup rho
    = HNil : HDup {}
    | HDupCons : Int -> String -> HDup rho -> HDup { x : Int, x : String | rho }


rebuild : type rho. HDup rho -> HDup rho
rebuild xs =
    case xs of
        HDupCons i s rest ->
            HDupCons i s rest

        _ ->
            xs


main : Int
main =
    0
