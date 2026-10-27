module M exposing (main)

-- CLASS 2: A TUPLE (perf word-arm-surface).
--
-- `Tup` has no emission of its own — `lowerTup` is `lowerVal (buildTuple es)`,
-- a right-nested `cons` chain terminated by the fixnum 0 — so the classifier
-- classifies the DESUGAR.  Three elements because the interesting cases are in
-- the middle: element 1 is an immediate, element 2 is a HEAP object (a string
-- cell), and element 3 is an immediate again, so a stride error in the cons
-- spine shows up as the wrong element rather than as the right one by luck.
-- The printed form is `[cons 1 . [cons "hi" . 2]]` — note the tuple's tail is
-- the NUMBER 0, not nil, which is the difference between `buildTuple` and
-- `buildList` and is why the two are separate desugars.
main =
    ( 1, "hi", 2 )
