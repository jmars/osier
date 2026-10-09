module AdtMatch exposing (main, once)

-- SHAPE: adtmatch -- ADT-heavy pattern matching.
--
-- `Expr` has four constructors (one nullary-free, two recursive, one mixed)
-- and `eval` matches all four, recursing through them.  Each round
-- CONSTRUCTS a five-node expression (`Lit`/`Add`/`Neg`/`Pair`) and then
-- pattern-matches it apart again -- construction and matching cost are both
-- in the loop.
--
-- CORPUS GAP FILLED: the corpus's `Case` sites are almost entirely
-- single-constructor record-ish matches over a handful of tiny types; there
-- is no ADT whose tag dispatch dominates.  Matching is also the stage-2
-- surface that was reached LAST on the native path (docs/qbe-backend.md item
-- 2), so a change there has never been measured against a matching-heavy
-- workload.


type Expr
    = Lit Int
    | Add Expr Expr
    | Neg Expr
    | Pair Expr Expr


eval : Expr -> Int
eval e =
    case e of
        Lit n ->
            n

        Add a b ->
            eval a + eval b

        Neg a ->
            0 - eval a

        Pair a b ->
            eval a * 3 + eval b


mk : Int -> Expr
mk n =
    Add (Lit n) (Neg (Pair (Lit 2) (Lit 3)))


loop : Int -> Int -> Int
loop n acc =
    if n <= 0 then
        acc

    else
        loop (n - 1) (acc + eval (mk n))


once : Int -> Int
once n =
    eval (mk n)


main : Int
main =
    loop 80000 0
