{- From stil4m/elm-syntax 7.3.9 (MIT, Copyright (c) 2018 Mats Stijlaart).
Diverged locally: the JSON codecs are pruned by
elm-compiler/selfhost/prune_codecs.py (the parse -> typecheck -> lower
path never serializes the AST).
-}

module Elm.Syntax.Comments exposing
    ( Comment
    )

{-| This syntax represents both single and multi line comments in Elm. For example:

    -- A comment


    {- Some
       multi
       line
       comment
    -}


## Types

@docs Comment


-}


{-| Type representing the comment syntax
-}
type alias Comment =
    String
