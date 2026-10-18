module Progio exposing (main)

-- STAGE 7B gate: the SYNCHRONOUS leaves of the Mid effect host, driven by a
-- real `Platform.program` — i.e. the ONE route that reaches the host at all.
--
-- WHY THIS FIXTURE EXISTS (MEASURED): the plan's 7B oracle row lists
-- `iofile ioecho readfile execenv`, but all four are `Platform.worker`, and
-- `Platform.worker` is `Runtime.worker`, the ELM-side SYNCHRONOUS driver
-- (`Runtime.drive` -> `runTask`) — it never builds a `Program` vector, so
-- `Rt.hostIsProgram` answers 0 and NEITHER host runs.  Arm A == arm B on
-- those rows is true and VACUOUS for the leaves.  `nowunit` is the only
-- pre-existing `Platform.program` fixture, and it only drives TaskNow and
-- TaskSleep, so without this file TaskWrite / TaskWriteFile / TaskReadLine
-- and the six prim leaves would ship unexercised by any arm-B row.
--
-- NOT COVERED HERE: TaskGlob.  MEASURED (a `Platform.program` probe built on
-- both arms): the effect host's glob leaf returns the prim's RAW tagged value
-- (`[cons, [string, name], tail]`) where the synchronous runner decodes it
-- (`Runtime.elm:174 TaskGlob -> decodeStringList (globPrim pattern)`), so a
-- program-mode glob is `"cons,[?],[?]"` on BOTH hosts today — a PRE-EXISTING
-- Zig-host defect 7B's faithful port inherits (the decode has no Mid seat
-- yet).  Pinning that shape in a golden would pin an accident, so this row
-- leaves glob out and the gap is named in handoff-s7-7b-result instead.
--
-- The chain, in order (each step is a DIFFERENT leaf).  The stdin is a
-- 260-byte line + a second line, so readLine's accumulator GROWS twice (a
-- line longer than the first 128-byte buffer) and STOPS at the newline.  The
-- growth path is otherwise only reachable by a hand probe: the first version
-- of this fixture read "hello", never grew, and a DOUBLE FREE in the grow arm
-- got past it — MEASURED: "free(): double free detected in tcache 2" on a
-- 300-byte line.
--   readLine              -> TaskReadLine           (stdin: a 260-byte line)
--   writeString           -> TaskWrite              (stdout "echo:" + the line)
--   setenv / getenv       -> TaskSetenv/TaskGetenv  (env -> "set")
--   getpid                -> TaskGetpid             (asserted only positive)
--   writeFile             -> TaskWriteFile          (out/progio.out)
--   cd / getcwd           -> TaskCd / TaskGetcwd    (cwd -> "/tmp")
--   sleep 15              -> TaskSleep              (the suspending leaf, so
--                                                    the deadline machinery is
--                                                    composed with the rest)
-- then a summary model.  The glob runs BEFORE the cd (a relative pattern), and
-- the writeFile too (a relative path).

type Msg
    = Got String


main =
    Platform.program { init = init, update = update, subscriptions = \_ -> Sub.none }


init () =
    ( "", Task.perform Got chain )


chain =
    Task.andThen afterLine Io.readLine


afterLine line =
    Task.andThen (\_ -> afterSet line)
        (Io.writeString (String.append "echo:" (String.append line "\n")))


afterSet line =
    Task.andThen (\_ -> afterEnv line) (Io.setenv "PROGIO_VAR" "set")


afterEnv line =
    Task.andThen (\env -> afterPid line env) (Io.getenv "PROGIO_VAR")


afterPid line env =
    Task.andThen (\pid -> afterWriteFile line env pid) Io.getpid


afterWriteFile line env pid =
    Task.andThen (\_ -> afterCd line env pid)
        (Io.writeFile "tests/elm-fixtures/out/progio.out"
            (String.append env (String.append "|" (String.append line "\n")))
        )


afterCd line env pid =
    Task.andThen (\_ -> afterCwd line env pid) (Io.cd "/tmp")


afterCwd line env pid =
    Task.andThen (\cwd -> afterSleep line env pid cwd) Io.getcwd


afterSleep line env pid cwd =
    Task.andThen (\_ -> Task.succeed (summary line env pid cwd)) (Io.sleep 15)


summary line env pid cwd =
    String.join "|"
        [ line
        , env
        , if pid > 0 then
            "pid-ok"

          else
            "pid-bad"
        , cwd
        ]


update msg model =
    case msg of
        Got status ->
            ( status, Cmd.none )
