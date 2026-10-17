module Mid.QbeModule exposing (compileEntry, exportScheme, loadUserMids, userCollisions)

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
import Mid.RtLang.Ast as RtAst
import Mid.TaintCheck as TaintCheck
import Set exposing (Set)
import Type.Check as Check
import Type.Env as Env exposing (Env, Scheme)
import Type.Error as Error
import Type.Infer as Infer
import Type.Representation as Rep exposing (Flex(..), Kind(..), Type(..), VarId)


compileEntry : MidRt.Runtime -> List String -> List String -> List String -> String -> Bool -> Bool -> Bool -> Bool -> Bool -> Bool -> Bool -> ( ( Bool, ( Bool, Bool, ( Bool, Bool ) ) ), Bool ) -> Result String String
compileEntry rt corpusSources groupSources groupMids entryKey flatten rep primDirect midRt midCons rtLean mono ( consArrRec, eqPtrFast ) =
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
                                                                compileGroup rt env nodeTypes refinedVars corpusUnits corpusGlobals ( groupSources, groupMids ) entryKey flatten rep primDirect midRt midCons rtLean mono ( consArrRec, eqPtrFast )
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
    MidRt.Runtime
    -> Env
    -> Dict String (List ( Range, Type ))
    -> Dict String (List Int)
    -> List MidModule.Unit
    -> Dict String Int
    -> ( List String, List String )
    -> String
    -> Bool
    -> Bool
    -> Bool
    -> Bool
    -> Bool
    -> Bool
    -> Bool
    -> ( ( Bool, ( Bool, Bool, ( Bool, Bool ) ) ), Bool )
    -> Result String String
compileGroup rt env corpusNodeTypes corpusRefinedVars corpusUnits corpusGlobals ( groupSources, groupMids ) entryKey flatten rep primDirect midRt midCons rtLean mono ( consArrRec, eqPtrFast ) =
    -- M3: load the group's user .mid modules FIRST — their exported keys'
    -- schemes join the env BEFORE the Elm sources are checked (an Elm source
    -- may reference a mid key by qualified name).  A .mid that fails to
    -- parse/check/lower, or that trips a collision rule, fails the GROUP.
    case loadUserMids rt groupMids of
        Err msg ->
            Err msg

        Ok userModules ->
            let
                envWithMids =
                    injectUserSchemes env userModules

                -- CONTRACT 4 (M4-enforce U1): the !taint export keys a result
                -- may not escape from — the user .mid exports UNION the
                -- runtime's exported types, filtered to `taint`.  The pass
                -- itself runs below, after the checker succeeds, over the
                -- ORIGINAL PRE-LIFT files (Lift would turn the owner's
                -- let + self-recursive case into a TAINTED snapshot argument).
                taintedKeys =
                    Set.fromList
                        (List.filterMap
                            (\e ->
                                if e.sig.taint then
                                    Just e.key

                                else
                                    Nothing
                            )
                            (List.concatMap .exports userModules)
                            ++ Dict.keys (Dict.filter (\_ sig -> sig.taint) rt.exportedTypes)
                        )
            in
            MidModule.parseAll groupSources
                |> Result.andThen
                    (\groupFiles ->
                        MidModule.collectAll groupFiles
                            |> Result.andThen
                                (\groupUnits0 ->
                                    Check.checkUserGroup envWithMids (List.map .file groupUnits0)
                                        |> Result.andThen
                                            (\checkedGroupFiles ->
                                                TaintCheck.checkGroup taintedKeys groupFiles
                                                    |> Result.andThen
                                                        (\() ->
                                                            MidModule.collectAll checkedGroupFiles
                                                                |> Result.andThen
                                                                    (\groupUnits ->
                                                                        case MidModule.mergedGlobals (corpusUnits ++ groupUnits) of
                                                                            Err msg ->
                                                                                Err msg

                                                                            Ok globals0 ->
                                                                                case userCollisions globals0 userModules of
                                                                                    Err msg ->
                                                                                        Err msg

                                                                                    Ok () ->
                                                                                        let
                                                                                            globals =
                                                                                                Dict.union (userArities userModules) globals0

                                                                                            groupTypes =
                                                                                                groupSchemes envWithMids groupUnits0

                                                                                            nodeTypesByModule =
                                                                                                Dict.union groupTypes.nodeTypes corpusNodeTypes

                                                                                            refinedVarsByModule =
                                                                                                Dict.union groupTypes.refinedVars corpusRefinedVars
                                                                                        in
                                                                                        lowerAll rt rep primDirect midRt midCons rtLean mono flatten globals nodeTypesByModule groupTypes refinedVarsByModule (corpusUnits ++ groupUnits) (userSurface userModules) entryKey ( consArrRec, eqPtrFast )
                                                                    )
                                                        )
                                            )
                                )
                    )


