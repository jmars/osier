module Mid.Qbe.Types exposing
    ( Binders(..)
    , DefunType(..)
    , Entry
    , Table
    , empty
    , envSchemes
    , fromSchemes
    , joinBinders
    , nodeTypeMap
    , note
    , typeOf
    , withBinders
    )

{-| Mid.Qbe.Types — the TYPE-INFORMATION SIDE TABLE for the QBE lowering
(monomorphisation step S1 / M0a).

WHAT THIS IS: a table keyed by the Mid defun key (`"Prelude.map"`, `"Main.fib"`
— the qualified dotted name `Mid.Ir.Defun.key` uses) holding, per defun, the
type the CHECKER has for it. It is the seat an unboxing pass reads to decide
what is an Int/Float local (S4) and a specialiser reads to know what to clone
(S5). S1 BUILDS AND CONSUMES NOTHING: `Mid.QbeModule` fills the table and no
pass reads it, which is what makes S1's oracle (every fixture `.ssa`
byte-identical) meaningful.

WHY A SIDE TABLE, NOT A CONSTRUCTOR ANNOTATION: every Mid pass pattern-matches
`Mid.Ir.Exp`; a side table reshapes nothing and changes no constructor, so no
pass moves. `Mid.Ir`'s doctrine ("the representation is a LOWER-LEVEL choice
and is not changed by this stage", Ir.elm's LABEL/representation header) is
upheld: this module carries the checker's TYPES, not a representation policy.
The HM type algebra is `Type.Representation`'s, imported UNCHANGED — that
module is the research contribution's own syntax and is not extended here.

SEED COST: ZERO. Every `Mid/*` file is absent from the 58-source selfhost
manifest (`elm-compiler/selfhost/manifest.json`), whose compiled form is the
committed bootstrap seed, so this file and its caller cost no seed re-freeze.
It IMPORTS `Type.Env`/`Type.Representation` (both in the 58) without editing
them, which is not the same thing as changing them.


## Monotype vs polymorphic — the quantifier test is exact, not a proxy

`Type.Env` builds every top-level scheme with `quantifiers = freeVars body`:
`signatureScheme` returns `{ quantifiers = freeVars t, body = t, bound = ...
}` (Type/Env.elm:361) and `generalize` returns
`{ quantifiers = freeVars t, body = t, bound = [] }` (Type/Env.elm:1045-1047);
`monoScheme` (Type/Env.elm:1065) is used for BINDERS, never for a top-level
defun. So `List.isEmpty scheme.quantifiers` is exactly "the body has no free
variable" — i.e. the scheme IS a closed monotype, and `Monotype scheme.body` is
safe to hand a consumer as one. Anything with quantifiers is kept WHOLE as
`Polymorphic scheme`, including `scheme.bound`: `bound` is the rigid subset
(GADT type indices and `type x a.` prefixes, Type/Env.elm:56-75), which is
exactly what S5's "refuse an instantiation containing a scheme-bound variable"
predicate reads. Dropping a polymorphic defun instead of recording it would
trade an honest "not a monotype" for a silent absence, so it is not done.


## THE GAP IS CLOSED (S2/M0b) — the per-binder half, and the join it rides on

S1 named two blockers: the per-binder types lived only inside `Type.Infer`'s
state, and there was NO Mid-binder-id <-> checker-Range correspondence. Both
are now built (ADDITIVELY — see below):

  * `Type.Infer` accumulates `nodeTypes : List (Range, Type)` — one entry per
    `inferExpr` visit plus one per pattern binder (VarPattern node,
    RecordPattern field node, AsPattern alias node) and per let-function NAME
    node — zonked ONCE at unit end, and exposes it on `CheckedUnit`.
    `Type.Check.checkBuiltins` hands out the corpus half keyed by module name;
    `Mid.QbeModule.groupSchemes` collects the group half the same way.
  * THE JOIN is `binderId -> Range`, emitted by `Mid.FromAst` itself at the
    exact `freshBinderAt` sites that issue a binder FROM a source pattern node
    (defun params, lambda params, case-arm pattern binds, let-destructuring
    binds, let-function names), keyed per defun by
    `Mid.Module.compileUnitJoin` (`Dict defunKey (Dict binderId Range)`).

