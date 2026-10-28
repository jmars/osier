module M exposing (main)

-- A `let` DESTRUCTURING PATTERN ACROSS COLLECTIONS, ON THE WORD ARM (perf
-- word-arm-letdestr).  The COLLECTING oracle for the destructuring class; the
-- behavioural half is tools/qbe/word-arm-diff/letdestr.elm.
--
-- WHY A COLLECTING ROW IS NEEDED FOR A CONSTRUCT THAT ALLOCATES NOTHING.  The
-- destructuring itself is alloc-free — a tag test plus pointer chases — so the
-- obvious reading is "nothing to collect, no ladder".  That reading is wrong,
-- and it is the one this row exists to refute: `lowerBind` gives every pattern
-- variable a FRESH ROOTED FRAME SLOT and the pattern's TAG TEST (`MTagEq`, which
-- the word arm answers through `Rt.=` — a CALL, i.e. an allocation site) plus
-- every value bound into those slots must survive whatever the body allocates
-- afterwards.  A slot is a root by frame registration, but a bind that wrote the
-- WRONG WIDTH — 8 bytes into an 8-byte word-arm slot is fine, a 40-byte
-- `valSizeBytes` blit of a one-word value is the `reboxArg` defect this arc
-- already paid for once — leaves a slot holding half a value, and only a
-- collection turns that into a wrong answer instead of a lucky one.
--
-- WHAT THE LOOP DOES, and why each part is there:
--   * `(P n s) = p`          — a CONSTRUCTOR destructuring whose two binds are
--     an IMMEDIATE (n) and a HEAP OBJECT (s, a runtime-built string cell);
--   * `noise = churn 12`     — an ALLOCATION WINDOW between the bind and its
--     use, so a scavenge lands while n and s are live in their slots;
--   * `( u, v ) = pair n s`  — a SECOND destructuring over the BOUND values, so
--     a slot written at the wrong width is re-read as a scrutinee.  THROUGH A
--     DEFUN, and that is load-bearing: `( u, v ) = ( n, s )` is a TUPLE of
--     Vars, which Flatten's `destructPlan` resolves (depth-1 `KindTuple`
--     binds), so the destructuring never reaches the emitter — MEASURED by the
--     word-arm-letdestr review, which found the comment claiming a window that
--     did not exist.  `pair` makes the scrutinee an APPLICATION, which Flatten
--     cannot see through;
--   * the checks compare `s` against a REBUILT string (`String.fromInt n`),
--     which walks the bytes — a reclaimed or wrongly-strided string cell reads
--     the wrong CONTENT while its length still looks right.
--
-- OUTPUT is `examined/matched/mismatched`; expected 6000/6000/0 at every heap
-- size, on both arms.  The val arm is the oracle: no expected count is spelled
-- here, because a hard-coded number would be a second thing to keep in step and
-- a wrong one would bless a wrong answer on both arms at once.

type P
    = P Int String


mk i =
    P i (String.fromInt i)


build i acc =
    if i == 0 then
        acc

    else
        build (i - 1) (mk i :: acc)


churn k =
    if k == 0 then
        ""

    else
        String.append (String.fromInt k) (churn (k - 1))


pair a b =
    ( a, b )


step xs examined matched mismatched =
    case xs of
        [] ->
            String.append (String.fromInt examined)
                (String.append "/"
                    (String.append (String.fromInt matched) (String.append "/" (String.fromInt mismatched)))
                )

        p :: rest ->
            let
                (P n s) =
                    p

                noise =
                    churn 12

                ( u, v ) =
                    pair n s
            in
            if (s == String.fromInt n) && (u == n) && (v == s) && (noise == churn 12) then
                step rest (examined + 1) (matched + 1) mismatched

            else
                step rest (examined + 1) matched (mismatched + 1)


main =
    step (build 6000 []) 0 0 0
