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
import Elm.Syntax.Range exposing (Range)
import Frontend.Lift as Lift
import Mid.Audit as Audit
import Mid.Ir exposing (Defun)
import Mid.Module as MidModule
import Mid.Qbe.Flatten as QbeFlatten
import Mid.Qbe.Lower as QbeLower
import Mid.Qbe.Monomorphise as QbeMono
import Mid.Qbe.Peephole as QbePeephole
import Mid.Qbe.Print as QbePrint
import Mid.Qbe.Types as QbeTypes
import Mid.Rt as MidRt
import Mid.RtGc as RtGc
import Set exposing (Set)
import Type.Check as Check
import Type.Env as Env exposing (Env, Scheme)
import Type.Error as Error
import Type.Infer as Infer
import Type.Representation exposing (Type)


compileEntry : List String -> List String -> String -> Bool -> Bool -> Bool -> Bool -> Bool -> Bool -> Bool -> ( Bool, ( Bool, Bool, Bool ) ) -> Bool -> Result String String
compileEntry corpusSources groupSources entryKey flatten rep primDirect midRt midCons rtLean mono consArrRec eqPtrFast =
    case
        MidModule.parseAll corpusSources
            |> Result.andThen
                (\corpusFiles ->
                    MidModule.collectAll corpusFiles
                        |> Result.andThen
                            (\_ ->
                                Check.checkBuiltins corpusFiles
                                    |> Result.andThen
                                        (\{ env, files, nodeTypes, refinedVars } ->
                                            MidModule.collectAll files
                                                |> Result.andThen
                                                    (\corpusUnits ->
                                                        case MidModule.mergedGlobals corpusUnits of
                                                            Err msg ->
                                                                Err msg

                                                            Ok corpusGlobals ->
                                                                compileGroup env nodeTypes refinedVars corpusUnits corpusGlobals groupSources entryKey flatten rep primDirect midRt midCons rtLean mono consArrRec eqPtrFast
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
    -> Dict String (List ( Range, Type ))
    -> Dict String (List Int)
    -> List MidModule.Unit
    -> Dict String Int
    -> List String
    -> String
    -> Bool
    -> Bool
    -> Bool
    -> Bool
    -> Bool
    -> Bool
    -> Bool
    -> ( Bool, ( Bool, Bool, Bool ) )
    -> Bool
    -> Result String String
compileGroup env corpusNodeTypes corpusRefinedVars corpusUnits corpusGlobals groupSources entryKey flatten rep primDirect midRt midCons rtLean mono consArrRec eqPtrFast =
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
                                                            let
                                                                groupTypes =
                                                                    groupSchemes env groupUnits0

                                                                -- S2/M0b: the checker's per-node/per-binder
                                                                -- record for BOTH halves, keyed by module
                                                                -- name (a Range is unique only within one
                                                                -- file). Corpus: from checkBuiltins; group:
                                                                -- from the same re-inference that recovered
                                                                -- the schemes.
                                                                nodeTypesByModule =
                                                                    Dict.union groupTypes.nodeTypes corpusNodeTypes

                                                                -- S5/M2 clause (c): the per-UNIT refined
                                                                -- variable sets, merged the same way (a
                                                                -- module name is unique per half).
                                                                refinedVarsByModule =
                                                                    Dict.union groupTypes.refinedVars corpusRefinedVars
                                                            in
                                                            lowerAll rep primDirect midRt midCons rtLean mono flatten globals nodeTypesByModule groupTypes refinedVarsByModule corpusUnits groupUnits entryKey consArrRec eqPtrFast
                                                )
                                    )
                        )
            )


{-| The group's schemes plus what the RECOVERY pass could not infer, plus the
group's node-type record (S2/M0b). This is `Qbe.Types`' input, not its output:
the table itself is built in `lowerAll`, where the program's defun keys are
known.
-}
type alias GroupSchemes =
    { schemes : List ( String, Scheme )
    , failures : List String
    , nodeTypes : Dict String (List ( Range, Type ))
    , refinedVars : Dict String (List Int)
    }


