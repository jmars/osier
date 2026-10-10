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
--
-- THE TYPE SEAT (monomorphisation S1/M0a): this driver also fills
-- `Mid.Qbe.Types` — the side table holding the CHECKER's type for every defun
-- key — a seat an unboxing pass (S4) and a specialiser (S5) will read. S1
-- CONSUMES NOTHING: `lowerAll` builds the table and no pass reads it, so the
-- emitted `.ssa` must be BYTE-IDENTICAL to the pre-change compiler's (the
-- oracle, since nothing about a live compilation may move).
--
-- WHERE THE SCHEMES COME FROM — ZERO-TOUCH, and the cost is MEASURED, not
-- hidden. The corpus half is FREE: `Check.checkBuiltins` already RETURNS the
-- environment holding every builtin unit's schemes (`Check.checkBuiltins`,
-- Type/Check.elm:80-91)... and this module already receives it (the `env`
-- threaded to `compileGroup`) and previously ignored it. The GROUP half is
-- not free: `Check.checkUserGroup` (Type/Check.elm:101) checks the group and
-- RETURNS ONLY the rewritten files — its schemes are merged into a local env
-- and dropped. `Type.Infer` exposes exactly `inferUnit`/`CheckedUnit`
-- (Type/Infer.elm:1), so the group's schemes are recoverable only by
-- RE-RUNNING inference over the group's own files — which is what
-- `groupSchemes` below does, mirroring `checkUserGroup`'s pipeline exactly
-- (Lift each file, merge ALL group signatures up front, then `inferUnit` per
-- unit, folding each unit's schemes into the env for the next).
--   * COST, MEASURED (this tree, n=9 interleaved HEAD/with-the-seat, whole
--     compile including the corpus): the re-inference runs over the GROUP's
--     files ONLY — the corpus is NOT re-parsed, re-collected or re-checked,
--     its env is reused whole — so the added work is one `inferUnit` per group
--     file, proportional to the GROUP, not to the program. On the QBE path a
--     group is 1-2 SMALL modules (`tools/qbe/qbe-check.sh` drives every
--     fixture as a one-file group). Medians: `QBE=1 QBE_ENTRY=Fib.fib` on
--     tests/elm-fixtures/fib.elm 419ms -> 411ms; `QBE_ENTRY=ArrayBasic.main`
--     on the biggest QBE-compilable fixture, tests/elm-fixtures/arraybasic.elm
--     (209 lines -> 528KB of .ssa) 7523ms -> 7537ms (+0.19%), against a
--     ~200ms run-to-run spread. I.e. the added work is BELOW the instrument's
--     resolution on every group this path drives today; that is the honest
--     reading of these numbers, and the deltas above are not claims of a
--     speedup. The one group where it would NOT be free is the 58-source
--     selfhost group (a full second inference of the group's own sources;
--     MEASUREMENT: not run — no QBE oracle drives that group, and the plan
--     records its .ssa generation as ~25 min). That cost is the price of the
--     ZERO-TOUCH, seed-free variant: the alternative (`Check.checkUserGroupEnv`
--     returning its final env) removes it but edits a 58-source seed file,
--     which is the user's S3 decision, not this step's.
--   * FAILURE POLICY: the re-inference CANNOT fail a build. `checkUserGroup`
--     has already decided the group's fate; if this second pass errors (a
--     multi-file group whose CLI order is not a topological order, so an
--     earlier unit calls a later unit's UNSIGNATURED function — `topoUser` is
--     private to Type.Check and is not duplicated here), the error is
--     RECORDED in `Qbe.Types.Table.notes` and the compile proceeds. The table
--     is then INCOMPLETE, never WRONG: a missing scheme is a missing entry,
--     and an unexposed name makes inference ERROR rather than invent a type.
--   * NO `Type/*` FILE IS TOUCHED, so no seed re-freeze (every Mid/* file is
--     absent from the 58-source selfhost manifest).

import Dict exposing (Dict)
import Elm.Syntax.File as File
import Frontend.Lift as Lift
import Mid.Ir exposing (Defun)
import Mid.Module as MidModule
import Mid.Qbe.Flatten as QbeFlatten
import Mid.Qbe.Lower as QbeLower
import Mid.Qbe.Peephole as QbePeephole
import Mid.Qbe.Print as QbePrint
import Mid.Qbe.Types as QbeTypes
import Set exposing (Set)
import Type.Check as Check
import Type.Env as Env exposing (Env, Scheme)
import Type.Error as Error
import Type.Infer as Infer


compileEntry : List String -> List String -> String -> Bool -> Bool -> Result String String
compileEntry corpusSources groupSources entryKey flatten rep =
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
                                                                compileGroup env corpusUnits corpusGlobals groupSources entryKey flatten rep
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
    -> Bool
    -> Result String String
compileGroup env corpusUnits corpusGlobals groupSources entryKey flatten rep =
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
                                                            lowerAll rep flatten globals (groupSchemes env groupUnits0) corpusUnits groupUnits entryKey
                                                )
                                    )
                        )
            )


{-| The group's schemes plus what the RECOVERY pass could not infer. This is
`Qbe.Types`' input, not its output: the table itself is built in `lowerAll`,
where the program's defun keys are known.
-}
type alias GroupSchemes =
    { schemes : List ( String, Scheme )
    , failures : List String
    }


{-| The GROUP's defun schemes, recovered a SECOND time (see the header's THE
TYPE SEAT section for the cost and the failure policy). `units` are the group's
units as PARSED — they are LIFTED here exactly as `Check.checkUserGroup` lifts
them, so the scheme keys name the same (lifted) functions the program will
contain. The result also carries the corpus half: `env0` is the group-checking
environment, i.e. the corpus env plus every group signature.
-}
groupSchemes : Env -> List MidModule.Unit -> GroupSchemes
groupSchemes env units =
    let
        lifted =
            List.map (\unit -> Lift.liftFile unit.file) units

        env0 =
            List.foldl (\f e -> Env.merge e (Env.collectFile f)) env lifted
    in
    inferInOrder env0 lifted (QbeTypes.envSchemes env0) []


{-| `Check.checkInOrder`'s loop, for the schemes only: infer each unit against
the env accumulated so far, folding its schemes in for the next unit. An error
is recorded and does not propagate (the group has already been checked by
`Check.checkUserGroup`, and this pass only ADDS information).
-}
inferInOrder : Env -> List File.File -> List ( String, Scheme ) -> List String -> GroupSchemes
inferInOrder env files schemes failures =
    case files of
        [] ->
            { schemes = schemes, failures = failures }

        f :: rest ->
            case Infer.inferUnit env f of
                Ok checked ->
                    inferInOrder
                        (List.foldl (\( n, s ) e -> Env.insert n s e) env checked.schemes)
                        rest
                        (schemes ++ checked.schemes)
                        failures

                Err err ->
                    inferInOrder env rest schemes (failures ++ [ Error.render err ])


lowerAll :
    Bool
    -> Bool
    -> Dict String Int
    -> GroupSchemes
    -> List MidModule.Unit
    -> List MidModule.Unit
    -> String
    -> Result String String
lowerAll rep flatten globals groupTypes corpusUnits groupUnits entryKey =
    compileAll globals (corpusUnits ++ groupUnits)
        |> Result.andThen
            (\program ->
                -- S1's TYPE TABLE (monomorphisation S1/M0a). BUILT AND READ BY
                -- NOTHING: this is the step's contract, and it is why every
                -- fixture `.ssa` must stay byte-identical. It is built HERE
                -- because `program` fixes the table's domain — the defun keys
                -- the passes below actually see — and it sits one call short
                -- of its consumer: S4's unboxing is a `QbeLower.lower`
                -- argument, which is the single call site a later dispatch
                -- touches.
                let
                    typeTable =
                        List.foldl QbeTypes.note
                            (QbeTypes.fromSchemes (Set.fromList (List.map .key program)) groupTypes.schemes)
                            groupTypes.failures
                in
                (if flatten then
                    QbeFlatten.run program

                 else
                    Ok program
                )
                    |> Result.andThen
                        (\flatProgram ->
                            QbeLower.lower
                                rep
                                typeTable
                                (completeArities globals program)
                                flatProgram
                                entryKey
                        )
            )
        |> Result.map (\il -> QbePrint.print (QbePeephole.optimize il))


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