-- ============================ M3: user .mid modules ============================


{-| Load the group's user `.mid` modules in TWO phases: parse ALL first (the
namespace rule + name/exports), so the cross-module extern table — the
runtime's EXPORTED keys (`rt.exportedTypes`, the privacy boundary: unexported
runtime defuns are module-private) UNION every user module's export — exists
before any check+lower runs.  At the CHECKER (J2) a user module may therefore
`call` any of those keys.

WHAT THE EMIT LEVEL DOES WITH THEM (M3fix-4, MEASURED):

  * a `call` to another USER module's exported defun is emitted — mid-c `call`
    lowers to RawCall (LowerToIr) naming that defun's key, and Lower's RawCall
    arm accepts a key by MEMBERSHIP IN THE SET THIS COMPILE EMITS (it no longer
    tests a `Rt.`-name SHAPE), in the callee's own ABI (a user defun is
    RtGeneric, never lean) and with the callee made REACHABLE by RawCall's
    call-graph edge.  The `user-mid` row runs exactly this, end to end.
  * a `call Rt.<exported>` is still NOT emitted in general: the user .mid body
    is raw nodes, so the used-prim census (`calledPrims`, which ignores Unsafe)
    does not see the call and Mid.Rt.seeds never seeds the target — the RawCall
    arm REFUSES it loudly ("a defun of this program that this compile does not
    EMIT") instead of emitting a dangling `q_Rt_*`.  Closing that is a census
    change (Lower.elm/midPrimRoute), NOT an acceptance one; it is measured and
    open, deliberately not claimed here.

An unknown key — one that names no defun of the program — stays a loud Err
(`run_midref`'s `midcallmissing` row pins it).
-}
loadUserMids : MidRt.Runtime -> List String -> Result String (List MidRt.UserModule)
loadUserMids rt sources =
    case sequence (List.map MidRt.parseUserModule sources) of
        Err msg ->
            Err msg

        Ok parsed ->
            let
                userExterns =
                    Dict.fromList
                        (List.concatMap
                            (\( _, exports, _ ) -> List.map (\e -> ( e.key, e.sig )) exports)
                            parsed
                        )

                externs =
                    Dict.union userExterns rt.exportedTypes
            in
            sequence (List.map (MidRt.checkLowerUserModule externs) parsed)


{-| The M3 COLLISION RULES, defined against the EXPORT BLOCK's namespace (the
module NAME from the header qualifies every key — see `Mid.Rt.parseUserModule`).
A loud reject for each, because a silent merge here is a silent miscompile:

  * (a) a user key in the `Rt.*` namespace — the RESERVED compiler-internal
    runtime namespace.  This covers BOTH a user defun keyed `Rt.foo` and a
    user module NAMED `Rt` (its keys are all `Rt.*`).
  * (c) a user key colliding with a DSL/list position — SUBSUMED by (a): every
    DSL seat (`primDefuns`/`helperDefuns`/`gcProgram`) and every runtime
    surface key is spelled `Rt.*`, so rejecting a user `Rt.*` key prevents the
    splice's REPLACE arm from ever swapping a runtime/DSL defun for a user one.
  * (b) a user key defined by TWO user modules (or an Elm source — the bonus
    arm: `globals` is the merged Elm global table, so a `.mid` and an `.elm`
    module that both claim one key is caught here too).

`Ok ()` = no collision; the caller then splices the user surface over `[]`
(an ADD, never a REPLACE).
-}
userCollisions : Dict String Int -> List MidRt.UserModule -> Result String ()
userCollisions globals modules =
    let
        keys =
            List.concatMap (\m -> List.map .key m.defuns) modules

        globalsSet =
            Set.fromList (Dict.keys globals)
    in
    case firstMatch (\k -> String.startsWith "Rt." k) keys of
        Just k ->
            Err
                ("user .mid: key '"
                    ++ k
                    ++ "' is in the reserved Rt.* namespace (the compiler-internal runtime AND the DSL seats live there) — rename the module or the defun"
                )

        Nothing ->
            case firstDuplicate keys of
                Just k ->
                    Err
                        ("user .mid: key '"
                            ++ k
                            ++ "' is defined by two modules — a .mid key is namespaced by its module name, so two modules may not claim the same key"
                        )

                Nothing ->
                    case firstMatch (\k -> Set.member k globalsSet) keys of
                        Just k ->
                            Err
                                ("user .mid: key '"
                                    ++ k
                                    ++ "' collides with an Elm global (a .elm module already defines it) — rename the .mid module or the Elm defun"
                                )

                        Nothing ->
                            Ok ()


