module Mid.Qbe.Monomorphise exposing (Output, run)

-- Mid.Qbe.Monomorphise — the SPECIALISER (monomorphisation S5/M2).
--
-- WHAT IT DOES.  A defun the checker typed POLYMORPHICALLY (`fold :
-- (a -> b -> b) -> b -> List a -> b`) is compiled once, generically: every
-- arithmetic, comparison and primitive inside it keeps the VM's tagged-Value
-- shape (an inline fast path plus a `q_Rt_*` fallback), because no pass can
-- know what `a` and `b` will be.  This pass CLONES such a defun at the
-- instantiations its CALL SITES actually use, so the clone lands in the type
-- table as a CLOSED MONOTYPE and the passes below (S4/M1, S4f) can decide
-- representation on it — `intParamsOf`/`floatParamsOf` then see real types
-- instead of `Nothing`.
--
-- CLONE, DO NOT REPLACE.  The original defun stays, byte-for-byte, and any
-- flow that needs it keeps it: a GRef used AS A VALUE (a closure, a partial
-- application, anything that reaches the runtime's `rt_apply`/`rt_callN`
-- table) still names the original.  Only the SATURATED DIRECT call site
-- naming a specialist is rewritten.  That is also why the clone can be
-- emitted for the generic boxed ABI with no new calling convention: it is
-- the same function, only better typed.
--
-- WHY A DIRECT CALL IS THE ONLY TRIGGER.  `Lower.lowerApp` emits a saturated
-- `App` with a `GRef` head as a direct call whose ARGUMENTS ARE ITS SOURCE
-- SUBEXPRESSIONS; everything else (under/over-application, a first-class
-- head) goes through `rt_apply`, where the callee is a runtime Value and no
-- signature is expressible.  The presence of the arguments in the tree is
-- what makes sigma derivable at all.
--
-- Key = `defunKey ++ "$" ++ Rep.pretty <monotype>`, with a per-defun
-- pretty -> monotype BIJECTION REGISTRY: two different monotypes must never
-- share a key (that would silently merge two specialisations into one), so a
-- collision is detected and DENIED rather than trusted.  `Rep.pretty` names
-- the residual variables `a`, `b`, ... which is why the closedness check
-- below must run BEFORE the key is built.
--
--
-- ========================= THE REFUSAL PREDICATE =========================
--
-- DENY BY DEFAULT (`Flatten.usesOK` is the precedent).  A clone is admitted
-- only if the instantiation is a CLOSED, RIGID-FREE, REFINEMENT-FREE
-- monotype.  Three clauses, all read from the checker's own records:
--
--   (a) UNCLOSED.  sigma could not be closed (some quantifier of the scheme
--       never got a ground type from the argument positions), or the
--       instantiated body still mentions a type variable (a `TVar`, or an
--       open row tail).  An open instantiation is not a monotype and must
--       not be handed to a pass that decides representation on types.
--   (b) RIGID.  A variable of `scheme.bound` — the rigid subset
--       (Type/Env.elm:56-75): GADT type indices and `type x a.` locally
--       abstract prefixes.  A rigid variable is not instantiable at all, so
--       an "instantiation" that binds or mentions one is not a specialisation
--       of the scheme — it is a different type.
--   (c) REFINED.  A variable mentioned by the unit's `refinedVars` (the
--       branch-local `unifyBranchM` equations, Type/Infer.elm `refinedVarsOf`
--       — the THIRD additive field this unit's epoch carries).  A
--       branch-local refinement is valid ONLY INSIDE THAT BRANCH; baking one
--       into a defun body that runs outside the branch is a fact that does
--       not hold there.  Under the uniform boxed `Value` such a clone merely
--       wastes code — but the moment a param is UNBOXED, it is a WRONG
--       ANSWER.  So it is refused, not checked.  MEASURED STAKES: hlist2
--       (GADT) has eqEnd 14/15 — 93% of its node types mention a
--       refinedTypeEqs variable.
--
-- (a) AND "UNTYPED" ARE NOT THE SAME FAILURE, and the counter line keeps them
-- apart.  (a) is "sigma closed but the instantiation still mentions a
-- variable"; `untyped` is "no sigma could be derived at all" — the argument
-- positions could not type the scheme (a literal, an application, or an
-- argument whose own type is the very variable being instantiated).  Both
-- refuse; only one of them is a statement about the scheme's shape.
--
-- ORDER: (b) is decided by the SCHEME ALONE and is therefore checked FIRST and
-- TOTALLY, before any derivation (see `decide` — it cannot admit a site and
-- cannot be masked by a derivation success).  Then (c), then (a).  The order
-- changes WHICH counter increments and never WHICH sites are admitted: a
-- refusal by any clause is a refusal.
--
-- THE VAR-ID NAMESPACE IS PER UNIT (every `inferUnit` starts a fresh supply),
-- so clause (c) intersects a defun's variable ids with ITS OWN unit's set ONLY
-- — which is why the caller hands this pass a map keyed by DEFUN, resolved
-- from `Type.Check.collectRefinedVars`'s per-module record where the module
-- name is still known structurally.
--
-- `Rt.*` keys are refused by construction: the runtime is hand-built Mid and
-- is absent from the type table, so it has no scheme to instantiate.  The
-- explicit guard below makes that a stated refusal rather than an accident.
--
--
-- ============================== SEED COST ==============================
--
-- Every `Mid/*` file is one of the sources of the selfhost seed at this HEAD
-- (the manifest carried 67 at the handover and carries 68 with this file), so
-- this file moves the seed: the unit's `--freeze` epoch re-freezes it with the
-- rest of the change (the S2 note in Mid/Qbe/Types.elm says the same thing
-- about the same tree). MEASURED: 12,691,624 -> 14,407,846 bytes (+13.5%),
-- well inside the 2x guard, with the ABI marker UNCHANGED.
--
-- AND IT IS WRITTEN IN THE SUBSET THE TREE COMPILES ITSELF WITH. `elm make`
-- accepting a construct says nothing about `tools/qbe-bootstrap.sh --freeze`:
-- the tree's OWN front end rejected `String.split` and the composition
-- operator `<<` in this file during the freeze (exit 2 both times), which is
-- why the refined-variable map arrives keyed by DEFUN and the `Unsafe` arm
-- uses a lambda.
--
--
-- ============================== THE ORACLE ==============================
--
-- `QBE_NOMONO=1` runs the compilation WITHOUT this pass, on the SAME source
-- (see run.js).  The pass's own output is a single `# mono: ...` line
-- prepended to the `.ssa` IFF it made any decision, so:
--   * a fixture the pass does not touch is BYTE-IDENTICAL on and off
--     (the attribution property the corpus re-freeze rides on);
--   * a fixture it does touch carries its own counts (candidates, clones,
--     refusals by clause) in the artifact the checker reads.
-- By design there is NO other consumer of the counts: byte identity of the
-- emitted `.ssa` on the off arm is the strong oracle, and the runtime
-- behaviour (golden + `QBE_HEAP_MB=16` churn) is the one that matters.

