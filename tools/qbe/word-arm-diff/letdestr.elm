module M exposing (main)

-- A `let` DESTRUCTURING PATTERN, EXECUTED ON BOTH ARMS (perf word-arm-letdestr).
--
-- WHY THIS FIXTURE IS NOT `letpat.elm`.  `letpat.elm` already carries a
-- `let ( a, b ) = ( 1, "hi" )`, and it is GREEN on both arms because it never
-- reaches the emitter as a destructuring: the scrutinee is a LITERAL TUPLE, so
-- Flatten substitutes the components and the `LetDestruct` node is gone before
-- lowering.  It therefore says nothing about the destructuring path at all.
--
-- SO EVERY SCRUTINEE HERE IS A CALL RESULT.  `pair`/`shp` are separate defuns,
-- so Flatten cannot see through them and the emitter really does emit the
-- pattern: a tag test plus payload chases into the SCRUTINEE's slot.
--
-- WHAT EACH SHAPE EXERCISES (the classifier's three walks, one per shape):
--   * `( a, b ) = pair 3`      — a TUPLE pattern: MCons on the cons spine (the
--     tuple's desugar is a cons chain whose tail is the fixnum 0), then
--     HdStep/TlStep binds — `fieldBase` + `chaseCdr` on the word arm.
--   * `(Mk n s) = shp a`       — a CONSTRUCTOR pattern: MTagEq (the forked tag
--     EQUALITY, i.e. `Rt.=` on the word arm) then IdxStep binds, which is the
--     one place the element stride (`valSizeBytes * j`) and the vector base
--     (`fieldBase 0`) are both read.
--   * `( x :: xs ) = ...`      — a LIST pattern: MCons, then the car and the
--     CDR (the `chaseCdr` path, which derives the tail through the car pointer
--     and is a different chase from `fieldBase`'s).
--   * `( ( p, q ), r )`        — a NESTED pattern: two levels of binds, so a
--     bind's slot is itself the scrutinee of the next chase.
--   * `rr = { f = n, g = s }` with `f = rr.f` — a record FIELD pattern's
--     sibling (the `VField` bind is reached from a record pattern; this fixture
--     keeps a plain field read beside it so the record built HERE is walked too).
--
-- THE ASSERTION IS THE USUAL ONE: both arms build, run, and print the SAME
-- BYTES.  A wrong payload stride or a wrong vector base on the word arm prints
-- a wrong number (every element below is a distinct small integer) rather than
-- crashing, which is the failure mode this row exists to catch.
--
-- THE OUTPUT IS A LIST OF STRINGS rather than a tuple: this frontend's tuple
-- arity is Elm's (2 or 3), and there are eleven values to show.

type Shape
    = Mk Int String
    | Nilish


pair n =
    ( n, n + 1 )


shp n =
    Mk n "s"


sum xs =
    case xs of
        [] ->
            0

        y :: rest ->
            y + sum rest


main =
    let
        ( a, b ) =
            pair 3

        (Mk n s) =
            shp a

        ( x :: xs ) =
            [ 7, 8, 9 ]

        ( ( p, q ), r ) =
            ( pair 20, "t" )

        rr =
            { f = n, g = s }

        f =
            rr.f

        g =
            rr.g
    in
    [ String.fromInt a
    , String.fromInt b
    , String.fromInt n
    , s
    , String.fromInt x
    , String.fromInt (sum xs)
    , String.fromInt p
    , String.fromInt q
    , r
    , String.fromInt f
    , g
    ]
