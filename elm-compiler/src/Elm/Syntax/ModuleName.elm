{- From stil4m/elm-syntax 7.3.9 (MIT, Copyright (c) 2018 Mats Stijlaart).
Diverged locally: the JSON codecs are pruned by
elm-compiler/selfhost/prune_codecs.py (the parse -> typecheck -> lower
path never serializes the AST).
-}

module Elm.Syntax.ModuleName exposing
    ( ModuleName
    )

{-| This syntax represents the module names in Elm. These can be used for imports, module names (duh), and for qualified access.
For example:

    module Elm.Syntax.ModuleName ...

    import Foo.Bar ...

    import ... as Something

    My.Module.something

    My.Module.SomeType


## Types

@docs ModuleName


-}


{-| Base representation for a module name
-}
type alias ModuleName =
    List String


