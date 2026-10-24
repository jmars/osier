{- An integer literal, carried EXACTLY from the parser to the emitter.

WHY THIS TYPE EXISTS. The frontend runs on a HOST whose `Int` may be an IEEE
double (the stock compiler runs under node), so a literal above 2^53 cannot be
held in an `Int` at all: the accumulator rounds it and the rounded value is
what gets emitted (MEASURED at fcbe722: `9223372036854775807` accumulated to
9223372036854778000 and the two backends then read it as two different
numbers). The language's Int is an i64 at EXECUTION, so the literal range must
be the i64 range; the answer is to never let a big literal be a host `Int`.

THE ARMS, and why the constructor distinction is the point:

  * `SmallInteger n` — `|n| <= 2^53`, so every host holds it exactly. This is
    the overwhelmingly common case and it emits exactly as it always has.
  * `BigInteger digits` — above 2^53: the VALIDATED canonical DECIMAL digits
    of the value (no leading zeros, no sign). Consumers emit the digits, never
    a number.
  * `Int64MinMagnitude digits` — exactly 2^63, the magnitude of INT64_MIN,
    which is out of the POSITIVE range but legal as `-9223372036854775808`
    (the parser sees the magnitude; only the negation knows the sign). It is a
    separate arm so that a bare `9223372036854775808` is a compile error at
    every consumer instead of a silently emitted positive value — Elm's
    exhaustiveness check turns a missed consumer into a compile error, not a
    wrong answer.

THE HOST RULE THIS MODULE IS SHAPED AROUND (measured, not assumed). The
compiler's own source is compiled by BOTH hosts: natively (i64 arithmetic) and
by stock Elm under node, where `Int` is a double AND **`//` is `(a/b)|0`, a
32-bit truncation**. So `//` is exact on both hosts only while the DIVIDEND is
below 2^31 — above that the node build silently answers garbage (the hazard
ParserFast's `hexadecimalExactnessProblem` documents, and the one that made the
first version of this module return corrupted digits: 4294967296 // 10 under
node). Therefore:

  * the limbs are base 2^26 (`limbUnit`), not 2^32: a `* 10`/`* 16` step keeps
    the next dividend under 2^31, so every `//` here has a dividend below
    2^31 and both hosts agree;
  * three limbs (78 bits) hold any i64 magnitude;
  * `decimalTextFromLimbs` is a base-2^26 LONG DIVISION by 10, where each step's
    dividend is `remainder * 2^26 + limb < 10 * 2^26 < 2^31` — exact on both
    hosts for the same reason;
  * the range check is LEXICAL on the source digits, so no arithmetic decides
    whether a literal fits.

Do not add arithmetic here whose intermediate exceeds 2^53, and do not divide
a value at or above 2^31: on node both round or truncate silently, and only the
fixed point would catch it.

-}

module IntegerLiteral exposing
    ( IntegerLiteral(..)
    , Limbs
    , decimalText
    , fromDecimalDigits
    , fromHexDigits
    , limbsOf
    )


{-| A literal as the frontend carries it. See the module header. -}
type IntegerLiteral
    = SmallInteger Int
    | BigInteger String
    | Int64MinMagnitude String


{-| A literal's magnitude as three base-2^26 limbs, plus its sign — the form the
emitter needs (`l0 + l1 * 2^26 + l2 * 2^52`, negated for a negative literal).
-}
type alias Limbs =
    { negative : Bool
    , l0 : Int
    , l1 : Int
    , l2 : Int
    }


{-| 2^26: the limb base. Chosen so that `limb * 10 + digit` and
`limb * 16 + digit` both stay under 2^31, which is where `//` stops agreeing
between the hosts (see the module header).
-}
limbUnit : Int
limbUnit =
    67108864


{-| The value's decimal digits, for a consumer that must render the literal as
text (`String.fromInt` of a host Int would round a big one).
-}
decimalText : IntegerLiteral -> String
decimalText lit =
    case lit of
        SmallInteger n ->
            String.fromInt n

        BigInteger digits ->
            digits

        Int64MinMagnitude digits ->
            digits


