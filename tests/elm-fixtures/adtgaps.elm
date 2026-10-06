module AdtGaps exposing (main)

-- Part A pin (exhaustiveness): a `case` that omits a POSSIBLE arm. Before the
-- exhaustiveness check this program COMPILED CLEAN and raised
-- `non-exhaustive case` at runtime (Lower/Expr.elm's fallthrough). It must now
-- ERROR at COMPILE time with a clear message.

type Color
    = Red
    | Green
    | Blue


describe : Color -> String
describe c =
    case c of
        Red ->
            "red"

        Green ->
            "green"


main : String
main =
    describe Blue