import Dict exposing (Dict)
import Mid.Ir exposing (Alt, Binder, Defun, Exp(..), Lambda, LetBinder(..), Lit(..), UnsafeNode(..))
import Mid.Qbe.Types as QbeTypes
import Set exposing (Set)
import Type.Env as Env exposing (Scheme)
import Type.Representation as Rep exposing (Type(..), VarId)


{-| The pass's result: the rewritten program (originals with their saturated
specialist call sites retargeted, plus the clones appended), the type table
with one entry PER CLONE, and the one-line summary (`""` when the pass made no
decision at all — the byte-identity property described in the header).
-}
type alias Output =
    { program : List Defun
    , table : QbeTypes.Table
    , note : String
    }


{-| The maximum number of clones one base defun may accumulate. The guard is
for the unbounded case (a polymorphic defun called recursively at ever-finer
instantiations); the cap is fixed, and hitting it is RECORDED in the counters
rather than silently dropping the site.
-}
cloneCap : Int
cloneCap =
    16


{-| The read-only inputs threaded through the walk (the type table the pass
reads AND extends, the per-module refined-variable sets, and the arity table
the saturation test needs — the same table `Lower.lowerApp` dispatches on).
-}
type alias Pass =
    { table : QbeTypes.Table
    , refined : Dict String (Set Int)
    , arities : Dict String Int
    }


{-| One worklist item: the PRISTINE defun whose body is being instantiated
(`source`), the key that body will be emitted under (`key`), the substitution
that item's context is (`sigma`, empty for a root context), and the defun's
binder types ZONKED INTO THAT CONTEXT. `binders` is what makes a clone's inner
call sites derivable: a `Var` argument's type is read from here.
-}
type alias Ctx =
    { source : String
    , key : String
    , sigma : Rep.Subst
    , binders : Dict Int Rep.Type
    }


{-| The pass's own accounting. `candidates` counts every saturated direct call
whose head is a `GRef` to a TYPED POLYMORPHIC defun (the trigger);
`converted` counts the sites actually retargeted at a clone. They differ by
the refusals, which is the whole point of keeping both.
-}
type alias Counts =
    { candidates : Int
    , converted : Int
    , clones : Int
    , refusedA : Int
    , untyped : Int
    , refusedB : Int
    , refusedC : Int
    , capped : Int
    , collision : Int
    }


zeroCounts : Counts
zeroCounts =
    { candidates = 0, converted = 0, clones = 0, refusedA = 0, untyped = 0, refusedB = 0, refusedC = 0, capped = 0, collision = 0 }


type alias Acc =
    { pristine : Dict String Defun
    , outBodies : Dict String Exp
    , cloneKeys : List String -- creation order, append-only
    , sigmas : Dict String Rep.Subst
    , bases : Dict String String
    , keyTypes : Dict String Rep.Type -- the pretty -> monotype registry
    , cloneBinders : Dict String (Dict Int Rep.Type)
    , perBase : Dict String Int
    , done : Set String
    , counts : Counts
    }


{-| Run the specialiser. `refinedVarsByModule` is `Type.Check`'s per-module
refined-variable record (clause (c)); `arities` is the same completed arity
table `Lower` dispatches on; `entryKey` roots reachability exactly as `Lower`
roots it, so only reachable defuns are considered.
-}
run : QbeTypes.Table -> Dict String (List Int) -> Dict String Int -> List Defun -> String -> Result String Output
run table refinedVarsByModule arities program entryKey =
    let

        pristine =
            Dict.fromList (List.map (\d -> ( d.key, d )) program)

        pass =
            { table = table
            , refined = Dict.map (\_ vs -> Set.fromList vs) refinedVarsByModule
            , arities = arities
            }
    in
    case reach pristine entryKey [] of
        Err msg ->
            Err msg

        Ok keys ->
            let
                acc0 =
                    { pristine = pristine
                    , outBodies = Dict.empty
                    , cloneKeys = []
                    , sigmas = Dict.empty
                    , bases = Dict.empty
                    , keyTypes = Dict.empty
                    , cloneBinders = Dict.empty
                    , perBase = Dict.empty
                    , done = Set.empty
                    , counts = zeroCounts
                    }

                acc =
                    loop pass (List.map (rootCtx table) (List.reverse keys)) acc0

                cloneDefuns =
                    List.filterMap
                        (\k -> Maybe.map (\body -> { key = k, value = body }) (Dict.get k acc.outBodies))
                        acc.cloneKeys

                programOut =
                    List.map (\d -> { d | value = Maybe.withDefault d.value (Dict.get d.key acc.outBodies) }) program
                        ++ cloneDefuns
            in
            Ok
                { program = programOut
                , table = withClones table acc
                , note = summary acc.counts
                }


