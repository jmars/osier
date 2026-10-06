module Elm.Syntax.Type exposing
    ( Type, ValueConstructor
    )

{-| This syntax represents custom types.
For example:

    {-| This is a color
    -}
    type Color
        = Blue
        | Red


## Types

@docs Type, ValueConstructor


-}

import Elm.Syntax.Documentation as Documentation exposing (Documentation)
import Elm.Syntax.Node as Node exposing (Node)
import Elm.Syntax.TypeAnnotation as TypeAnnotation exposing (TypeAnnotation)


{-| Type alias that defines the syntax for a custom type.
All information that you can define in a type alias is embedded.
-}
type alias Type =
    { documentation : Maybe (Node Documentation)
    , name : Node String
    , generics : List (Node String)
    , constructors : List (Node ValueConstructor)
    }


{-| Syntax for a custom type value constructor. `result` is the optional
GADT-style per-constructor result annotation (`Here : Has l t { l : t | rho }`)
written after the argument list; `Nothing` for the ordinary unannotated form.
-}
type alias ValueConstructor =
    { name : Node String
    , arguments : List (Node TypeAnnotation)
    , result : Maybe (Node TypeAnnotation)
    }


