{- From stil4m/elm-syntax 7.3.9 (MIT, Copyright (c) 2018 Mats Stijlaart).
Diverged locally: the JSON codecs are pruned by
elm-compiler/selfhost/prune_codecs.py (the parse -> typecheck -> lower
path never serializes the AST).
-}

module Elm.Syntax.TypeAlias exposing
    ( TypeAlias
    )

{-| This syntax represents type aliases.
For example:

    {-| This is a person
    -}
    type alias Person =
        { name : String
        , age : Int
        }


## Types

@docs TypeAlias


-}

import Elm.Syntax.Documentation as Documentation exposing (Documentation)
import Elm.Syntax.Node as Node exposing (Node)
import Elm.Syntax.TypeAnnotation as TypeAnnotation exposing (TypeAnnotation)


{-| Type alias that defines the syntax for a type alias.
A bit meta, but you get the idea. All information that you can define in a type alias is embedded.
-}
type alias TypeAlias =
    { documentation : Maybe (Node Documentation)
    , name : Node String
    , generics : List (Node String)
    , typeAnnotation : Node TypeAnnotation
    }


