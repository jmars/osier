{- From stil4m/elm-syntax 7.3.9 (MIT, Copyright (c) 2018 Mats Stijlaart).
Diverged locally: the JSON codecs are pruned by
elm-compiler/selfhost/prune_codecs.py (the parse -> typecheck -> lower
path never serializes the AST).
-}

module Elm.Syntax.Documentation exposing
    ( Documentation
    )

{-| This syntax represents documentation comments in Elm.


## Types

@docs Documentation


-}


{-| Type representing the documentation syntax
-}
type alias Documentation =
    String


