module Mid.Qbe.Types exposing
    ( Binders(..)
    , DefunType(..)
    , Entry
    , Table
    , empty
    , envSchemes
    , fromSchemes
    , note
    , typeOf
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


## THE GAP — the per-binder half is NOT obtainable at S1, and is named here

The plan's sketch of this table is
`Dict defunKey (monotype, Dict binderId monotype)`. The SECOND half cannot be
built without editing `Type/*`: `Infer.CheckedUnit` and `Infer.inferUnit` are
the only names `Type.Infer` exposes (Type/Infer.elm:1), and they hand back the
rewritten `File` plus the unit's TOP-LEVEL schemes (Type/Infer.elm:61-73).
Per-binder (Lam param / Let binder / Case alt binds / scrutinee) types live
only in the `InferState` threaded through inference and are exposed by no name.
Producing them means an additive accumulator inside `Type/Infer.elm` — a
58-source seed file — which is the plan's S2 probe plus the user's S3 decision
to re-freeze the seed, NOT this step's.

So `Binders` has one constructor and carries no map. That is deliberate over an
empty `Dict binderId Type`: an empty Dict reads as "no binder types are KNOWN",
which cannot be told apart from "no source for binder types exists" — the
distinction this whole step is about. `BindersAbsent` cannot be misread, and a
consumer must handle it EXPLICITLY (deny-by-default), so the missing half
cannot be walked past by accident.

SECOND, INDEPENDENT REASON the binder half is out of reach even WITH exposed
types: there is no binder-ID correspondence to key a map on. Mid binder ids are
issued by `Mid.FromAst.Gen`'s supply, while Infer keys every node by its source
`Range`; joining Mid ids to Infer's node types is itself an unsolved step
(plan S2, including its UNMEASURED duplicate-Range hazard).


## Domain

`fromSchemes` keeps ONLY keys that are defun keys of the lowered program, so
the table's domain is exactly "the program's defuns" — a consumer looking up a
`Mid.Ir.Defun.key` either finds the checker's type for it or finds nothing
because the checker has no scheme for that name, never because the table
quietly carried a non-defun entry (the environment also holds constructor
schemes and type aliases, which are not defuns).

-}

import Dict exposing (Dict)
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


{-| The per-binder half of the side table. `BindersAbsent` is not a transient
failure state and not a placeholder to be filled by a caller: it is the MEASURED
state of S1, since no exposed name in `Type/*` reports a binder's type (see the
module header's THE GAP section). A consumer that needs per-binder types must
first land the `Type/Infer` accumulator (S2) and the seed re-freeze (S3) that
unblocks it.
-}
type Binders
    = BindersAbsent


{-| One defun's entry: its type, and (S1: always) the absence of per-binder
types.
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
