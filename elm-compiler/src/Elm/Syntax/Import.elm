{- From stil4m/elm-syntax 7.3.9 (MIT, Copyright (c) 2018 Mats Stijlaart).
Diverged locally: the JSON codecs are pruned by
elm-compiler/selfhost/prune_codecs.py (the parse -> typecheck -> lower
path never serializes the AST).
-}

module Elm.Syntax.Import exposing
    ( Import
    )

{-| This syntax represents imports in Elm.
For example:

    import Html.Attributes as HA exposing (style)


## Types

@docs Import


-}

import Elm.Syntax.Exposing as Exposing exposing (Exposing)
import Elm.Syntax.ModuleName as ModuleName exposing (ModuleName)
import Elm.Syntax.Node as Node exposing (Node)


{-| Type alias representing an Import
-}
type alias Import =
    { moduleName : Node ModuleName
    , moduleAlias : Maybe (Node ModuleName)
    , exposingList : Maybe (Node Exposing)
    }
