module CharOrd exposing (main)

-- Char ORDERING (<, <=, >, >=) must not silently lower to False.  Each
-- operator is pinned by a distinct decimal digit; the equality control (==),
-- the Int control (n < 66), and the OTHER shared-path families (a Char
-- case-binder and a Char record FIELD) prove the row cannot pass by accident:
-- the digits for `eq 'A'` and `lti 65` were already correct before the fix,
-- and the four ordering digits were all 0.  Every even power of ten is a
-- TRUE check and every odd power a FALSE one, so the golden is the
-- alternating 0101...01:
--   lt 'A'=1 lt 'B'=0 | le 'B'=1 le 'a'=0 | gt 'B'=1 gt 'A'=0 | ge 'A'=1 ge '0'=0
--   eq 'A'=1 eq 'B'=0 | lti 65=1 lti 66=0 | guard 'A'=1 guard '0'=0
--   recf {a='A'}=1 recf {a='0'}=0   ->  101010101010101
-- (place values stop at 10^15: an integer literal >= 2^53 does not parse in
-- this front end.)


lt : Char -> Int
lt c =
    if c < 'B' then 1 else 0


le : Char -> Int
le c =
    if c <= 'B' then 1 else 0


gt : Char -> Int
gt c =
    if c > 'A' then 1 else 0


ge : Char -> Int
ge c =
    if c >= 'A' then 1 else 0


eq : Char -> Int
eq c =
    if c == 'A' then 1 else 0


lti : Int -> Int
lti n =
    if n < 66 then 1 else 0


-- a Char CASE-BINDER compared by ordering (the match binder `x` is Char-typed)
guard : Char -> Int
guard c =
    case c of
        x ->
            if x >= 'A' then 1 else 0


-- a Char record FIELD compared by ordering (RecordGet `r.a` is Char-typed)
type alias CharRec =
    { a : Char }


recf : CharRec -> Int
recf r =
    if r.a >= 'A' then 1 else 0


main =
    (lt 'A' * 1)
        + (lt 'B' * 10)
        + (le 'B' * 100)
        + (le 'a' * 1000)
        + (gt 'B' * 10000)
        + (gt 'A' * 100000)
        + (ge 'A' * 1000000)
        + (ge '0' * 10000000)
        + (eq 'A' * 100000000)
        + (eq 'B' * 1000000000)
        + (lti 65 * 10000000000)
        + (lti 66 * 100000000000)
        + (guard 'A' * 1000000000000)
        + (guard '0' * 10000000000000)
        + (recf { a = 'A' } * 100000000000000)
        + (recf { a = '0' } * 1000000000000000)
