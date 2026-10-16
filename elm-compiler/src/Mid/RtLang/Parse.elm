module Mid.RtLang.Parse exposing
    ( expression
    , parseBlock
    , parseDefun
    , parseExp
    , parseModule
    , parseProgram
    )

{-| Mid.RtLang.Parse — the surface-language parser for the runtime
(tier-2 plan, `handoff-osier-tier2-midlang-plan`, THE GRAMMAR).
The Mid-written runtime (`Mid.RtPrims` / `Mid.RtGc`, ~9k lines of
hand-numbered DSL builders) is being migrated onto a small C-like surface
text; this module turns that text into `Mid.RtLang.Ast` — the EXPRESSION
layer (T2) plus, since T3, the CONTAINER layer: statements, blocks,
defuns and the `@flag` guards.  The typechecker (J1-J10) follows with
T4/T5; the lowering with T6.  Nothing outside `TestMain` imports this
module yet — T7 wires the pipeline in, so the compiler's emitted behaviour
is unchanged until then (the corpus is the emit-inert oracle).

BACKEND-NEUTRAL (the `Mid.Rt` contract, Rt.elm:17-21): imports are
`Mid.RtLang.Ast`, the vendored `ParserFast`, and the `Parser` DeadEnd
error-surface stub.  No QBE type and no `Mid.Ir` type appears here.

NO LEXER PASS.  `ParserFast` is char-level, so tokenization and parsing
are one pass.  Its header warns about two things, and the grammar answers
both:

  * whitespace commits — the discipline here is "every token consumes its
    own trailing whitespace" (`spelled`, `atom`, `followedBySkipWhileWhitespace`),
    and every level's OPERATOR step is chosen by PEEKING the source
    (`opStep` reads 3 chars and dispatches on an exact table) instead of
    committing `symbol` attempts, so a non-match never leaves a committed
    state and the operator loops of `loopWhileSucceeds...` back up cleanly;
  * oneOf commit-on-first-match — `atom` dispatches by peeking one
    character, so alternatives are chosen, never raced.

THE PRECEDENCE TABLE (pinned, C convention; rows 1-10 all LEFT-associative,
row 0 RIGHT-associative — the C conditional's own associativity; the DSL
has no precedence because Elm nesting is explicit — this table is the
surface's only grouping rule besides parentheses):

    0  ?:            EIf           cond :val, branches AGREE on a class
    1  ||            EShortOr      val,val -> val
    2  &&            EShortAnd     val,val -> val
    3  |             EWordBin      word
    4  ^             EWordBin      word
    5  &             EWordBin      word
    6  == != f== f!= EWordCmp / EFltCmp
    7  < <= > >= f< f<= f> f>=
    8  << >> >>>     EWordBin      (>> is arithmetic, >>> zero-fill)
    9  + - f+ f-     EWordBin / EFltBin
    10 * / f* f/     EWordBin / EFltBin    (tightest)
    atom literals, names, call/rawcall/aggcall, builtins,
       if (c) {..} else {..}   EIfBlock   (T23 — an ATOM: the block-branch
       if expression, else REQUIRED; the statement/term `if` is a
       DIFFERENT path — `itemStepAt`'s own arm — and is unchanged)
       (expression), withroots [..] ..

A compare yields a WORD 0/1, never a bool — the DSL's
`mkBool (cmpW ...)` boxing discipline is a T4 concern, but the shape the
parser produces is exactly `EWordCmp`/`EFltCmp` (Ast's J1 table).

SPELLING DECISIONS pinned here (each is a MEASURED grammar fact or a
deliberate, documented restriction):

  * `true`/`false` are sugar for `mkbool(1)`/`mkbool(0)`; `mknil` is a
    bare literal keyword (the plan lists it among the literals) — it takes
    no parentheses.
  * Whitespace is space, newline and carriage return ONLY — the vendored
    `skipWhileWhitespace` handles exactly those three; a tab is a loud
    reject.  The surface text (like the rest of this repo) uses spaces.
  * `//` to end of line is a COMMENT (M0), dropped at parse: nothing in
    `Mid.RtLang.Ast`, the checker or the lowerer sees it, and a comment
    never becomes a statement.  A comment IS whitespace — the local
    `skipWsCommentsFollowedBy` / `followedBySkipWsComments` replace the
    vendored whitespace combinators and skip it at EVERY whitespace-legal
    position (before/after a defun, between statements, after a statement,
    at end of file), so a comment also serves as a REQUIRED separator
    between two tokens (`defun //c\nRt.f(..)`).
    THE ONE RESTRICTION: a comment may not ABUT a bare token — a `//`
    whose immediately preceding character is a token character
    (`[A-Za-z0-9_.]`, `isTokenChar`) is NOT a comment.  So `a //c`, `;//c`
    and `)//c` are comments, while `a//b` is `a`, then the `/` operator,
    then `/b` in operand position — a LOUD parse error, never a silent
    truncation of `a` to `a`.  This is what keeps the token readers (whose
    KEY charset includes `/`) authoritative: a `//` inside a would-be key
    is read as part of the token and rejected by key validation, never
    truncated.  A `//` inside a string literal is string content —
    `stringChunkAt` never consults the skipper.  The newline that ends a
    comment stays (it is whitespace the vendored skipper already handles),
    so line/column numbers keep their meaning.
  * Float operators are `f+ f- f* f/`, float compares `f< f<= f> f>= f== f!=`.
    They are recognized ONLY in operator position, and the f itself must
    be AT the operator position — the token reader has already eaten a
    name's leading `f`, so `x f+ y` is a float add while `f+3` lexes as
    the variable `f` plus 3, and `f<3` is `f < 3` (a word compare).
    Spaces decide; a class confusion left over is T4's loud reject.
  * Negative literals (T8b): a `-` IMMEDIATELY followed by digits in
    operand position is one negative number literal (`-2` is `EInt -2`,
    NOT `0 - 2` — `Rt.close` tests a result against `Lit (LNumber -2)` and
    only a literal node is that tree).  A `-` in INFIX position is still
    binary subtraction (`x - 2`), and a `-` not touching its digits is the
    loud no-unary-minus reject (`- 2`, `-x`, a bare `-`) — the whitespace
    rule is what keeps `x -2` (an operator followed by a positive literal)
    and `f-3` (the variable `f` minus 3) parsing exactly as before.
  * `?:` (T9b) is the VALUE JOIN in expression position — row 0, the
    loosest binding, so `a || b ? c : d` reads `(a || b) ? c : d` and a
    call argument's comma still splits `f(x ? y : z, w)` in two (the
    comma is no operator's token).  It is RIGHT-associative (C
    convention): the THEN branch is parsed at the FULL expression level
    (so `a ? b ? c : d : e` nests in the middle — `?:` consumes its own
    `:`, making the two-colon shape unambiguous) and the ELSE branch
    re-enters the `?:` level (so `a ? b : c ? d : e` nests right).  It is
    deliberately the ONLY surface spelling: no `if (c) { e1 } else { e2 }`
    in expression position — `if` is a legal plain VARIABLE there today,
    the statement `if` keeps its block-position dispatch untouched, and no
    measured Rt body needs a second spelling.  `?` and `:` are neither
    token nor key characters, so the expression lexer is untouched and no
    existing parse moves (a `?` after an expression was a parse error
    before this level existed).
  * Key charset (T8b): keys are read ONLY in key positions — the defun
    header and a `call` name — by `keyTokenAt`, whose charset adds
    `- + = < >` to the general token's `[A-Za-z0-9_.]`, plus `@` (T12 —
    `Rt.@p` is a real key and the guard parser only ever sees `@` BEFORE
    the `defun` keyword, so a key-position `@` is unambiguous), plus
    `* / ?` (T20 — `Rt.*`, `Rt./`, `Rt.f/` and the four `?` tag-predicate
    keys are real keys; `?` is safe because keys are read only in the two
    key positions, both followed by `(`, so the expression lexer — and the
    `?:` join it owns — is untouched).  The nine added characters are
    MEASURED over the real `Rt.*` key set
    (`Rt.write-byte`, `Rt.exec-run`, `Rt.address->`, `Rt.<-address`,
    `Rt.@p`, `Rt.=`, `Rt.+`, `Rt.-`, `Rt.>=`, `Rt.<=`, `Rt.>`, `Rt.<`,
    `Rt.shen.str->bytes`, `Rt.*`, `Rt./`, `Rt.f/`, `Rt.number?`,
    `Rt.string?`, `Rt.cons?`, `Rt.empty?`); the expression
    lexer is UNCHANGED, so a body's `-` is still binary minus and an
    unspaced `x-2` still lexes as subtraction.  The three ambiguities this
    creates are pinned by the rules themselves: a key ending `->` stops at
    the `(` the header requires next (so `defun Rt.address->(..) -> ..`
    keeps its arrow); `=` is a key char but a body's `ty x = e;` bind and
    `==` compare are read by the expression layer, not the key reader; and
    a key never crosses whitespace, so `call Rt.write - byte(..)` is a
    loud `expected (` reject, never a key+subtraction.  `isValidKey`'s
    shape rule accepts every measured shape (segments may be pure symbols,
    start with `<`, end with `>`, carry an inner `->`); resolution is
    still J2's (`Rt.` prefix + the defun/extern tables).
  * String literals are ASCII (32..126, no raw newline) with escapes
    `\n \t \r \0 \" \\`; anything else is a loud reject.  The runtime
    interns bytes, and every DSL string is ASCII today.
  * Integer literals accept decimal and `0x` hex, under the vendored
    parser's exactness rules (<= 2^53, no leading zeros); floats accept
    the vendored float forms (`1.5`, `1e3`, `1.5e-3`).
  * `payload(v)` / `payload32(v)` are shorthand for index 0; the index
    slot of `payload`/`payload32`/`tagis` is an INTEGER LITERAL token,
    because `RawPayload.word` / `RawTagIs.tag` are constants inside the
    lowered node (Ast's header) — a computed index is unrepresentable, so
    the parser rejects it rather than emitting an AST that cannot lower.
  * `call` takes the full dotted Rt key (`call Rt.getpid(..)`); `rawcall`
    a C-style symbol (no dots); `aggcall` a `ret`/`val` shape then a
    primary fn expression then its argument list (0 uses today; shape
    pinned for stage-6).
  * The parser is ARITY-BLIND except for those literal slots: argument
    counts and classes are the T4 checker's judgments (J1/J2/J3), read
    from `Ast.builtinClass` / `Ast.rawcallArity`.
  * `withroots [ids] { block }` — the `[ids]` list (T2) and the block
    body (T3) meet in `withrootsExp`; the form's value is the block's
    terminator.

THE CONTAINER LAYER (T3).  `program := defun*`,
`defun := ['@'flag | '@!'flag]{1+} 'defun' Key '(' [id ':' ty {',' id ':' ty}] ')'
'->' ty block`, `block := stmt* term`, `stmt := ty id '=' exp ';' | exp ';' |
'if' (exp) block ['else' block]`, `term := 'return' exp ';' |
'recur' '(' [exps] ')' ';' | 'if' (exp) block ['else' block]` — the plan's
grammar, verbatim, with the guard slot generalized to a CONJUNCTION (T10:
the `{1+}` — RtPrims' eqDefun varies by `rec` AND `eqPtrFast`, so `Rt.=`
needs `@rec @eqPtrFast`; guardsHold folds the list, J8 counts whole-list
holds per key, and a one-guard defun parses exactly as before).  The
mechanism points, each MEASURED off the vendored
parser's commit semantics:

  * A block is a FOLD over `Item = IStmt | ITermEnd`
    (`loopWhileSucceedsOntoResultFromParser`), then `validate`: exactly one
    terminator, and NOTHING after it (a statement smuggled past the term
    would be silently dropped or reordered by the fold — that state is a
    loud reject, never a silent fold).  `return`/`recur` arms produce
    `ITermEnd`; `word/float/val` arms produce `SBind`; any other token
    starts an effect statement.
  * The `if` SIf/TIf ambiguity resolves by PEEKING after the if has
    parsed: if `}` follows, the if was the block's terminator (`TIf`);
    otherwise it was a mid-block statement (`SIf`).  Both peek arms
    SUCCEED — the decision must never be a failed `map2` second slot,
    because `map2` promotes even a non-committed failure to committed
    (that promotion is also how `commit` works, below).
  * Handbacks.  The fold's loop stops only on a NON-committed failure
    (`problem` is exactly that), so the tokens that mean "this block's
    statement list is over" — a stray `else` (the enclosing `if` already
    took its else), the next `defun`, `}`, `@`, end of input — are
    non-committed handbacks, never parse errors.
  * `commit` — after a dispatch has matched (`if` seen, `@` seen), every
    continuation failure is a REAL error and must be reported as one;
    `commit parser = map2 (\\_ r -> r) (succeed ()) parser` uses the map2
    promotion to turn the parser's non-committed failure loud.  `if`
    without parentheses is THE example: without it, the if-arm would
    silently hand back and the block would report a misleading
    missing-terminator error.
  * RESERVED at statement/defun positions: `word float val if return
    recur else defun` (dispatch reads them first — a statement cannot
    START with one of them as an expression).  Inside expressions T2's
    rules are unchanged EXCEPT T23's `if`, which is now the block-branch
    if EXPRESSION's keyword (an `if` token in expression position parses
    `if (c) {..} else {..}` — it is no longer a legal plain variable
    there; a surface BINDER may still be NAMED `if` at declaration but
    cannot be read as an expression).  Binder SPELLING is otherwise
    unchecked here (any plain name) — names are the checker's judgments
    (J5).
  * `recur` is a TERM only, per the plan (L4): a mid-block `recur`
    becomes a second terminator and the exactly-one-terminator reject
    fires; the loop-state-completeness judgment on it is T5's (J4).

MID-LANE HAZARD (MEASURED, Rt.elm:531-545): the selfhost front end
resolves let binders strictly in order, so every helper here — including
the mutually recursive ones (`atom` ⇄ `expression` through `parenExp`) —
is a TOP-LEVEL definition, never let-bound.  The recursion closes through
`atomAt`'s function body, which Elm accepts for top-level definitions;
T3's cycles (`block` ⇄ `itemStep` ⇄ `ifTail`, `defun` ⇄ `block`) close the
same way, through top-level function bodies only.
The selfhost's CORE surface is also narrower than elm/core (MEASURED,
Lower/Resolve.elm's dotted rows): this module uses only `String.slice /
toList / any / startsWith / length / fromInt / join`, `Char.isAlpha /
isDigit / isAlphaNum / isUpper / isLower / toCode`, `List.map / singleton /
reverse`, `Dict.get / fromList` — no `String.uncons / left / split / contains`,
and — per the O(n) invariant in the token-plumbing section — NO
`dropLeft` anywhere (the pre-fix form, an O(n^2) scanner).

-}

import Dict exposing (Dict)
import Mid.RtLang.Ast exposing (AggShape(..), Block, Builtin(..), Defun, Effect(..), Exp(..), Export, ExportSig, Flag(..), FlagGuard(..), FltBinOp(..), FltCmpOp(..), Header, Module, OTy(..), Param, Program, Stmt(..), Term(..), Type(..), WordBinOp(..), WordCmpOp(..), builtinName)
import Parser exposing (DeadEnd, Problem(..))
import ParserFast



-- ============================ entry points ============================


{-| Parse one surface expression and require it to be the whole input.
The error is a rendered `row:col: message` list (ParserFast's DeadEnd
surface) — loud, with position, as the checker T4 will also be.
-}
parseExp : String -> Result String Exp
parseExp src =
    resultOfRun parseTarget src


{-| The shared whole-input run for every `parse*` entry: the value on a
full match, otherwise the rendered `row:col: message` list (ParserFast's
DeadEnd surface) — loud, with position, as the checker T4 will also be.
-}
resultOfRun : ParserFast.Parser res -> String -> Result String res
resultOfRun parser src =
    case ParserFast.run parser src of
        Ok res ->
            Ok res

        Err deadEnds ->
            Err (String.join "; " (List.map deadEndToString deadEnds))


{-| Parse a WHOLE PROGRAM (`defun*`) — `Mid.RtLang.Ast.Program`.
-}
parseProgram : String -> Result String Program
parseProgram src =
    resultOfRun programTarget src


{-| Parse a WHOLE `.mid` MODULE: the OPTIONAL header (module name + export
block) followed by `defun*` — `Mid.RtLang.Ast.Module`.  `load` uses this;
`parseProgram` stays the headerless defun-list form the checker/lowerer
rows feed.
-}
parseModule : String -> Result String Module
parseModule src =
    resultOfRun moduleTarget src


parseDefun : String -> Result String Defun
parseDefun src =
    resultOfRun defunTarget src


parseBlock : String -> Result String Block
parseBlock src =
    resultOfRun blockTarget src


{-| The whole-input parser behind `parseExp`: leading whitespace, the
expression, trailing whitespace; `ParserFast.run` enforces EOF.
-}
parseTarget : ParserFast.Parser Exp
parseTarget =
    followedBySkipWsComments expression


{-| The expression grammar's root (the `?:` value join — row 0, loosest:
see `ifExpLevel`), skipping leading whitespace.  Exported for T3, which
embeds expressions inside statements and blocks — everything here is
re-enterable at any position because the entry skip and the per-token
trailing skip compose.
-}
expression : ParserFast.Parser Exp
expression =
    skipWsCommentsFollowedBy ifExpLevel



-- ============================ precedence chain ============================


{-| Row 0 — the `?:` value join, binding LOOSER than `||` and TIGHTER than
a call argument's comma (which is no operator's token).  The level parses
its test at the `||` level, then PEEKS: a `?` commits the conditional
(then-branch = a full expression, `:` required, else-branch = this level
again — right-associative, C convention); no `?` and the test stands
alone.  The peek is `offsetSourceAndThen` on the position AFTER the test
(the `ifItem` pattern), so a non-match never leaves a committed state.
-}
ifExpLevel : ParserFast.Parser Exp
ifExpLevel =
    ParserFast.map2
        (\test tail -> tail test)
        orLevel
        ifExpTail


ifExpTail : ParserFast.Parser (Exp -> Exp)
ifExpTail =
    ParserFast.offsetSourceAndThen ifExpTailAt


ifExpTailAt : Int -> String -> ParserFast.Parser (Exp -> Exp)
ifExpTailAt offset src =
    if String.slice offset (offset + 1) src == "?" then
        spelled "?"
            (ParserFast.map2
                (\thn els test -> EIf test thn els)
                expression
                (spelled ":" ifExpLevel)
            )

    else
        succeed identity


{-| `binaryLeft step operand` — a LEFT-associative operator loop: parse
`operand`, then while an operator of this level matches, fold
`mk lhs rhs` over the accumulated left side.  A non-matching step ends
the loop without consuming (the peek dispatch fails non-committed); a
step that MATCHED its operator but then lost its operand is a hard
committed error (`1 +` never silently re-associates).
-}
binaryLeft : ParserFast.Parser (Exp -> Exp) -> ParserFast.Parser Exp -> ParserFast.Parser Exp
binaryLeft step operand =
    ParserFast.loopWhileSucceedsOntoResultFromParser
        step
        operand
        applyLeft
        identity


applyLeft : (Exp -> Exp) -> Exp -> Exp
applyLeft f lhs =
    f lhs


{-| One operator level's step: peek 3 chars (the longest operator is 3:
`>>>`, `f<=`, `f==`), dispatch on an exact longest-first table, and on a
match consume the operator, the whitespace after it, and the (tighter)
right operand.  The third table field is a banned continuation char for
the cross-level maximal-munch pairs: `&` must not eat the first `&` of
`&&`, `|` of `||`, `<` of `<<`, `>` of `>>`/`>>>` (within one level the
longest-first table order already handles `<=`/`<`, `f<=`/`f<`, `>>>`/`>>`).
-}
opStep : List ( String, Exp -> Exp -> Exp, String ) -> ParserFast.Parser Exp -> ParserFast.Parser (Exp -> Exp)
opStep table operand =
    -- runs for EVERY operand at EVERY precedence level (the binaryLeft
    -- chain is ~11 levels deep), so the peek must be O(1): a 3-char slice
    -- at the offset, never a `dropLeft` of the tail (that would copy the
    -- remaining input once per level per token -> O(n^2) over the file)
    ParserFast.offsetSourceAndThen
        (\offset src -> opAt table operand (String.slice offset (offset + 3) src))


opAt : List ( String, Exp -> Exp -> Exp, String ) -> ParserFast.Parser Exp -> String -> ParserFast.Parser (Exp -> Exp)
opAt table operand peek3 =
    case table of
        [] ->
            -- a non-operator ends the loop without consuming; this problem
            -- is discarded by `loopWhileSucceeds...` and never reported
            ParserFast.problem "expected an operator"

        ( sym, mk, banned ) :: rest ->
            if
                String.startsWith sym peek3
                    && not (banned /= "" && String.startsWith banned (String.slice (String.length sym) 3 peek3))
            then
                opStepArm mk sym operand

            else
                opAt rest operand peek3


opStepArm : (Exp -> Exp -> Exp) -> String -> ParserFast.Parser Exp -> ParserFast.Parser (Exp -> Exp)
opStepArm mk sym operand =
    ParserFast.symbolFollowedBy sym
        (skipWsCommentsFollowedBy
            (ParserFast.map (\rhs lhs -> mk lhs rhs) operand)
        )


orLevel : ParserFast.Parser Exp
orLevel =
    binaryLeft (opStep shortOrTable andLevel) andLevel


andLevel : ParserFast.Parser Exp
andLevel =
    binaryLeft (opStep shortAndTable bitOrLevel) bitOrLevel


bitOrLevel : ParserFast.Parser Exp
bitOrLevel =
    binaryLeft (opStep bitOrTable bitXorLevel) bitXorLevel


bitXorLevel : ParserFast.Parser Exp
bitXorLevel =
    binaryLeft (opStep bitXorTable bitAndLevel) bitAndLevel


bitAndLevel : ParserFast.Parser Exp
bitAndLevel =
    binaryLeft (opStep bitAndTable eqLevel) eqLevel


eqLevel : ParserFast.Parser Exp
eqLevel =
    binaryLeft (opStep eqTable relLevel) relLevel


relLevel : ParserFast.Parser Exp
relLevel =
    binaryLeft (opStep relTable shiftLevel) shiftLevel


shiftLevel : ParserFast.Parser Exp
shiftLevel =
    binaryLeft (opStep shiftTable addLevel) addLevel


addLevel : ParserFast.Parser Exp
addLevel =
    binaryLeft (opStep addTable mulLevel) mulLevel


mulLevel : ParserFast.Parser Exp
mulLevel =
    binaryLeft (opStep mulTable atom) atom


{-| The operator tables, longest-first within a level.  Every row is 1:1
with an `Ast` constructor (word binops / word compares / float binops /
float compares / the two short-circuit forms).
-}
shortOrTable : List ( String, Exp -> Exp -> Exp, String )
shortOrTable =
    [ ( "||", EShortOr, "" ) ]


shortAndTable : List ( String, Exp -> Exp -> Exp, String )
shortAndTable =
    [ ( "&&", EShortAnd, "" ) ]


bitOrTable : List ( String, Exp -> Exp -> Exp, String )
bitOrTable =
    [ ( "|", EWordBin WBitOr, "|" ) ]


bitXorTable : List ( String, Exp -> Exp -> Exp, String )
bitXorTable =
    [ ( "^", EWordBin WBitXor, "" ) ]


bitAndTable : List ( String, Exp -> Exp -> Exp, String )
bitAndTable =
    [ ( "&", EWordBin WBitAnd, "&" ) ]


eqTable : List ( String, Exp -> Exp -> Exp, String )
eqTable =
    [ ( "f==", EFltCmp FEq, "" )
    , ( "f!=", EFltCmp FNe, "" )
    , ( "==", EWordCmp WCeq, "" )
    , ( "!=", EWordCmp WCne, "" )
    ]


relTable : List ( String, Exp -> Exp -> Exp, String )
relTable =
    [ ( "f<=", EFltCmp FLe, "" )
    , ( "f>=", EFltCmp FGe, "" )
    , ( "f<", EFltCmp FLt, "" )
    , ( "f>", EFltCmp FGt, "" )
    , ( "<=", EWordCmp WCles, "" )
    , ( ">=", EWordCmp WCges, "" )
    , ( "<", EWordCmp WClts, "<" )
    , ( ">", EWordCmp WCgts, ">" )
    ]


shiftTable : List ( String, Exp -> Exp -> Exp, String )
shiftTable =
    [ ( ">>>", EWordBin WShR, "" )
    , ( ">>", EWordBin WShAr, "" )
    , ( "<<", EWordBin WShl, "" )
    ]


addTable : List ( String, Exp -> Exp -> Exp, String )
addTable =
    [ ( "f+", EFltBin FAdd, "" )
    , ( "f-", EFltBin FSub, "" )
    , ( "+", EWordBin WAdd, "" )
    , ( "-", EWordBin WSub, "" )
    ]


mulTable : List ( String, Exp -> Exp -> Exp, String )
mulTable =
    [ ( "f*", EFltBin FMul, "" )
    , ( "f/", EFltBin FDiv, "" )
    , ( "*", EWordBin WMul, "" )
    , ( "/", EWordBin WDiv, "" )
    ]



-- ============================ atoms ============================


{-| An atom, entered at a non-whitespace character (every token before it
consumed its trailing whitespace).  Dispatches by peeking one character:
deterministic, no oneOf races.
-}
atom : ParserFast.Parser Exp
atom =
    ParserFast.offsetSourceAndThen atomAt


atomAt : Int -> String -> ParserFast.Parser Exp
atomAt offset src =
    case String.slice offset (offset + 1) src of
        "(" ->
            parenExp

        "\"" ->
            stringLit

        "-" ->
            negAtom offset src

        "" ->
            ParserFast.problem "expected an expression, found end of input"

        c ->
            if isTokenStart c then
                tokenAtom offset src

            else
                ParserFast.problem ("expected an expression, found `" ++ c ++ "`")


parenExp : ParserFast.Parser Exp
parenExp =
    -- entered at the `(` peeked by `atomAt`; `expression` skips the
    -- whitespace after it, and its last token has already consumed the
    -- whitespace before the `)`
    ParserFast.symbolFollowedBy "("
        (ParserFast.map2 (\e _ -> e)
            expression
            (spelled ")" (succeed ()))
        )


{-| A token-shaped atom: number literal or name.  The token read is pure
(`tokenAtOff` — a peek, no state advance); the chosen continuation
re-consumes it with an exact `symbol` match, so the state advance stays
inside the library.
-}
tokenAtom : Int -> String -> ParserFast.Parser Exp
tokenAtom offset src =
    case tokenAtOff offset src of
        Nothing ->
            -- unreachable: `atomAt` only gets here after a token-start peek
            ParserFast.problem "expected an expression"

        Just ( tok, _ ) ->
            if isNumberToken tok then
                numberAtom tok

            else
                nameAtom tok


numberAtom : String -> ParserFast.Parser Exp
numberAtom tok =
    -- the vendored number parser owns literal semantics: decimal/hex ints
    -- (exactness-checked, no leading zeros) and the float forms
    case ParserFast.run numberLitParser tok of
        Ok exp ->
            spelled tok (succeed exp)

        Err deadEnds ->
            ParserFast.problem ("malformed number literal `" ++ tok ++ "`: " ++ firstProblem deadEnds)


numberLitParser : ParserFast.Parser Exp
numberLitParser =
    ParserFast.floatOrIntegerDecimalOrHexadecimalMapWithRange
        (\_ f -> EFlt f)
        (\_ n -> EInt n)
        (\_ n -> EInt n)


{-| A negative number literal, entered at the `-` peeked by `atomAt`: the
pinned rule (module header) is that `-` must IMMEDIATELY touch its
digits — a space or a name after it is the loud no-unary-minus reject,
never a silent `0 - x` rewrite.  `tokenAtOff` at the position after the
`-` returns `Nothing` for both the `- 2` and bare-`-` shapes and a name
token for `-x`; the digits path re-reads the number with the negating
parser below.
-}
negAtom : Int -> String -> ParserFast.Parser Exp
negAtom offset src =
    case tokenAtOff (offset + 1) src of
        Just ( tok, _ ) ->
            if isNumberToken tok then
                negNumberAtom tok

            else
                ParserFast.problem noUnaryMinusMsg

        Nothing ->
            ParserFast.problem noUnaryMinusMsg


noUnaryMinusMsg : String
noUnaryMinusMsg =
    "`-` starts no expression — a negative literal is `-` immediately followed by digits (no unary minus; write `0 - x`)"


negNumberAtom : String -> ParserFast.Parser Exp
negNumberAtom tok =
    -- `tok` is the DIGITS token — the `-` was peeked by `atomAt`, never
    -- consumed — so the vendored number parser owns it directly (same
    -- decimal/hex/float forms and exactness rules; the old form parsed
    -- `dropLeft 1 ("-" ++ tok)`, which is exactly `tok`).  The
    -- `spelled` re-consumes `-<tok>` and its trailing whitespace in one
    -- exact match.
    case ParserFast.run negNumberLitParser tok of
        Ok exp ->
            spelled ("-" ++ tok) (succeed exp)

        Err deadEnds ->
            ParserFast.problem ("malformed number literal `-" ++ tok ++ "`: " ++ firstProblem deadEnds)


{-| `numberLitParser` with every result negated — written as `0 - n`
(the repo's selfhost-safe negation style, Prelude.elm:1262), so a `-2`
in operand position lowers to the single `Lit (LNumber -2)` node
`Rt.close`'s comparison needs, not a `RawBin RSub`.
-}
negNumberLitParser : ParserFast.Parser Exp
negNumberLitParser =
    ParserFast.floatOrIntegerDecimalOrHexadecimalMapWithRange
        (\_ f -> EFlt (0 - f))
        (\_ n -> EInt (0 - n))
        (\_ n -> EInt (0 - n))


{-| A name-shaped token: `true`/`false`/`mknil` sugar, the three call
forms, `withroots`, a builtin (read from `Ast.builtinName` — one spelling,
one place), or a plain variable.  Full-token matching, so `truex` and
`callx` are ordinary variables, never prefixes.
-}
nameAtom : String -> ParserFast.Parser Exp
nameAtom tok =
    case tok of
        "true" ->
            spelled tok (succeed (EBuiltin MkBool [ EInt 1 ]))

        "false" ->
            spelled tok (succeed (EBuiltin MkBool [ EInt 0 ]))

        "mknil" ->
            spelled tok (succeed (EBuiltin MkNil []))

        "call" ->
            spelled tok callExp

        "rawcall" ->
            spelled tok rawcallExp

        "aggcall" ->
            spelled tok aggcallExp

        "withroots" ->
            spelled tok withrootsExp

        "if" ->
            -- T23: the BLOCK-BRANCH if EXPRESSION (`if (c) {..} else {..}`
            -- in any value slot).  Statement-position `if` never reaches
            -- this arm — `itemStepAt` dispatches it to SIf/TIf first; the
            -- `?:` join is a different token (`?`) and keeps its own level.
            spelled tok ifBlockExp

        _ ->
            case Dict.get tok builtinTable of
                Just b ->
                    spelled tok (builtinCall b)

                Nothing ->
                    if hasDot tok then
                        ParserFast.problem
                            ("`" ++ tok ++ "` — a dotted name is only valid as a `call` key")

                    else
                        spelled tok (succeed (EVar tok))



-- ============================ string literals ============================


{-| `"..."` — ASCII only, no raw newline, escapes `\n \t \r \0 \" \\`.
Entered at the opening quote (peeked).  `loopUntil` tries the closing
quote BEFORE each chunk, so the chunk reader never sees one.
-}
stringLit : ParserFast.Parser Exp
stringLit =
    followedBySkipWsComments
        (ParserFast.symbolFollowedBy "\""
            (ParserFast.map EStr
                (ParserFast.loopUntil endQuote stringChunk "" (\chunk acc -> acc ++ chunk) identity)
            )
        )


