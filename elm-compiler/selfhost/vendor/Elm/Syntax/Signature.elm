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

