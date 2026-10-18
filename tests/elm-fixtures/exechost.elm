module ExecHost exposing (main)

-- STAGE 7D gate: TaskExec through the EFFECT HOST — the async single-command
-- path (fork + piped capture + poll + waitpid), which NO pre-existing fixture
-- reaches.  The eight `exec*` rows beside this one in the gate are all
-- `Platform.worker` fixtures: `Runtime.runTask` drives them SYNCHRONOUSLY
-- through the `exec-plan` PRIM, so none of them ever constructs a Program
-- vector or enters the host's TaskExec leaf (MEASURED: they are green on both
-- arms with the leaf absent, which is why this row exists).
--
-- ONE plain command, so the host takes its async arm, and every piece of that
-- arm is exercised at once:
--   * `seq 20000 | tr -d '\n'` writes 88894 bytes with no separators — more
--     than the 65536-byte drain chunk, so the OUT accumulator GROWS
--     (double-and-copy) while the child is blocked writing into a full pipe:
--     the loop can only finish by polling and draining, which is the async
--     machinery itself.  The digits-only payload is deliberate: the model can
--     then print the FIRST 11 bytes (`String.sliceLen`), so a grow that lost
--     or mis-ordered the first chunk is a VALUE change and not merely a
--     length one (a lost chunk leaves `blen` right — it counts what was read);
--   * `printf oops 1>&2` puts 5 bytes on the ERR accumulator — the only row
--     where the captured stderr is non-empty through the host (fastexec and
--     signaldeathasync both leave it ""), so the second accumulator and its
--     own buffer are covered;
--   * `exit 3` is a NON-ZERO code that is not a signal: the reap path must
--     decode WIFEXITED/EXITSTATUS (signaldeathasync covers the WIFSIGNALED
--     arm), and the model prints the code, both LENGTHS and the err BYTES.
--
-- Golden = "3|88894|12345678910|oops" (code | length of out | out's first 11
-- bytes | captured stderr).

type Msg
    = Got ( Int, String, String )


main =
    Platform.program { init = init, update = update, subscriptions = \_ -> Sub.none }


argv =
    Plan.cons (Plan.str "sh")
        (Plan.cons (Plan.str "-c")
            (Plan.cons (Plan.str "seq 20000 | tr -d '\\n'; printf oops 1>&2; exit 3") Plan.nil)
        )


cmd =
    Plan.cons argv (Plan.cons Plan.nil (Plan.cons Plan.nil Plan.nil))


pipeline =
    Plan.cons cmd Plan.nil


chain =
    Plan.cons (Plan.sym "seq") (Plan.cons pipeline Plan.nil)


plan =
    Plan.cons chain Plan.nil


init () =
    ( "", Task.perform Got (Io.exec plan) )


update msg model =
    case msg of
        Got ( code, out, err ) ->
            ( String.join "|"
                [ String.fromInt code
                , String.fromInt (String.length out)
                , String.sliceLen 0 11 out
                , err
                ]
            , Cmd.none
            )
