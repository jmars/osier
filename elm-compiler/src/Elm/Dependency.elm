{- From stil4m/elm-syntax 7.3.9 (MIT, Copyright (c) 2018 Mats Stijlaart).
Diverged locally: the JSON codecs are pruned by
elm-compiler/selfhost/prune_codecs.py (the parse -> typecheck -> lower
path never serializes the AST).
-}

module Elm.Dependency exposing (Dependency, Version)

{-| stil4m `Elm.Dependency`, verbatim (no Json codec surface — the pruner left
the parse closure's `addDependency` path, which needs the record shape).

-}

import Dict exposing (Dict)
import Elm.Interface exposing (Interface)
import Elm.Syntax.ModuleName exposing (ModuleName)


type alias Dependency =
    { name : String
    , version : Version
    , interfaces : Dict ModuleName Interface
    }


type alias Version =
    String
