{- From stil4m/elm-syntax 7.3.9 (MIT, Copyright (c) 2018 Mats Stijlaart).
Diverged locally: the JSON codecs are pruned by
elm-compiler/selfhost/prune_codecs.py (the parse -> typecheck -> lower
path never serializes the AST).
-}

module Elm.Syntax.Infix exposing
    ( Infix, InfixDirection(..)
    )

{-|


## Types

@docs Infix, InfixDirection


-}

import Elm.Syntax.Node as Node exposing (Node)


{-| Type annotation for a infix definition
-}
type alias Infix =
    { direction : Node InfixDirection
    , precedence : Node Int
    , operator : Node String
    , function : Node String
    }


{-| Union type for infix direction
-}
type InfixDirection
    = Left
    | Right
    | Non
