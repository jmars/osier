module Frontend.Lift exposing (liftFile)

{-| Frontend lambda-lifting for self- and mutually-recursive LOCAL `let`
function groups.

The checker (`Type.Infer.inferLetFunction`) and lowerer
(`Lower.Expr.lowerLetFunction`) both treat `let` declarations SEQUENTIALLY: a
function's own name is bound only AFTER its body is checked, so a
self-recursive local helper fails with `type error at L:C: unknown name: f`.
Top-level recursion already works (Infer's `sccOrder` treats the unit's
top-level functions as one recursive group), so the fix is to HOIST each
recursive local group to the top level as an ordinary top-level function,
threading the group's free variables as leading parameters.

=============================================================================
THE INVARIANT (one sentence)
=============================================================================

After lifting, every reference in the program denotes the SAME BINDING it
denoted before lifting, resolved POSITIONALLY under the substrate's sequential
visibility (with the settled Elm-shadowing policy exceptions for self/backward
references), and any group the pass cannot rewrite consistently is left
untouched so the checker rejects it LOUDLY.

The substrate resolves `let` names POSITIONALLY and SEQUENTIALLY: `inferLet`
(Infer.elm:1173) folds declarations in order and prepends each binding, so a
reference inside declaration `i` sees the enclosing scope plus declarations
`0..i-1`.  One source NAME can therefore denote two DIFFERENT bindings at two
different positions.  Every earlier revision of this pass modelled the rewrite
as a map keyed by source name and so conflated them; the design below keys
every decision by `(name, declaration position)` instead.

=============================================================================
THE TRANSFORMATION
=============================================================================

  * All of the block's `LetFunction` declarations form the CANDIDATE group;
    only the members that lie ON A CYCLE of the reference graph (self- or
    mutual recursion) are lifted (see EDGE RULE below).
  * FIX 2 -- CYCLIC VALUES ARE NOT LIFTED.  If any member on a cycle has
    ARITY 0 (a `let v = ...` VALUE binding), the group is left untouched and
    the checker rejects it loudly.  A cycle through a value is a cyclic
    DEFINITION: real Elm rejects it (`CYCLIC DEFINITION`), and the substrate
    rejects it as `unknown name` when the name has no outer binding.  Lifting
    it would diverge (the previous revision looped forever / aborted here).
  * FIX 3 -- SNAPSHOT CAPTURES.  Each CAPTURE is given its own uniquely-named
    0-arg binding -- a SNAPSHOT -- keyed by the BINDING it denotes, i.e. by
    `(source name, declaration position)`:
      - `Enclosing n` -- a binding from the enclosing lexical scope (a
        parameter / outer `let`); its snapshot is `n$snap<k>` emitted at the
        TOP of the block, where the enclosing binding is observable (this is
        what makes `c5`'s parameter visible before a like-named sibling
        shadows it);
      - `Sibling n i` -- a binding made by declaration `i` of THIS block; its
        snapshot is emitted IMMEDIATELY AFTER declaration `i`.
    Since `$` is illegal in Elm identifiers, no snapshot can collide with a
    user name, so a call site NEVER spells an ambiguous source name again --
    that is what makes the conflation structurally impossible.
  * Every LIFTED member's declaration is DELETED from the block and emitted as
    a top-level `f$lift_<k>` with parameters `[all snapshot names] ++ [own
    params]`; every reference to a lifted member -- in member bodies, in
    staying declarations, and in the block's final expression -- is rewritten
    to `g$lift_<j> <all snapshot names>` (a bare name when there are no
    snapshots: `Lower.Expr.application` emits an `Apply` for any Application,
    so a 0-argument application of an N-arg closure would fail at runtime).
  * R2 -- ORDERING REFUSAL.  A snapshot is visible only after its own
    declaration, so if a STAYING declaration that references a lifted member
    would have to spell a snapshot declared at or after it, the whole group is
    left untouched (loudly rejected by the checker, which is what HEAD does
    today for exactly these ill-founded orderings).

=============================================================================
EDGE RULE (FIX 1) -- keyed by DECLARATION ORDER
=============================================================================

For a reference from member `f` (declaration index `i`) to a group-member name
`g` (declaration index `j`), a cycle EDGE exists iff `g` is free in `f`'s body
and `g` is not bound by the enclosing scope, AND:

  * `j <= i` (self or BACKWARD): the sibling is already visible under the
    substrate's sequential rule, so it shadows the outer binding -- always an
    edge.  This is the settled Elm-shadowing edge that keeps `liftself`,
    `liftdelegate`, `liftprelude` and `mutual` cycles lifting.
  * `j > i` (FORWARD): an edge only if the name has NO outer binding, or if
    the SHADOWING refinement applies (`forwardAllowed`).  A forward reference
    is resolved outward by the substrate, so a program that already compiles
    keeps its sequential meaning -- this is what keeps `/tmp/lr3/src/b13.elm`
    at HEAD's 999 instead of a fabricated 5000 (variants b9/b10/b11/b12
    likewise keep HEAD's values).

ONE RESOLUTION PROCEDURE.  Cycle detection, a lifted member's body, a STAYING
declaration and the block's final expression ALL resolve a reference through
`forwardAllowed` + `resolvePositional` at the reference's own declaration
index.  It is never classified one way to find the cycle and another way when
the rewrite runs: `rewriteDeclRefs` is position-AWARE, so a staying declaration
only spells a lifted member when the reference really denotes it at that
position (w5: `g v = helper v` beside a self-recursive local `helper` keeps the
MODULE `helper`, HEAD's 999 -- a position-blind rewrite printed 5000).

`outerNames` is the set of bare names THE CHECKER ITSELF would resolve
outward, taken from the checker's own table so the two passes cannot drift:
`Lower.Resolve.aliasTableFor` (module's own exports + explicit import exposes
+ Prelude/prims/platform, the SAME call `Type.Infer.inferUnit` makes at
Infer.elm:105), UNION this file's top-level declaration and constructor names.
This is deliberately NOT a hand-rolled Prelude name list (that was the round-3
hole).  A `(..)`-imported name is never in scope at all (`Lower.Resolve.importAlias`
returns `[]` for `Exposing.All` -- it cannot enumerate a module's exports), so
the hole there is vacuous; an opened `T(..)` constructor is the one residual
that a per-file AST pass cannot enumerate (documented, not silent here because
such a name only ever VETOES an edge -- the loud direction).

DECLARED DIVERGENCE FROM TRUE ELM (liftfwd invariant; deliberate): for a
FORWARD reference to a later sibling whose name also exists at module/Prelude
level, the pass takes the SUBSTRATE's SEQUENTIAL answer, not Elm's letrec
answer.  `b13` is the witness: the substrate resolves `h`'s forward `helper`
to the top-level `helper` (999); true Elm letrec would make both local and
print 5000.  The sequential answer is chosen because the pass ENABLES recursion
the substrate cannot express -- it must not change the meaning of a program
that already compiles.

THE SHADOWING REFINEMENT (`forwardAllowed`), and why it is SCC- and
TARGET-scoped.  The divergence above would un-lift a mutually recursive pair
whose names ALL shadow outer bindings (`liftdelegmut`: `let even ...; odd ...`
beside a top-level `even`/`odd`), reverting the user's Elm-shadowing decision
(0 -> HEAD's 888).  So the veto is relaxed exactly when the reference is the
decision's case, decided PER (referrer, target) PAIR over the permissive edges:
(1) the TARGET is on the REFERRER's own strongly-connected set (both endpoints
of the same recursive cycle -- the wiring), AND (2) every name in that SCC
shadows an outer binding.  Consequences, each pinned by a fixture:
  * the census is per-SCC, not a union of all cycles in the block, so an
    unrelated disjoint cycle cannot flip a shadowing cycle's answer
    (n25/liftdisjointshadow; w11/liftcycshadows the value-sibling variant);
  * a forward reference to a NON-cycle sibling keeps the substrate's outward
    resolution even from a cycle member (n33/liftrelaxleak: even's forward `m`
    is not on even's cycle, so it stays the module `m`);
  * a reference FROM OUTSIDE any cycle keeps the substrate's outward resolution
    (w5/liftstayfwd: the staying `g v = helper v` delegates to the top-level
    `helper`).
The relaxation is therefore per-REFERENCE and stable: renaming or adding a
declaration that does not participate in the reference's own cycle cannot change
how that reference resolves.

SHADOWING POLICY (Elm shadowing; user decision 2026-10-06): a local recursive
group member's name shadows a MODULE-level / imported / Prelude binding --
`let identity k = ... identity ...` recurses rather than delegating to
Prelude.identity.  The one retained exception is a name bound by an ENCLOSING
scope binding (a parameter or an outer `let`): that keeps the substrate's
SEQUENTIAL priority and does not create a cycle edge (see `liftenclosing`).

NON-recursive let groups, let-destructuring, and everything else are left
byte-identical (the corpus oracle).  Signatures carried on a let-function ARE
DROPPED: the vendored parser does attach them (vendor
Elm/Parser/Expression.elm:740-795), but the checker's `inferLetFunction`
ignores let signatures entirely (Infer.elm:1197-1211), so the drop matches
checker behavior.

LIMITATION (loud, never a wrong value): a recursive helper defined INSIDE a
GADT case branch whose body reads a branch-refined field is REJECTED after
lifting -- the hoisted top-level function has no branch equations, so the field
read fails `rigid a cannot be unified with {| a}` while the identical
non-recursive in-place control compiles and runs.  No wrong-value witness
exists; the failure is a type error, not silent.

The pass itself is written in the accepted subset: top-level recursion only,
no recursive local `let` (chicken-and-egg).

-}

import Elm.Syntax.Declaration as Declaration exposing (Declaration(..))
import Elm.Syntax.Expression as Expression exposing (Expression(..), Function, FunctionImplementation, Lambda, LetBlock, LetDeclaration(..), RecordSetter)
import Elm.Syntax.File as File exposing (File)
import Elm.Syntax.Module as SyntaxModule
import Elm.Syntax.Node as Node exposing (Node(..))
import Elm.Syntax.Pattern as Pattern exposing (Pattern(..))
import Elm.Syntax.Range as Range exposing (Range)
import Lower.Resolve as Resolve



-- ======================= PUBLIC API =======================


{-| Lift every recursive local `let` function group in a file to fresh
top-level declarations, appending the lifted declarations after the file's
(rewritten) original declarations.  Non-recursive constructs are unchanged.
-}
liftFile : File -> File
liftFile file =
    let
        declared =
            List.concatMap topLevelNames file.declarations

        outerNames =
            List.map Tuple.first
                (Resolve.aliasTableFor
                    (SyntaxModule.moduleName (Node.value file.moduleDefinition))
                    (Resolve.exportedNames file.moduleDefinition declared)
                    file.imports
                )
                ++ declared
                |> dedupe

        ( finalState, decls ) =
            walkDecls { nextId = 0, lifted = [], outerNames = outerNames } file.declarations
    in
    { file | declarations = decls ++ finalState.lifted }


{-| The names the checker would resolve OUTWARD for a bare reference: this
file's top-level function names, constructor names, and top-level
destructuring bindings.
-}
topLevelNames : Node Declaration -> List String
topLevelNames (Node _ decl) =
    case decl of
        FunctionDeclaration fn ->
            [ nodeString (Node.value fn.declaration).name ]

        CustomTypeDeclaration ct ->
            List.map (\c -> nodeString (Node.value c).name) ct.constructors

        Destructuring pat _ ->
            patternNames pat

        _ ->
            []



-- ======================= STATE =======================


{-| Threaded pass state: the next fresh id (module-wide, so nested lifts and
snapshots never collide), the accumulated lifted top-level declarations, and
the checker's outward name set (`outerNames`).
-}
type alias State =
    { nextId : Int
    , lifted : List (Node Declaration)
    , outerNames : List String
    }


{-| A CAPTURE SLOT: the binding a free name denotes at a given declaration
position.  `Enclosing n` is a binding of the enclosing lexical scope;
`Sibling n i` is declaration `i` of the current block.  Slots are the KEY of
the snapshot model -- one snapshot per slot, never one per source name.
-}
type Slot
    = Enclosing String
    | Sibling String Int


{-| How one free name of ONE member is resolved at that member's position.
-}
type Resolved
    = Keep

    -- leave the source name alone (module/import/Prelude binding, or unknown -> loud)
    | Snapshot Slot

    -- rewrite to this slot's snapshot name
    | Call String

    -- rewrite to `g$lift_<j> <snapshots>`


{-| Source name -> lift name map (association list; groups are tiny).
-}
type alias NameMap =
    List ( String, String )


lookupName : String -> NameMap -> String
lookupName name map =
    case lookupOpt name map of
        Just v ->
            v

        Nothing ->
            name


lookupOpt : String -> NameMap -> Maybe String
lookupOpt name map =
    case map of
        [] ->
            Nothing

        ( k, v ) :: rest ->
            if k == name then
                Just v

            else
                lookupOpt name rest


lookupRes : String -> List ( String, Resolved ) -> Maybe Resolved
lookupRes name map =
    case map of
        [] ->
            Nothing

        ( k, v ) :: rest ->
            if k == name then
                Just v

            else
                lookupRes name rest


{-| Assign a fresh lift id to each group member name, in declaration order.
-}
assignNames : State -> List String -> ( NameMap, State )
assignNames state names =
    List.foldl
        (\n ( map, st ) ->
            ( ( n, liftNameSuffix st.nextId n ) :: map
            , { st | nextId = st.nextId + 1 }
            )
        )
        ( [], state )
        names


{-| `f$lift_<k>` names.  `$` is illegal in Elm identifiers, so a lifted name
can never collide with a user name or with `$case`/`$snap` (reserved-ish
lowerer names).
-}
liftNameSuffix : Int -> String -> String
liftNameSuffix k name =
    name ++ "$lift_" ++ String.fromInt k


{-| The snapshot name for a slot.  Keyed by `(name, position)` through the
slot itself, and made unique by the module-wide id, so two bindings of the
same source name never share a spelling.
-}
snapshotName : Int -> Slot -> String
snapshotName k slot =
    snapshotSource slot ++ "$snap" ++ String.fromInt k


snapshotSource : Slot -> String
snapshotSource slot =
    case slot of
        Enclosing n ->
            n

        Sibling n _ ->
            n



-- ======================= TOP-LEVEL WALK =======================


walkDecls : State -> List (Node Declaration) -> ( State, List (Node Declaration) )
walkDecls state decls =
    mapAccum walkDecl state decls


walkDecl : State -> Node Declaration -> ( State, Node Declaration )
walkDecl state (Node r decl) =
    case decl of
        FunctionDeclaration fn ->
            let
                impl =
                    Node.value fn.declaration

                pnames =
                    patternNamesList impl.arguments

                ( st2, newExpr ) =
                    walkExpr state pnames impl.expression

                newImpl =
                    { impl | expression = newExpr }

                newFn =
                    { fn | declaration = Node.map (\_ -> newImpl) fn.declaration }
            in
            ( st2, Node r (FunctionDeclaration newFn) )

        Destructuring pat e ->
            let
                ( st2, newE ) =
                    walkExpr state (patternNames pat) e
            in
            ( st2, Node r (Destructuring pat newE) )

        _ ->
            ( state, Node r decl )



-- ======================= EXPRESSION WALK =======================


{-| Rewrite an expression: lift every nested recursive let group, accumulating
their lifted declarations.  `bound` is the set of names bound by the ENCLOSING
lexical scope (function params, outer lets, lambdas, case patterns) -- exactly
the names a nested group may capture.
-}
walkExpr : State -> List String -> Node Expression -> ( State, Node Expression )
walkExpr state bound (Node r expr) =
    case expr of
        LetExpression lb ->
            walkLet state bound r lb

        LambdaExpression lam ->
            let
                ( st2, newBody ) =
                    walkExpr state (patternNamesList lam.args ++ bound) lam.expression
            in
            ( st2, Node r (LambdaExpression { lam | expression = newBody }) )

        Application nodes ->
            let
                ( st2, newNodes ) =
                    mapAccum (\st nd -> walkExpr st bound nd) state nodes
            in
            ( st2, Node r (Application newNodes) )

        OperatorApplication op dir l rt ->
            let
                ( s1, l2 ) =
                    walkExpr state bound l

                ( s2, rt2 ) =
                    walkExpr s1 bound rt
            in
            ( s2, Node r (OperatorApplication op dir l2 rt2) )

        Negation x ->
            let
                ( st2, x2 ) =
                    walkExpr state bound x
            in
            ( st2, Node r (Negation x2) )

        ParenthesizedExpression x ->
            let
                ( st2, x2 ) =
                    walkExpr state bound x
            in
            ( st2, Node r (ParenthesizedExpression x2) )

        IfBlock c t e ->
            let
                ( s1, c2 ) =
                    walkExpr state bound c

                ( s2, t2 ) =
                    walkExpr s1 bound t

                ( s3, e2 ) =
                    walkExpr s2 bound e
            in
            ( s3, Node r (IfBlock c2 t2 e2) )

        CaseExpression cb ->
            let
                ( s1, e2 ) =
                    walkExpr state bound cb.expression

                ( s2, cases2 ) =
                    mapAccum (walkCase bound) s1 cb.cases
            in
            ( s2, Node r (CaseExpression { cb | expression = e2, cases = cases2 }) )

        RecordExpr setters ->
            let
                ( st2, newSetters ) =
                    mapAccum (walkSetter bound) state setters
            in
            ( st2, Node r (RecordExpr newSetters) )

        ListExpr xs ->
            let
                ( st2, newXs ) =
                    mapAccum (\st nd -> walkExpr st bound nd) state xs
            in
            ( st2, Node r (ListExpr newXs) )

        TupledExpression xs ->
            let
                ( st2, newXs ) =
                    mapAccum (\st nd -> walkExpr st bound nd) state xs
            in
            ( st2, Node r (TupledExpression newXs) )

        RecordAccess rec name ->
            let
                ( st2, rec2 ) =
                    walkExpr state bound rec
            in
            ( st2, Node r (RecordAccess rec2 name) )

        RecordUpdateExpression name setters ->
            let
                ( st2, newSetters ) =
                    mapAccum (walkSetter bound) state setters
            in
            ( st2, Node r (RecordUpdateExpression name newSetters) )

        InsertionValue x ->
            let
                ( st2, x2 ) =
                    walkExpr state bound x
            in
            ( st2, Node r (InsertionValue x2) )

        _ ->
            ( state, Node r expr )


walkCase : List String -> State -> ( Node Pattern, Node Expression ) -> ( State, ( Node Pattern, Node Expression ) )
walkCase bound state ( pat, e ) =
    let
        ( st2, newE ) =
            walkExpr state (patternNames pat ++ bound) e
    in
    ( st2, ( pat, newE ) )


walkSetter : List String -> State -> Node RecordSetter -> ( State, Node RecordSetter )
walkSetter bound state (Node sr ( name, e )) =
    let
        ( st2, newE ) =
            walkExpr state bound e
    in
    ( st2, (Node sr ( name, newE )) )



-- ======================= LET WALK =======================


walkLet : State -> List String -> Range -> LetBlock -> ( State, Node Expression )
walkLet state bound r lb =
    let
        groupNames =
            List.filterMap letFnName lb.declarations

        ( st1, newDecls ) =
            mapAccum (walkLetDecl groupNames bound) state lb.declarations

        ( st2, newFinal ) =
            walkExpr st1 (groupNames ++ bound) lb.expression

        group =
            planGroup st2.outerNames groupNames bound newDecls
    in
    if List.isEmpty group.lifted then
        ( st2, Node r (LetExpression { declarations = newDecls, expression = newFinal }) )

    else
        liftRecursiveGroup st2 group r newFinal


{-| Walk one let declaration for nested lifts.  The whole group is mutually
visible (`groupNames`), so a nested group inside one member's body sees the
sibling members as enclosing locals and captures them correctly.
-}
walkLetDecl : List String -> List String -> State -> Node LetDeclaration -> ( State, Node LetDeclaration )
walkLetDecl groupNames bound state (Node dr decl) =
    case decl of
        LetFunction fn ->
            let
                impl =
                    Node.value fn.declaration

                pnames =
                    patternNamesList impl.arguments

                ( st2, newExpr ) =
                    walkExpr state (pnames ++ groupNames ++ bound) impl.expression

                newImpl =
                    { impl | expression = newExpr }

                newFn =
                    { fn | declaration = Node.map (\_ -> newImpl) fn.declaration }
            in
            ( st2, Node dr (LetFunction newFn) )

        LetDestructuring pat e ->
            let
                ( st2, newE ) =
                    walkExpr state (patternNames pat ++ groupNames ++ bound) e
            in
            ( st2, Node dr (LetDestructuring pat newE) )



-- ======================= GROUP PLAN (FIX 1 + the shadowing refinement) =======================


{-| A let block's candidate group plus the two decisions every later step must
agree with:

  * `shadowing` -- the members for which the ELM reading relaxes the forward
    veto (`forwardAllowed`).  It is the block's recursive CYCLE when every
    member of that cycle shadows an outer binding, and `[]` otherwise, so the
    census is taken over the set that is actually being lifted and cannot be
    flipped by a declaration that is not part of the recursion.
  * `lifted` -- the members ON A CYCLE of the reference graph (including a
    self-loop), in declaration order.  Only these are lifted.  A member that
    merely forward-references a later sibling is NOT on a cycle and must stay
    in place (the whole reason the corpus oracle holds -- its sequential lets
    are full of backward references, e.g. Lipgloss's `b1`/`b2`/`b3` chain).

Cycle detection and the rewrite BOTH resolve references through this record, so
a reference can never be classified one way to find the cycle and another way
when the rewrite runs.
-}
type alias Group =
    { outerNames : List String
    , groupNames : List String
    , bound : List String
    , decls : List (Node LetDeclaration)
    , permissive : List (String, List String)
    , lifted : List String
    }


planGroup : List String -> List String -> List String -> List (Node LetDeclaration) -> Group
planGroup outerNames groupNames bound decls =
    let
        -- The PERMISSIVE edge set: every forward reference into the block that
        -- the enclosing scope does not mask is an edge (the Elm reading).  It is
        -- the cycle structure the shadowing census and the forward veto are both
        -- keyed on, so the census can never feed back into the veto it decides.
        permissive =
            List.filterMap (memberEdge (\_ _ -> True) groupNames bound decls) (indexed decls)
    in
    { outerNames = outerNames
    , groupNames = groupNames
    , bound = bound
    , decls = decls
    , permissive = permissive
    , lifted = List.filter (\n -> onCycle n (buildEdges outerNames permissive groupNames bound decls)) groupNames
    }


{-| Does a reference from `referrer` to a LATER sibling `target` denote the
local sibling (True) or the outward binding (False)?

  * `target` is not in `outerNames`: the substrate cannot resolve it outward at
    all, so the local sibling is the only meaning that exists -- the pass's
    charter case (a program HEAD rejects).  Always local.
  * otherwise the substrate resolves it OUTWARD (the declared divergence), with
    one exception: the Elm-shadowing relaxation, which applies PER (referrer,
    target) PAIR over the permissive edges -- iff (1) the target is on the
    REFERRER's OWN strongly-connected set (mutually reachable, i.e. the two are
    in the same recursive cycle) AND (2) every name in that SCC shadows an outer
    binding.  A forward reference to a NON-cycle sibling (m not on even's cycle,
    n33/liftrelaxleak) and a reference from a non-cycle referrer
    (w5/liftstayfwd) both keep the substrate's outward resolution; an unrelated
    disjoint cycle cannot flip the census for this one (n25/liftdisjointshadow).
-}
forwardAllowed : List String -> List (String, List String) -> List String -> String -> String -> Bool
forwardAllowed outerNames permissive groupNames referrer target =
    not (List.member target outerNames)
        || (canReach referrer target permissive []
                && canReach target referrer permissive []
                && List.all (\n -> List.member n outerNames) (sccMembers referrer permissive groupNames))


buildEdges : List String -> List (String, List String) -> List String -> List String -> List (Node LetDeclaration) -> List (String, List String)
buildEdges outerNames permissive groupNames bound decls =
    List.filterMap
        (memberEdge (\referrer target -> forwardAllowed outerNames permissive groupNames referrer target) groupNames bound decls)
        (indexed decls)


{-| One member's outgoing edges, keyed by DECLARATION ORDER (FIX 1).
-}
memberEdge : (String -> String -> Bool) -> List String -> List String -> List (Node LetDeclaration) -> ( Int, Node LetDeclaration ) -> Maybe (String, List String)
memberEdge forwardAllowedFn groupNames bound decls ( i, nd ) =
    case nd of
        Node _ (LetFunction fn) ->
            let
                impl =
                    Node.value fn.declaration

                selfName =
                    nodeString impl.name

                frees =
                    exprFreeVars (patternNamesList impl.arguments) impl.expression
            in
            Just
                ( selfName
                , List.filter
                    (\g ->
                        List.member g frees
                            && not (List.member g bound)
                            && edgeAllowed forwardAllowedFn decls i selfName g
                    )
                    groupNames
                )

        _ ->
            Nothing


edgeAllowed : (String -> String -> Bool) -> List (Node LetDeclaration) -> Int -> String -> String -> Bool
edgeAllowed forwardAllowedFn decls i referrer g =
    case bindingIndexOf g decls of
        Just j ->
            j <= i || forwardAllowedFn referrer g

        Nothing ->
            False



{-| Is `name` reachable from itself via the edge relation (>= 1 edge)?
-}
onCycle : String -> List (String, List String) -> Bool
onCycle name edges =
    canReach name name edges []


canReach : String -> String -> List (String, List String) -> List String -> Bool
canReach node target edges visited =
    if List.member node visited then
        False

    else
        List.any (\n -> n == target || canReach n target edges (node :: visited)) (lookupRefs node edges)


lookupRefs : String -> List (String, List String) -> List String
lookupRefs name edges =
    case edges of
        [] ->
            []

        ( n, refs ) :: rest ->
            if n == name then
                refs

            else
                lookupRefs name rest


{-| The referrer's strongly-connected set in the permissive edge graph: every
name mutually reachable with `referrer` (its recursive cycle).  Empty when the
referrer is not on a cycle, so the conjunction in `forwardAllowed` is never
vacuously relaxed for a non-cycle referrer.
-}
sccMembers : String -> List (String, List String) -> List String -> List String
sccMembers referrer permissive groupNames =
    List.filter
        (\n -> canReach referrer n permissive [] && canReach n referrer permissive [])
        groupNames



-- ======================= SLOT ANALYSIS (FIX 3) =======================


{-| Per LIFTED member: the resolution of each of its free names, keyed by the
BINDING that name denotes at that member's declaration position.
-}
analyzeGroup : Group -> List ( Int, List ( String, Resolved ) )
analyzeGroup group =
    List.filterMap (memberResolutions group) (indexed group.decls)


memberResolutions : Group -> ( Int, Node LetDeclaration ) -> Maybe ( Int, List ( String, Resolved ) )
memberResolutions group ( i, nd ) =
    case nd of
        Node _ (LetFunction fn) ->
            let
                impl =
                    Node.value fn.declaration

                selfName =
                    nodeString impl.name

                frees =
                    dedupe (exprFreeVars (patternNamesList impl.arguments) impl.expression)
            in
            if List.member selfName group.lifted then
                Just ( i, List.map (\n -> ( n, resolveName group i selfName n )) frees )

            else
                Nothing

        _ ->
            Nothing


{-| Resolve one free name of the member declared at index `i`, positionally.

  * SELF (`n == selfName`): the substrate does not bind the member at its own
    declaration, so the name resolves outward -- EXCEPT that the whole charter
    is to make it recursive; the retained enclosing mask (`liftenclosing`)
    applies when the name is in the enclosing scope.
  * BACKWARD (`j < i`): declaration `j` is already visible, so that binding
    shadows anything outer.  (NOTE: the EDGE rule drops a backward edge when
    the name is also in `bound`; that only costs a missed lift -- it is loud,
    never a wrong value -- and the resolution here follows the substrate.)
  * FORWARD (`j > i`): the name is not yet bound, so it resolves outward;
    `forwardAllowed` decides whether the local sibling shadows instead.

This is the SELF-aware form used for a lifted member's body.  A STAYING
declaration (and the block's final expression) calls `resolvePositional`
directly -- the SAME procedure, so the two cannot disagree (the w5 chimera was
exactly that disagreement: position-aware in a member body, position-blind in a
staying declaration).
-}
resolveName : Group -> Int -> String -> String -> Resolved
resolveName group i selfName n =
    if n == selfName then
        if List.member n group.bound then
            Snapshot (Enclosing n)

        else
            Call n

    else
        resolvePositional group i selfName n


resolvePositional : Group -> Int -> String -> String -> Resolved
resolvePositional group i referrer n =
    case bindingIndexOf n group.decls of
        Just j ->
            if j < i then
                if List.member n group.lifted then
                    Call n

                else
                    Snapshot (Sibling n j)

            else if j > i then
                if List.member n group.bound then
                    Snapshot (Enclosing n)

                else if not (forwardAllowed group.outerNames group.permissive group.groupNames referrer n) then
                    Keep

                else if List.member n group.lifted then
                    Call n

                else if bindsFunction group.decls j then
                    Snapshot (Sibling n j)

                else
                    Keep

            else
                Keep

        Nothing ->
            if List.member n group.bound then
                Snapshot (Enclosing n)

            else
                Keep


{-| The distinct slots a group needs, in CANONICAL order: enclosing slots
first, then sibling slots by declaration index -- the order used for both the
snapshot declarations and every call site's argument list.
-}
collectSlots : List ( Int, List ( String, Resolved ) ) -> List Slot
collectSlots analyses =
    let
        slots =
            List.concatMap
                (\( _, res ) -> List.filterMap (\( _, r ) -> slotOf r) res)
                analyses
    in
    List.map Enclosing (dedupe (List.filterMap enclosingName slots))
        ++ List.concatMap
            (\j -> List.map (\n -> Sibling n j) (dedupe (List.filterMap (siblingName j) slots)))
            (sortInts (dedupeInts (List.filterMap siblingIndex slots)))


enclosingName : Slot -> Maybe String
enclosingName slot =
    case slot of
        Enclosing n ->
            Just n

        Sibling _ _ ->
            Nothing


siblingIndex : Slot -> Maybe Int
siblingIndex slot =
    case slot of
        Sibling _ j ->
            Just j

        Enclosing _ ->
            Nothing


siblingName : Int -> Slot -> Maybe String
siblingName j slot =
    case slot of
        Sibling n k ->
            if k == j then
                Just n

            else
                Nothing

        Enclosing _ ->
            Nothing


slotOf : Resolved -> Maybe Slot
slotOf r =
    case r of
        Snapshot s ->
            Just s

        _ ->
            Nothing


sortInts : List Int -> List Int
sortInts xs =
    List.foldl insertInt [] xs


insertInt : Int -> List Int -> List Int
insertInt x acc =
    case acc of
        [] ->
            [ x ]

        y :: rest ->
            if x < y then
                x :: acc

            else
                y :: insertInt x rest


dedupeInts : List Int -> List Int
dedupeInts xs =
    List.foldl (\x acc -> if List.member x acc then acc else acc ++ [ x ]) [] xs


{-| Assign a fresh, module-unique snapshot id to each slot, in canonical order.
-}
assignSlots : State -> List Slot -> ( List ( Slot, String ), State )
assignSlots state slots =
    List.foldl
        (\slot ( acc, st ) ->
            ( ( slot, snapshotName st.nextId slot ) :: acc, { st | nextId = st.nextId + 1 } )
        )
        ( [], state )
        slots
        |> (\( pairs, st ) -> ( List.reverse pairs, st ))


snapNameOf : Slot -> List ( Slot, String ) -> String
snapNameOf slot pairs =
    case pairs of
        [] ->
            snapshotSource slot

        ( s, n ) :: rest ->
            if slotEq s slot then
                n

            else
                snapNameOf slot rest


slotEq : Slot -> Slot -> Bool
slotEq a b =
    case ( a, b ) of
        ( Enclosing x, Enclosing y ) ->
            x == y

        ( Sibling x i, Sibling y j ) ->
            x == y && i == j

        _ ->
            False



-- ======================= LIFT =======================


{-| Lift the members on a cycle (`group.lifted`).  Refuses (leaving the block
untouched, so the checker rejects loudly) when the cycle runs through a VALUE
member (FIX 2) or when a staying declaration would have to spell a snapshot
declared at/after itself (R2).
-}
liftRecursiveGroup : State -> Group -> Range -> Node Expression -> ( State, Node Expression )
liftRecursiveGroup state group r finalExpr =
    let
        decls =
            group.decls

        unchanged =
            Node r (LetExpression { declarations = decls, expression = finalExpr })
    in
    if List.any (\n -> isValueMember n decls) group.lifted then
        -- FIX 2: a cycle through a 0-arg (VALUE) member is a cyclic definition.
        ( state, unchanged )

    else
        let
            analyses =
                analyzeGroup group

            slotAssignment =
                assignSlots state (collectSlots analyses)

            slotPairs =
                Tuple.first slotAssignment

            ( liftNames, st2 ) =
                assignNames (Tuple.second slotAssignment) group.lifted

            snaps =
                List.map Tuple.second slotPairs

            lastSiblingIndex =
                highestSibling slotPairs
        in
        if refuseOrdering group lastSiblingIndex then
            ( st2, unchanged )

        else
            let
                newDecls =
                    topSnapshots r slotPairs
                        ++ List.concatMap
                            (\( i, nd ) ->
                                if isLiftedMember group.lifted nd then
                                    []

                                else
                                    [ rewriteDeclRefs group i liftNames snaps nd ]
                                        ++ snapshotsAfter r i slotPairs
                            )
                            (indexed decls)

                newFinal =
                    -- The final expression follows every declaration, so every
                    -- block binding is backward for it; the empty referrer is
                    -- therefore never consulted (only the forward branch of
                    -- `resolvePositional` asks for it).
                    rewriteAt group (List.length decls) "" liftNames snaps [] finalExpr

                lifted =
                    List.filterMap (buildLifted group liftNames snaps slotPairs) analyses

                st3 =
                    { st2 | lifted = st2.lifted ++ lifted }
            in
            if List.isEmpty newDecls then
                -- Every declaration was lifted: the block was pure scaffolding.
                ( st3, newFinal )

            else
                ( st3, Node r (LetExpression { declarations = newDecls, expression = newFinal }) )


{-| The highest declaration index carrying a sibling snapshot (-1 if none).
-}
highestSibling : List ( Slot, String ) -> Int
highestSibling pairs =
    List.foldl
        (\( slot, _ ) acc ->
            case slot of
                Sibling _ j ->
                    if j > acc then
                        j

                    else
                        acc

                Enclosing _ ->
                    acc
        )
        -1
        pairs


{-| R2: a staying declaration that references a lifted member spells EVERY
snapshot, and snapshots become visible only after their own declaration, so a
sibling snapshot at index `j` requires `j < i` for every referencing staying
declaration `i`.  Refuse the whole group otherwise (loud, HEAD-consistent).
-}
refuseOrdering : Group -> Int -> Bool
refuseOrdering group lastSiblingIndex =
    List.any
        (\( i, nd ) ->
            not (isLiftedMember group.lifted nd)
                && i <= lastSiblingIndex
                && declSpellsLifted group i nd
        )
        (indexed group.decls)


{-| Does this declaration's rewritten body actually SPELL a snapshot, i.e. does
it contain a reference that resolves to a LIFTED MEMBER at its own position?
Computed with the SAME positional resolver the rewrite uses, so a forward
reference the veto keeps outward (w5's `g v = helper v`) cannot trigger an
ordering refusal it does not need.
-}
declSpellsLifted : Group -> Int -> Node LetDeclaration -> Bool
declSpellsLifted group i (Node _ decl) =
    case decl of
        LetFunction fn ->
            let
                impl =
                    Node.value fn.declaration

                selfName =
                    nodeString impl.name
            in
            List.any
                (\n -> isCallAt group i selfName n)
                (exprFreeVars (patternNamesList impl.arguments) impl.expression)

        LetDestructuring _ e ->
            List.any (\n -> isCallAt group i "" n) (exprFreeVars [] e)


isCallAt : Group -> Int -> String -> String -> Bool
isCallAt group i referrer n =
    case resolvePositional group i referrer n of
        Call _ ->
            True

        _ ->
            False


{-| The enclosing slots' snapshots: emitted at the TOP of the block, where the
enclosing binding is observable (before any sibling can shadow it).
-}
topSnapshots : Range -> List ( Slot, String ) -> List (Node LetDeclaration)
topSnapshots r pairs =
    List.filterMap
        (\( slot, snap ) ->
            case slot of
                Enclosing _ ->
                    Just (snapshotDecl r (snapshotSource slot) snap)

                Sibling _ _ ->
                    Nothing
        )
        pairs


{-| The sibling snapshots for declaration `i`: emitted IMMEDIATELY AFTER it,
where that sibling's binding becomes observable.
-}
snapshotsAfter : Range -> Int -> List ( Slot, String ) -> List (Node LetDeclaration)
snapshotsAfter r i pairs =
    List.filterMap
        (\( slot, snap ) ->
            case slot of
                Sibling _ j ->
                    if j == i then
                        Just (snapshotDecl r (snapshotSource slot) snap)

                    else
                        Nothing

                Enclosing _ ->
                    Nothing
        )
        pairs


{-| A snapshot: a 0-arg binding of the source name under a unique spelling
(`Lower.Expr.lowerLetFunction` lowers a 0-arg LetFunction as a VALUE binding).
-}
snapshotDecl : Range -> String -> String -> Node LetDeclaration
snapshotDecl r sourceName snap =
    Node r
        (LetFunction
            { documentation = Nothing
            , signature = Nothing
            , declaration =
                Node r
                    { name = Node r snap
                    , arguments = []
                    , expression = Node r (FunctionOrValue [] sourceName)
                    }
            }
        )


{-| Rewrite a STAYING declaration.  A reference changes ONLY when it resolves
to a LIFTED MEMBER at this declaration's own position -- the same
`resolvePositional` call a member body would get there; everything else (a
capture, a plain sibling, a reference the forward veto keeps OUTWARD) keeps its
source name and therefore its original resolution, because the declaration
keeps its position.  A LetDestructuring has no referrer name of its own, so its
RHS is resolved as a non-shadowing referrer (the sequential reading).
-}
rewriteDeclRefs : Group -> Int -> NameMap -> List String -> Node LetDeclaration -> Node LetDeclaration
rewriteDeclRefs group i refLift snaps (Node dr decl) =
    case decl of
        LetFunction fn ->
            let
                impl =
                    Node.value fn.declaration

                newExpr =
                    rewriteAt group i (nodeString impl.name) refLift snaps (patternNamesList impl.arguments) impl.expression

                newImpl =
                    { impl | expression = newExpr }
            in
            Node dr (LetFunction { fn | declaration = Node.map (\_ -> newImpl) fn.declaration })

        LetDestructuring pat e ->
            Node dr (LetDestructuring pat (rewriteAt group i "" refLift snaps [] e))


{-| The position-aware reference rewrite: a free name of the expression at
declaration index `i` (inside `ownBound` binders) becomes `g$lift_j <snaps>`
exactly when `resolvePositional` says it denotes a lifted member there.
-}
rewriteAt : Group -> Int -> String -> NameMap -> List String -> List String -> Node Expression -> Node Expression
rewriteAt group i referrer refLift snaps ownBound node =
    rewriteGeneric
        (\_ r name ->
            case resolvePositional group i referrer name of
                Call target ->
                    memberRef r (lookupName target refLift) snaps

                _ ->
                    Node r (FunctionOrValue [] name)
        )
        ownBound
        node


{-| The lifted top-level declaration: parameters `[snapshots...] ++ [own
params...]` and the body rewritten through the member's OWN positional
resolution map.
-}
buildLifted : Group -> NameMap -> List String -> List ( Slot, String ) -> ( Int, List ( String, Resolved ) ) -> Maybe (Node Declaration)
buildLifted group liftNames snaps slotPairs ( i, resMap ) =
    case findDeclAt i group.decls of
        Just (Node dr (LetFunction fn)) ->
            let
                impl =
                    Node.value fn.declaration

                name =
                    nodeString impl.name

                newArgs =
                    List.map (\s -> Node dr (VarPattern s)) snaps ++ impl.arguments

                newBody =
                    rewriteMemberBody liftNames resMap slotPairs snaps (patternNamesList impl.arguments) impl.expression

                newImpl =
                    { name = Node (Node.range impl.name) (lookupName name liftNames)
                    , arguments = newArgs
                    , expression = newBody
                    }

                newFn =
                    { documentation = Nothing
                    , signature = Nothing
                    , declaration = Node dr newImpl
                    }
            in
            Just (Node dr (FunctionDeclaration newFn))

        _ ->
            Nothing



-- ======================= BINDER-AWARE REWRITE =======================


{-| Rewrite a lifted member's body through its positional resolution map.
`ownParams` seeds the bound set; inner binders extend it as we descend, so a
shadowed name is never rewritten.
-}
rewriteMemberBody : NameMap -> List ( String, Resolved ) -> List ( Slot, String ) -> List String -> List String -> Node Expression -> Node Expression
rewriteMemberBody refLift resMap slotPairs snaps ownParams body =
    rewriteGeneric
        (\_ r name ->
            case lookupRes name resMap of
                Just (Call target) ->
                    memberRef r (lookupName target refLift) snaps

                Just (Snapshot slot) ->
                    Node r (FunctionOrValue [] (snapNameOf slot slotPairs))

                _ ->
                    Node r (FunctionOrValue [] name)
        )
        ownParams
        body


{-| The generic binder-aware descent: the hook is consulted for every FREE
bare name, and binders (lambda args, case patterns, sequential nested-let
declarations) extend the bound set exactly as `inferLet` does.
-}
rewriteGeneric : (List String -> Range -> String -> Node Expression) -> List String -> Node Expression -> Node Expression
rewriteGeneric hook bound (Node r expr) =
    case expr of
        FunctionOrValue modName name ->
            if List.isEmpty modName && not (List.member name bound) then
                hook bound r name

            else
                Node r expr

        Application nodes ->
            Node r (Application (List.map (rewriteGeneric hook bound) nodes))

        OperatorApplication op dir l rt ->
            Node r
                (OperatorApplication op dir
                    (rewriteGeneric hook bound l)
                    (rewriteGeneric hook bound rt)
                )

        Negation x ->
            Node r (Negation (rewriteGeneric hook bound x))

        ParenthesizedExpression x ->
            Node r (ParenthesizedExpression (rewriteGeneric hook bound x))

        IfBlock c t e ->
            Node r
                (IfBlock
                    (rewriteGeneric hook bound c)
                    (rewriteGeneric hook bound t)
                    (rewriteGeneric hook bound e)
                )

        LambdaExpression lam ->
            Node r
                (LambdaExpression
                    { lam
                        | expression =
                            rewriteGeneric hook (patternNamesList lam.args ++ bound) lam.expression
                    }
                )

        LetExpression lb ->
            Node r (LetExpression (rewriteGenericLet hook bound lb))

        CaseExpression cb ->
            Node r
                (CaseExpression
                    { cb
                        | expression = rewriteGeneric hook bound cb.expression
                        , cases =
                            List.map
                                (\( pat, e ) ->
                                    ( pat, rewriteGeneric hook (patternNames pat ++ bound) e )
                                )
                                cb.cases
                    }
                )

        RecordExpr setters ->
            Node r (RecordExpr (List.map (rewriteGenericSetter hook bound) setters))

        ListExpr xs ->
            Node r (ListExpr (List.map (rewriteGeneric hook bound) xs))

        TupledExpression xs ->
            Node r (TupledExpression (List.map (rewriteGeneric hook bound) xs))

        RecordAccess rec name ->
            Node r (RecordAccess (rewriteGeneric hook bound rec) name)

        RecordUpdateExpression name setters ->
            Node r (RecordUpdateExpression name (List.map (rewriteGenericSetter hook bound) setters))

        InsertionValue x ->
            Node r (InsertionValue (rewriteGeneric hook bound x))

        _ ->
            Node r expr


rewriteGenericSetter : (List String -> Range -> String -> Node Expression) -> List String -> Node RecordSetter -> Node RecordSetter
rewriteGenericSetter hook bound (Node sr ( name, e )) =
    Node sr ( name, rewriteGeneric hook bound e )


{-| Rewrite a nested (already-walked, hence non-recursive) let.  Binder names
are threaded SEQUENTIALLY -- exactly as `inferLet` accumulates decls
(Infer.elm:1173) -- so a later sibling sees the names bound by earlier siblings
(function names AND destructuring pattern names), and the final expression sees
them all.  A destructuring RHS sees only the OUTER scope (the pattern binds
AFTER the RHS).
-}
rewriteGenericLet : (List String -> Range -> String -> Node Expression) -> List String -> LetBlock -> LetBlock
rewriteGenericLet hook bound lb =
    let
        ( finalBound, newDecls ) =
            rewriteGenericDecls hook bound lb.declarations

        newFinal =
            rewriteGeneric hook finalBound lb.expression
    in
    { declarations = newDecls, expression = newFinal }


rewriteGenericDecls : (List String -> Range -> String -> Node Expression) -> List String -> List (Node LetDeclaration) -> ( List String, List (Node LetDeclaration) )
rewriteGenericDecls hook bound decls =
    case decls of
        [] ->
            ( bound, [] )

        Node dr decl :: rest ->
            case decl of
                LetFunction fn ->
                    let
                        impl =
                            Node.value fn.declaration

                        name =
                            nodeString impl.name

                        newExpr =
                            rewriteGeneric hook (patternNamesList impl.arguments ++ bound) impl.expression

                        newImpl =
                            { impl | expression = newExpr }

                        newFn =
                            { fn | declaration = Node.map (\_ -> newImpl) fn.declaration }

                        ( b, rest2 ) =
                            rewriteGenericDecls hook (name :: bound) rest
                    in
                    ( b, Node dr (LetFunction newFn) :: rest2 )

                LetDestructuring pat e ->
                    let
                        newE =
                            rewriteGeneric hook bound e

                        ( b, rest2 ) =
                            rewriteGenericDecls hook (patternNames pat ++ bound) rest
                    in
                    ( b, Node dr (LetDestructuring pat newE) :: rest2 )



-- ======================= FREE-VARIABLE COMPUTATION =======================


{-| The free bare names of an expression w.r.t. a bound set (binder-aware:
inner lets/lambdas/case patterns extend the bound set as we descend).
Qualified references and non-name expressions contribute nothing.
-}
exprFreeVars : List String -> Node Expression -> List String
exprFreeVars bound (Node _ expr) =
    case expr of
        FunctionOrValue modName name ->
            if List.isEmpty modName && not (List.member name bound) then
                [ name ]

            else
                []

        Application nodes ->
            List.concatMap (exprFreeVars bound) nodes

        OperatorApplication _ _ l rt ->
            exprFreeVars bound l ++ exprFreeVars bound rt

        Negation x ->
            exprFreeVars bound x

        ParenthesizedExpression x ->
            exprFreeVars bound x

        IfBlock c t e ->
            exprFreeVars bound c ++ exprFreeVars bound t ++ exprFreeVars bound e

        LambdaExpression lam ->
            exprFreeVars (patternNamesList lam.args ++ bound) lam.expression

        LetExpression lb ->
            letFreeVars bound lb

        CaseExpression cb ->
            exprFreeVars bound cb.expression
                ++ List.concatMap (\( pat, e ) -> exprFreeVars (patternNames pat ++ bound) e) cb.cases

        RecordExpr setters ->
            List.concatMap (\(Node _ ( _, v )) -> exprFreeVars bound v) setters

        ListExpr xs ->
            List.concatMap (exprFreeVars bound) xs

        TupledExpression xs ->
            List.concatMap (exprFreeVars bound) xs

        RecordAccess rec _ ->
            exprFreeVars bound rec

        RecordUpdateExpression _ setters ->
            List.concatMap (\(Node _ ( _, v )) -> exprFreeVars bound v) setters

        InsertionValue x ->
            exprFreeVars bound x

        _ ->
            []


letFreeVars : List String -> LetBlock -> List String
letFreeVars bound lb =
    let
        ( finalBound, declFrees ) =
            letDeclFreeVarsList bound lb.declarations

        finalFrees =
            exprFreeVars finalBound lb.expression
    in
    declFrees ++ finalFrees


{-| SEQUENTIAL binder accumulation for the free-variable computation: a nested
decl's body sees only the OUTER scope plus EARLIER siblings (mirroring
`inferLet` and the rewrite side's `rewriteGenericDecls`), so a capture
referenced BEFORE a same-named nested value sibling is not masked out of the
capture set.
-}
letDeclFreeVarsList : List String -> List (Node LetDeclaration) -> ( List String, List String )
letDeclFreeVarsList bound decls =
    case decls of
        [] ->
            ( bound, [] )

        Node _ decl :: rest ->
            case decl of
                LetFunction fn ->
                    let
                        impl =
                            Node.value fn.declaration

                        name =
                            nodeString impl.name

                        frees =
                            exprFreeVars (patternNamesList impl.arguments ++ bound) impl.expression

                        ( b, restFrees ) =
                            letDeclFreeVarsList (name :: bound) rest
                    in
                    ( b, frees ++ restFrees )

                LetDestructuring pat e ->
                    let
                        names =
                            patternNames pat

                        frees =
                            exprFreeVars bound e

                        ( b, restFrees ) =
                            letDeclFreeVarsList (names ++ bound) rest
                    in
                    ( b, frees ++ restFrees )



-- ======================= HELPERS =======================


{-| Build the reference to a lifted name applied to its snapshots.  A group
with NO snapshots must be a bare name, not a 1-element `Application` --
`Lower.Expr.application` emits an `Apply` for any Application, so a 0-argument
application of an N-arg closure would apply it to zero args at runtime
("appterm non-lambda").
-}
memberRef : Range -> String -> List String -> Node Expression
memberRef r liftName snaps =
    case List.map (\c -> Node r (FunctionOrValue [] c)) snaps of
        [] ->
            Node r (FunctionOrValue [] liftName)

        capRefs ->
            Node r (Application (Node r (FunctionOrValue [] liftName) :: capRefs))


letFnName : Node LetDeclaration -> Maybe String
letFnName (Node _ decl) =
    case decl of
        LetFunction fn ->
            Just (nodeString (Node.value fn.declaration).name)

        LetDestructuring _ _ ->
            Nothing


{-| The names a declaration binds (a function's own name, or a destructuring
pattern's names).
-}
declBindings : LetDeclaration -> List String
declBindings decl =
    case decl of
        LetFunction fn ->
            [ nodeString (Node.value fn.declaration).name ]

        LetDestructuring pat _ ->
            patternNames pat


{-| The index of the declaration that binds `name` (first match; duplicate
names are rejected by the checker).
-}
bindingIndexOf : String -> List (Node LetDeclaration) -> Maybe Int
bindingIndexOf name decls =
    bindingIndexOfHelp name 0 decls


bindingIndexOfHelp : String -> Int -> List (Node LetDeclaration) -> Maybe Int
bindingIndexOfHelp name i decls =
    case decls of
        [] ->
            Nothing

        (Node _ decl) :: rest ->
            if List.member name (declBindings decl) then
                Just i

            else
                bindingIndexOfHelp name (i + 1) rest


bindsFunction : List (Node LetDeclaration) -> Int -> Bool
bindsFunction decls i =
    case findDeclAt i decls of
        Just (Node _ (LetFunction _)) ->
            True

        _ ->
            False


findDeclAt : Int -> List (Node LetDeclaration) -> Maybe (Node LetDeclaration)
findDeclAt i decls =
    case decls of
        [] ->
            Nothing

        x :: rest ->
            if i == 0 then
                Just x

            else
                findDeclAt (i - 1) rest


isLiftedMember : List String -> Node LetDeclaration -> Bool
isLiftedMember liftedNames (Node _ decl) =
    case decl of
        LetFunction fn ->
            List.member (nodeString (Node.value fn.declaration).name) liftedNames

        LetDestructuring _ _ ->
            False


isValueMember : String -> List (Node LetDeclaration) -> Bool
isValueMember name decls =
    List.any
        (\(Node _ decl) ->
            case decl of
                LetFunction fn ->
                    let
                        impl =
                            Node.value fn.declaration
                    in
                    nodeString impl.name == name && List.isEmpty impl.arguments

                LetDestructuring _ _ ->
                    False
        )
        decls


indexed : List a -> List ( Int, a )
indexed xs =
    indexedHelp 0 xs


indexedHelp : Int -> List a -> List ( Int, a )
indexedHelp i xs =
    case xs of
        [] ->
            []

        x :: rest ->
            ( i, x ) :: indexedHelp (i + 1) rest


nodeString : Node String -> String
nodeString (Node _ s) =
    s


patternNamesList : List (Node Pattern) -> List String
patternNamesList pats =
    List.concatMap patternNames pats


patternNames : Node Pattern -> List String
patternNames (Node _ pat) =
    case pat of
        VarPattern name ->
            [ name ]

        TuplePattern ps ->
            List.concatMap patternNames ps

        RecordPattern names ->
            List.map nodeString names

        UnConsPattern l r ->
            patternNames l ++ patternNames r

        ListPattern ps ->
            List.concatMap patternNames ps

        NamedPattern _ subs ->
            List.concatMap patternNames subs

        AsPattern inner name ->
            patternNames inner ++ [ nodeString name ]

        ParenthesizedPattern inner ->
            patternNames inner

        _ ->
            []


dedupe : List String -> List String
dedupe list =
    dedupeHelp list []


dedupeHelp : List String -> List String -> List String
dedupeHelp remaining acc =
    case remaining of
        [] ->
            List.reverse acc

        x :: rest ->
            if List.member x acc then
                dedupeHelp rest acc

            else
                dedupeHelp rest (x :: acc)


mapAccum : (State -> a -> ( State, b )) -> State -> List a -> ( State, List b )
mapAccum f state xs =
    case xs of
        [] ->
            ( state, [] )

        x :: rest ->
            let
                ( s1, y ) =
                    f state x

                ( s2, ys ) =
                    mapAccum f s1 rest
            in
            ( s2, y :: ys )
