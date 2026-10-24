module Inttoobigparse exposing (main)

-- L3-U1 — THE PARSER'S OWN REFUSAL, and the message SURFACING (design §2 rows
-- 1-2, §6 row (b)).  20 digits is above 2^63, so the parser refuses it — and
-- the row requires the reason to arrive intact through `Mid.Module.parseOne`,
-- which until this unit collapsed EVERY parse error to `err parse failed`
-- (MEASURED at VR3b2: a 19-digit literal reported nothing but those two
-- words).  A refusal a reader cannot act on is barely a refusal.
--
-- (The bare `9223372036854775808` in inttoobig.elm takes a different route on
-- purpose: the parser must ACCEPT that magnitude so `-9223372036854775808`
-- parses, so its refusal happens at the negation site in FromAst.)

main : Int
main =
    99999999999999999999
