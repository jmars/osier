module HostProg exposing (main)

-- THE HOST PROGRAM PATH, AS A PROGRAM RATHER THAN A TEXT ROW (perf
-- word-arm-hostpath).  This fixture is the class's behavioural oracle and it
-- exists because the class was a SILENT WRONG ANSWER: on the word arm the host
-- event loop's state blob was laid out with the val arm's 40-byte Value stride,
-- so seven corpus groups printed `[vector 4]` — the Program vector itself —
-- with rc 0 and NO STDERR.  A pin over the emitted text cannot see that; only a
-- program that RUNS the loop can.
--
-- WHAT IT EXERCISES, and each item is why a piece of the port is load-bearing:
--
--   * `Platform.program` -> `Runtime.program` -> the `Program` vector, then
--     `Rt.hostIsProgram` -> `Rt.hostInit`.  `hostInit` is the blob's ONE malloc:
--     `8 + 33031 * 8 + ...` on the word arm, with the model at `blob + 8` and
--     the update closure at `blob + 8 + 8`.  A wrong stride here reads the
--     update closure out of the model's slot.
--   * THREE concurrent tasks from `Cmd.batch`, so three evaluation slots are
--     live at once (`Rt.hostSpawnFromCmd`, `Rt.hostSpawnFind`,
--     `Rt.hostSpawnAt`).
--   * A spawn FROM an update (`Step` issues another `Task.perform`), which is
--     the fixpoint drain: the new task lands in a slot the step cursor has
--     already passed.  That is `Rt.hostDeliver`'s
--     `vecstore(h + 8 + (33026 * 8), ...)` path.
--   * EVERY update is a closure call of arity 2 (`msg`, `model`) reached
--     through `Rt.hostDispatch` -> `Rt.hostCall` -> `Rt.apply-at` ->
--     `Rt.callArity` -> `rt_call2`.  THAT CHAIN IS THE POINT: `Rt.apply-at`
--     hands `Rt.callArity` a slice of the ROOTED SLOT ARRAY as the argument
--     buffer, so at the val arm's 40-byte pitch against the word arm's 8-byte
--     slots the MODEL would be read from slot 5 — and a record read out of a
--     neighbouring slot prints a plausible record with the wrong field values,
--     rc 0, no stderr.  The model is a RECORD with three fields for exactly
--     that reason: a wrong slot yields a wrong record, not a crash.
--   * `String.append` per step, so the loop ALLOCATES and the collector has
--     something to move; `Rt.hostInit` registers the slot array with
--     `rootPushValueArray(blob + 8, blob)`, whose scan stride IS the layout's.
--     (The COLLECTING oracle is `word-arm-gcchurn/host.elm`; this row runs at
--     default knobs and does not claim to collect.)
--
-- THE TERMINATION IS STRUCTURAL, not a counter in the harness: `steps` reaches
-- 4 and the last update issues `Done`, whose update returns `Cmd.none`.  A wrong
-- stride cannot make it loop forever — it makes it print a different record.

type Msg
    = Seed
    | Step Int
    | Done


type alias Model =
    { log : String
    , total : Int
    , steps : Int
    }


main =
    Platform.program { init = init, update = update, subscriptions = \_ -> Sub.none }


init () =
    ( { log = "", total = 0, steps = 0 }
    , Cmd.batch
        [ Task.perform (\_ -> Seed) (Task.succeed ())
        , Task.perform (\_ -> Step 2) (Task.succeed ())
        , Task.perform (\_ -> Step 3) (Task.succeed ())
        ]
    )


update msg model =
    case msg of
        Seed ->
            ( { model | log = String.append model.log "s" }
            , Task.perform (\_ -> Step 7) (Task.succeed ())
            )

        Step k ->
            ( { model
                | log = String.append model.log "d"
                , total = model.total + k
                , steps = model.steps + 1
              }
            , if model.steps < 4 then
                Task.perform (\_ -> Step (k * 2)) (Task.succeed ())

              else
                Task.perform (\_ -> Done) (Task.succeed ())
            )

        Done ->
            ( { model | log = String.append model.log "!" }, Cmd.none )
