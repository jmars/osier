module Mid.Rt exposing (program, primImpl, seeds)

-- Mid.Rt — the MID-WRITTEN RUNTIME's program assembly (handoff
-- osier-consspike, TRACK 2 step 4).
--
-- The runtime is COMPILER-INTERNAL defuns under the reserved `Rt.*` key
-- namespace, built here from the bodies in Mid.RtPrims and injected into the
-- compile by Mid.QbeModule AFTER Flatten (whose rewriter rightly rejects raw
-- nodes — Rt code is already final) and BEFORE Mid.Qbe.Lower.  This module
-- is the ONE place that knows which Rt defun implements which surface prim
-- (`primImpl`) and which Rt keys a used prim transitively needs (`seeds`) —
-- the seed list exists because `RawCall` crosses the Mid-level call graph as
-- an opaque symbol, invisible to Lower's GRef reachability walk (Mid.Ir's
-- header records the caveat); the builder that issued the calls is the only
-- side that can close the dependency.
--
-- BACKEND-NEUTRAL BY CONSTRUCTION: this module and Mid.RtPrims import only
-- Mid.Ir — a Lua backend consumes the SAME defuns through its own lowering.
-- The seeding contract travels with them: seed exactly the used prims' keys,
-- so a program that never conses never carries the cons machinery (the
-- pruning a committed runtime blob could not offer).
--
-- THE `Rt` MODULE NAME IS RESERVED: a surface module actually named `Rt`
-- would emit keys under this same prefix and slip past Mid.Audit's
-- namespace test — Mid.QbeModule rejects it loudly at collect time (the
-- residual hole osier-rawnodes recorded for this step to close).

import Dict exposing (Dict)
import Mid.Ir exposing (Defun)
import Mid.RtPrims exposing (consDefun)
import Set exposing (Set)


{-| The Rt program: every Mid-implemented runtime defun.  Injected whole by
QbeModule; Lower keeps only the SEEDED (used) subset.
-}
program : List Defun
program =
    [ consDefun ]


{-| prim name -> the Rt defun key implementing it.  A prim absent here has no
Mid implementation yet (step 5 ports the rest); Lower consults this for the
per-prim call route (the step-6 flip generalizes it).
-}
impls : Dict String String
impls =
    Dict.fromList
        [ ( "cons", "Rt.cons" )
        ]


{-| The Rt key implementing a prim, if any.
-}
primImpl : String -> Maybe String
primImpl prim =
    Dict.get prim impls


{-| The Rt defun keys a USED-PRIM census seeds: for every used prim with a
Mid implementation, its key plus every Rt key it transitively references
(today `Rt.cons` references none; when step 5's prims share helpers, the
helper keys are listed HERE, at the referencing prim, because the GRef walk
cannot see RawCall edges).  `used` is the set of prim names the REACHED
surface defuns will call (Mid.QbeLower.calledPrims — including the
ListLit/RecordLit desugars, which lower to cons chains).
-}
seeds : Set String -> List String
seeds used =
    Set.toList used
        |> List.filterMap primImpl
        |> keepRtDependencies


{-| The transitive Rt->Rt edge list, keyed by the REFERENCING defun.  Empty
while Rt.cons stands alone; every entry added by step 5 names the keys that
defun RawCalls, and `seeds` closes over them here (one place, walked to a
fixed point).
-}
rtDeps : Dict String (List String)
rtDeps =
    Dict.empty


keepRtDependencies : List String -> List String
keepRtDependencies roots =
    let
        step : List String -> List String -> List String
        step acc queue =
            case queue of
                [] ->
                    List.reverse acc

                key :: rest ->
                    if List.member key acc then
                        step acc rest

                    else
                        case Dict.get key rtDeps of
                            Just deps ->
                                step (key :: acc) (deps ++ rest)

                            Nothing ->
                                step (key :: acc) rest
    in
    step [] roots
