module M exposing (main)

-- THE RECORD FAMILY, CLASS 3: UPDATE + INSERTION (perf word-arm-records R4).
--
-- The word arm's record is ONE code-14 block `[data_0 .. data_{n-1} | namesBase]`,
-- so an update copies the data words AND carries the names word, and an
-- INSERTION must also build a new names array — a block of raw name-byte
-- pointers with the new name spliced in at its SORTED position.
--
-- Four routes, each reaching a different defun:
--   * `{ base | x = 9 }`  — the CLOSED update      -> Rt.recUpdCopy
--   * `ins r = { r | z <- 7 }` on a bare parameter — the WALK update, which is
--     the insertion route                          -> Rt.recInsert/recAppend
--   * `.z` on the inserted record — the field the runtime ADDED, so the names
--     array it built is the only way to find it    -> Rt.recGet (walk) or the
--     positional read, depending on the row
--   * `{ a | y = 5 }` on an ALREADY-built record — the update of an APPENDED
--     record, i.e. a names array this unit allocated, not a static blob.
main =
    let
        base =
            { x = 1, y = 2 }

        upd =
            { base | x = 9 }

        ins r =
            { r | z <- 7 }

        a =
            ins base

        b =
            ins upd

        c =
            { a | y = 5 }
    in
    [ upd.x, upd.y, a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z ]