{-| The pass's one-line report, or `""` when it decided nothing — the
property `qbe-check`'s inertness row and the corpus attribution both rest on.
-}
summary : Counts -> String
summary c =
    if c.candidates + c.converted + c.clones + c.capped + c.collision == 0 then
        ""

    else
        "mono: candidates="
            ++ String.fromInt c.candidates
            ++ " converted="
            ++ String.fromInt c.converted
            ++ " clones="
            ++ String.fromInt c.clones
            ++ " refused_b="
            ++ String.fromInt c.refusedB
            ++ " refused_c="
            ++ String.fromInt c.refusedC
            ++ " refused_a="
            ++ String.fromInt c.refusedA
            ++ " untyped="
            ++ String.fromInt c.untyped
            ++ " capped="
            ++ String.fromInt c.capped
            ++ " collision="
            ++ String.fromInt c.collision


{-| The clone entries: a CLOSED MONOTYPE (what the key encodes) plus the base
defun's binder types ZONKED THROUGH THE CLONE'S OWN sigma — the "rewritten in
their own context" half of clone-do-not-replace. `Binders` (not
`BindersAbsent`) is used even when the base had no binder record at all: the
defun's unit WAS checked for the clone to exist, so an empty map is the honest
value (absent would mean "no inference ran", which is the wrong claim).
-}
withClones : QbeTypes.Table -> Acc -> QbeTypes.Table
withClones table acc =
    List.foldl
        (\k t ->
            case ( Dict.get k acc.keyTypes, Dict.get k acc.sigmas, Dict.get k acc.bases ) of
                ( Just ty, Just sigma, Just base ) ->
                    { t
                        | defuns =
                            Dict.insert k
                                { defunType = QbeTypes.Monotype ty
                                , binders = QbeTypes.Binders (Maybe.withDefault Dict.empty (Dict.get k acc.cloneBinders))
                                }
                                t.defuns
                    }

                _ ->
                    t
        )
        table
        acc.cloneKeys


binderTypesOf : QbeTypes.Table -> String -> Dict Int Rep.Type
binderTypesOf table key =
    case Dict.get key table.defuns of
        Just entry ->
            case entry.binders of
                QbeTypes.Binders m ->
                    m

                QbeTypes.BindersAbsent ->
                    Dict.empty

        Nothing ->
            Dict.empty


rootCtx : QbeTypes.Table -> String -> Ctx
rootCtx table key =
    { source = key, key = key, sigma = Rep.emptySubst, binders = binderTypesOf table key }


cloneCtx : QbeTypes.Table -> Acc -> String -> Maybe Ctx
cloneCtx table acc key =
    case ( Dict.get key acc.sigmas, Dict.get key acc.bases ) of
        ( Just sigma, Just base ) ->
            Just
                { source = base
                , key = key
                , sigma = sigma
                , binders = Maybe.withDefault Dict.empty (Dict.get key acc.cloneBinders)
                }

        _ ->
            Nothing


loop : Pass -> List Ctx -> Acc -> Acc
loop pass work acc =
    case work of
        [] ->
            acc

        ctx :: rest ->
            if Set.member ctx.key acc.done then
                loop pass rest acc

            else
                case Dict.get ctx.source acc.pristine of
                    Nothing ->
                        loop pass rest acc

                    Just defun ->
                        let
                            ( body, acc1 ) =
                                rw pass ctx acc defun.value

                            created =
                                List.drop (List.length acc.cloneKeys) acc1.cloneKeys

                            acc2 =
                                { acc1
                                    | done = Set.insert ctx.key acc1.done
                                    , outBodies = Dict.insert ctx.key body acc1.outBodies
                                }
                        in
                        loop pass (rest ++ List.filterMap (cloneCtx pass.table acc2) created) acc2



-- ============================ THE SITE ============================


{-| A saturated direct call whose head is a `GRef`, checked against the type
table. Returns the key the call site must name (the clone) when the site is
ADMITTED, and the updated accounting in every case.
-}
site : Pass -> Ctx -> Acc -> { key : String, force : Bool } -> List Exp -> ( Maybe String, Acc )
site pass ctx acc ref args =
    if ref.force then
        -- A forced thunk is a 0-arity direct call: it carries no argument
        -- subexpression, so no sigma is derivable from it by construction.
        ( Nothing, acc )

    else if isRtKey ref.key then
        -- The hand-built runtime: absent from the type table, so it has no
        -- scheme to instantiate. Stated rather than left to the lookup.
        ( Nothing, acc )

    else
        case Dict.get ref.key pass.arities of
            Just n ->
                if List.length args /= n then
                    ( Nothing, acc )

                else
                    case Dict.get ref.key pass.table.defuns of
                        Just entry ->
                            case entry.defunType of
                                QbeTypes.Polymorphic scheme ->
                                    decide pass ctx (bump (\c -> { c | candidates = c.candidates + 1 }) acc) ref.key scheme args

                                QbeTypes.Monotype _ ->
                                    ( Nothing, acc )

                        Nothing ->
                            ( Nothing, acc )

            Nothing ->
                ( Nothing, acc )