{-| `Just lit` for decimal digits in the i64 range — i.e. a magnitude of at
most 2^63 - 1, plus EXACTLY 2^63 (the INT64_MIN magnitude, which only a
negating context may use); `Nothing` above that.

The bound is decided LEXICALLY on the digits: no host arithmetic can be trusted
to answer "does this fit", which is the whole point of the module.
-}
fromDecimalDigits : String -> Maybe IntegerLiteral
fromDecimalDigits digits =
    let
        magnitude : String
        magnitude =
            stripLeadingZeros digits
    in
    case compareMagnitude magnitude int64MaxText of
        GT ->
            if magnitude == int64MinMagnitudeText then
                Just (Int64MinMagnitude magnitude)

            else
                Nothing

        _ ->
            accumulate 10 magnitude |> Maybe.map classifyLimbs


{-| The same for `0x...` hex digits (the `0x` already stripped). Hex is
accumulated exactly like decimal (base 16 steps are under 2^31 too), and the
big arms carry DECIMAL digits — one canonical form for every consumer,
whatever the source spelling.
-}
fromHexDigits : String -> Maybe IntegerLiteral
fromHexDigits digits =
    let
        magnitude : String
        magnitude =
            stripLeadingZeros (String.toLower digits)
    in
    case compareMagnitude magnitude hexInt64MaxText of
        GT ->
            if magnitude == hexInt64MinMagnitudeText then
                accumulate 16 magnitude
                    |> Maybe.map (\limbs -> Int64MinMagnitude (decimalTextFromLimbs limbs))

            else
                Nothing

        _ ->
            accumulate 16 magnitude |> Maybe.map classifyLimbs


{-| The 64-bit value's limbs for the emitter, from a VALIDATED literal string
(optional leading `-`). `Nothing` for a malformed string — no consumer can
reach one, because the parser validates before this form exists.
-}
limbsOf : String -> Maybe Limbs
limbsOf digits =
    let
        ( negative, magnitude ) =
            splitSign digits
    in
    accumulate 10 magnitude
        |> Maybe.map
            (\( l0, l1, l2 ) ->
                { negative = negative, l0 = l0, l1 = l1, l2 = l2 }
            )


splitSign : String -> ( Bool, String )
splitSign digits =
    case String.toList digits of
        '-' :: rest ->
            ( True, String.fromList rest )

        _ ->
            ( False, digits )


int64MaxText : String
int64MaxText =
    "9223372036854775807"


int64MinMagnitudeText : String
int64MinMagnitudeText =
    "9223372036854775808"


hexInt64MaxText : String
hexInt64MaxText =
    "7fffffffffffffff"


hexInt64MinMagnitudeText : String
hexInt64MinMagnitudeText =
    "8000000000000000"


{-| Magnitude comparison on digit strings, which is a numeric comparison once
leading zeros are gone: fewer digits is smaller, more is bigger, and equal
lengths compare lexicographically (the digits are all in one base).
-}
compareMagnitude : String -> String -> Order
compareMagnitude a b =
    let
        la : Int
        la =
            String.length a

        lb : Int
        lb =
            String.length b
    in
    if la < lb then
        LT

    else if la > lb then
        GT

    else
        compare a b


stripLeadingZeros : String -> String
stripLeadingZeros digits =
    if String.length digits > 1 && String.startsWith "0" digits then
        stripLeadingZeros (String.dropLeft 1 digits)

    else
        digits


{-| Three-limb accumulation in base `base` (10 or 16), every dividend under
2^31 (see the module header). `Nothing` once the high limb leaves the 26-bit
range — a magnitude of 2^78, which is far above the i64 range the caller has
already decided lexically.
-}
accumulate : Int -> String -> Maybe ( Int, Int, Int )
accumulate base digits =
    accumulateHelp base (String.toList digits) 0 0 0


