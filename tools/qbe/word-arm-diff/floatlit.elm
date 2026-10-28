module M exposing (main)

-- THE FLOAT CELL AND `fload` ON THE WORD ARM (perf word-arm-floats).
--
-- Until this unit NO float could exist under `QBE_VALREP=word`: a float literal
-- was refused by the classifier ("the word arm heap-boxes a float as a
-- `[hdr | f64]` cell, WHICH DOES NOT EXIST YET") and `f/` by the inline-prim
-- list.  Both refusals described a path that already worked — the cell is
-- `storeWordFloatCell` (built for the runtime's `mkflt` lane since perf
-- word-arm-area3rt) — so the port was two admissions plus the site the admission
-- EXPOSED: `RawLoadFlt` (`fload`), which read `slot + 8` of a one-word slot, i.e.
-- THE NEXT FRAME SLOT, and which every float reader in the runtime goes through.
--
-- WHAT THIS FIXTURE IS FOR.  It is the only oracle that RUNS a float on both
-- representations and compares the BYTES.  A word-arm float is a code-12 heap
-- block whose body unit 0 is the f64 — so the ways to get it wrong are a wrong
-- body offset, a missing `allocFloat` (a cell the collector hands out twice), a
-- `fload` that reads the slot instead of the body, and a tag that is not the
-- heap pointer tag.  Each shows up here as a different number, a crash, or (the
-- silent one) the value of a neighbouring slot.
--
-- EVERY VALUE IS PRODUCED BY A DEFUN, deliberately.  A tuple of literals would
-- be resolved by Flatten before the emitter ever saw it — the mistake perf
-- word-arm-letdestr's review caught in two of its own fixtures — so the shapes
-- that matter (a float RETURNED from a call, a float ARGUMENT to a call) are
-- calls and nothing else.  The literals are only the defuns' operands.
--
-- THE SHAPES, and why each is here:
--   * `bump`/`twice`/`half`  — a float literal in a body, `*`, `+` and `f/`
--     (the prim that had its own refusal entry), each on an ARGUMENT, so the
--     value crosses the call ABI as a word and comes back as a cell;
--   * `pick`                 — `<` on two floats: `Rt.<`'s float arm, which
--     reads BOTH operands through `fload` after `Rt.asF`;
--   * `mixed`                — `Int + Float` (floatmix's shape): `Rt.+` promotes,
--     so `Rt.asF` builds a float cell out of a fixnum;
--   * the `flag` triple      — `==` between an Int and a Float and between two
--     Floats (`Rt.=`'s float arm), and `>` against an Int;
--   * `0.1 + 0.2`            — the printer's shortest-round-trip path
--     (`Rt.floatText` -> `Rt.fRender` -> `fload`), which is the site that
--     CRASHED (SIGABRT, empty stdout) when the `fload` fork was switched off;
--   * `lst`                  — float cells INSIDE cons cells, so the printed
--     walk reaches a code-12 object through a scanned body word (a float's body
--     is raw, so nothing traces the cell itself);
--   * `big`/`small`          — two more literals, so a wrong `flt:` data symbol
--     dedup (`floatData`'s key) would print the wrong one.
--
-- NO EXPECTED TEXT IS SPELLED HERE: the row is a DIFFERENTIAL (both arms, same
-- bytes), so the val arm is the oracle and a hard-coded golden would be a second
-- thing to keep in step.

bump x =
    x + 1.5


twice x =
    x * 2.0


half x =
    x / 2.0


pick a b =
    if a < b then
        a

    else
        b


mixed n =
    n + 2.5


main =
    let
        a =
            2.5

        b =
            bump a

        c =
            half 7.0

        d =
            twice 1.25

        e =
            0.1 + 0.2

        big =
            1.0e300

        small =
            0.000001

        flag =
            ( 2 == 2.0, 2.5 > 2, 3.0 == 3.0 )

        lst =
            [ 1.5, 2.5, half 9.0 ]

        m =
            mixed 7

        p =
            pick 1.0 2.0
    in
    ( ( a, b, c )
    , ( ( d, e, big ), ( small, flag, lst ), ( m, p, half 5.0 ) )
    , ( bump 0.5, twice 0.75, pick 3.0 4.0 )
    )
