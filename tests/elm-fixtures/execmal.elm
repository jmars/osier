module ExecMal exposing (main)

-- 3B-2a-ii gate: a MALFORMED plan must fail LOUDLY — that is decode's whole
-- contract.  The chain's op is a symbol the decoder does not know ("bogus",
-- not seq/and/or), so Rt.epChain's OP GUARD (isSeq/isAnd/isOr all miss ->
-- op = -1 -> reject) is the arm that fires; the run must HALT with the
-- runtime's halt diagnostic instead of silently running the (otherwise
-- perfectly valid) echo pipeline behind the bad op.
--
-- The row's RED proof mutates epChain's unknown-op arm to decode as seq
-- (RtPrims.elm, the `opV` iff-chain's else): the fixture then prints
-- "0|hi\n|" and exits 0 — the silent-accept class this row exists to catch.
--
-- Coverage note: ONE malformed shape per program is all a worker can show —
-- the halt kills the process, so later rows would never run.  The other
-- malformed classes (empty pipeline, non-string argv, bad fd, dup->0, two
-- stdins, depth 33, 257 chains) are the 3B-2a equivalence battery's job,
-- compared PRE-vs-POST (see handoff-osier-stage3-g3b2a-ii).

type Msg
    = Got ( Int, String, String )


main =
    Platform.worker { init = init, update = update, subscriptions = \_ -> Sub.none }


echoArgv =
    Plan.cons (Plan.str "echo") (Plan.cons (Plan.str "hi") Plan.nil)


echoCmd =
    Plan.cons echoArgv (Plan.cons Plan.nil (Plan.cons Plan.nil Plan.nil))


pipeline =
    Plan.cons echoCmd Plan.nil


-- the malformed link: "bogus" is not a chain op
chain =
    Plan.cons (Plan.sym "bogus") (Plan.cons pipeline Plan.nil)


plan =
    Plan.cons chain Plan.nil


init () =
    ( ""
    , Task.perform Got (Io.exec plan)
    )


update msg model =
    case msg of
        Got ( code, out, err ) ->
            ( String.join "" [ String.fromInt code, "|", out, "|", err ], Cmd.none )
