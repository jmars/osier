module Inttoobighex exposing (main)

-- L3-U1: the same bound in HEX (design §2 row 2 — "hex same bound"). 0x8000...
-- is 2^63. Decimal and hex share the range check's OUTCOME but decide it on
-- their own digits (hex compares against 7fffffffffffffff).

main : Int
main =
    0x8000000000000000
