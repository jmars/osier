module RmProbe exposing (main)

{-| THE RECORD.REMOVE-CHAIN GUARD (unit-B item 3, blocker-1) — arithmetic on
the field of a `Record.remove` result.  `Record.remove` returns an assoc CHAIN
(tag 4, NOT a positional tag-14 vector) through the trusted-lie scheme
(`String -> a -> b`), yet `f`'s signature types the result as a CLOSED
`{ n : Int }`.  The item-3 raw read licensed itself on "closed-TRecord binder
⇒ positional vector" and read `data[rank]+8` with NO tag test — a plausible
wrong int, exit 0 (MEASURED pre-fix: 140046797636105, where the correct answer
is 6).  `main` is 6 iff the field read is correct.

WHY THE GATE COULD NOT SEE THIS BEFORE: `remrec.elm` reads `Record.remove`
results too, but its fields are unannotated `number` TVars (and its first
remove is a duplicate-label chain), so the item-3 arm denied them and the
boxed route ran.  This fixture forces `n : Int` with a signature — the exact
shape the static licence was wrong about.  The fix (a tag-14 test with the
boxed fallback) makes the chain take the assoc+snd arm and answer 6.
-}


f : { n : Int } -> Int
f r2 =
    r2.n + 1


main : Int
main =
    let
        r =
            { n = 5, m = 1 }
    in
    f (Record.remove "m" r)
