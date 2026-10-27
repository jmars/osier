module M exposing (main)

-- THE OVER-APPLIED APPLY ARM, UNDER A COLLECTION (perf word-arm-closures,
-- review should-fix 2).  `mk` is arity 1 and RETURNS a lambda, so the spine
-- `mk 10 5` hands the generic apply TWO args against rem=1 — the
-- `sp->args = args + rem * STRIDE` advance in BOTH `Rt.applyGo` and
-- `Rt.applyTailGo`, plus `copyWords(fslot, r, 1)` writing the next closure into
-- cell 0 of the staged block.
--
-- NAMING: this is the OVER-applied arm (rem < nargs), NOT the under-applied
-- one; the under-applied (partial) arm is `Rt.applyPartGo` and is what
-- `partial.elm` covers.  Nothing in the tree exercised this arm on the word arm
-- before this fixture — `lap-apply` is the val arm's oracle and runs on the
-- default arm only.
--
-- The churn keeps the arm running across collections, which is the point: a
-- wrong stride survives a single apply and only shows up when the staged block
-- is read after a scavenge.
mk n =
    \v -> v + n

g x =
    mk x 5

loop i acc =
    if i == 0 then
        acc
    else
        loop (i - 1) (acc + g i + (mk i 1))

main =
    ( mk 10 5, g 10, loop 20000 0 )
