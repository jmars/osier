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
--   {qbeFlatten}/{qbeRep}/{...}/{qbeMono}/{qbeWordVal} — the QBE backend's
--     A/B switches (see run.js).  `qbeWordVal` is `QBE_VALREP=word` (VR3b1):
--     it selects the WORD value-representation instance, which the emitter
--     does not lower yet — it stops with a loud error naming the construct.
--   {qbeWordArmProbe} — `QBE_WORDARM_PROBE=<name>` (perf VR3b3): emit ONE
--     word-arm BEHAVIOUR PROBE (`Mid.Qbe.WordArmProbe`) instead of compiling
--     the groups.  This is the CLI route `tools/qbe/word-arm-probe.sh` uses to
--     produce a module it can ASSEMBLE AND RUN — the only oracle that sees the
--     word arm at all, because every real program stops at the runtime
--     (AREA 6).  Empty = the ordinary compile path.
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

import Dict
import Json.Decode as JD
import Json.Encode as JE
import Mid.Qbe.Lower as QbeLower
import Mid.Qbe.Print as QbePrint
import Mid.Qbe.Types as QbeTypes
import Mid.Qbe.WordArmProbe as WordArmProbe
import Mid.QbeModule as QbeModule
import Mid.Rt as MidRt
import Mid.RtLayout as RtLayout
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
    , qbeMidGcYoung : Bool
    , qbeLeafFree : Bool
    , qbeWordVal : Bool
    , qbeWordArmProbe : String
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
    -- (perf VR3c) the arm splice: `QBE_VALREP=word` selects the runtime text's
    -- word-arm regions (`Mid.Rt.loadArm`); on the val arm this is byte-for-byte
    -- the text this hoist always parsed.
    case MidRt.loadArm flags.qbeWordVal flags.runtimeMidJson of
        Err msg ->
            encodeStrings [ "err " ++ msg ]

        Ok rt ->
          if flags.qbeWordArmProbe /= "" then
            encodeStrings [ probeModule rt flags.qbeWordArmProbe ]

          else
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
                                    case QbeModule.compileEntry rt corpusSources groupSources groupMids entry (toQbeFlags flags) of
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


{-| THE PORT FLAGS -> the backend's PACKED FLAG VECTOR.  This is the ONE
translation site for the node driver (VR3b1: the vector is a record because the
positional form crossed the language's own 16-parameter ceiling — see
`Mid.QbeModule.Flags`).  `midGc` is the RETIRED collector switch: the Mid
collector is the only one, so it is the literal True and no arm reads it (it is
kept in the shape only because `selfhost/NativeMain.elm`'s twin must agree with
this one on every field).
-}
toQbeFlags : Flags -> QbeModule.Flags
toQbeFlags flags =
    { flatten = flags.qbeFlatten
    , rep = flags.qbeRep
    , primDirect = flags.qbePrimDirect
    , midRt = flags.qbeMidRt
    , midCons = flags.qbeMidCons
    , rtLean = flags.qbeRtLean
    , mono = flags.qbeMono
    , wordVal = flags.qbeWordVal
    , consArr = flags.qbeConsArr
    , rec = flags.qbeRec
    , typeSpec = flags.qbeTypeSpec
    , midGc = True
    , midGcYoung = flags.qbeMidGcYoung
    , leafFree = flags.qbeLeafFree
    , eqPtrFast = flags.qbeEqPtrFast
    }


{-| `QBE_WORDARM_PROBE=<name>`: emit ONE behaviour probe's module under the WORD
arm, for `tools/qbe/word-arm-probe.sh` to assemble and RUN.  The probe's defun
comes from `Mid.Qbe.WordArmProbe` (the SAME definitions TestMain pins), and the
lowering is the ordinary `Mid.Qbe.Lower.lowerWith` call with the word instance —
so what runs is exactly what the emitter produces, not a hand-written module.
-}
probeModule : MidRt.Runtime -> String -> String
probeModule rt wanted =
    case List.filter (\m -> WordArmProbe.name m == wanted) WordArmProbe.modules of
        m :: _ ->
            let
                ds =
                    WordArmProbe.defuns m

                d =
                    WordArmProbe.defun m
            in
            case
                QbeLower.lowerWith RtLayout.wordLayout
                    rt
                    False
                    False
                    False
                    True
                    True
                    True
                    True
                    False
                    False
                    True
                    QbeTypes.empty
                    (Dict.fromList (List.map (\x -> ( x.key, WordArmProbe.arity x )) ds))
                    ds
                    d.key
            of
                Ok mod ->
                    QbePrint.print mod

                Err msg ->
                    "err " ++ msg

        [] ->
            "err QBE_WORDARM_PROBE="
                ++ wanted
                ++ " is not a probe (known: "
                ++ String.join ", " (List.map WordArmProbe.name WordArmProbe.modules)
                ++ ")"


encodeStrings : List String -> String
encodeStrings strings =
    JE.encode 0 (JE.list JE.string strings)
