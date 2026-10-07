{- From stil4m/elm-syntax 7.3.9 (MIT, Copyright (c) 2018 Mats Stijlaart).
Diverged locally: the JSON codecs are pruned by
elm-compiler/selfhost/prune_codecs.py (the parse -> typecheck -> lower
path never serializes the AST).
-}

module Elm.Syntax.Signature exposing
    ( Signature
    )

{-| This syntax represents type signatures in Elm.

For example :

    add : Int -> Int -> Int


## Types

@docs Signature




-}

import Elm.Syntax.Node as Node exposing (Node)
import Elm.Syntax.TypeAnnotation as TypeAnnotation exposing (TypeAnnotation)


{-| Type alias representing a signature in Elm.
-}
type alias Signature =
    { name : Node String
    , typeAnnotation : Node TypeAnnotation

    -- Locally abstract types (`type a. a -> a`, OCaml-style): the names
    -- bound by an optional `type <name>+ .` prefix on the annotation,
    -- in scope for that annotation.  Empty for ordinary Elm signatures.
    , bound : List (Node String)
    }

