module Mid.RtLang.Error exposing
    ( MidcError
    , lineWidth
    , oneLine
    , render
    , titleFor
    )

{-| THE MID-C ERROR SURFACE — one structured value, one renderer.

A rejection in this lane is a `MidcError`: the judgment TAG (a machine field),
a TITLE for the banner, ONE sentence naming the law that was violated, the FIX
as a `Maybe String`, the defun KEY, and the source SPAN when there honestly is
one. `render` prints it in Elm's own 0.19.1 form; `oneLine` prints the
tag-and-rule form the line-based consumers need.

WHY A RECORD AND NOT A STRING (plan-b's message policy, MEASURED over
Check.elm's 121 message sites): the welded prose the lane has today mixes three
different things — the SITE (`binder 'b'`, `struct 'S'`, `at byte 4`), the RULE
(the law), and the RATIONALE (why the law exists for us, i.e. lowering
internals the reader cannot act on) — plus a fix tail. The record keeps the
site and rule in `rule`, moves the fix to `hint`, and leaves the rationale to a
source comment beside the judgment. `tag` stays a FIELD rather than being
parsed back out of prose so the 33 J-tag-only TestMain pins and qbe-check's
`grep -q` rows survive any prose rewrite; `span` stays `Maybe` so a message
with no honest position degrades to banner + prose rather than inventing one.

WHY THE RENDERER LIVES HERE AND NOT IN `Ast` (the arc's D2 decision):
`Ast.renderSpan` (Ast.elm:1963) is the ONLY offset-to-position arithmetic in
the tree — it hands back `{ row, col, line, startCol, endCol, multiline }`.
This module formats AROUND that record and never sees a raw offset, so there is
one caret implementation, not one per caller, and a formatting bug cannot move
a position.

FORMAT PROVENANCE — read from the elm/compiler source at tag 0.19.1, not from
memory (fetched this unit):

  * `compiler/src/Reporting/Error.hs` `toMessageBar` —
    `usedSpace = 4 + length title + 1 + length filePath`,
    `"-- " ++ title ++ " " ++ replicate (max 1 (80 - usedSpace)) '-' ++ " " ++ filePath`.
  * `compiler/src/Reporting/Render/Code.hs` `addLineNumber` —
    `lineNumber = replicate (width - length number) ' ' ++ number ++ "|"`, then
    ONE spacer character (`">"` inside a multiline region, `" "` otherwise);
    `makeUnderline` —
    `spaces = replicate (c1 + width + 1) ' '` then
    `replicate (max 1 (c2 - c1)) '^'`, and `Nothing` (no caret at all) when the
    region spans more than one line. `render`'s `width` is the digit count of
    the LAST displayed line number.
  * `compiler/src/Reporting/Doc.hs` `toSimpleHint` — a hint is the same
    `fillSep` word fill the prose gets, so the `Hint:` prefix participates in
    the wrap.

DELIBERATE DEVIATIONS FROM ELM, each with its reason:

  * A FINAL `-- <tag>` FOOTER LINE. Elm has no such line. Our payload is
    consumed by line-based tooling (`grep -q` rows in tools/qbe/qbe-check.sh,
    the 33 J-tag TestMain pins), and the tag must be greppable even when the
    prose is rewritten — the footer makes the tag a LINE, not a substring hunt.
  * NO ANSI COLOUR, EVER. Elm colourises the bar, the `>` margin and the
    caret. This payload is written into `.ssa` files that
    tools/osier-corpus-ssa.sh hashes and that diffs compare, so an escape byte
    would corrupt both. There is no opt-in flag: a flag nobody consumes is a
    seat never read.
  * NO TRUNCATION and NO TAB EXPANSION. Elm truncates nothing either; we state
    it because the longest corpus line is 355 chars (a runtime.mid comment) and
    an ellipsis at the caret would hide the text a reader must quote. A tab
    cannot reach a caret: ParserFast's whitespace class is space/`\n`/`\r`
    (ParserFast.elm:3177), so a tab can only sit inside a comment, which ends
    the line.
  * ONE SNIPPET LINE. Elm prints every line of the region; `Ast.renderSpan`'s
    record carries the START line and no end row (Ast.elm:1971), so a
    multi-line region shows its first line with the `>` margin and no caret —
    the same signal Elm gives that the caret cannot be placed, minus the lines
    we cannot position. NAMED GAP: showing the rest of a multiline region needs
    an end row in that record, i.e. an `Ast` change, not a formatting one.

WIDTH AND CHARACTER-COUNTING: every column here is an Elm `String` index, the
same unit `Ast` measures in (UTF-16 code units), which is also Elm's own
char-naive choice in `Code.hs`. A caret after a non-ASCII character would
misalign in a terminal; it cannot arise for a parsed-OK line — non-ASCII is
refused inside literals (Rt.elm:308-311) and otherwise lives only in comments,
which end the line.

@docs MidcError, lineWidth, titleFor, render, oneLine

-}

import Mid.RtLang.Ast as Ast


{-| The render width, in `String` indices — Elm's own 80 (`Doc.hs`'s render
width), and the ONE place the number appears. Exposed so a test can assert
"no rendered line exceeds it" against the constant the renderer reads, instead
of against a second copy of the literal.
-}
lineWidth : Int
lineWidth =
    80


{-| One Mid-c rejection.

  * `tag` — `"J1"`..`"J15"` (the judgment number, Check.elm:71-250) or one of
    the lane tags `"PARSE"`, `"EXPORT"`, `"NS"`, `"LOWER"`, `"INTERNAL"`.
  * `title` — the banner's uppercase phrase; `titleFor` is the table, and the
    field exists so a site can override it (Elm has no dependent record, so the
    two cannot be derived from one another — the table is the one place the
    strings live and the field is what `render` reads).
  * `rule` — ONE sentence: the law that was violated, with the site's own
    names interpolated. NOT the rationale (that belongs in a source comment
    beside the judgment) and NOT the fix (that is `hint`).
  * `hint` — the FIX, as an instruction the reader can carry out.
  * `key` — the defun key the error is in (`"Wesc.run"`), when there is one.
  * `span` — the source position, when there HONESTLY is one. `Nothing` is a
    first-class value: the renderer prints no snippet for it (the degradation
    path is what a LowerToIr internal or an export error uses — neither has a
    position this arc). Never synthesize a span to fill it.

-}
type alias MidcError =
    { tag : String
    , title : String
    , rule : String
    , hint : Maybe String
    , key : Maybe String
    , span : Maybe Ast.Span
    }


{-| The tag-to-title table: one title per tag, and the DEFAULT a site passes as
`title`. A default is only honest when it is TRUE for every site carrying the
tag, and several tags do not have that property (J2 is resolution AND arity AND
argument classes; J13 is the field/index/deref classes AND the frame-escape
rule), so the site overrides it with `Check.withTitle` — `title` is a FIELD for
exactly that reason. The DEFAULTS:

  * J1/J6/J12/J13 → `TYPE MISMATCH` — the class rules (operand/result classes,
    the `return` class, the pointer-coercion matrix, field/index/deref).
  * J2/J3/J5/J10 → `UNKNOWN NAME` — a key, rawcall symbol, binder or `withroots`
    id that does not resolve in scope.
  * J4 → `BAD ARITY` — `recur` against the enclosing defun's parameter count.
  * J7 → `BAD CONTROL FLOW` — the divergence rule, an `else`-less terminating
    `if` whose then-branch falls through, and `break`/`continue` outside a loop:
    three STATEMENT-ARRANGEMENT rejects, none of them about memory layout (the
    sense `BAD LAYOUT` carries for J11).
  * J11 → `BAD LAYOUT` — the struct table's offsets, sizes, alignment and field
    widths.
  * J8/J14/J15/`NS` → `NAMING PROBLEM` — one key with more than one active
    defun, a duplicate declaration or enum constant, an extern symbol that
    claims a reserved name, a module whose header name disagrees with its keys.
  * J9/`LOWER`/`INTERNAL` → `INTERNAL ERROR` — J9 is deliberately NOT checked
    (Check.elm:185-190), so a J9 message can only be our own bug, like the
    lowering's invariants.
  * `PARSE` → `SYNTAX PROBLEM`; `EXPORT` → `BAD SIGNATURE` (the export's
    declared arity disagrees with the defun's — the one export reject that IS a
    claim about a signature; the duplicate and unknown-key halves pass their own
    titles).

THE SITE-SUPPLIED TITLES, and the tag whose default they replace — the whole
vocabulary a reader can meet in a banner, so a new one is a deliberate
addition and never an accident:

  * `BAD ARITY` — every arity disagreement under a tag that is not J4: `call`
    and `recur`/`rawcall` argument counts (J2/J3/J4 via `checkArgsAt`), a
    `mkval` with no tag word (J1), an extern declaration's fixed/variadic counts
    (J3).
  * `BAD CONDITION` — an `if`/`?:` condition the grammar admits but the lowering
    cannot branch on AS WRITTEN: a constant, a bare word variable, a word-valued
    join (J1).
  * `BAD CONTROL FLOW` — a `for` STEP that is not a store or an effect statement
    (J1).
  * `BAD SIGNATURE` — a declared SIGNATURE the value ABI cannot express: a
    struct/array return, a `bool` result or parameter in a non-all-word
    signature, a struct/array parameter by value (J11), a `void` parameter
    (J15).
  * `NAMING PROBLEM` — a DUPLICATE, under a tag that also carries other kinds: a
    duplicate parameter or binder (J5), a duplicate struct/enum declaration or
    field (J11), a field initialised twice (J13), a duplicate export (`EXPORT`).
  * `UNKNOWN NAME` — a `call` target that is not namespace-qualified (J2), an
    export naming no defun (`EXPORT`).
  * `UNKNOWN STRUCT` — a struct NAME that resolves in no table (J11).
  * `UNKNOWN FIELD` — a field name the struct does not declare (J13).
  * `NOT ADDRESSABLE` — `&` of something with no raw address: a pointer, a
    scalar, a `val` field, a narrow field (J13).
  * `DANGLING POINTER` — the address of this frame's own storage escaping the
    frame (J13).

`UNKNOWN STRUCT` IS NOT A TAG DEFAULT, deliberately: J11 covers both an unknown
struct NAME and a struct that is not word-aligned or not a whole number of
words (Check.elm:1095-1133, :1478), so its default is the layout family's
`BAD LAYOUT` and the unknown-struct sites pass `UNKNOWN STRUCT` explicitly —
that is exactly what the `title` field is for.

AN UNRECOGNISED TAG IS `INTERNAL ERROR`: tags are written by our own code, never
by the user, so an unknown one is a bug in this lane, not user input to explain.

-}
titleFor : String -> String
titleFor tag =
    case tag of
        "J1" ->
            "TYPE MISMATCH"

        "J2" ->
            "UNKNOWN NAME"

        "J3" ->
            "UNKNOWN NAME"

        "J4" ->
            "BAD ARITY"

        "J5" ->
            "UNKNOWN NAME"

        "J6" ->
            "TYPE MISMATCH"

        "J7" ->
            "BAD CONTROL FLOW"

        "J8" ->
            "NAMING PROBLEM"

        "J9" ->
            "INTERNAL ERROR"

        "J10" ->
            "UNKNOWN NAME"

        "J11" ->
            "BAD LAYOUT"

        "J12" ->
            "TYPE MISMATCH"

        "J13" ->
            "TYPE MISMATCH"

        "J14" ->
            "NAMING PROBLEM"

        "J15" ->
            "NAMING PROBLEM"

        "PARSE" ->
            "SYNTAX PROBLEM"

        "EXPORT" ->
            "BAD SIGNATURE"

        "NS" ->
            "NAMING PROBLEM"

        "LOWER" ->
            "INTERNAL ERROR"

        "INTERNAL" ->
            "INTERNAL ERROR"

        _ ->
            "INTERNAL ERROR"


{-| The multi-line form — Elm's own, plus the machine footer:

    -- TYPE MISMATCH -------- src/Wesc.mid

    the right side of `+` is a `val`, but `+` needs word operands

     41|   word n = n + acc;
                ^^^^^

    Hint: bind the value through `payload(..)` or a word binder
    -- J1

`ctx.source` is the text the span is measured against and `ctx.path` the name
in the banner. The result has NO trailing newline: the caller decides how the
payload is framed (the lane exits prefix `"err "`, which keeps `head -c 4` and
`grep -q` consumers reading the same bytes they read today).

A `span = Nothing` error drops the whole snippet BLOCK — no `NN|` gutter line
and no caret — leaving banner, blank, rule, [blank, `Hint: ...`], footer. That
path is reachable on purpose (see `MidcError.span`) and a test pins it.
-}
render : { source : String, path : String } -> MidcError -> String
render ctx e =
    String.join "\n"
        (List.concat
            [ [ banner e.title ctx.path, "" ]
            , wrap lineWidth e.rule
            , case e.span of
                Just span ->
                    "" :: snippet ctx.source span

                Nothing ->
                    []
            , case e.hint of
                Just hint ->
                    -- The `Hint:` prefix rides INSIDE the wrap, as Elm's
                    -- `fillSep ("Hint:" : words)` does (Doc.hs:166-170), so the
                    -- first line's budget is the prefix's too.
                    "" :: wrap lineWidth ("Hint: " ++ hint)

                Nothing ->
                    []
            , [ "-- " ++ e.tag ]
            ]
        )


{-| The single-line form the line-based consumers read: `"<key>: <tag>: <rule>"`,
with the key omitted when there is none.

NOT wrapped, deliberately: this is the fallback for a consumer that reads ONE
line (TestMain's `chkModuleFlags` adapter, a `grep -q` row), so breaking it at
80 would defeat its only purpose. It carries the tag for the same reason the
footer does — a prose rewrite must never unhook a tag pin.
-}
oneLine : MidcError -> String
oneLine e =
    case e.key of
        Just key ->
            key ++ ": " ++ e.tag ++ ": " ++ e.rule

        Nothing ->
            e.tag ++ ": " ++ e.rule


{-| Elm's message bar, to the character: `"-- "`, the title, one space, the
dashes, one space, the path, where the dashes are `max 1 (80 - usedSpace)` and
`usedSpace = 4 + len title + 1 + len path` (Error.hs `toMessageBar`). The
`max 1` is why a long path can push the line PAST 80 instead of printing a
zero-width bar — Elm's own behaviour, kept.
-}
banner : String -> String -> String
banner title path =
    let
        dashes =
            max 1 (lineWidth - (4 + String.length title + 1 + String.length path))
    in
    "-- " ++ title ++ " " ++ repeatText dashes "-" ++ " " ++ path


{-| `n` copies of `s` — `String.repeat` is NOT in this language's String surface
(MEASURED: the self-host front end rejects it, the same boundary `Ast.splitLines`
records), and this module IS compiled by that front end.

`n <= 0` yields `""`, which is `String.repeat`'s own answer (its loop runs while
`n > 0`).

WHY THE RECURSION AND NOT THE TWO OBVIOUS SHORTER SPELLINGS (both MEASURED by
the audit, both rejected by this lane):
`String.concat (List.repeat n s)` is a type error — MEASURED `cannot unify
List a with String` — because the alias table maps `String.concat` to
`Prelude.concat`, which is the LIST concat (`List (List a) -> List a`,
Resolve.elm:150); that is a latent alias-table bug this unit cannot fix
(Resolve.elm is outside its write scope), and the reason the spelling is not
used rather than a reason to work around it. A recursive `acc ++ s` accumulator
inside a let-bound `go : Int -> String -> String` is MEASURED to be rejected as
`ambiguous (++)`; INTERPRETATION: the appendable var is only ever unified with
`go`'s annotation, which this checker does not zonk the appendable through. The
`++` below is MEASURED to resolve — INTERPRETATION: because its other branch is
the literal `""`, which pins the node's type to String.
-}
repeatText : Int -> String -> String
repeatText n s =
    if n <= 0 then
        ""

    else
        s ++ repeatText (n - 1) s


{-| The snippet: the gutter, the margin character, the line's own text, and —
for a single-line span only — the caret line.

THE GUTTER WIDTH is the digit count of the LAST displayed line number, which is
Elm's rule (`render`'s `width = length (show (fst (last relevantLines)))`,
Code.hs:113). With exactly ONE displayed line (the only case today — see the
module note) "last" and "only" are the same number, so the choice is
unobservable now; it is written as a fold over `shown` because it is the rule
that stays correct for several lines (numbers ascend, so the last is the widest,
e.g. 9 → 12 gives width 2 and `" 9|"`).

AN EMPTY `line` (the span points at a blank line, or the source is empty — U3's
EOF/empty row pins `Ast.renderSpan "" { start = 0, end = 0 }` to `row 1, line
""`) is printed VERBATIM: `NN|` plus the margin and nothing after it, followed
by the caret line. No placeholder text (`<blank line>`) is invented — it would
land in the hashed payload and read as source — and the gutter is never
dropped, because the row number is then the only position left to report.

THE CARET is `max 1 (endCol - startCol)` carets starting at `startCol` (1-based,
inclusive start / exclusive end from `Ast.renderSpan`), indented by
`startCol - 1` spaces after the margin — Elm's `replicate (c1 + width + 1) ' '`
under the gutter's `width + 1` characters and its one spacer (Code.hs
`makeUnderline`/`addLineNumber`). `Ast` already clamps the run to the node's own
text and gives an empty run ONE caret, so a caret can never be zero-width here.

