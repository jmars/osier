module Mid.DeadGlobals exposing (Stats, run)

-- Mid.DeadGlobals — the middle tier's FIFTH pass: whole-program reachability
-- plus duplicate-defun elimination.
--
-- FRESH CODE, no MLton source.  The plan's spec is "fresh reachability; roots
-- = the entry + prim wrappers + hostcall/value-table names", but the ROOT SET
-- below is what is actually SOUND for this driver, and the module header is
-- the place the reasoning lives.
--
-- ============================ WHAT IS REMOVED ============================
--
-- The bundle carries three kinds of defun (Mid.Module.compileUnit, in order):
-- user functions (`Mod.fn`), constructor defuns (`Mod.Ctor`, a `Lam` whose
-- body is a bare `Con`), and the CURRIED PRIM WRAPPERS (`.curried` keys).  The
-- wrappers are emitted by EVERY unit — the corpus (10 modules) plus the group
-- each contribute the same ~46 wrappers, so a bundle carries ~500 wrapper
-- ENTRIES of which only 46 are DISTINCT: the VM's `defunSet` already collapses
-- them by name (later-store-wins, byte-identical bodies).  Those duplicates
-- are the first, and largest, thing removed here.
--
-- ============================ THE ROOT SET ============================
--
-- The entry function is chosen AT RUN TIME — `elmvm <bundle> <name> <args>`
-- resolves `<name>` by name through the defun table (tools/elmvm.zig builds a
-- `g <name> p` snippet), and the gate drives a DIFFERENT user function per
-- fixture (`Fib.fib`, `Sub.sub`, …) while the selfhost drives
-- `NativeMain.main`.  The compiler therefore cannot know the entry, and the
-- only SOUND root set is "every user function" — any `Mod.fn` could be the
-- entry the next run names.  (Rooting only `NativeMain.main` would delete
-- every gate fixture's entry and empty the gate bundles.)
--
-- Concretely the roots are: every defun whose key does NOT end in `.curried`.
-- That is exactly "user functions + constructor defuns".  The wrappers are the
-- ONLY defuns that cannot be a CLI entry (no gate names a `.curried` global,
-- and the VM's by-name lookups — the Shen eval-kl chain — never appear in an
-- Elm bundle), so a wrapper is kept IFF a root references it via `GRef` (an
-- operator used as a value).  Constructor defuns are kept even when
-- unreferenced: after Mid.Inline has substituted a ctor call's body into a
-- caller, a user function's body can BE a bare `Con`, so "body is a Con" is no
-- longer a reliable ctor marker — the name is the only stable signal, and it
-- cannot separate `Mod.Ctor` from `Mod.fn`.  Keeping all of them is the
-- conservative, sound choice; the unreferenced-ctor population is small (the
-- corpus constructs almost everything it declares).
--
-- WHAT IS NOT REMOVED (and why, honestly): user functions that are dead in a
-- SPECIFIC entry's view (e.g. an unused helper in the selfhost's 58 sources).
-- Rooting them is the price of not knowing the entry; a future refinement can
-- pass the entry-name list in and turn this into a smaller root set.
--
-- CORRECTION TO THE S5 COMMIT MESSAGE (recorded, history NOT rewritten): the
-- message attributes the -10.7% to "the plan's compounding — Inline duplicates
-- bodies and DeadGlobals then removes the defuns whose calls were all inlined".
-- MEASURED, that is wrong: the bulk of the -182,224 instructions is the WRAPPER
-- DEDUP above (460 duplicate wrapper entries removed IDENTICALLY with and
-- without Inline); Inline's real compounding is 15 EXTRA wrapper removals
-- (removed=29 with Inline vs 14 without, because inlining a full-arity wrapper
-- call turns it into a direct PrimApp and drops the last GRef).  DeadGlobals
-- CANNOT remove inlined USER defuns — they are all roots.  The honest split is
-- wrapper-dedup (Inline-independent) plus 15 Inline-dependent wrapper drops.

import Dict exposing (Dict)
import Mid.Ir exposing (Alt, Defun, Exp(..), LetBinder(..))
import Set exposing (Set)


type alias Stats =
    { defuns : Int
    , distinct : Int
    , duplicates : Int
    , roots : Int
    , reachable : Int
    , removed : Int
    }


zero : Stats
zero =
    { defuns = 0
    , distinct = 0
    , duplicates = 0
    , roots = 0
    , reachable = 0
    , removed = 0
    }


run : List Defun -> ( List Defun, String )
run defuns =
    let
        deduped =
            dedup defuns

        roots =
            deduped
                |> List.filter (not << isWrapper)
                |> List.map .key
                |> Set.fromList

        graph =
            List.foldl (\d acc -> Dict.insert d.key (grefsOf d.value) acc) Dict.empty deduped

        reachable =
            fixpoint roots graph

        kept =
            List.filter (\d -> Set.member d.key reachable) deduped
    in
    ( kept
    , report
        { defuns = List.length defuns
        , distinct = List.length deduped
        , duplicates = List.length defuns - List.length deduped
        , roots = Set.size roots
        , reachable = Set.size reachable
        , removed = List.length deduped - List.length kept
        }
    )


