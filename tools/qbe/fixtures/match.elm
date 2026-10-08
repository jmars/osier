module Match exposing (main)

type Expr
    = Num Int
    | Add Expr Expr
    | Neg Expr

type Option
    = Some Int
    | None

-- constructor patterns with sub-patterns, nested patterns
eval : Expr -> Int
eval e =
    case e of
        Num n ->
            n

        Add l r ->
            eval l + eval r

        Neg inner ->
            0 - eval inner

-- constructor pattern binding (IdxStep binds)
unwrap : Option -> Int
unwrap o =
    case o of
        Some v ->
            v

        None ->
            0

-- destructuring let (LetDestruct) via a tuple pattern
addPair p =
    let
        (a, b) = p
    in
    a + b

-- ordered alts where order matters: Some 0 must be tested before Some _
describe : Option -> Int
describe o =
    case o of
        Some 0 -> 1

        Some _ -> 2

        None -> 3

-- literal patterns (int) with a catch-all
lit : Int -> Int
lit n =
    case n of
        0 -> 10

        1 -> 11

        _ -> 0 - n

-- a Case inside a closure body
makeClassifier : Int -> (Int -> Int)
makeClassifier threshold =
    \x ->
        case x of
            0 ->
                threshold

            _ ->
                threshold + x

main =
    eval (Add (Num 3) (Neg (Num 10)))
        + unwrap (Some 5)
        + addPair (2, 3)
        + describe (Some 0)
        + describe (Some 7)
        + describe None
        + lit 0
        + lit 1
        + lit 9
        + (makeClassifier 100) 0
        + (makeClassifier 100) 5