A MULTILINE span takes `>` as the margin on its line and gets NO caret line —
Elm's signal that the caret cannot be placed (`makeUnderline` returns `Nothing`
when `start /= end`).
-}
snippet : String -> Ast.Span -> List String
snippet source span =
    let
        at =
            Ast.renderSpan source span

        shown =
            [ ( at.row, at.line ) ]

        width =
            String.length
                (String.fromInt
                    (Maybe.withDefault 1
                        (List.head (List.reverse (List.map Tuple.first shown)))
                    )
                )

        gutter number =
            let
                digits =
                    String.fromInt number
            in
            repeatText (width - String.length digits) " " ++ digits ++ "|"

        margin =
            if at.multiline then
                ">"

            else
                " "

        caretLine =
            if at.multiline then
                []

            else
                [ gutter at.row
                    ++ margin
                    ++ repeatText (max 0 (at.startCol - 1)) " "
                    ++ repeatText (max 1 (at.endCol - at.startCol)) "^"
                ]
    in
    List.map (\( number, text ) -> gutter number ++ margin ++ text) shown
        ++ caretLine


{-| Greedy word fill at `width`, breaking ONLY at spaces.

A SINGLE TOKEN WIDER THAN `width` IS EMITTED WHOLE on its own line, so that line
EXCEEDS the width. That is the one place this renderer prints a long line, and
it is the right trade: the payload's consumers grep for fragments of the rule
(`grep -q` rows, and a human quoting the text back), so a mid-token break would
split the very string they search for. Elm's `fillSep` behaves the same way.

`words` is the splitter, so runs of spaces collapse and a blank `rule` yields
one empty line rather than no line — the banner/blank/rule/blank skeleton must
not collapse when a message's prose is empty.
-}
wrap : Int -> String -> List String
wrap width text =
    let
        step word ( line, earlier ) =
            if line == "" then
                ( word, earlier )

            else if String.length line + 1 + String.length word <= width then
                ( line ++ " " ++ word, earlier )

            else
                ( word, line :: earlier )

        ( pending, earlierLines ) =
            List.foldl step ( "", [] ) (words text)

        filled =
            List.reverse
                (if pending == "" then
                    earlierLines

                 else
                    pending :: earlierLines
                )
    in
    if List.isEmpty filled then
        [ "" ]

    else
        filled


