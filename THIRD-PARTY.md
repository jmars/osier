# Third-party code in this repository

This repository carries derived code from the following third-party packages.
Each entry names the package, its licence and copyright line, where the
derived files live, and how they diverge from upstream. The per-file
attribution comments at the top of each derived file are the primary notice;
this file is the central record.

## stil4m/elm-syntax 7.3.9

- **Licence:** MIT — Copyright (c) 2018 Mats Stijlaart
- **Upstream:** https://package.elm-lang.org/packages/stil4m/elm-syntax/7.3.9
- **Derived files (40):**
  - `elm-compiler/src/Elm/Syntax/*.elm` (17 files)
  - `elm-compiler/src/Elm/Parser/*.elm` (12 files) and `elm-compiler/src/Elm/Parser.elm`
  - `elm-compiler/src/Elm/{Dependency,Interface,Processing,RawFile}.elm`
  - `elm-compiler/src/Elm/Internal/RawFile.elm`
  - `elm-compiler/src/ParserFast.elm`, `elm-compiler/src/ParserWithComments.elm`, `elm-compiler/src/Rope.elm`
  - `elm-compiler/src/List/Extra.elm`
  - `elm-compiler/src/Char/Extra.elm` (which additionally carries miniBill/elm-unicode code — see below)
- **Local divergence from upstream:**
  1. **JSON codecs pruned** from 24 files by `elm-compiler/selfhost/prune_codecs.py`
     (now retired; kept as the record of the derivation): every
     `encode`/`decoder` and codec-only helper is deleted, because the
     parse -> typecheck -> lower path never serializes the AST.
  2. **Three additive parser patch hunks** (recorded in the headers of the
     touched files; the former `.elm-cache` copy carried the full
     `FXUI-PATCHES.md`):
     - hunk 1 — `Elm/Syntax/Expression.elm`: new `InsertionValue (Node Expression)`
       constructor (the record-INSERTION setter RHS, `{ r | f <- v }`);
     - hunk 2 — `Elm/Parser/Expression.elm`: the record-setter separator accepts
       `<-` as well as `=`, wrapping an `<-` RHS in `InsertionValue`;
     - hunk 3 — `Elm/Parser/TypeAnnotation.elm`: `recordTypeAnnotation` accepts an
       optional `| tailvar` producing `GenericRecord`, so both tail-first
       (`{ r | x : Int }`) and tail-last (`{ x : Int | r }`) record syntax parse.
  3. `elm-compiler/src/Parser.elm` is **not** upstream code — it is original to
     this project (a minimal stub of elm/parser's `Problem`/`DeadEnd` surface).
- **Note:** this package was previously consumed as a dependency and vendored
  under `elm-compiler/selfhost/vendor/`; the `elm/parser`,
  `rtfeldman/elm-hex` and `stil4m/structured-writer` transitive dependencies
  went with it.

### Upstream licence text

```
The MIT License (MIT)

Copyright (c) 2018 Mats Stijlaart

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## miniBill/elm-unicode (code carried inside `Char/Extra.elm`)

- **Copyright:** 2021 Leonardo Taglialegne
- **Licence:** BSD 3-Clause — the full notice is retained verbatim inside
  `elm-compiler/src/Char/Extra.elm` (immediately below the module declaration),
  and that file is included unmodified from the elm-syntax package copy of it.

## Upstream `Parser.elm` stub

`elm-compiler/src/Parser.elm` is original to this project (no upstream licence
claim); listed here only to make explicit that it is *not* part of the
elm-syntax derivation above.