accumulateHelp : Int -> List Char -> Int -> Int -> Int -> Maybe ( Int, Int, Int )
accumulateHelp base chars l0 l1 l2 =
    case chars of
        [] ->
            Just ( l0, l1, l2 )

        c :: rest ->
            case digitValue c of
                Nothing ->
                    Nothing

                Just d ->
                    let
                        c0 : Int
                        c0 =
                            l0 * base + d

                        k0 : Int
                        k0 =
                            c0 // limbUnit

                        c1 : Int
                        c1 =
                            l1 * base + k0

                        k1 : Int
                        k1 =
                            c1 // limbUnit

                        c2 : Int
                        c2 =
                            l2 * base + k1
                    in
                    if c2 >= limbUnit then
                        Nothing

                    else
                        accumulateHelp base rest (c0 - k0 * limbUnit) (c1 - k1 * limbUnit) c2


digitValue : Char -> Maybe Int
digitValue c =
    let
        code : Int
        code =
            Char.toCode c
    in
    if code >= 48 && code <= 57 then
        Just (code - 48)

    else if code >= 97 && code <= 102 then
        Just (code - 87)

    else if code >= 65 && code <= 70 then
        Just (code - 55)

    else
        Nothing


{-| The range decision, once the limbs are known. The RANGE itself was settled
lexically by the caller; this only picks the arm.

`2^53` is `limbUnit * limbUnit * 2`, so limbs with `l2 < 2`, or `l2 == 2` with
both lower limbs zero, are exactly the values a double holds.

`2^63` is `limbUnit * limbUnit * 2^11`, i.e. `(0, 0, 2048)`.
-}
classifyLimbs : ( Int, Int, Int ) -> IntegerLiteral
classifyLimbs ( l0, l1, l2 ) =
    if l2 == 0 || l2 == 1 || (l2 == 2 && l1 == 0 && l0 == 0) then
        SmallInteger (limbsToInt ( l0, l1, l2 ))

    else if l0 == 0 && l1 == 0 && l2 == 2048 then
        Int64MinMagnitude (decimalTextFromLimbs ( l0, l1, l2 ))

    else
        BigInteger (decimalTextFromLimbs ( l0, l1, l2 ))


{-| A SMALL value's `Int`. Each term is exact and the sum is at most 2^53, so
both hosts agree.
-}
limbsToInt : ( Int, Int, Int ) -> Int
limbsToInt ( l0, l1, l2 ) =
    l0 + l1 * limbUnit + l2 * (limbUnit * limbUnit)


{-| The decimal digits of the three limbs.

A base-2^26 LONG DIVISION by 10: at each step the running remainder is < 10, so
`remainder * 2^26 + limb < 10 * 2^26 < 2^31` — the dividend stays in the range
where `//` is exact on BOTH hosts (see the module header; dividing the whole
64-bit value in one expression would be garbage on node).
-}
decimalTextFromLimbs : ( Int, Int, Int ) -> String
decimalTextFromLimbs limbs =
    if limbs == ( 0, 0, 0 ) then
        "0"

    else
        decimalTextHelp limbs []


decimalTextHelp : ( Int, Int, Int ) -> List Char -> String
decimalTextHelp ( l0, l1, l2 ) acc =
    if l0 == 0 && l1 == 0 && l2 == 0 then
        String.fromList acc

    else
        let
            ( q2, r2 ) =
                divideLimb 0 l2

            ( q1, r1 ) =
                divideLimb r2 l1

            ( q0, r0 ) =
                divideLimb r1 l0
        in
        decimalTextHelp ( q0, q1, q2 ) (digitChar r0 :: acc)


divideLimb : Int -> Int -> ( Int, Int )
divideLimb remainder limb =
    let
        current : Int
        current =
            remainder * limbUnit + limb

        quotient : Int
        quotient =
            current // 10
    in
    ( quotient, current - quotient * 10 )


digitChar : Int -> Char
digitChar d =
    Char.fromCode (48 + d)