endQuote : ParserFast.Parser ()
endQuote =
    ParserFast.symbol "\"" ()


stringChunk : ParserFast.Parser String
stringChunk =
    ParserFast.offsetSourceAndThen stringChunkAt


stringChunkAt : Int -> String -> ParserFast.Parser String
stringChunkAt offset src =
    case String.slice offset (offset + 1) src of
        "" ->
            ParserFast.problem "unterminated string literal"

        "\n" ->
            ParserFast.problem "string literals must not contain a raw newline"

        "\\" ->
            ParserFast.symbolFollowedBy "\\" (ParserFast.offsetSourceAndThen escapeAt)

        c ->
            if isSurfaceChar c then
                ParserFast.symbolFollowedBy c (succeed c)

            else
                ParserFast.problem
                    ("string literals are ASCII (printable, no raw newline) on the surface — found"
                        ++ surfaceCharReport c
                    )


{-| The one character after a backslash.  Unknown escapes are a loud
reject, never a silent pass-through.
-}
escapeAt : Int -> String -> ParserFast.Parser String
escapeAt offset src =
    case String.slice offset (offset + 1) src of
        "n" ->
            spelled "n" (succeed "\n")

        "t" ->
            spelled "t" (succeed "\t")

        "r" ->
            spelled "r" (succeed "\r")

        "0" ->
            spelled "0" (succeed "\u{0000}")

        "\"" ->
            spelled "\"" (succeed "\"")

        "\\" ->
            spelled "\\" (succeed "\\")

        "" ->
            ParserFast.problem "unterminated string literal (input ends after a backslash)"

        c ->
            ParserFast.problem
                ("unknown string escape `\\"
                    ++ c
                    ++ "` — supported: \\n \\t \\r \\0 \\\" \\\\"
                )



