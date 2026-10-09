port module Main exposing (main)

-- M1b -> M3 -> batch: orchestrate the Elm -> ZINC-csexp compiler pipeline.
--
-- Receives ALL sources via flags:
--   {corpusSourcesJson} — a JSON array of the FIXED corpus module sources
--     (Prelude + Runtime + the eight core-libs), parsed+typechecked+lowered
--     ONCE per process.
--   {groupsJson}        — a JSON array of JSON arrays: one source list per
--     fixture group (1-2 user modules each).
--   {midtier}           — the MIDDLE-TIER switch (S1, default false).  false
--     (MIDTIER=0) lowers straight from the AST via Lower.Module — the
--     byte-identity ANCHOR; true (MIDTIER=1) goes through the Mid IR
--     (Mid.FromAst -> Mid.ToZinc), which in stage 1 carries ZERO optimization
--     passes and must emit the SAME BYTES (tools/midtier-diff.sh).
--
-- THE SWITCH LIVES HERE, NOT IN Lower.Module, ON PURPOSE: the only place a
-- shared driver could dispatch from is one of the 58 sources in
-- elm-compiler/selfhost/manifest.json, and those 58 ARE the committed
-- bootstrap seed (tools/bootstrap/selfhost.csexp) — editing any of them
-- changes the seed by construction.  Main.elm is the driver (not a manifest
-- source), so MIDTIER=1 can reproduce the seed's exact bytes.
--
-- Lower.Module.compileBatch / Mid.Module.compileBatch turn the flags into ONE
-- bundle text per group (the corpus bundle entries reused across groups); the
-- corpus is paid for once, so compiling all N fixtures in this single process
-- costs ~1 corpus pass instead of N.  Emits over the `emit` port a single JSON
-- ARRAY of per-group strings (the bundle text, or "err <msg>" for that group
-- alone); run.js writes each element to its group's output .csexp.
--
-- The `modeReport` port exists so the differential can PROVE which path ran
-- (run.js subscribes only when MIDTIER_TRACE=1, and prints it to stderr): a
-- byte-identity check whose subject never engaged would otherwise pass
-- vacuously.

import Json.Decode as JD
import Json.Encode as JE
import Lower.Module as Module
import Mid.Module as MidModule
import Mid.QbeModule as QbeModule
import Mid.Simplify as Simplify
import Platform


port emit : String -> Cmd msg


port modeReport : String -> Cmd msg


type alias Flags =
    { corpusSourcesJson : String
    , groupsJson : String
    , midtier : Bool
    , passes : Passes
    , inlineThreshold : Int
    , stats : Bool
    , qbe : Bool
    , qbeEntry : String
    , qbeFlatten : Bool
    , qbeRep : Bool
    }


{-| The middle tier's per-pass switches (`Mid.Simplify`'s flag scheme, which is
documented there and in one place only).  `MIDTIER=1` with no flags arrives
here with every field True — "all passes on" is the zero-configuration shape.
-}
type alias Passes =
    { shrink : Bool
    , constFold : Bool
    , inline : Bool
    , arity : Bool
    , deadGlobals : Bool
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
    let
        ( payload, report ) =
            compileAll flags
    in
    ( (), Cmd.batch [ modeReport (modeLine flags report), emit payload ] )


{-| The mode report, extended with the PASS REPORT when MIDTIER_STATS=1.

The mode word stays FIRST and unmodified (`mode=mid` / `mode=lower`) because
the differential greps for it to prove that the switch ENGAGED: a byte- or
behaviour-differential whose subject never ran would otherwise pass vacuously.

The pass report is on the same channel rather than a new port for the same
reason the port exists at all: it must arrive from the compiler, and a second
port would be a second thing that can silently fail to fire.
-}
modeLine : Flags -> List String -> String
modeLine flags report =
    let
        mode =
            if flags.qbe then
                qbeName flags.qbeEntry

            else
                pathName flags.midtier
    in
    if flags.stats && not (List.isEmpty report) then
        mode ++ " passes=[" ++ String.join " | " report ++ "]"

    else
        mode


pathName : Bool -> String
pathName midtier =
    if midtier then
        "mode=mid"

    else
        "mode=lower"


qbeName : String -> String
qbeName entry =
    "mode=qbe entry=" ++ entry


passConfig : Flags -> Simplify.Config
passConfig flags =
    { shrink = flags.passes.shrink
    , constFold = flags.passes.constFold
    , inline = flags.passes.inline
    , arity = flags.passes.arity
    , deadGlobals = flags.passes.deadGlobals
    , inlineThreshold = flags.inlineThreshold
    }


{-| `payload` is the emit-port string (the per-group bundle JSON); `report` is
the middle tier's pass report (empty on the MIDTIER=0 path, which never reaches
Mid.Module — that is what keeps the byte-identity anchor structural).
-}
compileAll : Flags -> ( String, List String )
compileAll flags =
    case
        ( JD.decodeString (JD.list JD.string) flags.corpusSourcesJson
        , JD.decodeString (JD.list (JD.list JD.string)) flags.groupsJson
        )
    of
        ( Ok corpusSources, Ok groups ) ->
            if flags.qbe then
                -- NATIVE backend slice (handoff-qbe-lower): one .ssa text per
                -- group lowered from the entry defun, or "err <msg>".  The
                -- ZINC paths below are untouched.
                ( encodeStrings
                    (List.map
                        (\groupSources ->
                            case QbeModule.compileEntry corpusSources groupSources flags.qbeEntry flags.qbeFlatten flags.qbeRep of
                                Ok ssa ->
                                    ssa

                                Err msg ->
                                    "err " ++ msg
                        )
                        groups
                    )
                , []
                )

            else if flags.midtier then
                let
                    batch =
                        MidModule.compileBatch (passConfig flags) corpusSources groups
                in
                case batch.bundles of
                    Ok bundles ->
                        ( encodeStrings bundles, batch.report )

                    Err msg ->
                        -- Corpus-level failure: every group reports the same err.
                        ( encodeStrings (List.map (\_ -> "err " ++ msg) groups), batch.report )

            else
                case Module.compileBatch corpusSources groups of
                    Ok bundles ->
                        ( encodeStrings bundles, [] )

                    Err msg ->
                        ( encodeStrings (List.map (\_ -> "err " ++ msg) groups), [] )

        _ ->
            ( encodeStrings [ "err internal: bad flags" ], [] )


encodeStrings : List String -> String
encodeStrings strings =
    JE.encode 0 (JE.list JE.string strings)
