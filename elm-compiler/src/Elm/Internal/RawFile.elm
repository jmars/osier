{- From stil4m/elm-syntax 7.3.9 (MIT, Copyright (c) 2018 Mats Stijlaart).
Unmodified from the package copy this project carried — no patch hunks, no
codec pruning.
-}

module Elm.Internal.RawFile exposing (RawFile(..), fromFile)

import Elm.Syntax.File exposing (File)


type RawFile
    = Raw File


fromFile : File -> RawFile
fromFile =
    Raw