-- ============================ calls ============================


{-| `call Key(..)` — the Key is the full Rt name, dotted, verbatim
(`Rt.getpid`).  Key resolution and arity are J2 (T4); the parser takes
any dotted-or-plain name.
-}
callExp : ParserFast.Parser Exp
callExp =
    ParserFast.offsetSourceAndThen callAt


callAt : Int -> String -> ParserFast.Parser Exp
callAt offset src =
    case keyTokenAtOff offset src of
        Just ( tok, _ ) ->
            if isValidKey tok then
                spelled tok (ParserFast.map (ECall tok) argsInParens)

            else
                ParserFast.problem
                    ("expected a Rt key after `call` (dotted, e.g. Rt.getpid), found `" ++ tok ++ "`")

        Nothing ->
            ParserFast.problem "expected a Rt key after `call`"


{-| `rawcall sym(..)` — sym is a C-style name (letters, digits,
underscores; no dots).  Symbol membership and arity are J3 + `Ast.rawcallArity`
(T4).
-}
rawcallExp : ParserFast.Parser Exp
rawcallExp =
    ParserFast.offsetSourceAndThen rawcallAt


rawcallAt : Int -> String -> ParserFast.Parser Exp
rawcallAt offset src =
    case tokenAtOff offset src of
        Just ( tok, _ ) ->
            if isPlainName tok then
                spelled tok (ParserFast.map (ERawCall tok) argsInParens)

            else
                ParserFast.problem
                    ("expected a C-style symbol after `rawcall` (no dots), found `" ++ tok ++ "`")

        Nothing ->
            ParserFast.problem "expected a C-style symbol after `rawcall`"


