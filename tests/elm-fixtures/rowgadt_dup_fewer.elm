module RowgadtDupFewer exposing (main)

-- H1 DUPLICATE-LABEL PROBE, THE KNOWN FALSE REJECT (handoff-rowgadt plan
-- Step 5), pinned as a compile_error on purpose. The SAME duplicate-label
-- refinement `rho ~ { x : Int, x : String | rho' }`, but the branch rebuilds
-- with FEWER duplicate occurrences: `HOne i rest : HDup { x : Int | rho' }`
-- (one `x` instead of two). Under scoped labels the DOMAIN of
-- `{ x : Int, x : String | rho' }` is `{ x } ++ dom(rho')`, which EQUALS the
-- domain of `{ x : Int | rho' }`: dropping a SHADOWED duplicate is domain-
-- (and selection-) preserving, so the domain-based escape rule (Lean
-- `h2b_domain_accepts_rebuild`) ACCEPTS this return.
--
-- The implementation's REBUILD arm (`rebuildMatches`) instead requires the
-- returned row to UNIFY with the equation body exactly, and
-- `{ x : Int | rho' }` does not (the shared tail turns the field-list
-- mismatch into an infinite-type failure inside the unify), so it is REJECTED.
-- THIS IS A FALSE REJECT — an INCOMPLETENESS of the duplicate-label check,
-- NEVER a soundness requirement: full-duplicate rebuilds are accepted
-- (rowgadt_dup_rebuild), and no fewer-duplicate program escapes. DO NOT "fix"
-- this by weakening the check. MEASURED error: "cannot unify a with
-- {x:Int| a}" (the rigid row head `a` against the one-occurrence rebuild).

type HDup rho
    = HNil : HDup {}
    | HOne : Int -> HDup rho -> HDup { x : Int | rho }
    | HDupCons : Int -> String -> HDup rho -> HDup { x : Int, x : String | rho }


rebuild : type rho. HDup rho -> HDup rho
rebuild xs =
    case xs of
        HDupCons i s rest ->
            HOne i rest

        _ ->
            xs


main : Int
main =
    0
