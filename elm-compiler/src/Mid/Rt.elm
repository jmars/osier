module Mid.Rt exposing (Impl, program, primImpl, rtDeps, seeds)

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
import Mid.RtPrims exposing (helperDefuns, primDefuns)
import Set exposing (Set)


{-| The Rt program: every Mid-implemented runtime defun.  Injected whole by
QbeModule; Lower keeps only the SEEDED (used) subset.
-}
program : List Defun
program =
    primDefuns ++ helperDefuns


{-| One Mid prim implementation: the Rt defun key AND its arity — the arity
the route check reads (Lower's midPrimRoute).  Step 5's hand-off #1: a
hardcoded arity silently mis-handles every non-binary prim, so the table
carries it next to the key it belongs to.
-}
type alias Impl =
    { key : String
    , arity : Int
    }


{-| prim name -> the Rt defun implementing it.  A prim absent here has no
Mid implementation (the host-only and unreachable prims — the
classification lives in Mid.RtPrims' header); Lower consults this for the
per-prim call route (the step-6 flip generalizes it).
-}
impls : Dict String Impl
impls =
    Dict.fromList
        [ ( "cons", { key = "Rt.cons", arity = 2 } )
        , ( "@p", { key = "Rt.@p", arity = 2 } )
        , ( "emptylist", { key = "Rt.emptylist", arity = 1 } )
        , ( "=", { key = "Rt.=", arity = 2 } )
        , ( "+", { key = "Rt.+", arity = 2 } )
        , ( "-", { key = "Rt.-", arity = 2 } )
        , ( "*", { key = "Rt.*", arity = 2 } )
        , ( "/", { key = "Rt./", arity = 2 } )
        , ( "f/", { key = "Rt.f/", arity = 2 } )
        , ( "<", { key = "Rt.<", arity = 2 } )
        , ( "<=", { key = "Rt.<=", arity = 2 } )
        , ( ">", { key = "Rt.>", arity = 2 } )
        , ( ">=", { key = "Rt.>=", arity = 2 } )
        , ( "bitwise-and", { key = "Rt.bitwise-and", arity = 2 } )
        , ( "bitwise-or", { key = "Rt.bitwise-or", arity = 2 } )
        , ( "bitwise-xor", { key = "Rt.bitwise-xor", arity = 2 } )
        , ( "bitwise-not", { key = "Rt.bitwise-not", arity = 1 } )
        , ( "bitwise-shift-left", { key = "Rt.bitwise-shift-left", arity = 2 } )
        , ( "bitwise-shift-right", { key = "Rt.bitwise-shift-right", arity = 2 } )
        , ( "bitwise-shift-right-zf", { key = "Rt.bitwise-shift-right-zf", arity = 2 } )
        , ( "number?", { key = "Rt.number?", arity = 1 } )
        , ( "string?", { key = "Rt.string?", arity = 1 } )
        , ( "cons?", { key = "Rt.cons?", arity = 1 } )
        , ( "empty?", { key = "Rt.empty?", arity = 1 } )
        , ( "c-strlen", { key = "Rt.c-strlen", arity = 1 } )
        , ( "char-code", { key = "Rt.char-code", arity = 2 } )
        , ( "substring", { key = "Rt.substring", arity = 3 } )
        , ( "cn", { key = "Rt.cn", arity = 2 } )
        , ( "repeat", { key = "Rt.repeat", arity = 2 } )
        , ( "shen.str->bytes", { key = "Rt.shen.str->bytes", arity = 1 } )
        , ( "shen.bytes->string", { key = "Rt.shen.bytes->string", arity = 1 } )
        , ( "absvector", { key = "Rt.absvector", arity = 1 } )
        , ( "address->", { key = "Rt.address->", arity = 3 } )
        , ( "<-address", { key = "Rt.<-address", arity = 2 } )
        , ( "assoc", { key = "Rt.assoc", arity = 2 } )
        , ( "snd", { key = "Rt.snd", arity = 1 } )
        ]


{-| The Rt defun implementing a prim, if any.
-}
primImpl : String -> Maybe Impl
primImpl prim =
    Dict.get prim impls


{-| The Rt defun keys a USED-PRIM census seeds: for every used prim with a
Mid implementation, its key plus every Rt key it transitively references
(the RawCall edges — GRef reachability cannot see them, so they are
declared in `rtDeps` below and closed to a fixed point here).  `used` is
the set of prim names the REACHED surface defuns will call
(Mid.QbeLower.calledPrims — including the ListLit/RecordLit/RecordGet/
Tup/StreamRef desugars, which lower to cons/@p/emptylist/assoc/snd/value).
-}
seeds : Set String -> List String
seeds used =
    Set.toList used
        |> List.filterMap (\p -> Maybe.map .key (primImpl p))
        |> keepRtDependencies


{-| The transitive Rt->Rt edge list, keyed by the REFERENCING defun —
exactly the RawCall keys each body names (Mid.RtPrims is the only
producer; a key named in a body but absent here makes that defun
unreachable, and Lower's rawCall arm fails LOUDLY on it).
-}
rtDeps : Dict String (List String)
rtDeps =
    Dict.fromList
        [ ( "Rt.=", [ "Rt.deepEq", "Rt.symEq", "Rt.bytesEqGo", "Rt.asF" ] )
        , ( "Rt.+", [ "Rt.asF" ] )
        , ( "Rt.-", [ "Rt.asF" ] )
        , ( "Rt.*", [ "Rt.asF" ] )
        , ( "Rt.f/", [ "Rt.asF" ] )
        , ( "Rt.<", [ "Rt.asF" ] )
        , ( "Rt.<=", [ "Rt.asF" ] )
        , ( "Rt.>", [ "Rt.asF" ] )
        , ( "Rt.>=", [ "Rt.asF" ] )
        , ( "Rt.bitwise-and", [ "Rt.toI32" ] )
        , ( "Rt.bitwise-or", [ "Rt.toI32" ] )
        , ( "Rt.bitwise-xor", [ "Rt.toI32" ] )
        , ( "Rt.bitwise-not", [ "Rt.toI32" ] )
        , ( "Rt.bitwise-shift-left", [ "Rt.toI32" ] )
        , ( "Rt.bitwise-shift-right", [ "Rt.toI32" ] )
        , ( "Rt.bitwise-shift-right-zf", [ "Rt.toI32" ] )
        , ( "Rt.deepEq", [ "Rt.deepEq", "Rt.bytesEqGo", "Rt.symEq", "Rt.vecEq" ] )
        , ( "Rt.vecEq", [ "Rt.vecEq", "Rt.deepEq" ] )
        , ( "Rt.bytesEqGo", [ "Rt.bytesEqGo" ] )
        , ( "Rt.symEq", [ "Rt.symEq" ] )
        , ( "Rt.dgs", [ "Rt.dgs", "Rt.cons" ] )
        , ( "Rt.revGo", [ "Rt.revGo", "Rt.cons" ] )
        , ( "Rt.bytesOf", [ "Rt.bytesOf", "Rt.cons" ] )
        , ( "Rt.appendL", [ "Rt.revGo" ] )
        , ( "Rt.numText", [ "Rt.dgs", "Rt.revGo", "Rt.bytesToStr", "Rt.cons" ] )
        , ( "Rt.bytesToStr", [ "Rt.countL", "Rt.fillGo" ] )
        , ( "Rt.countL", [ "Rt.countL" ] )
        , ( "Rt.fillGo", [ "Rt.fillGo" ] )
        , ( "Rt.cn", [ "Rt.cn2", "Rt.strOf" ] )
        , ( "Rt.cn2", [ "Rt.bytesToStr", "Rt.appendL", "Rt.bytesOf" ] )
        , ( "Rt.strOf", [ "Rt.numText", "Rt.symToStr" ] )
        , ( "Rt.symToStr", [ "Rt.bytesToStr", "Rt.nameBytes", "Rt.cons" ] )
        , ( "Rt.nameBytes", [ "Rt.nameBytes", "Rt.cons" ] )
        , ( "Rt.assoc", [ "Rt.assocGo" ] )
        , ( "Rt.assocGo", [ "Rt.assocGo", "Rt.deepEq" ] )
        , ( "Rt.substring", [ "Rt.bytesToStr", "Rt.subGo" ] )
        , ( "Rt.subGo", [ "Rt.subGo", "Rt.cons" ] )
        , ( "Rt.repeat", [ "Rt.bytesToStr", "Rt.repGo" ] )
        , ( "Rt.repGo", [ "Rt.repGo", "Rt.appendL", "Rt.bytesOf" ] )
        , ( "Rt.shen.str->bytes", [ "Rt.bytesBuild" ] )
        , ( "Rt.bytesBuild", [ "Rt.bytesBuild", "Rt.cons" ] )
        , ( "Rt.shen.bytes->string", [ "Rt.bytesToStr" ] )
        ]


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