TOTALITY of the join, on the shapes that reach it: both sides walk the SAME
(lifted, checker-rewritten) file and key the SAME pattern nodes — a binder
FromAst issues from a source pattern node is a node the checker's
`inferPattern`/`inferPatterns` typed, so its range has a record. DENY-BY-
DEFAULT, and this is the exhaustive list of denials:

  * synthetic binders (`$case`, `$argN`, `$argv`, `rec`, curried-prim wrapper
    params, ctor defun params) have NO source node — they record no range and
    get NO type, which is the honest answer;
  * a binder whose range is AMBIGUOUS in the checker's record (two DIFFERENT
    zonked types at one range — Lift's snapshot nodes all share the let-block
    range; a snapshot PARAM row shares the declaration range) is dropped by
    `nodeTypeMap`'s deny-on-conflict rule rather than guessed at;
  * a defun whose unit was never checked (trusted JsArray/Array bodies, or a
    group re-inference failure) keeps `BindersAbsent` — "no source", the
    S1 doctrine;
  * a binder whose recorded type does not exist at all (the checker trusted
    the body, or the range simply never recorded) simply lacks a dict entry.

SEED NOTE: at the 2d127d1 HEAD this file, like the whole `Mid/*` tree, IS one
of the selfhost seed's sources, so filling the half is seed-bearing — the S2
epoch re-freezes the seed with the rest of this change. (The S1-era claim
"Mid/* is seed-free" described the pre-flip manifest and is STALE.)


## Domain

`fromSchemes` keeps ONLY keys that are defun keys of the lowered program, so
the table's domain is exactly "the program's defuns" — a consumer looking up a
`Mid.Ir.Defun.key` either finds the checker's type for it or finds nothing
because the checker has no scheme for that name, never because the table
quietly carried a non-defun entry (the environment also holds constructor
schemes and type aliases, which are not defuns).

-}

import Dict exposing (Dict)
import Elm.Syntax.Range exposing (Range)
import Set exposing (Set)
import Type.Env as Env exposing (Env, Scheme)
import Type.Representation exposing (Type)


{-| The checker's type for one defun.

  - `Monotype` — a CLOSED type (`quantifiers == []`), the shape an unboxing
    pass (S4) can decide representation on without instantiating anything.
  - `Polymorphic` — the scheme VERBATIM (quantifiers, body, `bound`), for a
    specialiser (S5) to instantiate; `bound` is retained because S5's refusal
    predicate reads it.

-}
type DefunType
    = Monotype Type
    | Polymorphic Scheme


{-| The per-binder half of the side table (S2/M0b).

  - `Binders` — the defun's unit WAS checked: the map is `binderId -> Type`
    for every binder whose source pattern node's range joined UNAMBIGUOUSLY
    to the checker's record. An ABSENT id in the map is a denial (synthetic
    binder, or a range whose recorded types conflicted), never "unknown
    source".
  - `BindersAbsent` — the S1 doctrine, unchanged: NO inference ran for this
    defun's unit (a trusted body, or a group re-inference failure), so there
    is no source for binder types at all. Cannot be misread for an empty map.

-}
type Binders
    = BindersAbsent
    | Binders (Dict Int Type)


{-| One defun's entry: its type, and the per-binder half (see `Binders`).
-}
type alias Entry =
    { defunType : DefunType
    , binders : Binders
    }


{-| The table. `defuns` is keyed by the `Mid.Ir.Defun.key` string;
`notes` carries the facts a consumer must know before trusting the table
(a group whose re-inference failed, so its defuns are simply missing — never
wrongly typed).
-}
type alias Table =
    { defuns : Dict String Entry
    , notes : List String
    }


empty : Table
empty =
    { defuns = Dict.empty
    , notes = []
    }


{-| Record a fact about the table's COMPLETENESS (not about a defun). The
accumulating form is `List.foldl note table msgs`.
-}
note : String -> Table -> Table
note msg table =
    { table | notes = table.notes ++ [ msg ] }


