module MatchLit exposing (main)

-- literal patterns beyond Int: Bool, String, Char (a 1-char string), plus a
-- string literal inside a constructor sub-pattern (order matters).

type Option
    = Some String
    | None

not_ : Bool -> Bool
not_ b =
    case b of
        True -> False

        False -> True

-- string literal patterns (MLitEq LString)
pick : String -> Int
pick s =
    case s of
        "a" -> 1

        "b" -> 2

        _ -> 99

-- char literal patterns (a Char is a 1-char string)
charCode : Char -> Int
charCode c =
    case c of
        'x' -> 1

        'y' -> 2

        _ -> 0

-- string literal inside a constructor sub-pattern; order matters
inner : Option -> Int
inner o =
    case o of
        Some "hit" -> 1

        Some _ -> 2

        None -> 3

main =
    let
        a = if not_ True then 0 else 100
        b = if not_ False then 100 else 0
        c = pick "a" + pick "b" + pick "z"
        d = charCode 'x' + charCode 'y' + charCode 'q'
        e = inner (Some "hit") + inner (Some "miss") + inner None
    in
    a + b + c + d + e