{-| The words of a text: its maximal runs of non-whitespace, in order.

`String.words` is NOT in this language's String surface (MEASURED: the self-host
front end rejects it), so the split is spelled with `String.toList`,
`String.fromChar` and `++`, which are. WHITESPACE is the same four characters
`Ast.dropTrailingSpace` names — space, `\t`, `\r`, `\n` — which is what a `rule`
or `hint` can carry: both are built from source text and message literals, and
neither contains a newline (the renderer would be wrapping a line that is already
one).

ONE DEVIATION, stated: an EMPTY (or all-whitespace) text yields NO word, where
`String.words` yields one empty word. It is unobservable at the only caller:
`wrap` maps "no word" and "one empty word" onto the same single empty line (its
`List.isEmpty filled` arm), which is exactly the skeleton the prose must not
collapse.
-}
words : String -> List String
words text =
    let
        step c ( current, earlier ) =
            if isSpaceChar c then
                if current == "" then
                    ( "", earlier )

                else
                    ( "", current :: earlier )

            else
                ( current ++ String.fromChar c, earlier )

        ( pending, earlierWords ) =
            List.foldl step ( "", [] ) (String.toList text)
    in
    if pending == "" then
        List.reverse earlierWords

    else
        List.reverse (pending :: earlierWords)


{-| The whitespace `words` splits on, and the set `Ast.dropTrailingSpace` drops
— the four characters a `.mid`/`.elm` source carries between tokens.
-}
isSpaceChar : Char -> Bool
isSpaceChar c =
    c == ' ' || c == '\t' || c == '\r' || c == '\n'