{-| The value schemes of a merged environment. The CORPUS half of the table is
free: `Type.Check.checkBuiltins` already returns the environment holding every
builtin unit's schemes, and `Mid.QbeModule` already receives it. `Mid.QbeModule`
also passes the group-checking environment (corpus + every group SIGNATURE,
`Check.checkUserGroup`'s `env0`), so a group defun whose body re-inference
failed still contributes its declared scheme.
-}
envSchemes : Env -> List ( String, Scheme )
envSchemes env =
    Dict.toList env.values


{-| Build the table from a scheme list, keeping only `keys` (the program's
defun keys) and classifying each scheme (see the header). Later entries win on
a duplicate key, which is what lets a caller put inferred schemes after
collected signatures.
-}
fromSchemes : Set String -> List ( String, Scheme ) -> Table
fromSchemes keys schemes =
    List.foldl
        (\( name, scheme ) table ->
            if Set.member name keys then
                { table
                    | defuns =
                        Dict.insert name
                            { defunType = classify scheme
                            , binders = BindersAbsent
                            }
                            table.defuns
                }

            else
                table
        )
        empty
        schemes


{-| The classification the header justifies: no quantifiers means the scheme is
already a closed type.
-}
classify : Scheme -> DefunType
classify scheme =
    if List.isEmpty scheme.quantifiers then
        Monotype scheme.body

    else
        Polymorphic scheme


{-| Look a defun's type up by `Mid.Ir.Defun.key`. `Nothing` means the checker
has no scheme for that name (a constructor defun, or a name the re-inference
could not reach — check `Table.notes` before reading it as "untyped").
-}
typeOf : String -> Table -> Maybe DefunType
typeOf key table =
    Maybe.map .defunType (Dict.get key table.defuns)



-- ======================= S2/M0b: THE BINDER HALF =======================


{-| A `Range` encoded as a comparable key (Elm 0.19 records have no ordering,
so a `Range` cannot key a `Dict` directly; this is the usual row/column
quadruple, total and injective on real ranges).
-}
type alias RangeKey =
    ( ( Int, Int ), ( Int, Int ) )


rangeKey : Range -> RangeKey
rangeKey r =
    ( ( r.start.row, r.start.column ), ( r.end.row, r.end.column ) )


{-| The checker's per-unit node-type record as a `RangeKey -> Type` map, with
the ONE policy this module owns: DENY ON CONFLICT. The record is a LIST with
duplicates by design (`Type.Infer.CheckedUnit.nodeTypes`), because a source
range genuinely can carry two different zonked types — Lift's synthetic
snapshot nodes all share the let-block's range, and a snapshot param row shares
its declaration range. A range whose recorded types DISAGREE is dropped
entirely (a wrong type is worse than no type); agreeing duplicates collapse to
one entry. This is the collision gate: whatever reads this map can never be
handed a silently-guessed type.
-}
nodeTypeMap : List ( Range, Type ) -> Dict RangeKey Type
nodeTypeMap entries =
    let
        -- Ok = one agreeing type; Err () = conflicted (denied).
        insert : ( Range, Type ) -> Dict RangeKey (Result () Type) -> Dict RangeKey (Result () Type)
        insert ( r, t ) acc =
            case Dict.get (rangeKey r) acc of
                Nothing ->
                    Dict.insert (rangeKey r) (Ok t) acc

                Just (Ok u) ->
                    if u == t then
                        acc

                    else
                        Dict.insert (rangeKey r) (Err ()) acc

                Just (Err ()) ->
                    acc
    in
    List.foldl insert Dict.empty entries
        |> Dict.toList
        |> List.filterMap
            (\( r, v ) ->
                case v of
                    Ok t ->
                        Just ( r, t )

                    Err () ->
                        Nothing
            )
        |> Dict.fromList


{-| THE JOIN'S SECOND HALF: a defun's `binderId -> Range` map (from
`Mid.Module.compileUnitJoin`) against a unit's `RangeKey -> Type` map (from
`nodeTypeMap`). Total on the binders that recorded a range: a binder with no
range entry (synthetic) or a conflicted range is simply ABSENT from the result
— deny-by-default, never a guess.
-}
joinBinders : Dict Int Range -> Dict RangeKey Type -> Dict Int Type
joinBinders binderRanges rangeTypes =
    Dict.toList binderRanges
        |> List.filterMap
            (\( id, r ) ->
                Maybe.map (\t -> ( id, t )) (Dict.get (rangeKey r) rangeTypes)
            )
        |> Dict.fromList


{-| Fill the per-binder half of every tabled defun whose key the given map
covers. `BindersAbsent` (no source — trusted body, failed re-inference) is
OVERWRITTEN only for defuns the map actually covers, i.e. defuns whose unit
was checked; everything else keeps the S1 doctrine. Later calls win, so a
caller can seed corpus binders first and group binders second.
-}
withBinders : Dict String (Dict Int Type) -> Table -> Table
withBinders perDefun table =
    { table
        | defuns =
            Dict.map
                (\key entry ->
                    case Dict.get key perDefun of
                        Just binderMap ->
                            { entry | binders = Binders binderMap }

                        Nothing ->
                            entry
                )
                table.defuns
    }
