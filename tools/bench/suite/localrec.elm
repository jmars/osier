module LocalRec exposing (main, once)

-- SHAPE: localrec -- a record LITERAL born and consumed inside ONE defun.
--
-- `let r = { a = n, b = 2 } in ... r.a ... r.b` is the exact shape
-- Mid.Qbe.Flatten exists to remove: the record never escapes the defun, so
-- the object and its `assoc`/`snd`/`@p`/`cons`/`emptylist` prim sequence can
-- be deleted entirely, leaving the components in pooled frame slots.
--
-- CORPUS GAP FILLED: the compiler's own 58-source corpus contains only NINE
-- let-bound record literals across all 58 sources (docs/qbe-backend.md,
-- "Aggregate flattening -- what it buys, and on what"), which is why Flatten
-- measured -0.08% on it.  This program is nothing but that shape, in a loop.


loop : Int -> Int -> Int
loop n acc =
    if n <= 0 then
        acc

    else
        let
            r =
                { a = n, b = 2 }
        in
        loop (n - 1) (acc + r.a + r.b)


once : Int -> Int
once n =
    let
        r =
            { a = n, b = 2 }
    in
    r.a + r.b


main : Int
main =
    loop 800000 0
