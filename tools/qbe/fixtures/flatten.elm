module Flatten exposing (main, recLocal, recPatternLet, recPatternCase, recNested, conLocal, conNullary, tupLocal, listLocal, recRooted)

-- FLATTEN: the POSITIVE direction of Mid.Qbe.Flatten (handoff-qbe-flatten).
--
-- Every aggregate here is built AND consumed inside ONE defun, so it never
-- needs a heap object: the pass binds its components to pooled frame slots and
-- deletes the `rt_con`/`cons`/`@p`/`assoc`/`snd`/`emptylist` prim sequence
-- and its allocations.  Each entry returns an Int, so a miscompile is a wrong
-- NUMBER rather than a crash — and qbe-check.sh compares the number against
-- elmvm AND asserts the structural absence of the aggregate prims (a fixture
-- that only checked the number would still pass if the pass silently did
-- nothing).
--
-- NOTHING here calls a Prelude function that would pull an aggregate-reading
-- defun into the emitted reachable set: an `assoc`/`snd` site anywhere in the
-- emitted `.ssa` would break the structural assertion.  The helpers below are
-- deliberately hand-written self-tail loops for the same reason.

-- A local record literal read by three fields in a DIFFERENT order from
-- construction: `assoc` + `snd` per read, plus the whole `@p`/`cons`/
-- `emptylist` chain, are all gone.
recLocal : Int
recLocal =
    let
        r =
            { a = 1, b = 2, c = 3 }
    in
    r.c + 10 * r.a + 100 * r.b


-- A record-pattern DESTRUCTURING LET (a `LetDestruct` whose binds are
-- `VField []`): the fields come straight out of the components.
recPatternLet : Int
recPatternLet =
    let
        { x, y } =
            { x = 7, y = 8 }
    in
    x + 10 * y


-- The same `VField` machinery as a case scrutinee's pattern.
recPatternCase : Int
recPatternCase =
    case { x = 4, y = 9 } of
        { x, y } ->
            x + 100 * y


-- A record read whose value is used ACROSS an allocation: `a` comes out of a
-- flattened record into a frame slot, 200000 cons cells are allocated (the
-- collector runs mid-build under CHURN_MB), and `a` is read again afterwards.
-- A component that were not rooted would change value here.
recNested : Int
recNested =
    let
        r =
            { inner = 5, other = 6 }
    in
    r.inner + 10 * r.other


type Wrap
    = Wrap Int


-- An ADT construction consumed by a local case: `rt_con` (plus its argument
-- staging array) and the `MVector`/`MTagEq` tests are all gone.
conLocal : Int
conLocal =
    let
        w =
            Wrap 21
    in
    case w of
        Wrap n ->
            n + 100


-- A NULLARY constructor: `rt_con` with 0 args, matched by a `MVector` tag
-- test with no element.
conNullary : Int
conNullary =
    let
        m =
            Nothing
    in
    case m of
        Just n ->
            n

        Nothing ->
            55


-- A tuple is a right-nested cons chain (`@p` is not involved; `cons` is), and
-- the tuple pattern reads it with FstStep/SndStep.
tupLocal : Int
tupLocal =
    let
        p =
            ( 3, 4 )
    in
    case p of
        ( a, b ) ->
            a + 10 * b


-- A ListLit matched by an EXACT list pattern: both `MCons` cells and the
-- trailing `MEmpty` decide statically, and the element binds are HdStep/TlStep
-- reads out of the components.
listLocal : Int
listLocal =
    let
        l =
            [ 5, 6, 7 ]
    in
    case l of
        [ a, b, c ] ->
            a + 10 * b + 100 * c

        _ ->
            0


recRooted : Int
recRooted =
    let
        r =
            { a = 11, b = 12 }

        big =
            go 200000 []

        unused =
            big
    in
    r.a + 10 * r.b


-- A hand-written self-tail allocator (NOT List.range / List.foldl): the
-- positive fixture must not drag a Prelude defun with aggregate prims into the
-- reachable set.
go : Int -> List Int -> List Int
go n acc =
    if n == 0 then
        acc

    else
        go (n - 1) (n :: acc)


main : Int
main =
    recLocal
        + recPatternLet
        + recPatternCase
        + recNested
        + conLocal
        + conNullary
        + tupLocal
        + listLocal
        + recRooted