{-| The GROUP's defun schemes and node types, recovered a SECOND time (see the
header's THE TYPE SEAT section for the cost and the failure policy). `units`
are the group's units as PARSED — they are LIFTED here exactly as
`Check.checkUserGroup` lifts them, so the scheme keys name the same (lifted)
functions the program will contain. The result also carries the corpus half:
`env0` is the group-checking environment, i.e. the corpus env plus every group
signature. The node-type record is keyed by MODULE NAME because a `Range` is
unique only within one file — the join resolves a binder against its OWN
unit's record.
-}
groupSchemes : Env -> List MidModule.Unit -> GroupSchemes
groupSchemes env units =
    let
        lifted =
            List.map (\unit -> ( String.join "." unit.moduleName, Lift.liftFile unit.file )) units

        env0 =
            List.foldl (\( _, f ) e -> Env.merge e (Env.collectFile f)) env lifted
    in
    inferInOrder env0 lifted (QbeTypes.envSchemes env0) [] Dict.empty Dict.empty


{-| `Check.checkInOrder`'s loop, for the schemes and node types only: infer
each unit against the env accumulated so far, folding its schemes in for the
next unit. An error is recorded and does not propagate (the group has already
been checked by `Check.checkUserGroup`, and this pass only ADDS information).
A unit whose re-inference fails contributes NO node types either (deny: a
defun of that unit keeps `BindersAbsent`).
-}
inferInOrder : Env -> List ( String, File.File ) -> List ( String, Scheme ) -> List String -> Dict String (List ( Range, Type )) -> Dict String (List Int) -> GroupSchemes
inferInOrder env files schemes failures nodeTypes refinedVars =
    case files of
        [] ->
            { schemes = schemes, failures = failures, nodeTypes = nodeTypes, refinedVars = refinedVars }

        ( modName, f ) :: rest ->
            case Infer.inferUnit env f of
                Ok checked ->
                    inferInOrder
                        (List.foldl (\( n, s ) e -> Env.insert n s e) env checked.schemes)
                        rest
                        (schemes ++ checked.schemes)
                        failures
                        (Dict.insert modName checked.nodeTypes nodeTypes)
                        (Dict.insert modName checked.refinedVars refinedVars)

                Err err ->
                    inferInOrder env rest schemes (failures ++ [ Error.render err ]) nodeTypes refinedVars


lowerAll :
    Bool
    -> Bool
    -> Bool
    -> Bool
    -> Bool
    -> Bool
    -> Bool
    -> Dict String Int
    -> Dict String (List ( Range, Type ))
    -> GroupSchemes
    -> Dict String (List Int)
    -> List MidModule.Unit
    -> List MidModule.Unit
    -> String
    -> ( Bool, ( Bool, Bool, Bool ) )
    -> Bool
    -> Result String String