{-| `aggcall ret|val f(..)` — the fn is a primary expression (so a
computed code pointer spells `(wload p 0)`); fn, args and result are all
words (Ast's EAggCall contract).  0 uses today; shape pinned for stage-6.
-}
aggcallExp : ParserFast.Parser Exp
aggcallExp =
    ParserFast.offsetSourceAndThen aggcallAt


aggcallAt : Int -> String -> ParserFast.Parser Exp
aggcallAt offset src =
    case tokenAtOff offset src of
        Just ( "ret", _ ) ->
            spelled "ret" (aggTail AggRet)

        Just ( "val", _ ) ->
            spelled "val" (aggTail AggVal)

        Just ( tok, _ ) ->
            ParserFast.problem
                ("expected `ret` or `val` after `aggcall`, found `" ++ tok ++ "`")

        Nothing ->
            ParserFast.problem "expected `ret` or `val` after `aggcall`"


aggTail : AggShape -> ParserFast.Parser Exp
aggTail shape =
    ParserFast.map2 (\fn args -> EAggCall shape fn args)
        atom
        argsInParens


{-| `withroots [ids] { block }` — the ids list is T2's (`withrootsIds`);
the block body is the T3 statement layer's (`block`).  The form's value
is the block's terminator (Ast's EWithRoots contract); the ids' `:val`
in-scope judgment is J10 (T5).
-}
withrootsExp : ParserFast.Parser Exp
withrootsExp =
    ParserFast.map2 EWithRoots withrootsIds block


withrootsIds : ParserFast.Parser (List String)
withrootsIds =
    spelled "["
        (ParserFast.oneOf2
            (spelled "]" (succeed []))
            (ParserFast.map2 (\ids _ -> ids)
                (ParserFast.map2 (::)
                    surfaceName
                    (ParserFast.loopWhileSucceeds (spelled "," surfaceName) [] (\x acc -> acc ++ [ x ]) identity)
                )
                (spelled "]" (succeed ()))
            )
        )


{-| A plain binder name (the ids of `withroots`, and the general
name-shaped token reader for keys/syms).
-}
surfaceName : ParserFast.Parser String
surfaceName =
    ParserFast.offsetSourceAndThen surfaceNameAt


surfaceNameAt : Int -> String -> ParserFast.Parser String
surfaceNameAt offset src =
    case tokenAtOff offset src of
        Just ( tok, _ ) ->
            if isPlainName tok then
                spelled tok (succeed tok)

            else
                ParserFast.problem ("expected a plain name, found `" ++ tok ++ "`")

        Nothing ->
            ParserFast.problem "expected a name"



-- ============================ builtins ============================


{-| Dispatch a builtin's argument grammar.  Everything but the
literal-slot builtins is a generic parenthesized argument list; the
parser is arity-blind (T4's J1 checks counts and classes against
`Ast.builtinClass`).
-}
builtinCall : Builtin -> ParserFast.Parser Exp
builtinCall b =
    case b of
        Payload ->
            payloadCall Payload

        Payload32 ->
            payloadCall Payload32

        TagIs ->
            tagIsCall

        RawStr ->
            rawStrCall

        RawSym ->
            rawSymCall

        _ ->
            ParserFast.map (EBuiltin b) argsInParens


