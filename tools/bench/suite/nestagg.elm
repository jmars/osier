module NestAgg exposing (main, once)

-- SHAPE: nestagg -- NESTED aggregates built locally and read back locally.
--
-- `{ p = ( n, 2 ), q = [ 3, 4 ] }` is a record whose components are
-- themselves aggregates, and `( ( 1, 2 ), 3 )` is a tuple of a tuple.  Both
-- are consumed by a pattern in the same defun.
--
-- CORPUS GAP FILLED: Flatten's note names "nested aggregates" as one of its
-- two known gaps, and the pass's own collapse (a tuple-vs-list representation
-- mix-up that silently returned `Nothing` for `unifyList`) came from exactly
-- this mix -- see tools/qbe/fixtures/flatnest.elm.  Nothing in the corpus has
-- the shape, so the gap has never been measured.  The tuple/list mix here is
-- deliberate: `q` is a LIST pattern (`[ u, v ]`) while `u` is a TUPLE pattern.


step : Int -> Int
step n =
    let
        t =
            { p = ( n, 2 ), q = [ 3, 4 ] }

        u =
            ( ( 1, 2 ), 3 )

        a =
            case t.p of
                ( x, y ) ->
                    x + 10 * y

        b =
            case t.q of
                [ q1, q2 ] ->
                    q1 + 10 * q2

                _ ->
                    0

        c =
            case u of
                ( ( x, _ ), z ) ->
                    x + 100 * z
    in
    a + b + c


loop : Int -> Int -> Int
loop n acc =
    if n <= 0 then
        acc

    else
        loop (n - 1) (acc + step n)


once : Int -> Int
once n =
    step n


main : Int
main =
    loop 400000 0