lowerAll rep primDirect midRt midCons rtLean mono flatten globals nodeTypesByModule groupTypes refinedVarsByModule corpusUnits groupUnits entryKey consArrRec eqPtrFast =
    let
        ( consArr, ( rec, typeSpec, midGc ) ) =
            consArrRec
    in
    reserveRtName (corpusUnits ++ groupUnits)
        |> Result.andThen (\_ -> compileAllJoin globals (corpusUnits ++ groupUnits) nodeTypesByModule refinedVarsByModule)
        -- The unsafe-node audit (osier-rawnodes): EVERY compile fails loudly
        -- if an `Unsafe` node appears outside the Rt.* namespace — i.e. if the
        -- front end ever emits one.  Passes nothing through unchanged-but-
        -- unaudited; on Ok the program is the SAME value, so byte identity of
        -- the emitted .ssa is this seat's inertness proof.
        |> Result.andThen
            (\( program0, binderPerDefun, refinedPerDefun ) ->
                Result.map (\p -> ( p, binderPerDefun, refinedPerDefun )) (Audit.run program0)
            )
        |> Result.andThen
            (\( program, binderPerDefun, refinedPerDefun ) ->
                -- THE Rt INJECTION (osier-consspike): the Mid-written runtime
                -- joins HERE — after the audit (which would pass it trivially:
                -- every Rt key is legal) and after Flatten (whose rewriter
                -- rightly rejects raw nodes; Rt code is already final), but
                -- BEFORE Lower, where the used-prim census seeds the injected
                -- defuns into reachability.  QBE_NOMIDRT=1 withholds the whole
                -- program: no Rt defun exists, no seed fires, and the emitted
                -- .ssa is byte-identical to the pre-Rt baseline (the corpus
                -- attribution proof).
                let
                    rtProgramR =
                        if midRt then
                            -- T7: `program` runs the surface pipeline
                            -- (Mid.RtSource -> Parse -> Check -> LowerToIr)
                            -- and is RESULT-VALUED: a bad surface text fails
                            -- the compile HERE, through the existing Err
                            -- plumbing — never as a silently-reduced runtime.
                            Result.map
                                (\spliced ->
                                    spliced
                                        ++ (if midGc then
                                                RtGc.gcProgram

                                            else
                                                []
                                           )
                                )
                                (MidRt.program consArr rec eqPtrFast)

                        else
                            Ok []
                in
                rtProgramR
                    |> Result.andThen
                        (\rtProgram ->
                            let
                                -- THE TYPE TABLE (monomorphisation S1 + S2). Built HERE
                                -- because `program` fixes the table's domain — the defun
                                -- keys the passes below actually see. S1: the defun-granular
                                -- half (schemes). S2: the per-BINDER half — every defun of a
                                -- CHECKED unit gets `Binders <binderId -> Type>` from the
                                -- FromAst binder join against the checker's node-type
                                -- record (see Mid.Qbe.Types's header for the totality and
                                -- deny-by-default doctrine); defuns of unchecked units keep
                                -- `BindersAbsent`. STILL READ BY NOTHING: S5's specialiser
                                -- is the consumer, and the byte-identity oracle below is
                                -- the proof this step changes no emitted output.
                                typeTable =
                                    List.foldl QbeTypes.note
                                        (QbeTypes.fromSchemes (Set.fromList (List.map .key (program ++ rtProgram))) groupTypes.schemes
                                            |> QbeTypes.withBinders binderPerDefun
                                        )
                                        groupTypes.failures
                            in
                            (if flatten then
                                QbeFlatten.run program

                             else
                                Ok program
                            )
                                |> Result.andThen
                                    (\flatProgram ->
                                        let
                                            emitProgram =
                                                flatProgram ++ rtProgram

                                            arities =
                                                completeArities globals (program ++ rtProgram)
                                        in
                                        (if mono then
                                            -- S5/M2: the specialiser runs LAST (on the
                                            -- flattened program the emitter will see) and
                                            -- hands down a program with the clones
                                            -- appended plus a type table carrying one
                                            -- MONOTYPE entry per clone.
                                            QbeMono.run typeTable refinedPerDefun arities emitProgram entryKey

                                         else
                                            -- QBE_NOMONO=1: the pre-S5 emission, byte for
                                            -- byte — no clone exists, no table entry is
                                            -- added, and no pass decision is reported.
                                            Ok { program = emitProgram, table = typeTable, note = "" }
                                        )
                                            |> Result.andThen
                                                (\specialised ->
                                                    QbeLower.lower
                                                        rep
                                                        primDirect
                                                        midCons
                                                        rtLean
                                                        consArr
                                                        rec
                                                        typeSpec
                                                        midGc
                                                        specialised.table
                                                        (completeArities globals specialised.program)
                                                        specialised.program
                                                        entryKey
                                                        |> Result.map
                                                            (\il ->
                                                                prependNote specialised.note (QbePrint.print (QbePeephole.optimize il))
                                                            )
                                                )
                                )
                        )
            )


