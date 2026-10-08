module Utf8 exposing (main, eq)

-- Non-ASCII STRING literals: the native string's bytes must be UTF-8 (not
-- Latin-1), and its byte length must be the UTF-8 byte count (not the code
-- point count).  `eq` uses `==` (primEq's byte compare) so the native bytes
-- must equal the VM's; `main` returns the string for a print comparison.

greeting : String
greeting =
    "héllo wörld — 🦀"


eq : Bool
eq =
    greeting == "héllo wörld — 🦀"


main =
    greeting
