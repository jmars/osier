module M exposing (main)

-- THE HOST EVENT LOOP UNDER COLLECTION, ON THE WORD ARM (perf
-- word-arm-hostpath).  The COLLECTING oracle for the host program path; the
-- behavioural half is tools/qbe/word-arm-diff/hostprog.elm.
--
-- WHY A COLLECTING ROW IS THE ONLY ORACLE THAT CAN SEE THIS CLASS.  The host
-- loop's state is ONE malloc'd blob, and the model lives in slot 0 of a
-- 33031-entry array that `Rt.hostInit` registers with
-- `rootPushValueArray(blob + 8, blob)` — whose live count is `lp->nslots` and
-- whose SCAN STRIDE IS THE LAYOUT'S.  A stride that disagrees with the array's
-- real element width does not crash and does not print wrong: it walks past the
-- registered cells into the rest of the blob and, when a collection MOVES the
-- model, rewrites a slot the program does not read while leaving the one it does
-- read pointing at the old, reused block.  The symptom is a wrong model at rc 0
-- with empty stderr — exactly the `[vector 4]` shape the class was found by.
-- Nothing below one collection can distinguish a correct stride from a wrong one,
-- so a row that does not collect is not coverage and is labelled a REGRESSION
-- row instead.
--
-- WHAT THE LOOP DOES, and why each part is there:
--   * the MODEL is a record of (String, Int, Int) and the string GROWS every
--     step, so the model itself is a freshly allocated cell at every collection —
--     a moved model is what exercises the slot array's scan;
--   * each update SPAWNS the next one, so the loop runs long enough to cross the
--     trigger at QBE_HEAP_MB=1 and the fixpoint drain has work on every
--     iteration;
--   * THE CHAIN IS SINGLE, deliberately, and that is a MEASURED decision: with
--     four concurrent chains (the first version of this fixture) the `Done`
--     branch fires once per chain, so four markers land in the log and the
--     rebuild below compares 4004 against 4045 — a check that says `/bad` on
--     BOTH arms, i.e. one that discriminates nothing.  Several live slots at
--     once is `word-arm-diff/hostprog.elm`'s axis (`Cmd.batch` of three tasks,
--     with the second generation spawned from an update); this row's axis is the
--     SCAN STRIDE, and one chain makes its arithmetic exact;
--   * the check compares the final string against one REBUILT from the step
--     count (`String.repeat`), which walks the bytes — a reclaimed or
--     wrongly-strided string cell reads the wrong CONTENT while its length still
--     looks right.
--
-- OUTPUT is `steps/len/ok|bad`.  The val arm is the oracle: no expected count is
-- spelled here, because a hard-coded number would be a second thing to keep in
-- step and a wrong one would bless a wrong answer on both arms at once.

type Msg
    = Tick Int
    | Done


type alias Model =
    { log : String
    , total : Int
    , steps : Int
    , xs : Int
    }


-- THE REBUILD.  The check cannot be `String.length model.log == model.steps`:
-- MEASURED, that compared 4003 against 4004 on BOTH arms and printed `/bad`
-- everywhere, i.e. a check that says the same thing on both sides and therefore
-- discriminates nothing.  A REBUILD from a counter the loop itself maintains is
-- a real content comparison — it walks the bytes, so a reclaimed or
-- wrongly-strided string cell answers the wrong CONTENT while its length still
-- looks right (the reason the `str` churn row's check is written this way).
build : Int -> String -> String
build n acc =
    if n <= 0 then
        acc

    else
        build (n - 1) (String.append acc "x")


limit : Int
limit =
    4000


main =
    Platform.program { init = init, update = update, subscriptions = \_ -> Sub.none }


init () =
    ( { log = "", total = 0, steps = 0, xs = 0 }
    , Task.perform (\_ -> Tick 1) (Task.succeed ())
    )


update msg model =
    case msg of
        Tick k ->
            ( { model
                | log = String.append model.log "x"
                , total = model.total + k
                , steps = model.steps + 1
                , xs = model.xs + 1
              }
            , if model.steps < limit then
                Task.perform (\_ -> Tick k) (Task.succeed ())

              else
                Task.perform (\_ -> Done) (Task.succeed ())
            )

        Done ->
            ( { model
                | log =
                    String.append model.log
                        (if model.log == build model.xs "" then
                            "/ok"

                         else
                            "/bad"
                        )
              }
            , Cmd.none
            )
