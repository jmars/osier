module Record exposing (main, fields, upd)

-- RecordLit / RecordGet / RecordUpdate.  The VM represents a record as an
-- assoc list of (field . value) pairs in SOURCE order (Mid.ToZinc RecordLit),
-- read back with assoc + snd.  `main` returns the record so the FULL printed
-- assoc-list structure is compared (field ORDER parity); `fields` reads the
-- fields back in a DIFFERENT order and combines them into one number (assoc/
-- snd correctness); `upd` returns an updated record (first-occurrence update,
-- domain-preserving: every field must still be present, with the new value).

type alias Inner =
    { a : Int, b : Int }


type alias Rec =
    { name : String, x : Int, y : Int, inner : Inner }


mk : Rec
mk =
    { name = "ada", x = 1, y = 2, inner = { a = 3, b = 4 } }


-- reads y before x (construction order is name/x/y/inner), and the nested
-- record's fields too — a wrong assoc arg order or fst/snd swap changes this.
fields : Int
fields =
    mk.y + 10 * mk.x + 100 * mk.inner.a + 1000 * mk.inner.b


-- update two fields (one nested); the untouched fields must survive.
upd : Rec
upd =
    let
        r =
            mk
    in
    { r | x = 30, inner = { a = 40, b = 50 } }


-- read the UPDATED record back: the new value must win (first-occurrence),
-- and the untouched fields must still be present (domain-preserving).
readUpd : Int
readUpd =
    let
        r0 =
            mk

        r =
            { r0 | x = 30 }
    in
    r.x + 10 * r.y + 100 * r.inner.a + 1000 * r.inner.b


main =
    mk
