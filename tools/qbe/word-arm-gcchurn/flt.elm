module M exposing (main)

-- A FLOAT CELL HELD ACROSS COLLECTIONS, ON THE WORD ARM (perf word-arm-floats).
-- The COLLECTING oracle for the float class; the behavioural half is
-- tools/qbe/word-arm-diff/floatlit.elm.
--
-- WHY A FLOAT NEEDS A COLLECTING ROW AT ALL, and why it is the SECOND half of
-- this unit rather than a formality.  Porting the float literal turned a
-- NON-ALLOCATING construct into an ALLOCATING one: on the val arm a literal is
-- `storew tagFloat` + `stored slot+8` and allocates nothing, while on the word
-- arm it is a code-12 block allocated by the EMITTER (`storeWordFloatCell` ->
-- `q_Rt_x2eallocFloat`).  That is a new allocation window inside every defun
-- that mentions a float, and it is the reason this unit also had to change the
-- runtime's own frame decision (`Mid.Rt.unsafeSafepoint`'s `RawMkValue` arm): a
-- word-arm `mk*` whose cell writer allocates is a DIRECT SAFEPOINT, or the defun
-- is classified FRAME-FREE and its live values are dropped on the floor.
--
-- WHAT THE LOOP HOLDS ACROSS THE ALLOCATION, and why each part is there:
--   * `( s, f ) = p`  — a RUNTIME-BUILT STRING (a code-1 cell with inline
--     bytes) and a RUNTIME-BUILT FLOAT CELL (`Basics.toFloat i * 0.5`, i.e. `Rt.*`'s float arm:
--     `Rt.asF` on the fixnum, then `mkflt`), both live in frame slots;
--   * `noise = churn 12` — the allocation window between the binds and their
--     use, so a scavenge lands while BOTH are live.  The string is scanned
--     through the slot; the float's body is RAW (`heapKindScanned` false), so
--     the collector never traces it — a float cell that is reclaimed shows up as
--     a WRONG DOUBLE, not a crash, which is exactly why a value check is needed;
--   * `again = pair f s` — both binds re-read as a SCRUTINEE of a call result,
--     so a slot written at the wrong width (8 bytes is right on this arm; a
--     40-byte `valSizeBytes` blit is the `reboxArg` defect) is re-read here;
--   * the two checks are computed by DIFFERENT ROUTES on purpose: `s` against a
--     REBUILT string (`String.fromInt`, which walks bytes, so a reclaimed or
--     wrongly-strided cell reads the wrong CONTENT while its length still looks
--     right), and `f` against `Basics.toFloat i / 2.0` (`Rt.f/`, which reads its operand through
--     `fload` after `Rt.asF` and builds a fresh cell through `mkflt`) — so a
--     mangled float cell disagrees with an independently computed one instead of
--     matching itself.
--
-- OUTPUT is `examined/matched/mismatched`; expected 6000/6000/0 at every heap
-- size, on both arms.  The val arm is the oracle: no expected count is spelled
-- here, because a hard-coded number would be a second thing to keep in step and
-- a wrong one would bless a wrong answer on both arms at once.

pair a b =
    ( a, b )


mk i =
    ( String.fromInt i, Basics.toFloat i * 0.5 )


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


step xs examined matched mismatched =
    case xs of
        [] ->
            String.append (String.fromInt examined)
                (String.append "/"
                    (String.append (String.fromInt matched) (String.append "/" (String.fromInt mismatched)))
                )

        p :: rest ->
            let
                ( s, f ) =
                    p

                noise =
                    churn 12

                again =
                    pair f s

                ( f2, s2 ) =
                    again

                n =
                    examined + 1
            in
            if (s == String.fromInt n) && (s2 == s) && (f == Basics.toFloat n / 2.0) && (f2 == f) && (noise == churn 12) then
                step rest n (matched + 1) mismatched

            else
                step rest n matched (mismatched + 1)


main =
    step (build 6000 []) 0 0 0
