{- From stil4m/elm-syntax 7.3.9 (MIT, Copyright (c) 2018 Mats Stijlaart).
Diverged locally: the JSON codecs are pruned by
elm-compiler/selfhost/prune_codecs.py (the parse -> typecheck -> lower
path never serializes the AST).
-}

module Elm.Syntax.File exposing
    ( File
    )

{-| This syntax represents a whole Elm file.


## Types

@docs File


-}

import Elm.Syntax.Comments as Comments exposing (Comment)
import Elm.Syntax.Declaration as Declaration exposing (Declaration)
import Elm.Syntax.Import as Import exposing (Import)
import Elm.Syntax.Module as Module exposing (Module)
import Elm.Syntax.Node as Node exposing (Node)


{-| Type annotation for a file
-}
type alias File =
    { moduleDefinition : Node Module
    , imports : List (Node Import)
    , declarations : List (Node Declaration)
    , comments : List (Node Comment)
    }
