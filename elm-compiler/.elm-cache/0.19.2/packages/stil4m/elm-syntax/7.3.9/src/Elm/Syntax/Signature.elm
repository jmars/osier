module Elm.Syntax.Signature exposing
    ( Signature
    , encode, decoder
    )

{-| This syntax represents type signatures in Elm.

For example :

    add : Int -> Int -> Int


## Types

@docs Signature


## Serialization

@docs encode, decoder

-}

import Elm.Syntax.Node as Node exposing (Node)
import Elm.Syntax.TypeAnnotation as TypeAnnotation exposing (TypeAnnotation)
import Json.Decode as JD exposing (Decoder)
import Json.Encode as JE exposing (Value)


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


{-| Encode a `Signature` syntax element to JSON.
-}
encode : Signature -> Value
encode { name, typeAnnotation, bound } =
    JE.object
        [ ( "name", Node.encode JE.string name )
        , ( "typeAnnotation", Node.encode TypeAnnotation.encode typeAnnotation )
        , ( "bound", JE.list (Node.encode JE.string) bound )
        ]


{-| JSON decoder for a `Signature` syntax element.
-}
decoder : Decoder Signature
decoder =
    JD.map3 Signature
        (JD.field "name" (Node.decoder JD.string))
        (JD.field "typeAnnotation" (Node.decoder TypeAnnotation.decoder))
        (JD.field "bound" (JD.list (Node.decoder JD.string)))
