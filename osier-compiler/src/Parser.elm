{- Original to this project — NOT from stil4m/elm-syntax. A minimal stub
of elm/parser's error surface (`Problem`/`DeadEnd`) so the parse closure
resolves without depending on the elm/parser package. -}

module Parser exposing (Problem(..), DeadEnd)

{-| Minimal selfhost stub of elm/parser's error-surface module.

`ParserFast` (the vendored, self-contained parser) and `Elm.Parser` reference
only elm/parser's `Problem`/`DeadEnd` TYPES (the ctor spellings the parse
closure emits on failure) — never the `Parser` value type or the combinator
library itself (ParserFast reimplements those).  This stub supplies exactly
that surface so the selfhost group closes without vendoring all of elm/parser.

-}


{-| elm/parser 1.1.0 `Problem`, verbatim ctor set (the subset ParserFast emits).
-}
type Problem
    = Expecting String
    | ExpectingInt
    | ExpectingHex
    | ExpectingOctal
    | ExpectingBinary
    | ExpectingFloat
    | ExpectingNumber
    | ExpectingVariable
    | ExpectingSymbol String
    | ExpectingKeyword String
    | ExpectingEnd
    | UnexpectedChar
    | Problem String
    | BadRepeat


{-| elm/parser 1.1.0 `DeadEnd`, verbatim.
-}
type alias DeadEnd =
    { row : Int
    , col : Int
    , problem : Problem
    }
