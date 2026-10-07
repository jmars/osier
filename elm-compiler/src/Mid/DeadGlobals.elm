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


-- Keep the FIRST occurrence of each key (all copies emit byte-identically, so
-- which copy survives is unobservable in the emitted bytes).
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
