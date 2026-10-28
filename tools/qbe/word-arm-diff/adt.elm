module M exposing (main)

-- A USER ADT: CONSTRUCTOR VALUES AND CONSTRUCTOR-TAG PATTERNS (perf
-- word-arm-frontier).  The first word-arm fixture in this row that builds a
-- VECTOR — a code-10 heap block whose body word 0 is a real SYMBOL cell — and
-- then takes it apart with the tag test.
--
-- WHY THE SHAPES ARE THESE.  A word-arm constructor value is one block,
-- `[tag_symbol, arg_0 .. arg_{n-1}]`, so the two things that can be wrong are
-- the TAG (a code-2 symbol cell, allocated by the emitter's own seat) and the
-- ELEMENT STRIDE (arguments are INLINE body words, 8 bytes each).  Each
-- function below reads one of them:
--   * `area` takes the tag test on a PARAMETER — the only shape that reaches
--     `MTagEq` without `Con` in the same defun, and the shape that would read the
--     NEXT FRAME SLOT if the tag were compared at the val arm's `slot + 8`;
--   * `describe` matches a two-argument constructor and uses BOTH binds, so a
--     stride error puts the wrong number in one of them rather than losing an
--     argument;
--   * `tagOf` matches on a NESTED value (`Wrap inner` then `inner`), so the tag
--     test runs on an element read out of another vector;
--   * `main` prints a CONSTRUCTED value as well as the numbers, so the printer's
--     vector walk runs on both arms.
--
-- MEASURED, both arms identical (val is the oracle; this is what it printed):
--   [cons 40 . [cons "sq 5x6" . [cons "circle 2" . [vector 3]]]]
-- 40 = 9 + 30 + 1, so all three alternatives of the tag test were taken, on a
-- value passed IN; the two-argument match produced "sq 5x6"; the nested match
-- produced "circle 2"; and the printer walked the constructed `Square 5 6` as a
-- 3-unit vector (tag + two arguments), which is the block's header count.

type Shape
    = Circle Int
    | Square Int Int
    | Dot


type Wrapper
    = Wrap Shape
    | Bare


area : Shape -> Int
area s =
    case s of
        Circle r ->
            r * r

        Square w h ->
            w * h

        Dot ->
            1


describe : Shape -> String
describe s =
    case s of
        Circle r ->
            String.append "circle " (String.fromInt r)

        Square w h ->
            String.append "sq "
                (String.append (String.fromInt w) (String.append "x" (String.fromInt h)))

        Dot ->
            "dot"


tagOf : Wrapper -> String
tagOf w =
    case w of
        Wrap inner ->
            describe inner

        Bare ->
            "bare"


main =
    -- A THREE-TUPLE because the surface language is Elm's: 2- and 3-tuples only.
    -- The last element is itself a pair so the CONSTRUCTED value is printed.
    ( area (Circle 3) + area (Square 5 6) + area Dot, describe (Square 5 6), ( tagOf (Wrap (Circle 2)), Square 5 6 ) )