{-| Inject the user modules' exported keys as Osier-side SCHEMES into the
checker env, so an Elm source can reference a mid key by qualified name
(`UserMid.answer`) and typecheck.  The scheme is the M3 PLACEHOLDER for M4's
real declared-type mapping (`exportScheme`): it honours the ARITY and the
`float`/known-scalar atoms, and reads `val`/unknown atoms as fresh polymorphic
variables (the conservative `Val a`).
-}
injectUserSchemes : Env -> List MidRt.UserModule -> Env
injectUserSchemes env modules =
    List.foldl
        (\m acc ->
            List.foldl (\e a -> Env.insert e.key (exportScheme e.sig) a) acc m.exports
        )
        env
        modules


{-| M4 — the Osier-side scheme for an export (the declared Osier types of the
M2 export block, mapped to the checker's type language).  This is where an
Osier call into an imported `.mid` defun is checked against the DECLARED types
(plan.md §2.5, the representation-pinned class mapping):

  * `val`  -> a FRESH polymorphic variable — the boxed `Val a` (§2.5: any
    boxed value; boxed scalars are NOT unboxed at the boundary).
  * `float` -> `Float` (boxed, ABI-pinned).
  * `word` -> the RIGID opaque type `Word` (a `TCon "Word" []` no Osier value
    inhabits) — §2.5's "an opaque Word (locally abstract)".  ENFORCED WITHOUT
    Phase-7 by two existing unifier facts, MEASURED: a concrete non-`Word`
    argument is a LOUD `CannotUnify` (name mismatch), and an unannotated
    literal (`5 : number`) is a LOUD `FlexConflict` — `bindVar`'s
    `propagate FNumber` rejects any non-Int/Float binding (Type.Unify.elm).  A
    `word`-typed export is therefore uncallable from a concrete Osier program,
    which is the sound reading of "opaque": no Osier value CAN be a raw word.
    THE ONE HONEST LEAK: a POLYMORPHIC Osier function passing its `a`-typed
    argument to a `word` export binds `a := Word` (an FNone var propagates
    trivially) — the classic phantom-escapes-through-polymorphism case, closed
    only by the Phase-7 locally-abstract machinery.
  * a type variable / quantifier / unknown `OCon` (`Ref s`) -> the M2
    conservative `:val` default (`Val a`) — WHERE THE PAYLOAD MAPPING STOPS:
    the quantifier/region semantics are Phase-7's, not mapped here.

The body is the declared arrow shape (`params -> result`, the M2-fix
quantifier unwrap via `splitArrow`), so an Osier reference checks at the right
ARITY (a saturated call to a `val -> val -> val` export checks as `a -> b ->
c`; too MANY args is a LOUD unify failure when it forces a non-function
result).  `quantifiers` are the fresh variables, in order; `word`'s rigid
`TCon` contributes none.
-}
exportScheme : RtAst.ExportSig -> Scheme
exportScheme sig =
    let
        ( params, result ) =
            RtAst.splitArrow sig.ty

        ( paramTys, n ) =
            mapTypes params 0

        ( resultTy, _ ) =
            otyToElm result n

        body =
            List.foldr Rep.TFun resultTy paramTys
    in
    { quantifiers = collectTypeVars body, body = body, bound = [] }


mapTypes : List RtAst.OTy -> Int -> ( List Type, Int )
mapTypes tys n =
    case tys of
        [] ->
            ( [], n )

        t :: rest ->
            let
                ( tt, n1 ) =
                    otyToElm t n

                ( restTys, n2 ) =
                    mapTypes rest n1
            in
            ( tt :: restTys, n2 )


otyToElm : RtAst.OTy -> Int -> ( Type, Int )
otyToElm ty n =
    case ty of
        RtAst.OVal ->
            ( freshVal n, n + 1 )

        RtAst.OFloat ->
            ( Rep.tFloat, n )

        RtAst.OWord ->
            ( Rep.TCon "Word" [], n )

        RtAst.OVar _ ->
            ( freshVal n, n + 1 )

        RtAst.OCon name args ->
            case scalarCon name args of
                Just t ->
                    ( t, n )

                Nothing ->
                    ( freshVal n, n + 1 )

        RtAst.OArrow a b ->
            let
                ( ta, n1 ) =
                    otyToElm a n

                ( tb, n2 ) =
                    otyToElm b n1
            in
            ( Rep.TFun ta tb, n2 )

        RtAst.OForall _ t ->
            otyToElm t n

        RtAst.OExists _ t ->
            otyToElm t n


freshVal : Int -> Type
freshVal n =
    Rep.TVar (Rep.var n Rep.KType Rep.FNone)


scalarCon : String -> List RtAst.OTy -> Maybe Type
scalarCon name args =
    case ( name, args ) of
        ( "Int", [] ) ->
            Just Rep.tInt

        ( "Float", [] ) ->
            Just Rep.tFloat

        ( "String", [] ) ->
            Just Rep.tString

        ( "Bool", [] ) ->
            Just Rep.tBool

        ( "Char", [] ) ->
            Just Rep.tChar

        ( "Word", [] ) ->
            -- M4: `Word` (uppercase, the §2.5 opaque-word spelling) is the SAME
            -- rigid opaque type as the lowercase `word` atom — a TCon no Osier
            -- value inhabits (see exportScheme's doc for the enforcement).
            Just (Rep.TCon "Word" [])

        _ ->
            Nothing


{-| The free type variables of a type, in first-appearance order.  The M3
placeholder scheme builds each `val`/unknown atom as a UNIQUE fresh variable,
so no dedup is needed — but `TFun`/`TCon` recursion keeps the order the
quantifiers must be listed in.
-}
collectTypeVars : Type -> List VarId
collectTypeVars t =
    case t of
        Rep.TVar v ->
            [ v ]

        Rep.TFun a b ->
            collectTypeVars a ++ collectTypeVars b

        Rep.TCon _ args ->
            List.concatMap collectTypeVars args

        Rep.TTuple ts ->
            List.concatMap collectTypeVars ts

        Rep.TRecord row ->
            List.concatMap (\( _, ft ) -> collectTypeVars ft) row.fields


{-| The group's user defun keys -> arity, for the merged globals table
(`FromAst.resolveGlobal` reads it; `Lower.completeArities` re-derives the
same arity from the defun's Lam).
-}
userArities : List MidRt.UserModule -> Dict String Int
userArities modules =
    Dict.fromList
        (List.concatMap
            (\m -> List.map (\d -> ( d.key, lamArity d )) m.defuns)
            modules
        )


{-| The merged user surface dict (key -> lowered Defun), the input to the
SAME splice the runtime surface goes through (`spliceSurface`, T25's ADD arm).
-}
userSurface : List MidRt.UserModule -> Dict String Defun
userSurface modules =
    Dict.fromList
        (List.concatMap
            (\m -> List.map (\d -> ( d.key, d )) m.defuns)
            modules
        )


lamArity : Defun -> Int
lamArity d =
    case d.value of
        Mid.Ir.Lam l ->
            List.length l.params

        _ ->
            0


firstMatch : (String -> Bool) -> List String -> Maybe String
firstMatch pred keys =
    case keys of
        [] ->
            Nothing

        k :: rest ->
            if pred k then
                Just k

            else
                firstMatch pred rest


firstDuplicate : List String -> Maybe String
firstDuplicate keys =
    firstDupHelp Set.empty keys


firstDupHelp : Set String -> List String -> Maybe String
firstDupHelp seen keys =
    case keys of
        [] ->
            Nothing

        k :: rest ->
            if Set.member k seen then
                Just k

            else
                firstDupHelp (Set.insert k seen) rest


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
    MidRt.Runtime
    -> Bool
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
    -> Dict String Defun
    -> String
    -> ( ( Bool, ( Bool, Bool, ( Bool, Bool ) ) ), Bool )
    -> Result String String
lowerAll rt rep primDirect midRt midCons rtLean mono flatten globals nodeTypesByModule groupTypes refinedVarsByModule units userSurf entryKey ( consArrRec, eqPtrFast ) =
    let
        ( consArr, ( rec, typeSpec, ( midGc, midDriver ) ) ) =
            consArrRec
    in
    reserveRtName units
        |> Result.andThen (\_ -> compileAllJoin globals units nodeTypesByModule refinedVarsByModule)
        -- The unsafe-node audit (osier-rawnodes): runs over the ELM PROGRAM
        -- only — the front end's (FromAst) output, born in `compileAllJoin`.
        -- It fails loudly if an `Unsafe` node appears outside the Rt.*
        -- namespace THERE (i.e. if the front end ever emits one), and passes
        -- the program through unchanged — byte identity of the emitted .ssa is
        -- this seat's inertness proof.  The `.mid` surface is NOT audited by
        -- it: the runtime's Rt.* defuns AND the group's user .mid defuns join
        -- AFTER this pass (rtProgram/userProgram below) and are the SANCTIONED
        -- unsafe lane — they carry Unsafe nodes (RawMkValue/RawCall/...) by
        -- design, gated instead by Mid.RtLang.Check's J1 class checks and J3
        -- rawcall signature table (see Mid.Audit's header for the span).
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
                            -- M1: the surface pipeline (runtime.mid ->
                            -- Parse -> Check -> LowerToIr) is RESULT-VALUED:
                            -- a bad surface text failed the compile at the
                            -- once-per-process `Mid.Rt.load` in Main — so the
                            -- record here is always a parse-success, and a
                            -- check/lower failure still fails through the
                            -- existing Err plumbing.  T18: `programPair`
                            -- splices over the WHOLE DSL program (prim ++
                            -- helper ++ gc) and splits the halves, so the gc
                            -- half appended under midGc is the SPLICED half
                            -- (surface-migrated collector defuns at their
                            -- gcProgram positions), not the raw DSL list —
                            -- appending `RtGc.gcProgram` here again would
                            -- duplicate every collector defun (the DSL entry
                            -- is a tripwire seat once migrated) and emit the
                            -- tripwire's `Rt.*.surface-seat` RawCall.
                            Result.map
                                (\( primHalf, gcHalf ) ->
                                    primHalf
                                        ++ (if midGc then
                                                gcHalf

                                            else
                                                []
                                           )
                                )
                                (rt.programPair consArr rec eqPtrFast)

                        else
                            Ok []

                    -- M3: the group's USER .mid defuns join through the SAME
                    -- splice as the runtime's own surface (T25's ADD arm — a
                    -- user key has no DSL position, so `spliceSurface` appends
                    -- every defun, ascending by key).  Reusing the splice keeps
                    -- ONE merge path; the collision check in compileGroup has
                    -- already rejected any user key that would REPLACE a DSL/
                    -- runtime seat, so the ADDs here are collision-free.
                    userProgramR =
                        MidRt.spliceSurface userSurf []
                in
                Result.map2 (\rtProgram userProgram -> ( rtProgram, userProgram )) rtProgramR userProgramR
                    |> Result.andThen
                        (\( rtProgram, userProgram ) ->
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
                                        (QbeTypes.fromSchemes (Set.fromList (List.map .key (program ++ rtProgram ++ userProgram))) groupTypes.schemes
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
                                                flatProgram ++ rtProgram ++ userProgram

                                            arities =
                                                completeArities globals (program ++ rtProgram ++ userProgram)
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
                                                        rt
                                                        rep
                                                        primDirect
                                                        midCons
                                                        rtLean
                                                        consArr
                                                        rec
                                                        typeSpec
                                                        midGc
                                                        midDriver
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