{-| Derive sigma from the ARGUMENTS, refuse if any clause fires, register the
key, and admit the site.
-}
decide : Pass -> Ctx -> Acc -> String -> Scheme -> List Exp -> ( Maybe String, Acc )
decide pass ctx acc callee scheme args =
    if not (List.isEmpty scheme.bound) then
        -- CLAUSE (b), and it is TOTAL — checked before anything is derived,
        -- because no derivation could ever admit the site. `bound` is a
        -- SUBSET of `quantifiers` (Type/Env.elm:56-75), and `quantifiers` IS
        -- `freeVars body`, so every rigid variable occurs in the scheme's
        -- body; the body is closed only if every occurrence is substituted,
        -- and instantiating a rigid variable is exactly what must not happen.
        -- So "the instantiation contains a variable in `bound`" is decided by
        -- the scheme alone: GADT type indices and `type x a.` prefixes make a
        -- defun un-specialisable, and no argument can change that.
        ( Nothing, bump (\c -> { c | refusedB = c.refusedB + 1 }) acc )

    else
        case ( deriveSigma ctx.binders scheme.body args, calleeSigma pass.table acc ctx.binders callee args ) of
        ( Just sigma, Just sigmaB ) ->
            let
                instantiated =
                    Rep.zonk sigma scheme.body

                quantIds =
                    List.map .id scheme.quantifiers

                closed =
                    List.all (\v -> Dict.member v.id sigma) scheme.quantifiers
                        && List.all (\k -> List.member k quantIds) (Dict.keys sigma)
                        && List.isEmpty (freeIds instantiated)
            in
            case refusal pass ctx scheme instantiated args closed of
                Just RefuseC ->
                    ( Nothing, bump (\c -> { c | refusedC = c.refusedC + 1 }) acc )

                Just RefuseA ->
                    ( Nothing, bump (\c -> { c | refusedA = c.refusedA + 1 }) acc )

                Nothing ->
                    let
                        cloneKey =
                            callee ++ "$" ++ Rep.pretty instantiated
                    in
                    case Dict.get cloneKey acc.keyTypes of
                        -- THE BIJECTION CHECK: the same key MUST denote the
                        -- same monotype. A different one is a collision — two
                        -- specialisations would silently share a body.
                        Just existing ->
                            if existing == instantiated then
                                ( Just cloneKey, bump (\c -> { c | converted = c.converted + 1 }) acc )

                            else
                                ( Nothing, bump (\c -> { c | collision = c.collision + 1 }) acc )

                        Nothing ->
                            case Dict.get callee acc.perBase of
                                Just n2 ->
                                    if n2 >= cloneCap then
                                        ( Nothing, bump (\c -> { c | capped = c.capped + 1 }) acc )

                                    else
                                        ( Just cloneKey, convertSite (create pass.table callee cloneKey sigma sigmaB instantiated acc) )

                                Nothing ->
                                    ( Just cloneKey, convertSite (create pass.table callee cloneKey sigma sigmaB instantiated acc) )

        -- NO INSTANTIATED CONTEXT: sigma (over the scheme's quantifiers) or
        -- sigmaB (over the callee's recorded ids — see `calleeSigma`) did not
        -- close, so there is no closed instantiation to rewrite the body in.
        -- Clause (a)'s family, with its own counter: "could not be typed at
        -- all" and "typed but left a variable open" are different failures and
        -- the record must not merge them.
        _ ->
            ( Nothing, bump (\c -> { c | untyped = c.untyped + 1 }) acc )


{-| A converted site is counted for the SITE, not for the clone: two call
sites that share one clone are two conversions and one clone.
-}
convertSite : Acc -> Acc
convertSite acc =
    bump (\c -> { c | converted = c.converted + 1 }) acc


{-| The clone's OWN binder context: the base defun's recorded binder types
zonked through the substitution derived from the defun's recorded PARAMETER
types (see `calleeSigma`). This is the "rewritten in their own context" half of
clone-do-not-replace: without it a nested call site inside the clone derives a
sigma over the SCHEME's ids while the binder types carry the INSTANTIATION's
ids, so every nested site — including the clone's own self-call — would be
refused as unclosed and the clone would tail-call the still-polymorphic
original: duplicated code with a call added, which is worse than not cloning.
-}
create : QbeTypes.Table -> String -> String -> Rep.Subst -> Rep.Subst -> Rep.Type -> Acc -> Acc
create table callee cloneKey sigma sigmaB instantiated acc =
    let
        binders =
            Dict.map (\_ v -> Rep.zonk sigmaB v) (binderTypesOf table callee)
    in
    bump (\c -> { c | clones = c.clones + 1 })
        { acc
            | cloneKeys = acc.cloneKeys ++ [ cloneKey ]
            , sigmas = Dict.insert cloneKey sigma acc.sigmas
            , bases = Dict.insert cloneKey callee acc.bases
            , keyTypes = Dict.insert cloneKey instantiated acc.keyTypes
            , cloneBinders = Dict.insert cloneKey binders acc.cloneBinders
            , perBase = Dict.insert callee (Maybe.withDefault 0 (Dict.get callee acc.perBase) + 1) acc.perBase
        }


{-| The substitution that names the INSTANTIATION in the callee's own recorded
ids — the ids its BINDER TYPES carry.

It exists because those are not the SCHEME's ids for a SIGNATUREd defun:
`inferClause` checks the body against `instantiatePartial` of the signature's
scheme (Type/Infer.elm:2818), so the parameter patterns are typed with the
INSTANTIATION's vars while `scheme.quantifiers` names the annotation's. Zonking
a binder map with `deriveSigma`'s substitution would therefore be a NO-OP —
silently, which is exactly how a clone ends up with an un-instantiated context.

So the same first-order match is run a second time, with the defun's RECORDED
PARAMETER TYPES as the pattern. If it cannot be closed, the clone's context
does not exist and the site is refused (clause (a), see `decide`).
-}
calleeSigma : QbeTypes.Table -> Acc -> Dict Int Rep.Type -> String -> List Exp -> Maybe Rep.Subst
calleeSigma table acc callersBinders callee args =
    case Dict.get callee acc.pristine of
        Just defun ->
            case defun.value of
                Lam lambda ->
                    Maybe.andThen
                        (\doms -> deriveList callersBinders doms args Rep.emptySubst)
                        (paramTypes table callee lambda)

                _ ->
                    Nothing

        Nothing ->
            Nothing


{-| The defun's parameter types in the callee's own ids — `Nothing` if any
parameter has no recorded type (a synthetic binder, a conflicted range, a unit
whose inference did not run), which is the deny-by-default answer.
-}
paramTypes : QbeTypes.Table -> String -> Lambda -> Maybe (List Rep.Type)
paramTypes table callee lambda =
    let
        binderMap =
            binderTypesOf table callee
    in
    List.foldr (Maybe.map2 (::)) (Just []) (List.map (\p -> Dict.get p.id binderMap) lambda.params)


{-| The three refusal clauses, in the order (b), (c), (a) so the counter line
attributes a refusal to the clause that really fired. See the header: the
order is accounting, not admission.
-}
type Refusal
    = RefuseA
    | RefuseC


refusal : Pass -> Ctx -> Scheme -> Rep.Type -> List Exp -> Bool -> Maybe Refusal
refusal pass ctx scheme instantiated args closed =
    let
        refinedIds =
            Dict.get ctx.source pass.refined
                |> Maybe.withDefault Set.empty
                |> Set.toList

        -- Every type the site USES, all of them in the caller's own unit
        -- namespace: the obtainable argument types, and the binder types of
        -- every variable appearing anywhere in an argument SUBTREE (the walk
        -- that catches a refined binder inside an argument whose own type is
        -- unobtainable).
        usedTypes =
            List.filterMap (argTypeOf ctx.binders) args
                ++ List.filterMap (\v -> Dict.get v ctx.binders) (List.concatMap varsOf args)

        mentions ids t =
            List.any (\i -> List.member i ids) (freeIds t)

        anyMention ids ts =
            List.any (mentions ids) ts
    in
    -- CLAUSE (b) IS NOT HERE: it is decided by the scheme alone and is total,
    -- so it is checked before the derivation (see `decide`).
    if anyMention refinedIds usedTypes || anyMention refinedIds [ instantiated ] then
        Just RefuseC

    else if closed then
        Nothing

    else
        Just RefuseA


{-| THE SIGMA. `Rep.TFun` is `arg -> result` (`Type.Representation`), so the
scheme's body peels in the callee's parameter order and the argument list
lines up with it positionally. Every admitted position contributes bindings;
a position whose type cannot be obtained contributes NONE but is only
tolerated when the expected type has no variable to bind (see `matchArg`), and
the completeness check in `decide` then refuses the instance unless every
quantifier closed.
-}
deriveSigma : Dict Int Rep.Type -> Rep.Type -> List Exp -> Maybe Rep.Subst
deriveSigma binders body args =
    Maybe.andThen (\doms -> deriveList binders doms args Rep.emptySubst) (domainsOf body (List.length args))


{-| The leading `n` domains of a function type, in parameter order. `Nothing`
when the type is not an `n`-ary function — a saturated call whose scheme does
not have that many domains is not a shape this pass understands.
-}
domainsOf : Rep.Type -> Int -> Maybe (List Rep.Type)
domainsOf t n =
    if n <= 0 then
        Just []

    else
        case t of
            TFun domain result ->
                Maybe.map ((::) domain) (domainsOf result (n - 1))

            _ ->
                Nothing


deriveList : Dict Int Rep.Type -> List Rep.Type -> List Exp -> Rep.Subst -> Maybe Rep.Subst
deriveList binders domains args sigma =
    case ( domains, args ) of
        ( [], [] ) ->
            Just sigma

        ( domain :: restDomains, arg :: restArgs ) ->
            case matchArg binders domain arg sigma of
                Nothing ->
                    Nothing

                Just sigma1 ->
                    deriveList binders restDomains restArgs sigma1

        _ ->
            Nothing


{-| ONE argument position.

  * a `Lam` argument is matched POSITIONALLY against the expected function
    type's domains, its own parameters' types read from the S2 binder map.
    The Lam's RESULT position is SKIPPED — that is where the caller's
    inference result lives, and it is not an input to the scheme;
  * anything else contributes its own type when the binder map has one;
  * anything else WITHOUT a type contributes nothing, which is admitted only
    when the expected type is variable-free (nothing to leave open).

-}
matchArg : Dict Int Rep.Type -> Rep.Type -> Exp -> Rep.Subst -> Maybe Rep.Subst
matchArg binders expected arg sigma =
    let
        -- ZONK FIRST. A position whose argument has no obtainable type is
        -- tolerated only when there is nothing left to bind, and "nothing
        -- left" is a fact about the sigma accumulated SO FAR: `b` is already
        -- ground once an earlier position bound it, and reading the raw
        -- `TVar b` here would refuse a shape the pass exists for.
        ground =
            Rep.zonk sigma expected
    in
    case ( ground, arg ) of
        ( TFun _ _, Lam lambda ) ->
            matchLam binders ground lambda.params sigma

        _ ->
            case argTypeOf binders arg of
                Just t ->
                    matchInto sigma ground t

                Nothing ->
                    if List.isEmpty (freeIds ground) then
                        Just sigma

                    else
                        Nothing


matchLam : Dict Int Rep.Type -> Rep.Type -> List Binder -> Rep.Subst -> Maybe Rep.Subst
matchLam binders expected params sigma =
    case params of
        [] ->
            Just sigma

        p :: rest ->
            case ( expected, Dict.get p.id binders ) of
                ( TFun domain result, Just pt ) ->
                    case matchInto sigma domain pt of
                        Nothing ->
                            Nothing

                        Just sigma1 ->
                            matchLam binders (Rep.zonk sigma1 result) rest sigma1

                _ ->
                    Nothing


{-| FIRST-ORDER MATCH of a scheme type against a concrete one (`pattern` may
mention variables; `concrete` is the type the checker gave the argument in the
caller's context). Variables already bound are substituted first, so a second
occurrence is an EQUALITY test, not a fresh binding.

`TRecord` is DENIED: a row carries a tail and `Rep.zonk` SPLICES bound rows, so
matching into one is not first-order — and no admitted shape needs it
(deny-by-default, the `Flatten.usesOK` precedent).

-}
matchInto : Rep.Subst -> Rep.Type -> Rep.Type -> Maybe Rep.Subst
matchInto sigma pattern concrete =
    let
        pat =
            Rep.zonk sigma pattern
    in
    if List.isEmpty (freeIds pat) then
        -- A GROUND pattern is an EQUALITY test, not a structural match: there
        -- is nothing left to bind, and the second occurrence of an already
        -- bound variable arrives here (a `Rec`-shaped binding re-read through
        -- `List a`, say). Equality is exact, and `Nothing` on a mismatch is
        -- the deny-by-default answer.
        if pat == concrete then
            Just sigma

        else
            Nothing

    else
        case pat of
            TVar v ->
                if concrete == TVar v then
                    -- THE IDENTITY: the argument's type IS the variable being
                    -- instantiated. Recorded by NOT binding it (binding a
                    -- variable to itself would make `Rep.zonk` loop), which
                    -- leaves the instantiation open — and the completeness
                    -- check in `decide` then refuses the site as unclosed,
                    -- which is what it is. It can never ADMIT a site.
                    Just sigma

                else if mentionsVar v concrete then
                    -- An occurs check: `a ~ List a` is not a match.
                    Nothing

                else
                    Just (Dict.insert v.id concrete sigma)

            TCon name targs ->
                case concrete of
                    TCon cname cargs ->
                        if name == cname && List.length targs == List.length cargs then
                            matchList sigma targs cargs

                        else
                            Nothing

                    _ ->
                        Nothing

            TFun a b ->
                case concrete of
                    TFun c d ->
                        matchList sigma [ a, b ] [ c, d ]

                    _ ->
                        Nothing

            TTuple ts ->
                case concrete of
                    TTuple us ->
                        if List.length ts == List.length us then
                            matchList sigma ts us

                        else
                            Nothing

                    _ ->
                        Nothing

            -- A ROW WITH VARIABLES IS DENIED: `Rep.zonk` splices a bound row
            -- into the enclosing field list, so matching into one is not
            -- first-order, and no admitted shape needs it (deny-by-default,
            -- the `Flatten.usesOK` precedent). A GROUND row never reaches
            -- here — it is the equality arm above.
            TRecord _ ->
                Nothing


matchList : Rep.Subst -> List Rep.Type -> List Rep.Type -> Maybe Rep.Subst
matchList sigma pats cons =
    case ( pats, cons ) of
        ( [], [] ) ->
            Just sigma

        ( p :: ps, c :: cs ) ->
            case matchInto sigma p c of
                Nothing ->
                    Nothing

                Just sigma1 ->
                    matchList sigma1 ps cs

        _ ->
            Nothing


mentionsVar : VarId -> Rep.Type -> Bool
mentionsVar v t =
    List.any (\u -> u.id == v.id) (Env.freeVars t)


freeIds : Rep.Type -> List Int
freeIds t =
    List.map .id (Env.freeVars t)


argTypeOf : Dict Int Rep.Type -> Exp -> Maybe Rep.Type
argTypeOf binders exp =
    case exp of
        Var id ->
            Dict.get id binders

        NoTail inner ->
            argTypeOf binders inner

        _ ->
            Nothing


{-| The variable ids appearing anywhere in an expression — the
argument-SUBTREE walk of clause (c). Built on `foldExp` so there is exactly
one account of what "anywhere in" means.
-}
varsOf : Exp -> List Int
varsOf exp =
    foldExp (\e acc -> collectVars e ++ acc) [] exp


collectVars : Exp -> List Int
collectVars exp =
    case exp of
        Var id ->
            [ id ]

        _ ->
            []



-- ============================ THE REWRITE ============================


{-| Rewrite one expression in one context. `App` keeps its ORIGINAL NESTING
(only the head key moves and the arguments are descended into): over-
application is nested `App` nodes in Mid, and `Lower.lowerApp` flattens them
with its own `spine`, so restructuring here would change nothing downstream
while breaking the pass's own inertness.
-}
rw : Pass -> Ctx -> Acc -> Exp -> ( Exp, Acc )
rw pass ctx acc exp =
    case exp of
        Lit _ ->
            ( exp, acc )

        Var _ ->
            ( exp, acc )

        GRef _ ->
            ( exp, acc )

        StreamRef _ ->
            ( exp, acc )

        NoTail inner ->
            let
                ( i, acc1 ) =
                    rw pass ctx acc inner
            in
            ( NoTail i, acc1 )

        Lam lambda ->
            let
                ( b, acc1 ) =
                    rw pass ctx acc lambda.body
            in
            ( Lam { lambda | body = b }, acc1 )

        App _ ->
            let
                ( head, args ) =
                    spine exp
            in
            case head of
                GRef ref ->
                    let
                        ( args1, acc1 ) =
                            rwList pass ctx acc args
                    in
                    let
                        ( admitted, acc2 ) =
                            site pass ctx acc1 ref args1
                    in
                    case admitted of
                        Just cloneKey ->
                            ( setHead cloneKey (putArgs args1 exp), acc2 )

                        Nothing ->
                            ( putArgs args1 exp, acc2 )

                _ ->
                    let
                        ( head1, acc1 ) =
                            rw pass ctx acc head

                        ( args1, acc2 ) =
                            rwList pass ctx acc1 args
                    in
                    ( setHeadNode head1 (putArgs args1 exp), acc2 )

        PrimApp app ->
            mapArgs pass ctx acc app.args (\as1 -> PrimApp { app | args = as1 })

        Let block ->
            let
                ( binders1, acc1 ) =
                    rwLetBinders pass ctx acc block.binders

                ( body1, acc2 ) =
                    rw pass ctx acc1 block.body
            in
            ( Let { block | binders = binders1, body = body1 }, acc2 )

        Case branch ->
            let
                ( scrut1, acc1 ) =
                    rw pass ctx acc branch.scrutinee

                ( bodies, acc2 ) =
                    rwList pass ctx acc1 (List.map .body branch.alts)
            in
            ( Case { branch | scrutinee = scrut1, alts = List.map2 (\alt b -> { alt | body = b }) branch.alts bodies }, acc2 )

        Con con ->
            mapArgs pass ctx acc con.args (\as1 -> Con { con | args = as1 })

        Tup es ->
            mapArgs pass ctx acc es Tup

        RecordLit setters ->
            mapArgs pass
                ctx
                acc
                (List.map Tuple.second setters)
                (\vs -> RecordLit (List.map2 (\p v -> ( Tuple.first p, v )) setters vs))

        RecordGet rec field ->
            let
                ( r, acc1 ) =
                    rw pass ctx acc rec
            in
            ( RecordGet r field, acc1 )

        RecordUpdate up ->
            let
                ( base1, acc1 ) =
                    rw pass ctx acc up.base

                ( values, acc2 ) =
                    rwList pass ctx acc1 (List.map Tuple.second up.updates)
            in
            ( RecordUpdate { up | base = base1, updates = List.map2 (\fld v -> ( Tuple.first fld, v )) up.updates values }, acc2 )

        ListLit es ->
            mapArgs pass ctx acc es ListLit

        If block ->
            let
                ( cond1, acc1 ) =
                    rw pass ctx acc block.cond

                ( then1, acc2 ) =
                    rw pass ctx acc1 block.thenBranch

                ( else1, acc3 ) =
                    rw pass ctx acc2 block.elseBranch
            in
            ( If { block | cond = cond1, thenBranch = then1, elseBranch = else1 }, acc3 )

        ShortAnd block ->
            rw2 pass ctx acc block.left block.right (\l r -> ShortAnd { block | left = l, right = r })

        ShortOr block ->
            rw2 pass ctx acc block.left block.right (\l r -> ShortOr { block | left = l, right = r })

        NotEqual block ->
            rw2 pass ctx acc block.left block.right (\l r -> NotEqual { block | left = l, right = r })

        Unsafe node ->
            -- (`<<` is not in the subset this tree compiles ITSELF with:
            -- `tools/qbe-bootstrap.sh --freeze` rejected the composition form,
            -- exit 2. The lambda is the same function.)
            mapArgs pass ctx acc (unsafeChildren node) (\parts -> Unsafe (unsafeRebuild node parts))


rw2 : Pass -> Ctx -> Acc -> Exp -> Exp -> (Exp -> Exp -> Exp) -> ( Exp, Acc )
rw2 pass ctx acc left right k =
    let
        ( l1, acc1 ) =
            rw pass ctx acc left

        ( r1, acc2 ) =
            rw pass ctx acc1 right
    in
    ( k l1 r1, acc2 )


mapArgs : Pass -> Ctx -> Acc -> List Exp -> (List Exp -> Exp) -> ( Exp, Acc )
mapArgs pass ctx acc args k =
    let
        ( args1, acc1 ) =
            rwList pass ctx acc args
    in
    ( k args1, acc1 )


rwList : Pass -> Ctx -> Acc -> List Exp -> ( List Exp, Acc )
rwList pass ctx acc args =
    List.foldl
        (\e ( out, a ) ->
            let
                ( e1, a1 ) =
                    rw pass ctx a e
            in
            ( out ++ [ e1 ], a1 )
        )
        ( [], acc )
        args


rwLetBinders : Pass -> Ctx -> Acc -> List LetBinder -> ( List LetBinder, Acc )
rwLetBinders pass ctx acc binders =
    List.foldl
        (\b ( out, a ) ->
            case b of
                LetBind bind ->
                    let
                        ( v, a1 ) =
                            rw pass ctx a bind.value
                    in
                    ( out ++ [ LetBind { bind | value = v } ], a1 )

                LetDestruct d ->
                    let
                        ( v, a1 ) =
                            rw pass ctx a d.value
                    in
                    ( out ++ [ LetDestruct { d | value = v } ], a1 )
        )
        ( [], acc )
        binders



-- ============================ SPINE HELPERS ============================
-- `Mid.Ir` builds an over-applied call as NESTED `App` nodes; `Lower.spine`
-- flattens that chain to (head, args) with the INNERMOST node's arguments
-- FIRST. The pass flattens only to DECIDE, and puts the rewritten arguments
-- back at the same leaves, so the tree it hands down is the tree it was
-- handed, argument positions aside.


spine : Exp -> ( Exp, List Exp )
spine exp =
    case exp of
        App app ->
            let
                ( head, args ) =
                    spine app.fn
            in
            ( head, args ++ app.args )

        NoTail inner ->
            spine inner

        _ ->
            ( exp, [] )


{-| Replace the key of the spine's `GRef` head, leaving the nesting as it was.
-}
setHead : String -> Exp -> Exp
setHead key exp =
    case exp of
        App app ->
            App { app | fn = setHead key app.fn }

        NoTail inner ->
            NoTail (setHead key inner)

        GRef ref ->
            GRef { ref | key = key }

        _ ->
            exp


{-| Put a FLAT argument list back into the nesting's own leaves, preserving
order: `spine` flattens INNERMOST-FIRST, so each `App` node owns the TAIL of
the list and the nodes below it own the prefix.
-}
putArgs : List Exp -> Exp -> Exp
putArgs args exp =
    case exp of
        App app ->
            let
                n =
                    List.length app.args

                below =
                    List.length args - n
            in
            App { app | fn = putArgs (List.take below args) app.fn, args = List.drop below args }

        NoTail inner ->
            NoTail (putArgs args inner)

        _ ->
            exp


{-| Replace the SPINE'S LEAF — the node the flattened head came from — keeping
the argument nesting intact. `spine` stops at the first node that is not an
`App`, so exactly one node in the chain has the head as its `fn`.
-}
setHeadNode : Exp -> Exp -> Exp
setHeadNode headR exp =
    case exp of
        App app ->
            App { app | fn = setHeadNode headR app.fn }

        NoTail inner ->
            NoTail (setHeadNode headR inner)

        _ ->
            headR



-- ============================ TRAVERSAL ============================


{-| Every direct subexpression, in a fixed order. ONE account of "the children
of a node" — `foldExp` is built on it, so a new constructor cannot be walked
by one consumer and missed by another (Elm's exhaustiveness check fails the
build on the omission).
-}
childrenOf : Exp -> List Exp
childrenOf exp =
    case exp of
        Lit _ ->
            []

        Var _ ->
            []

        GRef _ ->
            []

        StreamRef _ ->
            []

        Lam lambda ->
            [ lambda.body ]

        NoTail inner ->
            [ inner ]

        App app ->
            app.fn :: app.args

        PrimApp app ->
            app.args

        Let block ->
            List.map letValue block.binders ++ [ block.body ]

        Case branch ->
            branch.scrutinee :: List.map .body branch.alts

        Con con ->
            con.args

        Tup es ->
            es

        RecordLit setters ->
            List.map Tuple.second setters

        RecordGet rec _ ->
            [ rec ]

        RecordUpdate up ->
            up.base :: List.map Tuple.second up.updates

        ListLit es ->
            es

        If block ->
            [ block.cond, block.thenBranch, block.elseBranch ]

        ShortAnd block ->
            [ block.left, block.right ]

        ShortOr block ->
            [ block.left, block.right ]

        NotEqual block ->
            [ block.left, block.right ]

        Unsafe node ->
            unsafeChildren node


letValue : LetBinder -> Exp
letValue b =
    case b of
        LetBind bind ->
            bind.value

        LetDestruct d ->
            d.value


unsafeChildren : UnsafeNode -> List Exp
unsafeChildren node =
    case node of
        RawCall call ->
            call.args

        RawTagOf e ->
            [ e ]

        RawPayload r ->
            [ r.value ]

        RawMkValue r ->
            r.words

        RawAllocVector e ->
            [ e ]

        RawVecLoad r ->
            [ r.vec, r.index ]

        RawVecAddr r ->
            [ r.vec, r.index ]

        RawVecStore r ->
            [ r.vec, r.index, r.value ]

        RawStrByte r ->
            [ r.str, r.index ]

        WithRoots r ->
            [ r.body ]

        RawPayload32 r ->
            [ r.value ]

        RawTagIs r ->
            [ r.value ]

        RawBin r ->
            [ r.a, r.b ]

        RawUn r ->
            [ r.v ]

        RawCmp r ->
            [ r.a, r.b ]

        RawFltBin r ->
            [ r.a, r.b ]

        RawFltCmp r ->
            [ r.a, r.b ]

        RawIToF e ->
            [ e ]

        RawLoadFlt e ->
            [ e ]

        RawAllocRaw e ->
            [ e ]

        RawByteLoad r ->
            [ r.ptr, r.index ]

        RawByteStore r ->
            [ r.ptr, r.index, r.value ]

        RawWordLoad r ->
            [ r.ptr, r.index ]

        RawWordStore r ->
            [ r.ptr, r.index, r.value ]

        RawCallRaw call ->
            call.args

        RawDataAddr _ ->
            []


unsafeRebuild : UnsafeNode -> List Exp -> UnsafeNode
unsafeRebuild node parts =
    case ( node, parts ) of
        ( RawMkValue r, _ ) ->
            RawMkValue { r | words = parts }

        ( RawCall call, _ ) ->
            RawCall { call | args = parts }

        ( RawCallRaw call, _ ) ->
            RawCallRaw { call | args = parts }

        ( RawBin r, a :: b :: _ ) ->
            RawBin { r | a = a, b = b }

        ( RawCmp r, a :: b :: _ ) ->
            RawCmp { r | a = a, b = b }

        ( RawFltBin r, a :: b :: _ ) ->
            RawFltBin { r | a = a, b = b }

        ( RawFltCmp r, a :: b :: _ ) ->
            RawFltCmp { r | a = a, b = b }

        ( RawVecLoad r, a :: b :: _ ) ->
            RawVecLoad { r | vec = a, index = b }

        ( RawVecAddr r, a :: b :: _ ) ->
            RawVecAddr { r | vec = a, index = b }

        ( RawVecStore r, a :: b :: c :: _ ) ->
            RawVecStore { r | vec = a, index = b, value = c }

        ( RawStrByte r, a :: b :: _ ) ->
            RawStrByte { r | str = a, index = b }

        ( RawByteLoad r, a :: b :: _ ) ->
            RawByteLoad { r | ptr = a, index = b }

        ( RawByteStore r, a :: b :: c :: _ ) ->
            RawByteStore { r | ptr = a, index = b, value = c }

        ( RawWordLoad r, a :: b :: _ ) ->
            RawWordLoad { r | ptr = a, index = b }

        ( RawWordStore r, a :: b :: c :: _ ) ->
            RawWordStore { r | ptr = a, index = b, value = c }

        ( RawTagOf _, e :: _ ) ->
            RawTagOf e

        ( RawPayload r, e :: _ ) ->
            RawPayload { r | value = e }

        ( RawPayload32 r, e :: _ ) ->
            RawPayload32 { r | value = e }

        ( RawTagIs r, e :: _ ) ->
            RawTagIs { r | value = e }

        ( RawAllocVector _, e :: _ ) ->
            RawAllocVector e

        ( RawUn r, e :: _ ) ->
            RawUn { r | v = e }

        ( RawIToF _, e :: _ ) ->
            RawIToF e

        ( RawLoadFlt _, e :: _ ) ->
            RawLoadFlt e

        ( RawAllocRaw _, e :: _ ) ->
            RawAllocRaw e

        ( WithRoots r, e :: _ ) ->
            WithRoots { r | body = e }

        ( RawDataAddr _, _ ) ->
            node

        _ ->
            node


{-| A pre-order fold over every subexpression (including the root).
-}
foldExp : (Exp -> a -> a) -> a -> Exp -> a
foldExp f acc exp =
    foldKids f (childrenOf exp) (f exp acc)


foldKids : (Exp -> a -> a) -> List Exp -> a -> a
foldKids f kids acc =
    case kids of
        [] ->
            acc

        kid :: rest ->
            foldKids f rest (foldExp f acc kid)



-- ============================ REACHABILITY ============================


{-| The `GRef` closure of the program from the entry key — `Lower.reach`'s
walk, so the pass considers exactly the defuns the emitter will emit. Clones
are appended to the OUTPUT, never discovered here.
-}
reach : Dict String Defun -> String -> List String -> Result String (List String)
reach defuns key seen =
    if List.member key seen then
        Ok seen

    else
        case Dict.get key defuns of
            Nothing ->
                Err ("qbe: unknown global referenced: " ++ key)

            Just defun ->
                List.foldl
                    (\k acc -> Result.andThen (\s -> reach defuns k s) acc)
                    (Ok (key :: seen))
                    (grefsOf defun.value)


grefsOf : Exp -> List String
grefsOf exp =
    foldExp
        (\e acc ->
            case e of
                GRef ref ->
                    ref.key :: acc

                _ ->
                    acc
        )
        []
        exp


isRtKey : String -> Bool
isRtKey key =
    String.startsWith "Rt." key


bump : (Counts -> Counts) -> Acc -> Acc
bump f acc =
    { acc | counts = f acc.counts }