{-| `payload(v)` / `payload(v, idx)` — the shorthand is index 0; the
index slot is an INTEGER LITERAL token because `RawPayload.word` is a
constant inside the lowered node (Ast's header).  A non-literal index is
unrepresentable in the AST's contract, so it is a parse reject.  The
`(` is consumed HERE (not by the argument's `expression`): grouping
parentheses and an argument list are the same characters, and the
builtin owns the paren it dispatched on.
-}
payloadCall : Builtin -> ParserFast.Parser Exp
payloadCall b =
    spelled "("
        (ParserFast.map3 (\v idx _ -> EBuiltin b [ v, EInt idx ])
            expression
            (ParserFast.oneOf2
                (spelled "," intLitArg)
                (succeed 0)
            )
            (spelled ")" (succeed ()))
        )


{-| `tagis(v, tag)` — always two arguments, the tag an integer literal
(`RawTagIs.tag` is a constant; the DSL's tag tests are literal-tagged).
Owns its `(` for the same reason as `payloadCall`.
-}
tagIsCall : ParserFast.Parser Exp
tagIsCall =
    spelled "("
        (ParserFast.map3 (\v tag _ -> EBuiltin TagIs [ v, EInt tag ])
            expression
            (spelled "," intLitArg)
            (spelled ")" (succeed ()))
        )


{-| `rawstr("...")` — a static C-string address (stage 6 U2).  The ONE
argument is a STRING LITERAL token (reusing `stringLit`, which owns the
opening quote) — a computed string is unrepresentable (the content is a
static data def), so the parser rejects anything else loud, the same
literal-slot discipline as `payloadCall`/`tagIsCall`.  Owns its `(`.
-}
rawStrCall : ParserFast.Parser Exp
rawStrCall =
    spelled "("
        (ParserFast.map2 (\s _ -> EBuiltin RawStr [ s ]) stringLit (spelled ")" (succeed ())))


{-| `rawsym("...")` — a FUNCTION-symbol address (stage 6 A1b).  The ONE
argument is a STRING LITERAL token naming a function (a code label:
rt_bounce/rt_callN/a q_Rt_* defun) — the same literal-slot discipline as
`rawStrCall` (a computed name is unrepresentable: the symbol is baked into
the lowered `RawSym` node).  Owns its `(`.
-}
rawSymCall : ParserFast.Parser Exp
rawSymCall =
    spelled "("
        (ParserFast.map2 (\s _ -> EBuiltin RawSym [ s ]) stringLit (spelled ")" (succeed ())))


{-| The integer-literal token reader for index/tag slots: decimal or hex
under the vendored exactness rules; no sign (indexes and tags are
non-negative by construction).
-}
intLitArg : ParserFast.Parser Int
intLitArg =
    ParserFast.offsetSourceAndThen intLitAt


intLitAt : Int -> String -> ParserFast.Parser Int
intLitAt offset src =
    case tokenAtOff offset src of
        Just ( tok, _ ) ->
            if isNumberToken tok then
                case ParserFast.run intLitParser tok of
                    Ok n ->
                        spelled tok (succeed n)

                    Err deadEnds ->
                        ParserFast.problem
                            ("malformed integer literal `" ++ tok ++ "`: " ++ firstProblem deadEnds)

            else
                ParserFast.problem
                    ("expected an integer literal (the index/tag), found `" ++ tok ++ "`")

        Nothing ->
            ParserFast.problem "expected an integer literal (the index/tag)"


intLitParser : ParserFast.Parser Int
intLitParser =
    ParserFast.integerDecimalOrHexadecimalMapWithRange (\_ n -> n) (\_ n -> n)


{-| Every builtin spelling, read from `Ast.builtinName` — the Ast table
stays the one source of truth for the surface's spellings.  (`mknil` is
dispatched as a bare literal in `nameAtom` before this table is
consulted; its row here keeps the table a faithful reverse of
`builtinName`.)
-}
allBuiltins : List Builtin
allBuiltins =
    [ MkNum
    , MkBool
    , MkNil
    , MkStr
    , MkFlt
    , MkVec
    , MkVal
    , Payload
    , Payload32
    , Len32
    , TagIs
    , VecLoad
    , VecAddr
    , VecStore
    , StrByte
    , ByteLoad
    , ByteStore
    , WordLoad
    , WordStore
    , AllocVec
    , AllocRaw
    , IToF
    , FLoad
    , FToI32
    , Sext
    , Uext
    , BitNot
    , RecLen
    , RawStr
    , RawSym
    ]


builtinTable : Dict String Builtin
builtinTable =
    Dict.fromList (List.map (\b -> ( builtinName b, b )) allBuiltins)



-- ============================ argument lists ============================


{-| `( a, b, .. )` — possibly empty (arity is the checker's judgment);
a trailing comma is a reject (C89 style, pinned).
-}
argsInParens : ParserFast.Parser (List Exp)
argsInParens =
    spelled "("
        (ParserFast.oneOf2
            (spelled ")" (succeed []))
            (ParserFast.map2 (\args _ -> args)
                (ParserFast.loopWhileSucceedsOntoResultFromParser
                    (spelled "," expression)
                    (ParserFast.map List.singleton expression)
                    (\e acc -> acc ++ [ e ])
                    identity
                )
                (spelled ")" (succeed ()))
            )
        )



-- ============================ programs, defuns, blocks ============================


{-| The program layer: `defun*`, each defun entered by dispatch (peek)
so the loop's end is a NON-committed handback, never a failed match.
-}
programTarget : ParserFast.Parser Program
programTarget =
    followedBySkipWsComments programDefuns


programDefuns : ParserFast.Parser Program
programDefuns =
    ParserFast.loopWhileSucceeds defun [] (\d acc -> acc ++ [ d ]) identity



-- ============================ the module header (M2) ============================


{-| The whole-module layer: an OPTIONAL header (the `module` name line and
the `export` block) then `defun*`.  Each header item is entered by the
same NON-committed peek dispatch as `defun` (`moduleNameLine` peeks for
`module`, `exportLine` for `export`), so a headerless module — and a
header followed by defuns — both back up cleanly and the defun loop owns
the `defun`/`@` dispatch.
-}
moduleTarget : ParserFast.Parser Module
moduleTarget =
    followedBySkipWsComments
        (ParserFast.map2 (\hdr defs -> { header = hdr, defuns = defs })
            header
            programDefuns
        )


{-| The header: `module Name` (optional, at most one, first), then
`export*`.  Both halves hand back their empty form without committing when
the next line is not theirs, so the whole header is OPTIONAL.
-}
header : ParserFast.Parser Header
header =
    ParserFast.map2
        (\mname exports -> { name = mname, exports = exports })
        moduleNameLine
        (ParserFast.loopWhileSucceeds exportLine [] (\e acc -> acc ++ [ e ]) identity)


{-| `module Name` — the OPTIONAL name line.  `Just name` when the next
token is exactly `module` (peek, then commit); `Nothing` otherwise (the
non-committed handback the optional header needs).
-}
moduleNameLine : ParserFast.Parser (Maybe String)
moduleNameLine =
    ParserFast.offsetSourceAndThen moduleNameLineAt


moduleNameLineAt : Int -> String -> ParserFast.Parser (Maybe String)
moduleNameLineAt offset src =
    let
        at =
            skipWsCommentsAt offset src
    in
    case tokenAtOff at src of
        Just ( "module", _ ) ->
            skipWsCommentsFollowedBy (spelled "module" (ParserFast.map Just moduleName))

        _ ->
            succeed Nothing


{-| The module name: a plain identifier (`Rt`, later `Foo.Bar` would grow
the charset — not a type-syntax concern).  Reuses `surfaceName` (no dots,
starts alpha/underscore).
-}
moduleName : ParserFast.Parser String
moduleName =
    surfaceName


{-| One `export key : ty markers` line, entered by peeking for the
`export` token exactly (the key is read verbatim by `keyName` — the same
reader as the defun header, so the two can never disagree on a key's
spelling).
-}
exportLine : ParserFast.Parser Export
exportLine =
    ParserFast.offsetSourceAndThen exportLineAt


exportLineAt : Int -> String -> ParserFast.Parser Export
exportLineAt offset src =
    let
        at =
            skipWsCommentsAt offset src
    in
    case tokenAtOff at src of
        Just ( "export", _ ) ->
            skipWsCommentsFollowedBy
                (ParserFast.map2
                    (\key sig -> { key = key, sig = sig })
                    (spelled "export" keyName)
                    (spelled ":" exportSig)
                )

        _ ->
            ParserFast.problem "expected `export` or `defun` (or the end of the program)"


{-| `ty markers` — the declared type expression plus the postfix marker
list (`!io`, `!taint`).  The type is the FULL forward-compatible grammar
(`otype`); the markers attach to the RESULT position (the whole line's
tail) and are carried on the signature, never inside the type.
-}
exportSig : ParserFast.Parser ExportSig
exportSig =
    ParserFast.map2
        (\ty marks -> { ty = ty, effects = marks.effects, taint = marks.taint })
        otype
        markerList


{-| The postfix marker list: zero or more `!ident` (currently exactly
`!io` and `!taint`; anything else rejects loudly — a typo'd marker must
never pass silently).  Folded into `{ effects, taint }`.
-}
markerList : ParserFast.Parser { effects : List Effect, taint : Bool }
markerList =
    ParserFast.loopWhileSucceeds marker { effects = [], taint = False } addMarker identity


{-| One marker's contribution, for the fold.
-}
addMarker : Marker -> { effects : List Effect, taint : Bool } -> { effects : List Effect, taint : Bool }
addMarker m acc =
    case m of
        MIo ->
            { acc | effects = acc.effects ++ [ Io ] }

        MTaint ->
            { acc | taint = True }


type Marker
    = MIo
    | MTaint


marker : ParserFast.Parser Marker
marker =
    ParserFast.offsetSourceAndThen markerAt


markerAt : Int -> String -> ParserFast.Parser Marker
markerAt offset src =
    let
        at =
            skipWsCommentsAt offset src
    in
    if String.slice at (at + 1) src == "!" then
        -- `spelled "!"` COMMITS (a `!` in marker position is a marker, so an
        -- unknown name must be a LOUD reject, never a silent hand-back that
        -- leaves `!bogus` as trailing junk).
        spelled "!" markerName

    else
        ParserFast.problem "expected a marker (`!io`/`!taint`) or the end of the export line"


{-| The marker NAME after the committed `!` — exactly `io` or `taint`
(`Effect.Io` / the contract-4 taint); anything else rejects loudly.
-}
markerName : ParserFast.Parser Marker
markerName =
    ParserFast.offsetSourceAndThen markerNameAt


markerNameAt : Int -> String -> ParserFast.Parser Marker
markerNameAt offset src =
    case typeTokenAtOff offset src of
        Just ( "io", _ ) ->
            spelled "io" (succeed MIo)

        Just ( "taint", _ ) ->
            spelled "taint" (succeed MTaint)

        Just ( tok, _ ) ->
            ParserFast.problem ("unknown export marker `!" ++ tok ++ "` — the markers are exactly `!io` and `!taint`")

        Nothing ->
            ParserFast.problem "expected a marker name after `!` (`io` or `taint`)"


{-| The export-block TYPE grammar (the forward-compatible whole):
`forall`/`exists` quantifiers over a type variable, then a RIGHT-
associative arrow chain, then atoms.  See `Ast.OTy`'s header for why this
is not pinned to monomorphic types — a quantifier, a `Ref s`-style
application, and a polymorphic arrow argument all parse HERE, unchanged.
-}
otype : ParserFast.Parser OTy
otype =
    ParserFast.offsetSourceAndThen otypeAt


otypeAt : Int -> String -> ParserFast.Parser OTy
otypeAt offset src =
    let
        at =
            skipWsCommentsAt offset src
    in
    case typeTokenAtOff at src of
        Just ( "forall", _ ) ->
            spelled "forall" (ParserFast.map2 OForall typeVar (spelled "." otype))

        Just ( "exists", _ ) ->
            spelled "exists" (ParserFast.map2 OExists typeVar (spelled "." otype))

        _ ->
            oarrow


{-| A quantified variable: a lowercase identifier (`s`, `a`) — the bound
variable of `forall s.` / `exists s.`.  `val`/`float`/`word` are reserved
atoms, never variables.
-}
typeVar : ParserFast.Parser String
typeVar =
    ParserFast.offsetSourceAndThen typeVarAt


typeVarAt : Int -> String -> ParserFast.Parser String
typeVarAt offset src =
    case typeTokenAtOff offset src of
        Just ( tok, _ ) ->
            if isLowerName tok && not (isTypeKeyword tok) then
                spelled tok (succeed tok)

            else
                ParserFast.problem ("expected a lowercase type variable, found `" ++ tok ++ "`")

        Nothing ->
            ParserFast.problem "expected a type variable"


{-| `atom ('->' type)?` — the RIGHT-associative arrow (the recursive
`otype` in the tail makes `A -> B -> C` read `A -> (B -> C)`).
-}
oarrow : ParserFast.Parser OTy
oarrow =
    ParserFast.map2 (\a tail -> tail a) oatom oarrowTail


oarrowTail : ParserFast.Parser (OTy -> OTy)
oarrowTail =
    ParserFast.offsetSourceAndThen oarrowTailAt


oarrowTailAt : Int -> String -> ParserFast.Parser (OTy -> OTy)
oarrowTailAt offset src =
    let
        at =
            skipWsCommentsAt offset src
    in
    if String.slice at (at + 2) src == "->" then
        spelled "->" (ParserFast.map (\b a -> OArrow a b) otype)

    else
        succeed identity


{-| A type atom: `val`/`float`/`word` (the opaque class atoms), a
parenthesized full type (so an arrow argument can itself be polymorphic:
`(forall s. Ref s -> Int) -> Int`), an UPPERCASE constructor (bare or
applied — `Word`, `Val Int`, `Ref s`), or a lowercase type VARIABLE (`s`,
`a`).  A digit-starting token is a loud reject (a type is a name).
-}
oatom : ParserFast.Parser OTy
oatom =
    ParserFast.offsetSourceAndThen oatomAt


oatomAt : Int -> String -> ParserFast.Parser OTy
oatomAt offset src =
    let
        at =
            skipWsCommentsAt offset src
    in
    case String.slice at (at + 1) src of
        "(" ->
            spelled "(" (ParserFast.map2 (\ty _ -> ty) otype (spelled ")" (succeed ())))

        "" ->
            ParserFast.problem "expected a type, found end of input"

        c ->
            if isTokenStart c then
                otypeNameAt at src

            else
                ParserFast.problem ("expected a type, found `" ++ c ++ "`")


otypeNameAt : Int -> String -> ParserFast.Parser OTy
otypeNameAt at src =
    case typeTokenAtOff at src of
        Just ( "val", _ ) ->
            spelled "val" (succeed OVal)

        Just ( "float", _ ) ->
            spelled "float" (succeed OFloat)

        Just ( "word", _ ) ->
            spelled "word" (succeed OWord)

        Just ( tok, _ ) ->
            if isUpperName tok then
                conApp tok

            else if isLowerName tok && not (isTypeKeyword tok) then
                spelled tok (succeed (OVar tok))

            else
                ParserFast.problem ("expected a type (a name), found `" ++ tok ++ "`")

        Nothing ->
            ParserFast.problem "expected a type"


{-| The surface keywords that are NEVER type names (variable or
constructor): the top-level `defun`/`export`/`module` delimiters, the
type-level `forall`/`exists`/`val`/`float`/`word` atoms, and the two
MARKER names `io`/`taint`.  Excluding the delimiters here is what lets a
constructor-application loop (`Ref s`) STOP cleanly at the next defun
instead of greedily reading `defun` as a type variable.  `io`/`taint`
are excluded because they are reserved in marker position: without them a
DROPPED `!` is silent — `Val Int io` would parse as a type APPLICATION to
a type variable `io`, with no effect marker and no error, turning a typo
into a wrong answer the moment M4 enforces `!io`.
-}
isTypeKeyword : String -> Bool
isTypeKeyword tok =
    tok == "defun"
        || tok == "export"
        || tok == "module"
        || tok == "forall"
        || tok == "exists"
        || tok == "val"
        || tok == "float"
        || tok == "word"
        || tok == "io"
        || tok == "taint"


{-| `Name` / `Name atom atom ...` — a type constructor, bare (`OCon name
[]`) or applied to a sequence of atoms (`Val Int`, `Ref s`).  Application
arguments are ATOMS (not arrows), so `Ref s -> Int` groups as
`(Ref s) -> Int` and a deeper argument parenthesizes: `List (Ref s)`.
-}
conApp : String -> ParserFast.Parser OTy
conApp name =
    ParserFast.map2
        (\_ args -> OCon name args)
        (spelled name (succeed ()))
        (ParserFast.loopWhileSucceeds oatom [] (\a acc -> acc ++ [ a ]) identity)


{-| Starts with an UPPERCASE letter (a type constructor: `Val`, `Word`,
`Ref`, `Int`).  Lowercase is the variable space (and the three reserved
atoms `val`/`float`/`word`); digits are rejected at the call site.
-}
isUpperName : String -> Bool
isUpperName tok =
    case String.toList (String.slice 0 1 tok) of
        c :: _ ->
            Char.isUpper c

        [] ->
            False


{-| Starts with a lowercase letter or underscore (a type variable `s`,
`a`, `_x`).
-}
isLowerName : String -> Bool
isLowerName tok =
    case String.toList (String.slice 0 1 tok) of
        c :: _ ->
            Char.isLower c || c == '_'

        [] ->
            False


defunTarget : ParserFast.Parser Defun
defunTarget =
    followedBySkipWsComments defun


{-| One defun, including its leading whitespace.  Dispatch first (peek
past the whitespace for `@` or the exact token `defun`), and only then
skip whitespace inside the library (which commits): with no defun here,
the program loop must back up cleanly.
-}
defun : ParserFast.Parser Defun
defun =
    ParserFast.offsetSourceAndThen defunAt


defunAt : Int -> String -> ParserFast.Parser Defun
defunAt offset src =
    -- peek WITHOUT dropping the tail (the O(n) invariant): `skipWsCommentsAt`
    -- threads an offset, and the `@` / token checks read at that offset
    let
        at =
            skipWsCommentsAt offset src
    in
    if String.slice at (at + 1) src == "@" then
        skipWsCommentsFollowedBy defunCore

    else
        case tokenAtOff at src of
            Just ( "defun", _ ) ->
                skipWsCommentsFollowedBy defunCore

            _ ->
                ParserFast.problem "expected a defun (or the end of the program)"


{-| How far the whitespace (space, newline, CR — the vendored skipper's
exact set) AND the `//` comments extend from `n`: a pure scan used only
for PEEKING; the real consumption stays inside the library
(`skipWsCommentsFollowedBy`).  A comment ends at (and keeps) its newline.
-}
skipWsCommentsAt : Int -> String -> Int
skipWsCommentsAt n src =
    let
        afterWs =
            skipSpaces n src
    in
    case commentAt afterWs src of
        Just comment ->
            skipWsCommentsAt (afterWs + String.length comment) src

        Nothing ->
            afterWs


skipSpaces : Int -> String -> Int
skipSpaces n src =
    case String.slice n (n + 1) src of
        " " ->
            skipSpaces (n + 1) src

        "\n" ->
            skipSpaces (n + 1) src

        "\u{000D}" ->
            skipSpaces (n + 1) src

        _ ->
            n


{-| The comment starting at `offset`, if there is one: `Just "// ..."` up
to (not including) the newline that ends it, or `Nothing`.  The ABUT
rule (module header): a `//` whose immediately preceding character is a
token character is NOT a comment — that is what keeps `a//b` (and a `//`
inside a would-be key, whose charset includes `/`) from silently
truncating the token, and what makes the token readers authoritative.
The single source of truth for both the pure peek (`skipWsCommentsAt`)
and the parser (`commentOr`), so the two can never disagree.
-}
commentAt : Int -> String -> Maybe String
commentAt offset src =
    if String.slice offset (offset + 2) src == "//" && not (tokenCharBefore offset src) then
        Just (String.slice offset (commentEnd offset src) src)

    else
        Nothing


tokenCharBefore : Int -> String -> Bool
tokenCharBefore offset src =
    offset > 0 && String.any isTokenChar (String.slice (offset - 1) offset src)


{-| The offset of the newline (or CR, or the end of input) that ends the
comment starting at `n` — the comment's newline is NOT part of it (it is
whitespace the vendored skipper owns, so row/column stay correct).
-}
commentEnd : Int -> String -> Int
commentEnd n src =
    case String.slice n (n + 1) src of
        "\n" ->
            n

        "\u{000D}" ->
            n

        "" ->
            n

        _ ->
            commentEnd (n + 1) src


{-| The dispatch-committed defun body: the optional `@flag` guard, then
`defun Key(params) -> ty block`.
-}
defunCore : ParserFast.Parser Defun
defunCore =
    ParserFast.offsetSourceAndThen defunCoreAt


defunCoreAt : Int -> String -> ParserFast.Parser Defun
defunCoreAt offset src =
    case String.slice offset (offset + 1) src of
        "@" ->
            ParserFast.map2
                (\guards defunOf -> defunOf guards)
                (ParserFast.map2 (::) flagGuard moreFlagGuards)
                defunTail

        _ ->
            ParserFast.map (\defunOf -> defunOf []) defunTail


{-| The guards AFTER the first: PEEK for another `@` (whitespace skipped by
the `defunAt` scan; a second `@` commits the next guard via the same
committed dispatch the head used), anything else hands back what has — so
a one-guard defun parses exactly as before and no existing parse moves.
T10 (handoff-osier-tier2-t10): `Rt.=` is MEASURED to vary by TWO switches
(`rec` and `eqPtrFast` — RtPrims' eqDefun takes both), so one defun needs a
CONJUNCTION of guards (`@rec @eqPtrFast` = both on).  The AST's `flags` was
always a List and Check.guardsHold already folds it — this loop only makes
the conjunction SPELLABLE.
-}
moreFlagGuards : ParserFast.Parser (List FlagGuard)
moreFlagGuards =
    ParserFast.offsetSourceAndThen moreFlagGuardsAt


moreFlagGuardsAt : Int -> String -> ParserFast.Parser (List FlagGuard)
moreFlagGuardsAt offset src =
    let
        at =
            skipSpaces offset src
    in
    if String.slice at (at + 1) src == "@" then
        skipWsCommentsFollowedBy
            (ParserFast.map2 (::) flagGuard moreFlagGuards)

    else
        succeed []


{-| `@flag` / `@!flag` — the flag spellings are exactly `Ast.Flag`'s
three constructors (a fourth switch is a new emission axis: Ast and this
dispatch both grow, never a String).
-}
flagGuard : ParserFast.Parser FlagGuard
flagGuard =
    spelled "@"
        (ParserFast.offsetSourceAndThen
            (\offset src ->
                case String.slice offset (offset + 1) src of
                    "!" ->
                        spelled "!" (ParserFast.map GuardNot flagName)

                    _ ->
                        ParserFast.map Guard flagName
            )
        )


flagName : ParserFast.Parser Flag
flagName =
    ParserFast.offsetSourceAndThen flagNameAt


flagNameAt : Int -> String -> ParserFast.Parser Flag
flagNameAt offset src =
    case tokenAtOff offset src of
        Just ( "consArr", _ ) ->
            spelled "consArr" (succeed ConsArr)

        Just ( "rec", _ ) ->
            spelled "rec" (succeed Rec)

        Just ( "eqPtrFast", _ ) ->
            spelled "eqPtrFast" (succeed EqPtrFast)

        Just ( tok, _ ) ->
            ParserFast.problem
                ("unknown flag `" ++ tok ++ "` — the defun flags are exactly consArr, rec, eqPtrFast (Ast.Flag)")

        Nothing ->
            ParserFast.problem "expected a flag name after `@`"


{-| `defun Key(params) -> ty block` — everything after the guard slot.
Builds a `List FlagGuard -> Defun` function so the guard arm (which sees
its guard first, in source order) can hand `[guard]` in.
-}
defunTail : ParserFast.Parser (List FlagGuard -> Defun)
defunTail =
    ParserFast.map4
        (\key params ty body flags ->
            { key = key
            , flags = flags
            , params = params
            , ret = ty
            , body = body
            }
        )
        (spelled "defun" keyName)
        (spelled "(" paramList)
        (spelled ")" (spelled "->" surfaceType))
        block


{-| The defun's key: a full dotted Rt name (`Rt.getpid`), VERBATIM — the
leading `Rt.` is part of the name and is never stripped.  Resolution is
the checker's (J2); the parser takes any dotted key shape, exactly like
`call`.
-}
keyName : ParserFast.Parser String
keyName =
    ParserFast.offsetSourceAndThen keyNameAt


keyNameAt : Int -> String -> ParserFast.Parser String
keyNameAt offset src =
    case keyTokenAtOff offset src of
        Just ( tok, _ ) ->
            if isValidKey tok then
                spelled tok (succeed tok)

            else
                ParserFast.problem
                    ("expected a defun key (a dotted Rt name, e.g. Rt.getpid), found `" ++ tok ++ "`")

        Nothing ->
            ParserFast.problem "expected a defun key (a dotted Rt name, e.g. Rt.getpid)"


{-| `[id ':' ty {',' id ':' ty}]` — possibly empty (arity is the
checker's judgment); a trailing comma is a loud reject (the committed
`spelled` chain).
-}
paramList : ParserFast.Parser (List Param)
paramList =
    ParserFast.offsetSourceAndThen paramListAt


paramListAt : Int -> String -> ParserFast.Parser (List Param)
paramListAt offset src =
    -- entered right after `(` (spelled consumed its trailing whitespace)
    if String.slice offset (offset + 1) src == ")" then
        succeed []

    else
        ParserFast.map2 (::)
            param
            (ParserFast.loopWhileSucceeds (spelled "," param) [] (\p acc -> acc ++ [ p ]) identity)


param : ParserFast.Parser Param
param =
    ParserFast.map2
        (\name ty -> { name = name, ty = ty })
        surfaceName
        (spelled ":" surfaceType)


{-| `word | float | val` — the whole type grammar; anything else is a
loud reject (a malformed type must never lex as something else).
-}
surfaceType : ParserFast.Parser Type
surfaceType =
    ParserFast.offsetSourceAndThen surfaceTypeAt


surfaceTypeAt : Int -> String -> ParserFast.Parser Type
surfaceTypeAt offset src =
    case tokenAtOff offset src of
        Just ( "word", _ ) ->
            spelled "word" (succeed TWord)

        Just ( "float", _ ) ->
            spelled "float" (succeed TFloat)

        Just ( "val", _ ) ->
            spelled "val" (succeed TVal)

        Just ( tok, _ ) ->
            ParserFast.problem ("expected a type (`word`, `float` or `val`), found `" ++ tok ++ "`")

        Nothing ->
            ParserFast.problem "expected a type (`word`, `float` or `val`)"


blockTarget : ParserFast.Parser Block
blockTarget =
    followedBySkipWsComments (skipWsCommentsFollowedBy block)


{-| `{ stmt* term }`.  The fold sees every item; the closing `}` is
consumed AFTER the fold, so a block that never reached a terminator
reports against the `}` (or the end of input) that exposed it.
-}
block : ParserFast.Parser Block
block =
    spelled "{"
        (ParserFast.map2
            (\folded _ -> blockOfFold folded)
            blockInner
            (spelled "}" (succeed ()))
        )


{-| The `stmt* term` fold: items until a handback, then `validate` —
exactly one terminator and nothing after it (the module header has the
mechanism).  Statements accumulate REVERSED (prepend is O(1)); the
terminator arms consume only themselves — `block` owns the `}`.
-}
blockInner : ParserFast.Parser ( List Stmt, Maybe Term, Bool )
blockInner =
    ParserFast.validate
        (\( _, mterm, stray ) -> not stray && mterm /= Nothing)
        "a block has exactly one terminator — `return e;`, `recur(..);` or a final `if (..) ..` — and nothing may follow it (Mid has no fall-through and no join)"
        (ParserFast.loopWhileSucceedsOntoResultFromParser
            itemStep
            (succeed ( [], Nothing, False ))
            itemReduce
            identity
        )


{-| One folded item: a statement, or the block's terminator (the `End`
marks that nothing may follow it, not that it consumed the `}`).
-}
type Item
    = IStmt Stmt
    | ITermEnd Term


itemReduce : Item -> ( List Stmt, Maybe Term, Bool ) -> ( List Stmt, Maybe Term, Bool )
itemReduce item ( revStmts, mterm, stray ) =
    case item of
        IStmt stmt ->
            case mterm of
                Nothing ->
                    ( stmt :: revStmts, Nothing, stray )

                Just _ ->
                    -- a statement AFTER the terminator: the fold must not
                    -- silently drop or reorder it, so the fold is poisoned
                    -- and `validate` rejects
                    ( revStmts, mterm, True )

        ITermEnd term ->
            case mterm of
                Nothing ->
                    ( revStmts, Just term, stray )

                Just _ ->
                    -- a second terminator (e.g. a mid-block `return` or `recur`)
                    ( revStmts, mterm, True )


blockOfFold : ( List Stmt, Maybe Term, Bool ) -> Block
blockOfFold ( revStmts, mterm, _ ) =
    case mterm of
        Just term ->
            { stmts = List.reverse revStmts
            , term = term
            }

        Nothing ->
            -- unreachable: `validate` in blockInner rejects a fold that saw no terminator
            { stmts = List.reverse revStmts
            , term = TRet (EInt 0)
            }


{-| Dispatch one item by peeking its first token (the reserved-word
table and the handback set are in the module header).
-}
itemStep : ParserFast.Parser Item
itemStep =
    ParserFast.offsetSourceAndThen itemStepAt


itemStepAt : Int -> String -> ParserFast.Parser Item
itemStepAt offset src =
    case tokenAtOff offset src of
        Just ( "if", _ ) ->
            spelled "if" ifItem

        Just ( "return", _ ) ->
            ParserFast.map (\e -> ITermEnd (TRet e)) (spelled "return" expSemi)

        Just ( "recur", _ ) ->
            ParserFast.map ITermEnd (spelled "recur" recurTail)

        Just ( "word", _ ) ->
            ParserFast.map IStmt (spelled "word" (bindTail TWord))

        Just ( "float", _ ) ->
            ParserFast.map IStmt (spelled "float" (bindTail TFloat))

        Just ( "val", _ ) ->
            ParserFast.map IStmt (spelled "val" (bindTail TVal))

        Just ( "defun", _ ) ->
            -- the next defun begins: this block's statement list is over
            ParserFast.problem "the block's terminator must come before the next `defun`"

        Just ( "else", _ ) ->
            -- the enclosing `if` already took its else (or this is stray)
            ParserFast.problem "`else` does not start a statement"

        Just ( tok, _ ) ->
            -- any other token starts an effect statement; the expression
            -- parser reads the token itself (it may be a keyword-led form
            -- like `call`/`rawcall`/`withroots` — never pre-consume it)
            ParserFast.map (\e -> IStmt (SEffect e)) expSemi

        Nothing ->
            -- not a token character: `}` / `@` / end of input end the
            -- block; anything else (a `(`-grouped expression, a string
            -- literal) may still start an effect statement
            case String.slice offset (offset + 1) src of
                "}" ->
                    ParserFast.problem "end of block"

                "@" ->
                    ParserFast.problem "end of block (the next defun is guarded)"

                "" ->
                    ParserFast.problem "end of block (input ends)"

                _ ->
                    ParserFast.map (\e -> IStmt (SEffect e)) expSemi


{-| `recur`'s tail: `( [exp {',' exp}] ) ;` — the ONLY loop form (L4);
saturation (arity == own params) is J4, the checker's judgment.
-}
recurTail : ParserFast.Parser Term
recurTail =
    ParserFast.map2
        (\args _ -> TRecur args)
        argsInParens
        (spelled ";" (succeed ()))


{-| `exp ;` — an expression and its REQUIRED semicolon (`spelled`'s
committed continuation makes a missing one loud).  Shared by the effect
statements and `return`.
-}
expSemi : ParserFast.Parser Exp
expSemi =
    ParserFast.map2
        (\e _ -> e)
        expression
        (spelled ";" (succeed ()))


{-| `id = exp ;` — the SBind tail after the type token.  A NEW binder
only (rebinding-as-shadowing is T6's lowering concern); the declared
class is J5's.
-}
bindTail : Type -> ParserFast.Parser Stmt
bindTail ty =
    ParserFast.map2
        (SBind ty)
        surfaceName
        (spelled "=" expSemi)


{-| The ambiguous `if`, after its keyword: parse it whole (`ifTail`),
then peek — a following `}` means it was the block's terminator (`TIf`),
anything else a mid-block statement (`SIf`).  BOTH peek arms SUCCEED:
the decision must never be a failed `map2` second slot (that would
promote to committed and kill the parse).  An `if` handed back as a
statement in a block that then lacks a terminator is caught by
`validate` — a missing terminator, loudly.
-}
ifItem : ParserFast.Parser Item
ifItem =
    ParserFast.map2
        (\parts continuation -> continuation parts)
        ifTail
        (ParserFast.offsetSourceAndThen
            (\offset src ->
                if String.slice offset (offset + 1) src == "}" then
                    succeed
                        (\( cond, thn, els ) -> ITermEnd (TIf cond thn els))

                else
                    succeed
                        (\( cond, thn, els ) -> IStmt (SIf cond thn els))
            )
        )


{-| `if (cond) block [else block]` — the condition's parentheses are
REQUIRED (`commit`: the `if` keyword was matched, so a malformed
continuation is a real error, never a handback); the else binds to THIS
if (blocks are braced, so an inner if never sees the outer's else).
-}
ifTail : ParserFast.Parser ( Exp, Block, Maybe Block )
ifTail =
    ParserFast.map3
        (\cond thn els -> ( cond, thn, els ))
        (commit parenCond)
        (spelled ")" block)
        (ParserFast.oneOf2
            (ParserFast.map Just (spelled "else" block))
            (succeed Nothing)
        )


{-| The committed `( cond` head of an `if` — peek-confirm: at the `(`,
parse; not at one, name the grammar (the message the reject row pins).
-}
parenCond : ParserFast.Parser Exp
parenCond =
    ParserFast.offsetSourceAndThen
        (\offset src ->
            if String.slice offset (offset + 1) src == "(" then
                spelled "(" expression

            else
                ParserFast.problem "`if` needs its condition in parentheses — `if (cond) {..}`"
        )


{-| T23 — the BLOCK-BRANCH if EXPRESSION: `if (cond) { block } else {
block }` in any EXPRESSION position (an initializer slot, a call
argument, a nested arm).  Same tokens as the statement/term `if` but
reached only through the expression atom path (`nameAtom`) — the
statement dispatch (`itemStepAt`) keeps its own `if` arm, so SIf/TIf
parse exactly as before.  The cond parser (`parenCond`) and the branch
parser (`block`) are the statement if's OWN, reused verbatim; the else
block is REQUIRED — an expression needs a value from both arms (the
missing-else is the loud `expected `else`` symbol failure, pinned by a
TestMain reject row).  The lowering and the class judgment live in
LowerToIr (the TERM if's `mkIf` over two lowered blocks) and Check
(`checkCond` + branch-class agreement).
-}
ifBlockExp : ParserFast.Parser Exp
ifBlockExp =
    ParserFast.map3
        EIfBlock
        (commit parenCond)
        (spelled ")" block)
        (spelled "else" block)


{-| Force a committed failure for `parser`: `map2` promotes its SECOND
parser's failure to committed even when that failure was a
non-committed `problem`, and `succeed ()` never fails, so `parser`'s
failure arrives loud.  The one-way door from "dispatched" to "committed".
-}
commit : ParserFast.Parser res -> ParserFast.Parser res
commit parser =
    ParserFast.map2 (\_ res -> res) (succeed ()) parser



-- ============================ token plumbing ============================


{-| Match the literal `tok` (exactly, at the current position — callers
have just peeked it), then the whitespace AND `//` comments after it,
then `parser`.  The skip is `skipWsCommentsFollowedBy` (a committing
leading-skip), which is safe here: the `symbol` has already matched, so
the parse is committed either way.
-}
spelled : String -> ParserFast.Parser res -> ParserFast.Parser res
spelled tok parser =
    ParserFast.symbolFollowedBy tok (skipWsCommentsFollowedBy parser)


{-| The vendored `skipWhileWhitespaceFollowedBy`, extended with `//` line
comments (M0, module header): skip whitespace and comments, then `parser`.
Whitespace is skipped by the vendored skip (so row/column advance
correctly across newlines) and each comment by an exact `symbol` match on
the comment TEXT — which never contains a newline — so both the state
advance and the error positions stay the library's.  The recursion is
guarded by a consumed comment, so it terminates.
-}
skipWsCommentsFollowedBy : ParserFast.Parser a -> ParserFast.Parser a
skipWsCommentsFollowedBy parser =
    ParserFast.skipWhileWhitespaceFollowedBy (commentOr parser)


commentOr : ParserFast.Parser a -> ParserFast.Parser a
commentOr parser =
    ParserFast.offsetSourceAndThen
        (\offset src ->
            case commentAt offset src of
                Just comment ->
                    ParserFast.symbolFollowedBy comment (skipWsCommentsFollowedBy parser)

                Nothing ->
                    parser
        )


{-| The vendored `followedBySkipWhileWhitespace`, extended with `//`
comments: parse `parser`, then skip the whitespace AND comments after it.
Never fails (`skipWsCommentsFollowedBy (succeed ())` can only succeed),
so it adds no commit state a caller did not already have.
-}
followedBySkipWsComments : ParserFast.Parser a -> ParserFast.Parser a
followedBySkipWsComments parser =
    ParserFast.map2 (\res _ -> res) parser (skipWsCommentsFollowedBy (succeed ()))


{-| The vendored library exposes no `succeed`; a zero-length `symbol`
match is exactly it: always Good, consumes nothing.
-}
succeed : res -> ParserFast.Parser res
succeed res =
    ParserFast.symbol "" res


{-| The longest token starting at offset `start` of `src`:
`[A-Za-z0-9_.]` characters.  The dot is a token character so a `call`
key (`Rt.getpid`) and a float (`1.5`) read as one token each; a dot
anywhere else is rejected by name (`nameAtom`), which is the loud shape
the grammar wants.

THE O(n) INVARIANT (performance-only contract; parse results must not
move).  `ParserFast` threads `{ src, offset, row, col }` and NEVER
re-slices its source; every scan and peek here follows the same model:
read ONE character with `String.slice n (n + 1) src` (O(1)) and thread
the offset.  BANNED on the hot path: `dropLeft` and
`String.toList` OF A TAIL — each walks and copies every character of
the remaining input, so per-token or per-character use is O(n^2) over
the file (MEASURED: the pre-fix scanners burned ~12s of user CPU per
trivial fixture compile, 85% of it in this module).  What remains is
O(1) per step: 1-3 char slices at the offset, and `String.toList` /
`String.any` only on ALREADY-EXTRACTED SHORT strings (1-char slices and
token texts — O(token length), which sums to O(n)).
-}
tokenAtOff : Int -> String -> Maybe ( String, Int )
tokenAtOff start src =
    tokenAtHelp start start src


tokenAtHelp : Int -> Int -> String -> Maybe ( String, Int )
tokenAtHelp start n src =
    -- O(n): ONE char per step via an O(1) slice, offset threaded forward
    -- (a `toList` of the tail here — the pre-fix form — walks and copies
    -- the whole remaining input per character, O(n^2) over the file)
    case String.slice n (n + 1) src of
        "" ->
            finishedToken start n src

        c ->
            if String.any isTokenChar c then
                tokenAtHelp start (n + 1) src

            else
                finishedToken start n src


finishedToken : Int -> Int -> String -> Maybe ( String, Int )
finishedToken start n src =
    if n == start then
        Nothing

    else
        Just ( String.slice start n src, n - start )


{-| Does the (1-char slice) start a token?  List-shaped because a slice
can carry half a 2-part UTF-16 unit.
-}
isTokenStart : String -> Bool
isTokenStart s =
    case String.toList s of
        [ c ] ->
            Char.isAlpha c || Char.isDigit c || c == '_'

        _ ->
            False


isTokenChar : Char -> Bool
isTokenChar c =
    Char.isAlpha c || Char.isDigit c || c == '_' || c == '.'


{-| The longest TYPE token starting at offset `start` of `src`:
`[A-Za-z0-9_]` — deliberately WITHOUT the dot, so the export-block type
grammar's `.` (the `forall s.` / `exists s.` separator) is NOT swallowed
into a name token.  The general `tokenAtOff` keeps the dot (it is how
`Rt.getpid` reads as one token); the type grammar uses THIS reader so
`s.` splits into the variable `s` and the separator `.`.
-}
typeTokenAtOff : Int -> String -> Maybe ( String, Int )
typeTokenAtOff start src =
    typeTokenHelp start start src


typeTokenHelp : Int -> Int -> String -> Maybe ( String, Int )
typeTokenHelp start n src =
    case String.slice n (n + 1) src of
        "" ->
            finishedToken start n src

        c ->
            if String.any isTypeChar c then
                typeTokenHelp start (n + 1) src

            else
                finishedToken start n src


isTypeChar : Char -> Bool
isTypeChar c =
    Char.isAlphaNum c || c == '_'


{-| The longest KEY token starting at offset `start` of `src`: the general
token charset plus the characters the measured `Rt.*` key set needs beyond
it (`- + = < >` — see the module header's key-charset note — and `@`, T12's
`Rt.@p`, and `* / ?`, T20's arithmetic/tag-predicate keys).
Used ONLY in key positions (`callAt`, `keyNameAt`) — never by the
expression lexer, whose tokens stay `[A-Za-z0-9_.]` so a body's
unspaced `x-2` still lexes as `x`, `-`, `2` and every existing parse is
preserved.  The key still never crosses whitespace or a `(`, which is
what disambiguates it from the operators sharing its characters.
Offset-threaded like `tokenAtOff` (the O(n) invariant above).
-}
keyTokenAtOff : Int -> String -> Maybe ( String, Int )
keyTokenAtOff start src =
    keyTokenHelp start start src


keyTokenHelp : Int -> Int -> String -> Maybe ( String, Int )
keyTokenHelp start n src =
    case String.slice n (n + 1) src of
        "" ->
            finishedToken start n src

        c ->
            if String.any isKeyChar c then
                keyTokenHelp start (n + 1) src

            else
                finishedToken start n src


isKeyChar : Char -> Bool
isKeyChar c =
    isTokenChar c || c == '-' || c == '+' || c == '=' || c == '<' || c == '>' || c == '@' || c == '*' || c == '/' || c == '?'


{-| Does the token start with a digit (number) rather than a name?
The first character only, via an O(1) 1-char slice (`String.toList` of a
WHOLE token here would be O(token length) — allowed but pointless).
-}
isNumberToken : String -> Bool
isNumberToken tok =
    case String.toList (String.slice 0 1 tok) of
        c :: _ ->
            Char.isDigit c

        [] ->
            False


hasDot : String -> Bool
hasDot s =
    String.any (\c -> c == '.') s


{-| A plain name: starts alpha/underscore, no dots (C-style symbols,
binder names).
-}
isPlainName : String -> Bool
isPlainName tok =
    case String.toList tok of
        c :: _ ->
            isNameStartChar c && not (hasDot tok)

        [] ->
            False


isNameStartChar : Char -> Bool
isNameStartChar c =
    Char.isAlpha c || c == '_'


{-| A `call`/defun key: dot-separated segments, each a NON-EMPTY run of
key body chars that does not START with a digit (the one exclusion kept
from the old `[A-Za-z0-9_.]` rule — a key is a name, not a number, so
`call 5x(..)` still rejects).  The rule deliberately accepts every
MEASURED key shape verbatim — a segment may be pure symbols (`Rt.=`,
`Rt.>=`, `Rt.-`), start with `<` (`Rt.<-address`), start with `@`
(`Rt.@p`), end with `>`
(`Rt.address->`), or carry an inner `->` (`Rt.shen.str->bytes`); a
well-formed but unresolvable key is J2's reject, not the lexer's.
-}
isValidKey : String -> Bool
isValidKey tok =
    keySeg (String.toList tok)


{-| One segment — a non-empty `keySegRun` — then either the end of the
key or `.` + another segment.  (Written as a scan over the characters —
the selfhost's String surface has no `split`.)
-}
keySeg : List Char -> Bool
keySeg cs =
    case keySegRun True cs of
        Just rest ->
            case rest of
                [] ->
                    True

                '.' :: after ->
                    keySeg after

                _ ->
                    False

        Nothing ->
            False


{-| The longest run of key body chars (`.` is NOT one — it separates
segments): `Just` the unconsumed remainder, `Nothing` when the run would
be empty.  `first` is the segment-start position, where a digit may not
lead.
-}
keySegRun : Bool -> List Char -> Maybe (List Char)
keySegRun first cs =
    case cs of
        c :: rest ->
            if isKeyBodyChar c && not (first && Char.isDigit c) then
                keySegRun False rest

            else if first then
                Nothing

            else
                Just cs

        [] ->
            if first then
                Nothing

            else
                Just []


isKeyBodyChar : Char -> Bool
isKeyBodyChar c =
    Char.isAlphaNum c || c == '_' || c == '-' || c == '+' || c == '=' || c == '<' || c == '>' || c == '@' || c == '*' || c == '/' || c == '?'


{-| Surface string content is one ASCII printable/space character.
(The 1-char `String` slices here can carry half a 2-part UTF-16 unit,
which is exactly why the check is list-shaped.)
-}
isSurfaceChar : String -> Bool
isSurfaceChar s =
    case String.toList s of
        [ c ] ->
            let
                code =
                    Char.toCode c
            in
            code >= 32 && code <= 126

        _ ->
            False


surfaceCharReport : String -> String
surfaceCharReport s =
    case String.toList s of
        [ c ] ->
            " code " ++ String.fromInt (Char.toCode c)

        _ ->
            " a 2-part UTF-16 unit"



-- ============================ error rendering ============================


deadEndToString : DeadEnd -> String
deadEndToString de =
    String.fromInt de.row ++ ":" ++ String.fromInt de.col ++ ": " ++ problemText de.problem


problemText : Problem -> String
problemText p =
    case p of
        Expecting s ->
            "expected " ++ s

        ExpectingInt ->
            "expected an integer"

        ExpectingHex ->
            "expected hexadecimal digits"

        ExpectingOctal ->
            "expected octal digits"

        ExpectingBinary ->
            "expected binary digits"

        ExpectingFloat ->
            "expected a float"

        ExpectingNumber ->
            "expected a number"

        ExpectingVariable ->
            "expected a variable"

        ExpectingSymbol s ->
            "expected `" ++ s ++ "`"

        ExpectingKeyword k ->
            "expected keyword `" ++ k ++ "`"

        ExpectingEnd ->
            "unexpected input after the expression"

        UnexpectedChar ->
            "unexpected character"

        Problem msg ->
            msg

        BadRepeat ->
            "repetition"


firstProblem : List DeadEnd -> String
firstProblem deadEnds =
    case deadEnds of
        de :: _ ->
            deadEndToString de

        [] ->
            "unknown parse error"