{-| The specialiser's ONE-LINE report, prepended to the emitted `.ssa` when
the pass decided anything at all. It is a `#` comment (the vendored qbe's
lexer skips it to end of line, VERIFIED by running `qbe -o` on a copy of a
mono_int `.ssa` with a prepended comment: exit 0), and an EMPTY note prepends
NOTHING — which is what keeps a fixture the pass does not touch BYTE-IDENTICAL
on and off, the property the corpus attribution and the gate's inertness row
both rest on.
-}
prependNote : String -> String -> String
prependNote note ssa =
    if note == "" then
        ssa

    else
        "# " ++ note ++ "\n" ++ ssa


-- THE `Rt` MODULE NAME IS RESERVED for the compiler-internal runtime
-- (osier-rawnodes' residual hole, closed by the namespace's first real
-- occupant in osier-consspike): a surface module actually named `Rt` would
-- emit defun keys under the same `Rt.` prefix Mid.Audit whitelists, so its
-- (safe, front-end-produced) trees would never be audited.  One seat, every
-- compile, corpus and group alike.
reserveRtName : List MidModule.Unit -> Result String ()
reserveRtName units =
    case List.filter (\u -> u.moduleName == [ "Rt" ]) units of
        [] ->
            Ok ()

        offenders ->
            let
                first =
                    case offenders of
                        u :: _ ->
                            String.join "." u.moduleName

                        [] ->
                            "?"
            in
            Err
                ("qbe: the module name Rt is reserved for the compiler-internal runtime (Mid.Audit whitelists the Rt.* key namespace); rename module "
                    ++ first
                )


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


{-| S2/M0b: `compileAll` plus the binder join. Every unit compiles through
`Mid.Module.compileUnitJoin` (same defuns, same order — `compileUnit` IS that
function with the join dropped), and each defun's `binderId -> Range` join is
resolved against ITS OWN unit's node-type record (keyed by module name: a
Range is unique only within one file), through `Qbe.Types`'s deny-on-conflict
policy. A defun of a unit with NO record (trusted body, failed re-inference)
gets no entry in `binderPerDefun` and therefore keeps `BindersAbsent`.
-}
compileAllJoin :
    Dict String Int
    -> List MidModule.Unit
    -> Dict String (List ( Range, Type ))
    -> Dict String (List Int)
    -> Result String ( List Defun, Dict String (Dict Int Type), Dict String (List Int) )
compileAllJoin globals units nodeTypesByModule refinedVarsByModule =
    sequence (List.map (\u -> Result.map (\( ds, rs ) -> ( u.moduleName, ds, rs )) (MidModule.compileUnitJoin globals u)) units)
        |> Result.map
            (\triples ->
                ( List.concatMap (\( _, ds, _ ) -> ds) triples
                , List.foldl
                    (\( modName, defuns, ranges ) acc ->
                        let
                            rangeTypes =
                                QbeTypes.nodeTypeMap (Maybe.withDefault [] (Dict.get (String.join "." modName) nodeTypesByModule))
                        in
                        List.foldl
                            (\d a ->
                                Dict.insert d.key
                                    (QbeTypes.joinBinders (Maybe.withDefault Dict.empty (Dict.get d.key ranges)) rangeTypes)
                                    a
                            )
                            acc
                            defuns
                    )
                    Dict.empty
                    triples
                , List.foldl
                    (\( modName, defuns, _ ) acc ->
                        -- S5/M2 clause (c): the unit's refined-variable set,
                        -- RESOLVED TO DEFUN KEYS here because this is the one
                        -- place the module name is structural (the pass keys
                        -- everything by defun and must never re-derive a unit
                        -- name by splitting a string). A unit with no record
                        -- contributes nothing, which is the deny-by-default
                        -- answer — `refinedVars` is a LIST and the empty list
                        -- for a unit that WAS checked also contributes
                        -- nothing, because both mean "no variable here is
                        -- refinement-touched".
                        let
                            unitVars =
                                Maybe.withDefault [] (Dict.get (String.join "." modName) refinedVarsByModule)
                        in
                        if List.isEmpty unitVars then
                            acc

                        else
                            List.foldl (\d a -> Dict.insert d.key unitVars a) acc defuns
                    )
                    Dict.empty
                    triples
                )
            )


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
