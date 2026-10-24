module Inttoobig exposing (main)

-- L3-U1 — THE LOUD REFUSAL (design §2/§7): 2^63 is one above INT64_MAX, so it
-- is out of range as a POSITIVE literal. It is legal only as the magnitude of
-- `-9223372036854775808`, which intbig.elm pins from the other side — the
-- `Int64MinMagnitude` arm exists precisely so that this bare form cannot slip
-- through as a positive i64 that is silently the INT64_MIN bit pattern.
--
-- The row that compiles this fixture requires the RANGE in the message, and
-- requires it to arrive through `Mid.Module.parseOne` (which used to collapse
-- every parse error to `err parse failed`).

main : Int
main =
    9223372036854775808
