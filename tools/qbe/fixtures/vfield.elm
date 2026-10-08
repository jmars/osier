module VField exposing (main, letField, nestedField, mixedCase, rootedField)

-- VField: record FIELD PATTERNS.  A field pattern reads its record via the
-- same Step machinery as every other pattern (fst/snd/hd/tl/Idx), then looks
-- the field up the VM's way: snd (assoc (sym field) rec) — exactly
-- Mid.ToZinc's VField and this slice's own RecordGet (buildRecordGet), so
-- parity is by construction.  Records are assoc lists of (field . value)
-- pairs in source order; assoc searches by NAME, so field ORDER never
-- matters for a pattern (unlike a RecordLit read-back, which it does).

type alias Point =
    { x : Int, y : Int }


-- 1. a destructuring LET with a (top-level) field pattern: {x, y} = p —
--    VField [] (no steps: the record is the scrutinee itself).
letField : Int
letField =
    let
        p =
            { x = 3, y = 4 }

        { x, y } =
            p
    in
    x + 10 * y


-- 2. a NESTED field pattern: a record pattern inside a ctor pattern, so the
--    field read walks IdxStep 1 (the ctor's first arg = the record) before
--    assoc+snd — VField [IdxStep 1].
type Wrapped
    = Wrap Point


nestedField : Int
nestedField =
    case Wrap { x = 5, y = 6 } of
        Wrap { x, y } ->
            x + 100 * y


-- 3. a field pattern ALONGSIDE other pattern kinds in ONE case: a field-
--    pattern alt (Pick), a ctor + string-literal alt, a ctor + wildcard alt,
--    and a nullary-ctor alt.  The field-pattern bind runs AFTER its alts'
--    tests, in the same ordered-alt block flow as the others.
type Choice
    = Pick Point
    | Tag String
    | None


score : Choice -> Int
score c =
    case c of
        Pick { x, y } ->
            x + 1000 * y

        Tag "special" ->
            777

        Tag _ ->
            888

        None ->
            999


mixedCase : Int
mixedCase =
    score (Pick { x = 1, y = 2 })
        + score (Tag "special")
        + score (Tag "other")
        + score None


-- 4. a field pattern whose value is then USED ACROSS AN ALLOCATION: x is read
--    out of the record into a rooted slot, `big = go 200000 []` allocates
--    200000 cons cells (the collector runs mid-build under CHURN_MB), and x
--    is used again AFTER the allocation.  If the VField binding's slot were
--    unrooted/stale, x would change value — the rooting path, behaviourally.
go : Int -> List Int -> List Int
go n acc =
    if n == 0 then
        acc

    else
        go (n - 1) (n :: acc)


sumTail : List Int -> Int -> Int
sumTail l acc =
    case l of
        h :: t ->
            sumTail t (acc + h)

        [] ->
            acc


rootedField : Int
rootedField =
    let
        r =
            { x = 7 }

        { x } =
            r

        big =
            go 200000 []
    in
    x + sumTail big 0


main =
    letField + nestedField + mixedCase + rootedField
