module Mid.QbeModule exposing (compileEntry)

-- Mid.QbeModule — the NATIVE-backend driver: sources -> Mid.Ir -> QBE IL
-- text (.ssa) for ONE entry key (native-backend stage 1; handoff-qbe-lower).
--
-- It reuses Mid.Module's orchestration EXACTLY (parse, collect with the loud
-- import-shadowing/ambiguity checks, Type.Check, merged global arities,
-- Mid.FromAst) — exposed from that module for this purpose — and replaces
-- only the final step: instead of Mid.ToZinc/csexp it runs
--
--     reachability from the entry key  ->  Mid.Qbe.Lower  ->  peephole
--         ->  Mid.Qbe.Print
--
-- The middle tier's SIMPLIFY PASSES ARE DELIBERATELY NOT RUN: they were
-- tuned to the ZINC closure-VM cost model, and this slice measures the RAW
-- native path before any pass work is re-targeted.
--
-- OUTPUT CONTRACT: `Ok ssaText` on success; `Err msg` on any failure — an
-- unsupported construct inside a REACHED defun is a LOUD compile error, so
-- the native path can never silently miscompile (excluded constructs are
-- listed in Mid.Qbe.Lower's header).

import Dict exposing (Dict)
import Mid.Ir exposing (Defun)
import Mid.Module as MidModule
import Mid.Qbe.Flatten as QbeFlatten
import Mid.Qbe.Lower as QbeLower
import Mid.Qbe.Peephole as QbePeephole
import Mid.Qbe.Print as QbePrint
import Type.Check as Check
import Type.Env exposing (Env)


compileEntry : List String -> List String -> String -> Bool -> Result String String
compileEntry corpusSources groupSources entryKey flatten =
    case
        MidModule.parseAll corpusSources
            |> Result.andThen
                (\corpusFiles ->
                    MidModule.collectAll corpusFiles
                        |> Result.andThen
                            (\_ ->
                                Check.checkBuiltins corpusFiles
                                    |> Result.andThen
                                        (\{ env, files } ->
                                            MidModule.collectAll files
                                                |> Result.andThen
                                                    (\corpusUnits ->
                                                        case MidModule.mergedGlobals corpusUnits of
                                                            Err msg ->
                                                                Err msg

                                                            Ok corpusGlobals ->
                                                                compileGroup env corpusUnits corpusGlobals groupSources entryKey flatten
                                                    )
                                        )
                            )
                )
    of
        Ok ssa ->
            Ok ssa

        Err msg ->
            Err msg


compileGroup :
    Env
    -> List MidModule.Unit
    -> Dict String Int
    -> List String
    -> String
    -> Bool
    -> Result String String
compileGroup env corpusUnits corpusGlobals groupSources entryKey flatten =
    MidModule.parseAll groupSources
        |> Result.andThen
            (\groupFiles ->
                MidModule.collectAll groupFiles
                    |> Result.andThen
                        (\groupUnits0 ->
                            Check.checkUserGroup env (List.map .file groupUnits0)
                                |> Result.andThen
                                    (\checkedGroupFiles ->
                                        MidModule.collectAll checkedGroupFiles
                                            |> Result.andThen
                                                (\groupUnits ->
                                                    case MidModule.mergedGlobals (corpusUnits ++ groupUnits) of
                                                        Err msg ->
                                                            Err msg

                                                        Ok globals ->
                                                            lowerAll flatten globals corpusUnits groupUnits entryKey
                                                )
                                    )
                        )
            )


lowerAll :
    Bool
    -> Dict String Int
    -> List MidModule.Unit
    -> List MidModule.Unit
    -> String
    -> Result String String
lowerAll flatten globals corpusUnits groupUnits entryKey =
    compileAll globals (corpusUnits ++ groupUnits)
        |> Result.andThen
            (\program ->
                QbeLower.lower (completeArities globals program)
                    (if flatten then
                        QbeFlatten.run program

                     else
                        program
                    )
                    entryKey
            )
        |> Result.map (QbePeephole.optimize >> QbePrint.print)


-- The arity table `mergedGlobals` covers user functions + ctors ONLY; the
-- curried prim wrappers (cn.curried, c-strlen.curried, ...) that
-- Mid.Module.compileUnit appends to every unit's Program are ordinary Lam
-- defuns but NOT in that table.  The QBE lowering's direct-call dispatch
-- (Lower.lowerApp) reads the static arity from it, so a `String.append`/`++`
-- use would fail with "no arity for global cn.curried".  Complete the table
-- from the program itself: every defun is a Lam whose arity is its param
-- count, so this covers functions, ctors AND wrappers without touching the
-- shared mergedGlobals the ZINC path also reads.
completeArities : Dict String Int -> List Defun -> Dict String Int
completeArities globals program =
    List.foldl
        (\defun acc ->
            case defun.value of
                Mid.Ir.Lam lambda ->
                    Dict.insert defun.key (List.length lambda.params) acc

                _ ->
                    acc
        )
        globals
        program


compileAll : Dict String Int -> List MidModule.Unit -> Result String (List Defun)
compileAll globals units =
    sequence (List.map (MidModule.compileUnit globals) units)
        |> Result.map List.concat


sequence : List (Result String a) -> Result String (List a)
sequence results =
    List.foldr (Result.map2 (::)) (Ok []) results


maybeToList : Maybe a -> List a
maybeToList m =
    case m of
        Just x ->
            [ x ]

        Nothing ->
            []
