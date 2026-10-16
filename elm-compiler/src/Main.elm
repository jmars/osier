port module Main exposing (main)

-- M1b -> M3 -> batch: orchestrate the Elm -> QBE-IL compiler pipeline.
--
-- Receives ALL sources via flags:
--   {corpusSourcesJson} — a JSON array of the FIXED corpus module sources
--     (Prelude + Runtime + the eight core-libs), parsed+typechecked+lowered
--     ONCE per process.
--   {groupsJson}        — a JSON array of JSON arrays: one source list per
--     fixture group (1-2 user modules each).
--   {entriesJson}       — a JSON array of strings, one ENTRY DEFUN KEY per
--     group ("<Mod>.<fn>"): the QBE backend roots reachability at the
--     group's own entry, so a batch can lower every group in one process.
--   {qbeFlatten}/{qbeRep}/{...}/{qbeMono} — the QBE backend's A/B switches
--     (see run.js).
--
-- P8 (osier-delete-zinc): this driver is QBE-ONLY.  The ZINC-csexp output
-- paths (the direct AST lowerer `Lower.Module` and the middle-tier driver
-- `Mid.ToZinc.compileBatch` behind the MIDTIER switch) are deleted; every
-- compile lowers through `Mid.QbeModule.compileEntry` and emits QBE IL text
-- (.ssa) per group, or "err <msg>".
--
-- Lower.Module.compileBatch / Mid.ToZinc.compileBatch used to turn the flags
-- into ONE bundle text per group (the corpus bundle entries reused across
-- groups); the corpus is still paid for once inside QbeModule, so compiling
-- all N fixtures in this single process costs ~1 corpus pass instead of N.
-- Emits over the `emit` port a single JSON ARRAY of per-group strings; run.js
-- writes each element to its group's output file.

import Json.Decode as JD
import Json.Encode as JE
import Mid.QbeModule as QbeModule
import Mid.Rt as MidRt
import Platform


port emit : String -> Cmd msg


type alias Flags =
    { corpusSourcesJson : String
    , groupsJson : String
    , midsJson : String
    , entriesJson : String
    , runtimeMidJson : String
    , qbeFlatten : Bool
    , qbeRep : Bool
    , qbePrimDirect : Bool
    , qbeMidRt : Bool
    , qbeMidCons : Bool
    , qbeRtLean : Bool
    , qbeMono : Bool
    , qbeConsArr : Bool
    , qbeRec : Bool
    , qbeEqPtrFast : Bool
    , qbeTypeSpec : Bool
    , qbeMidGc : Bool
    , qbeMidDriver : Bool
    }


type Msg
    = Noop


main : Program Flags () Msg
main =
    Platform.worker
        { init = init
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }


init : Flags -> ( (), Cmd Msg )
init flags =
    ( (), emit (compileAll flags) )


compileAll : Flags -> String
compileAll flags =
    -- M1: the runtime surface text is parsed ONCE per process, here — the
    -- hoist that keeps the corpus wall ~16 s-class (the O(n^2) re-parse wall
    -- returns if this becomes per-compileEntry-call).  A runtime.mid that does
    -- not parse fails EVERY group loudly — never a silently-reduced runtime.
    case MidRt.load flags.runtimeMidJson of
        Err msg ->
            encodeStrings [ "err " ++ msg ]

        Ok rt ->
            case
                ( ( JD.decodeString (JD.list JD.string) flags.corpusSourcesJson
                  , JD.decodeString (JD.list (JD.list JD.string)) flags.groupsJson
                  , JD.decodeString (JD.list (JD.list JD.string)) flags.midsJson
                  )
                , JD.decodeString (JD.list JD.string) flags.entriesJson
                )
            of
                ( ( Ok corpusSources, Ok groups, Ok mids ), Ok entries ) ->
                    if List.length groups /= List.length entries || List.length groups /= List.length mids then
                        encodeStrings [ "err internal: groups/entries/mids length mismatch" ]

                    else
                        encodeStrings
                            (List.map3
                                (\groupSources groupMids entry ->
                                    case QbeModule.compileEntry rt corpusSources groupSources groupMids entry flags.qbeFlatten flags.qbeRep flags.qbePrimDirect flags.qbeMidRt flags.qbeMidCons flags.qbeRtLean flags.qbeMono ( ( flags.qbeConsArr, ( flags.qbeRec, flags.qbeTypeSpec, ( flags.qbeMidGc, flags.qbeMidDriver ) ) ), flags.qbeEqPtrFast ) of
                                        Ok ssa ->
                                            ssa

                                        Err msg ->
                                            "err " ++ msg
                                )
                                groups
                                mids
                                entries
                            )

                _ ->
                    encodeStrings [ "err internal: bad flags" ]


encodeStrings : List String -> String
encodeStrings strings =
    JE.encode 0 (JE.list JE.string strings)