report : Stats -> String
report s =
    if s.duplicates == 0 && s.removed == 0 then
        ""

    else
        "deadglobals: defuns="
            ++ String.fromInt s.defuns
            ++ " distinct="
            ++ String.fromInt s.distinct
            ++ " dups="
            ++ String.fromInt s.duplicates
            ++ " roots="
            ++ String.fromInt s.roots
            ++ " reachable="
            ++ String.fromInt s.reachable
            ++ " removed="
            ++ String.fromInt s.removed


-- Keep the FIRST occurrence of each key.  The VM's own `defunSet` keeps the
-- LAST (later-store-wins — see the header), so this pass and the VM disagree
-- on which copy survives; that asymmetry is UNOBSERVABLE only while same-key
-- copies emit byte-identical bodies, which the deterministic per-bundle passes
-- guarantee (every unit regenerates the same wrapper; no pass keys its rewrite
-- on which duplicate it sees).  If a future pass ever made same-key bodies
-- diverge, this dedup would silently keep a different body than the VM's
-- defunSet would have — the invariant to re-check first.
dedup : List Defun -> List Defun
dedup defuns =
    let
        ( rev, _ ) =
            List.foldl
                (\d ( acc, seen ) ->
                    if Set.member d.key seen then
                        ( acc, seen )

                    else
                        ( d :: acc, Set.insert d.key seen )
                )
                ( [], Set.empty )
                defuns
    in
    List.reverse rev


isWrapper : Defun -> Bool
isWrapper defun =
    String.endsWith ".curried" defun.key


-- A defun is reachable from the roots over the GRef edge set.  Small graphs
-- (a few hundred keys): iterate the transitive closure until it stops growing.
fixpoint : Set String -> Dict String (Set String) -> Set String
fixpoint reachable graph =
    let
        grown =
            Set.foldl
                (\k acc ->
                    Set.union (Dict.get k graph |> Maybe.withDefault Set.empty) acc
                )
                reachable
                reachable
    in
    if Set.size grown == Set.size reachable then
        reachable

    else
        fixpoint grown graph



-- ============================ GREF COLLECTION ============================
-- Every `GRef` key a body can load (a call target, a first-class function
-- value, a 0-arg thunk force).  `StreamRef` reads the VALUE table, not the
-- defun table, so it is deliberately not an edge.


grefsOf : Exp -> Set String
grefsOf exp =
    case exp of
        GRef ref ->
            Set.singleton ref.key

        Lit _ ->
            Set.empty

        Var _ ->
            Set.empty

        StreamRef _ ->
            Set.empty

        Lam lam ->
            grefsOf lam.body

        NoTail inner ->
            grefsOf inner

        App app ->
            Set.union (grefsOf app.fn) (grefsOfAll app.args)

        PrimApp app ->
            grefsOfAll app.args

        Let block ->
            Set.union (grefsOfBinders block.binders) (grefsOf block.body)

        Case branch ->
            Set.union (grefsOf branch.scrutinee) (grefsOfAlts branch.alts)

        Con con ->
            grefsOfAll con.args

        Tup es ->
            grefsOfAll es

        RecordLit setters ->
            grefsOfSetters setters

        RecordGet base _ ->
            grefsOf base

        RecordUpdate upd ->
            Set.union (grefsOf upd.base) (grefsOfSetters upd.updates)

        ListLit es ->
            grefsOfAll es

        If block ->
            Set.union (grefsOf block.cond)
                (Set.union (grefsOf block.thenBranch) (grefsOf block.elseBranch))

        ShortAnd block ->
            Set.union (grefsOf block.left) (grefsOf block.right)

        ShortOr block ->
            Set.union (grefsOf block.left) (grefsOf block.right)

        NotEqual block ->
            Set.union (grefsOf block.left) (grefsOf block.right)


grefsOfAll : List Exp -> Set String
grefsOfAll exps =
    List.foldl (\e acc -> Set.union (grefsOf e) acc) Set.empty exps


grefsOfSetters : List ( String, Exp ) -> Set String
grefsOfSetters setters =
    List.foldl (\( _, e ) acc -> Set.union (grefsOf e) acc) Set.empty setters


grefsOfBinders : List LetBinder -> Set String
grefsOfBinders binders =
    List.foldl
        (\b acc ->
            Set.union
                (case b of
                    LetBind bind ->
                        grefsOf bind.value

                    LetDestruct destruct ->
                        grefsOf destruct.value
                )
                acc
        )
        Set.empty
        binders


grefsOfAlts : List Alt -> Set String
grefsOfAlts alts =
    List.foldl (\a acc -> Set.union (grefsOf a.body) acc) Set.empty alts
