module Mid.RtSource exposing (source)

{-| Mid.RtSource — the RUNTIME's SURFACE-LANGUAGE TEXT, as a line list.

WHAT THIS IS.  The Mid-written runtime (`Rt.*` defuns) is being migrated
off the hand-rolled Elm builder DSL (Mid.RtPrims / Mid.RtGc, ~9k lines of
duplicate builders and hand-numbered binders) onto a small C-like surface
language (tier-2 plan, handoff-osier-tier2-midlang-plan).  The surface text
lives HERE, as `source : List String` — one line per element — because Elm
0.19 has no triple-quoted strings and a line list joined by
`String.join "\n"` is the readable form.

HOW IT IS CONSUMED.  The pipeline `Mid.RtLang.Parse -> Mid.RtLang.Check ->
Mid.RtLang.LowerToIr` (built in units T2-T6, AST in Mid.RtLang.Ast) parses
and checks this text ONCE per compiler process and lowers it to
`List Mid.Ir.Defun`; `Mid.Rt.program` splices the result into the existing
defun list positions (list ORDER affects the emitted .ssa bytes — a
migrated entry becomes a Dict lookup `surf "Rt.getpid"` at its old index).

WAVE MIGRATION.  T1 lands the container EMPTY: the surface text moves in
WAVE BY WAVE (T8-T18, one commit-shape landing per wave — surface lines
added, the corresponding Elm builders deleted, the corpus hash UNMOVED).
Until a wave lands, the defuns it migrates keep coming from the DSL; the
two sources are disjoint by construction and the corpus is byte-identical
at every step (the killer oracle).

Deliberately NOT a file: the plan's INJECTION PATH priced `.mid`-on-disk
and rejected it — a file on the compiler's own critical path adds a CLI
input, a bootstrap dependency and a provenance surface for zero benefit;
the blob-as-constant has none of those and the parser is needed in the
seed anyway.

-}


{-| The surface text, top-level defuns in the order they must occupy.

T8 (handoff-osier-tier2-t8) landed the FIRST wave: six trivial prims
transcribed 1:1 from their deleted RtPrims builders — `Rt.getpid`,
`Rt.emptylist`, `Rt.cStrEqLit`, `Rt.wStr`, `Rt.wRaw`,
`Rt.waitStatusCode`.  Each body is the SAME tree shape as the builder it
replaced (same 1-binder Lets in the same order, same call nodes in the
same order, same operator nesting); the corpus hash is the byte-level
proof, and TestMain's T8 rows pin the splice.

T8 also measured TWO GRAMMAR WALLS that forced it to defer `Rt.close`
and `Rt.write-byte`: no negative literal (`-2`), and no `-` in the key
charset.  Both walls fell in T8b (a `-` immediately followed by digits
is ONE `EInt`; key segments may carry `- + = < >`), so both defuns are
IN this wave — see T9 below.

T9 (handoff-osier-tier2-t9) is the SECOND wave — the first with real
control flow.  SEVEN defuns migrated: the four byte-walk SELF-TAIL
LOOPS `Rt.cStrLenGo` / `Rt.cStrCopyGo` / `Rt.cStrFill` / `Rt.memGo`
(the surface `recur` term lowers to the exact
`App { GRef own-key, force = False }` the DSL builds — the only loop
encoding; `lowerIf` propagates tail into both branches, so a
branch-final recur is the SAME `jmp @body` loop the classifier
privileges), `Rt.readFull` — whose EINTR retry is NOT recur: the DSL
builder self-references via plain `callR` (RawCall), a native call per
rare retry, and the surface `return call Rt.readFull(..);` spells that
exact tree (the T8 brief's "readFull is a self-tail loop" was refuted
by reading the builder) — plus the two unblocked prims `Rt.close` and
`Rt.write-byte`.

`Rt.readFileGo` is deliberately NOT in this wave: its `growB` binder
(RtPrims readFileGoDefun, `( growB, iff ... )`) holds an `If` in a LET
VALUE position, and the surface expression grammar has no
if-expression (`Ast.Exp` has no `EIf`); the L1 rule `ty x = e;` can
only spell an `e` built from the Exp constructors.  Every restructure
in the statement language moves the `If` nodes (the grammar has no
rebinding, so `grow` cannot be recomputed either) — a different tree,
not a transcription.  Same wall class as T8's two: whether to admit a
`?:` / if-expression form is a grammar decision for the owner — made
explicitly or not at all.  (The `?:` VALUE JOIN did land in T9b, but it
lowers through L1 as `Let { x = If { .. } }` — an EXTRA binder, not the
bare `If` a defun-tail chain spells — so it does not reopen this defun.)

T10 (handoff-osier-tier2-t10) is the THIRD wave and the first whose
defuns VARY BY FLAG: the EQUALITY family, five keys.  A flag-varied
defun is written as surface defuns sharing ONE key, each with an
`@flag`/`@!flag` guard — J8 (Check.guardWalk) enforces exactly one
ACTIVE variant per key under every flag combo, and Rt.activeSurf splices
the active one POSITIONALLY (the T8fix fix — first-not-last).  Migrated:
`Rt.deepEq` (@rec first — the tag-14 arm; @!rec second — the pre-E
tail), `Rt.vecEq`, `Rt.bytesEqGo`, `Rt.symEq` (unguarded), and `Rt.=`
FOUR variants: the DSL's eqDefun takes rec AND eqPtrFast (the
pointer-identity `or2` fast path at three symFast arms), so the surface
carries the 2x2 product as guard CONJUNCTIONS (`@rec @eqPtrFast`) — the
one grammar change T10 needed (Parse admitted a single guard; Ast.flags
was always a list and Check.guardsHold already folded it).  All
self-recursion here is `call Rt.<own-key>` (RawCall) — the DSL
self-references via callR, NOT recur (the T9 readFull lesson).

T11 (handoff-osier-tier2-t11) is the FOURTH wave — the NUMBER/STRING
builder family, NINE keys: `Rt.asF` (the float promote the arithmetic
prims share), `Rt.toI32` (the Bitwise operand conversion), `Rt.dgs` +
`Rt.revGo` + `Rt.numText` (decimal text: digits least-significant first,
reversed, sign prepended), and `Rt.bytesOf` + `Rt.countL` +
`Rt.bytesToStr` + `Rt.fillGo` (the bytes->string machinery: count the
list, ONE RawAllocRaw, fill byte by byte, wrap).  Two transcription
facts measured on the builders: ALL self-recursion here is
`call Rt.<own-key>` (RawCall) — including revGo/countL/fillGo, whose
builders self-reference via callR, NOT recur (the T9 readFull lesson;
the T11 brief's "self-tail loops" guess was refuted by reading) — and
`Rt.numText`'s `signed` and `Rt.dgs`'s `rAbs` binders hold an If in a
LET VALUE position, the exact wall that deferred `Rt.readFileGo` in T9;
this wave is the FIRST surface use of the T9b `?:` value join
(`val x = c ? a : b;` lowers 1:1 as `Let { x = If { .. } }` — the EIf
lowering is the same mkIf the statement layer uses), so both trees
transcribe exactly.

T13 (handoff-osier-tier2-t13) is wave-5 — the RECORDS / VECTOR family,
EIGHTEEN keys: thirteen from `helperDefuns` (assoc's walker `Rt.assocGo`;
the tag-14 record read `Rt.recGet` + `Rt.recGetGo`; the field update
`Rt.recUpd` + `Rt.recUpdFind` + `Rt.recUpdCopy`; the sorted-insert
machinery `Rt.recAppendFind` + `Rt.recAppendDataGo` +
`Rt.recAppendNamesGo` + `Rt.recAppend` + `Rt.recInsert`; the
positional-to-assoc `Rt.recToChain` + `Rt.recToChainGo`) and five from
`primDefuns` (`Rt.absvector`, `Rt.address->`, `Rt.<-address`,
`Rt.assoc`, `Rt.snd`).  ALL recursion in the family is
`call Rt.<own-key>` (RawCall) — measured PER DEFUN, zero recur (the
T9-T12 lesson: every DSL builder self/sibling-references via callR).
Two grammar firsts, both already covered: `reclen` (the nil-aware
length MACRO — exactly RtPrims' recLenOf tree, so every
`recLenOf (v rec)` transcribes 1:1) and keys carrying `<-`/`->`
(`Rt.address->`, `Rt.<-address` — the T8b charset, `>`/`<-` here first
exercised).  recAppendDataGo/NamesGo's `store` binder — an If in a Let
VALUE position — is the T9b `?:` join again (nested right; all three
branches vecstore/mknil = val, the checker's agreement rule).  The rec*
defuns are called only from rec-route sites, so the QBE_NOREC=1 arm
still never emits them: emission is per REACHABLE defun
(Qbe/Lower:358) and the call graph is unchanged by a same-shape
transcription — the corpus arms are the judge.

T12 (handoff-osier-tier2-t12) is wave-4 part 2 — the REMAINING
number/string builders plus the `@consArr` GUARD FAMILY.  SIX plain
keys: `Rt.cn2` (the primCn tail — append the two byte lists, bytesToStr),
`Rt.appendL` (prims.zig primAppend's reverse-reverse-onto-the-tail), the
NUL-name walk `Rt.symToStr` + `Rt.nameBytes`, `Rt.strOf` (primCn's
per-operand coercion, the five-way tag chain ending in the C literals),
and `Rt.floatCopy` (the countdown fill from the static float-text
buffer).  Plus the TWO-KEY cons pair `Rt.cons` + `Rt.@p` — the SECOND
flag axis: the DSL's consDefun takes the consArr switch (True = the
one-pointer fused pair, False = the pre-(A) two-word pair), so each key
carries TWO `@consArr`-guarded variants, @consArr FIRST (the
default-active variant, the T10 deepEq positional pattern) and
@!consArr LAST; the only body difference is the mkval word list (one
`vecaddr` under @consArr — every cdr reader derives it as pair[1] — two
under @!consArr).  The body is `WithRoots` around alloc + store + store
+ mkval, spelled `return withroots [car, cdr] { .. };`; the DSL's ONE
three-binder Let and the statement layer's nested 1-binder Lets emit
identical .ssa (Qbe/Lower.lowerLetBinders folds a Let's binder list in
order — the corpus is the judge).  The wave needed ONE grammar change,
the same class as T8b's: `@` joined keyTokenAt's charset (the guard
parser only ever sees `@` BEFORE the `defun` keyword, so a key-position
`@` is unambiguous) because the key `Rt.@p` could not otherwise lex.
ALL recursion in the six plain bodies is `call Rt.<key>` (RawCall),
none recur.  `Rt.readFileGo` was not in this wave's list (T9 kept it
dsl-side; T24 migrated it, the T24 block at the end of this list).

T14 (handoff-osier-tier2-t14) is wave-6 — the FD/PROCESS family and the
string/value prims, NINE keys: `Rt.read-byte` + `Rt.open` (the fd layer;
`Rt.close` went in T9), `Rt.intern` + `Rt.value` + `Rt.str` (the VM-state
and float-text prims), and `Rt.getcwd` + `Rt.cd` + `Rt.getenv` +
`Rt.setenv` (the libc process layer; `Rt.getpid` went in T8).  ALL
recursion below is a plain sibling `call` — measured PER DEFUN, zero
recur (the T9-T13 lesson).  Three builder shapes transcribe throughout:
`mkval(11, f, i + 4294967296 * s)` is the DSL's mkStream (the stream's
packed is_input/is_string word — a 64-bit multiply because the shift
family is 32-bit); `byteload(rawcall __errno_location(), 0)` is errnoOf
(the readFull precedent); and the cStrOf NUL-copy expands to its four
binders (`len32`, `allocraw(len + 1)`, box, `call Rt.cStrFill(..)`) in
every defun that NUL-terminates a string.  The mid-block ifs all have a
diverging then-branch — the L6 else-nesting — and `Rt.open`'s out arm
and `Rt.read-byte`'s file arm end in the T9b `?:` join in return
position (`return c ? a : b;` — TRet of the EIf, the same If the DSL's
iff spells).

T15 (handoff-osier-tier2-t15) is wave-7 — the GLOB family, NINE keys:
the eight helpers `Rt.globLastSlash` (the backward last-'/' walk),
`Rt.globIsDot` + `Rt.globIsDotDot` (byte-exact "." / ".." tests),
`Rt.globScanGo` (the readdir/fnmatch loop, all live state in a 5-word
C-heap state block), `Rt.globStrLess` + `Rt.globSortShift` +
`Rt.globSortGo` (strcmp-order insertion sort over the C-heap table) and
`Rt.globBuildGo` (sorted table -> tagged list, inside out), plus
`Rt.glob` itself (the one 8240-byte C scratch block: the "." / ".."
literals, the 1024-slot table, the state block; cStrOf's four binders at
the head).  Recursion MEASURED PER DEFUN: globLastSlash, globScanGo,
globStrLess, globSortShift, globSortGo and globBuildGo are SELF-TAIL
`recur` (their builders self-reference via App on the own key — the
in-frame jmp @body loop the classifier privileges), while globIsDot /
globIsDotDot / glob make no self-call.  Two transcription facts: the
OOM checks (glob's cbuf, globScanGo's dupe) and glob's in-place NUL over
the last '/' are Ifs in LET-VALUE positions whose branches are LETs
(haltV; store-then-mknum(0)) — spelled as the mid-block `if` with BOTH
branches diverging (`return` in each), which the lowerer dead-binds at a
fresh binder with the continuation as the Let body — the exact
`Let { b = If { .. } }` the DSL writes (execGo's b106 precedent).  And
globScanGo's dotfile-guard cond keeps the DSL's RAW `||` inside the `&&`
— `(nameDot || nameDD) && mkbool(guardW != 0)`, explicit parens against
the left-assoc parse, NOT a boxed one; glob's state[3] store reads
`payload((baseDot || baseDD) ? mknum(0) : mknum(1), 0)` — the T9b `?:`
join nested in a payload read, the DSL's `wOf (iff ..)`.

T16 (handoff-osier-tier2-t16) is wave-8 — the ep* EXEC-PLAN DECODE family,
TWENTY keys: the epUnwrap template written out EXPLICITLY (the Elm template
dies) as `Rt.epNum` (+16, tag 0) / `Rt.epStr` (+8, tag 1) / `Rt.epSymOf`
(+24, tag 2), the tdl walkers `Rt.epSymIs` / `Rt.epCount` / `Rt.epElem`,
the record decoders `Rt.epProg` / `Rt.epProgGo` / `Rt.epChain` /
`Rt.epPipeline` / `Rt.epPipeGo` / `Rt.epArgvGo` / `Rt.epRedirsGo` /
`Rt.epRedir`, the stdin guard `Rt.epCountStdin`, and the free walk
`Rt.epFreeChains` / `Rt.epFreeCmds` / `Rt.epFreeCmd` / `Rt.epFreeArgv` /
`Rt.epFreeRedirs`.  `Rt.epCmd` was NOT in T16 (its ago/rgo binders are
Ifs in LET-VALUE positions whose else carries a Let-chain (malloc + OOM
check + store + the argv/redir fill call) and whose VALUES the
continuation reads (`iff (ago < 0) ..`) — unspellable until T23's
block-branch if; T24 migrated it, the T24 block below).  The RtLayout blob offsets are transcribed
as LITERALS (prog 2 words, chain 2, cmd 5, redir 6 — kind0/fd1/path2/
dupfd3/body4/tmpfd5 —, op codes 0/1/2, kind codes 0..5, the cbuf literal
bytes 16/24/32..96); MEASURED before writing: the emitted .ssa of ALL
EIGHT exec fixtures reaches every migrated key, so the corpus pins each
offset.  Recursion MEASURED per defun: recur in epSymIs / epCount /
epElem / epProgGo / epPipeGo / epArgvGo / epRedirsGo / epCountStdin /
epFreeChains (two sites) / epFreeCmds / epFreeArgv / epFreeRedirs; no
self-call in the three unwraps, epProg, epChain, epPipeline, epRedir,
epFreeCmd.  Shapes: the tdl-state chain is the T9b ?: join nested right;
the OOM checks are the T15 both-branches-diverge spelling; epFreeCmd's
bare call branch values are `return call Rt.f(..);` (TRet of the call —
no Let, the dead binder takes the If); epCountStdin's compare rides
inside the acc addend; epRedir's malloc size is the T15 payload-of-?:
read (`len32(sN) + payload(isHstr ? mknum(1) : mknum(0), 0)`).

Elm 0.19 has no triple-quoted strings, so each element is one line.
The surface language has NO comment syntax — every prose line lives in
this Elm comment, never in the list.

-}
source : List String
source =
    [ -- -- Rt.getpid: primGetpid.  Arity 1: the nullary surface prim stages
      -- a dummy slot; it is ignored here.
      "defun Rt.getpid(dummy : val) -> val {"
    , "  return mknum(rawcall getpid());"
    , "}"
    , ""
    , -- -- Rt.emptylist: (number 0) -> nil; anything else halts (the Zig
      -- error.Halt arm).  The halt arm dead-binds the rt_halt call.
      "defun Rt.emptylist(a : val) -> val {"
    , "  if (mkbool(tagis(a, 0)) && mkbool(payload(a, 0) == 0)) {"
    , "    return mknil;"
    , "  } else {"
    , "    word h = rawcall rt_halt();"
    , "    return mknil;"
    , "  }"
    , "}"
    , ""
    , -- -- Rt.cStrEqLit: byte-compare the NUL-terminated C string at ptrN
      -- against the cbuf literal at byte offset litN, from index i.
      -- Self-tail (recur).
      "defun Rt.cStrEqLit(ptrN : val, litN : val, i : val) -> val {"
    , "  word pb = byteload(payload(ptrN, 0), payload(i, 0));"
    , "  word lb = byteload(payload(litN, 0), payload(i, 0));"
    , "  if (mkbool(lb == 0)) {"
    , "    return mkbool(pb == 0);"
    , "  }"
    , "  if (mkbool(pb == lb)) {"
    , "    recur(ptrN, litN, mknum(payload(i, 0) + 1));"
    , "  }"
    , "  return false;"
    , "}"
    , ""
    , -- -- Rt.wStr: write the NUL-terminated C string at ptrN to fdN (the
      -- result is ignored).  len is the byte COUNT (a Value from
      -- Rt.cStrLenGo); its payload word is the raw count for write.
      "defun Rt.wStr(fdN : val, ptrN : val) -> val {"
    , "  val len = call Rt.cStrLenGo(ptrN, mknum(0));"
    , "  rawcall write(payload(fdN, 0), payload(ptrN, 0), payload(len, 0));"
    , "  return mknil;"
    , "}"
    , ""
    , -- -- Rt.wRaw: write lenN bytes at ptrN to fdN.
      "defun Rt.wRaw(fdN : val, ptrN : val, lenN : val) -> val {"
    , "  rawcall write(payload(fdN, 0), payload(ptrN, 0), payload(lenN, 0));"
    , "  return mknil;"
    , "}"
    , ""
    , -- -- Rt.waitStatusCode: W.IFEXITED -> EXITSTATUS, else 128 + (st &
      -- 0x7f).  st is a 32-bit waitpid status, so the 32-bit shift family
      -- is exact; >>> is the zero-fill shift (RShR).
      "defun Rt.waitStatusCode(st : val) -> val {"
    , "  if (mkbool((payload(st, 0) & 127) == 0)) {"
    , "    return mknum((payload(st, 0) >>> 8) & 255);"
    , "  } else {"
    , "    return mknum(128 + (payload(st, 0) & 127));"
    , "  }"
    , "}"
    , ""
    , -- ====================== T9 — wave-2: the self-tail loops ======================
      --
      -- -- Rt.cStrLenGo: the length of the NUL-terminated C string at ptrN,
      -- counted from index i (entered at 0).  ptrN must be STABLE across the
      -- walk (libc-owned, or a GC buffer with no intervening alloc), and the
      -- loop is FRAME-FREE and NON-ALLOCATING — no safepoint anywhere, which
      -- is what keeps the callers' raw-buffer windows sound.  Self-tail
      -- (recur): the in-frame jmp @body loop, O(1) native stack.
      "defun Rt.cStrLenGo(ptrN : val, i : val) -> val {"
    , "  word byte = byteload(payload(ptrN, 0), payload(i, 0));"
    , "  if (mkbool(byte == 0)) {"
    , "    return mknum(payload(i, 0));"
    , "  }"
    , "  recur(ptrN, mknum(payload(i, 0) + 1));"
    , "}"
    , ""
    , -- -- Rt.cStrCopyGo: copy byte i of the C string at srcN into the GC
      -- buffer at dstN, stopping AT the NUL: the NUL is written at dst[len]
      -- (the Value's len excludes it).  Same stability/no-alloc contract as
      -- cStrLenGo.  Self-tail (recur).
      "defun Rt.cStrCopyGo(srcN : val, dstN : val, i : val) -> val {"
    , "  word byte = byteload(payload(srcN, 0), payload(i, 0));"
    , "  if (mkbool(byte == 0)) {"
    , "    bytestore(payload(dstN, 0), payload(i, 0), 0);"
    , "    return mknil;"
    , "  } else {"
    , "    bytestore(payload(dstN, 0), payload(i, 0), byte);"
    , "    recur(srcN, dstN, mknum(payload(i, 0) + 1));"
    , "  }"
    , "}"
    , ""
    , -- -- Rt.cStrFill: fill buf[0..len] with str's bytes and buf[len] with
      -- the NUL; returns bufN.  str is re-read FRESH each step (strbyte), so
      -- a post-alloc move of the string is handled.  Never allocate here.
      -- Self-tail (recur).
      "defun Rt.cStrFill(bufN : val, str : val, i : val) -> val {"
    , "  if (mkbool(payload(i, 0) >= payload32(str, 1))) {"
    , "    bytestore(payload(bufN, 0), payload(i, 0), 0);"
    , "    return bufN;"
    , "  } else {"
    , "    bytestore(payload(bufN, 0), payload(i, 0), strbyte(str, payload(i, 0)));"
    , "    recur(bufN, str, mknum(payload(i, 0) + 1));"
    , "  }"
    , "}"
    , ""
    , -- -- Rt.readFull: read(fd, buf, count) with the EINTR retry Zig's
      -- std.posix.read gives (raw libc read does not); -1 on a non-EINTR
      -- error.  Non-allocating: buf stays valid through the retry.  The
      -- retry is a PLAIN self-call (call Rt.readFull), NOT recur: the DSL
      -- builder self-references via RawCall (callR) — a native call per
      -- rare EINTR retry — and the corpus pins that shape; recur would
      -- lower it as the in-frame loop, a DIFFERENT tree.
      "defun Rt.readFull(fdN : val, bufN : val, countN : val) -> val {"
    , "  word n = rawcall read(payload(fdN, 0), payload(bufN, 0), payload(countN, 0));"
    , "  if (mkbool(n < 0)) {"
    , "    if (mkbool(byteload(rawcall __errno_location(), 0) == 4)) {"
    , "      return call Rt.readFull(fdN, bufN, countN);"
    , "    }"
    , "    return mknum(-1);"
    , "  }"
    , "  return mknum(n);"
    , "}"
    , ""
    , -- -- Rt.memGo: a generic byte memcpy over a 3-word C-block ([0]=src,
      -- [1]=dst, [2]=end): copies byte i and self-tails until i >= end.
      -- Length-based, NOT NUL-based (file bytes may include NULs).
      -- Frame-free and non-allocating — dst cannot move under it.
      "defun Rt.memGo(blkN : val, iN : val) -> val {"
    , "  word src = wload(payload(blkN, 0), 0);"
    , "  word dst = wload(payload(blkN, 0), 1);"
    , "  word end = wload(payload(blkN, 0), 2);"
    , "  if (mkbool(payload(iN, 0) >= end)) {"
    , "    return mknil;"
    , "  }"
    , "  word b = byteload(src, payload(iN, 0));"
    , "  bytestore(dst, payload(iN, 0), b);"
    , "  recur(blkN, mknum(payload(iN, 0) + 1));"
    , "}"
    , ""
    , -- ====================== T9 — the two T8-deferred prims ======================
      --
      -- -- Rt.close: a string stream closes through the rt_ss_close registry
      -- seat (-2 = halt, the error.Halt arm); a file stream closes only when
      -- its fd /= 0.
      "defun Rt.close(stream : val) -> val {"
    , "  word isStr = payload(stream, 1) > 1;"
    , "  if (mkbool(isStr)) {"
    , "    word r = rawcall rt_ss_close(payload(stream, 0));"
    , "    if (mkbool(r == -2)) {"
    , "      word h = rawcall rt_halt();"
    , "      return mknil;"
    , "    }"
    , "    return mknil;"
    , "  } else {"
    , "    word f = payload(stream, 0);"
    , "    if (mkbool(f != 0)) {"
    , "      rawcall close(f);"
    , "      return mknil;"
    , "    }"
    , "    return mknil;"
    , "  }"
    , "}"
    , ""
    , -- -- Rt.write-byte: stage the byte's low payload word in a 1-byte raw
      -- buffer and write it to the stream's fd; the write result is ignored
      -- exactly as Zig ignores it, and the byte is returned.
      "defun Rt.write-byte(byte : val, stream : val) -> val {"
    , "  word buf = allocraw(1);"
    , "  bytestore(buf, 0, payload(byte, 0));"
    , "  rawcall write(payload(stream, 0), buf, 1);"
    , "  return byte;"
    , "}"
    , ""

    , -- ====================== T10 — wave-3: the equality family, the first @flag-guarded defuns ======================
      --
      -- T10 (handoff-osier-tier2-t10) migrates FIVE keys — the first whose
      -- defuns VARY BY FLAG.  A flag-varied defun is written as surface
      -- defuns sharing ONE key, each with a guard: `@flag` holds when the
      -- flag is on, `@!flag` when off (J8: exactly one active variant per
      -- key per flag combo; the active set is Rt.activeFlags).  ALL
      -- self-recursion below is `call Rt.<own-key>` (RawCall, a native call
      -- per step) — the DSL builders self-reference via callR, NOT recur,
      -- exactly the readFull lesson from T9.
      --
      -- Rt.deepEq: TWO variants — @rec carries the tag-14 arm (records are
      -- positional only under rec; QBE_NOREC=1 restores the pre-E chain),
      -- @!rec is the pre-E tail.  @rec is FIRST and @!rec LAST: under [Rec]
      -- the FIRST must be the one spliced (the T8fix positional-selection
      -- shape, now load-bearing on real runtime bytes).
      --
      -- Rt.=: FOUR variants — the DSL's eqDefun takes rec AND eqPtrFast
      -- (the pointer-identity fast path is an `or2` at THREE symFast sites),
      -- so the trees are the 2x2 product.  Spelling a guard CONJUNCTION
      -- (`@rec @eqPtrFast`) needed the T10 grammar gap fix: the parser now
      -- admits repeated @guards; Ast.flags was always a list and
      -- Check.guardsHold already folded it (Ast/Check untouched).
      --
      -- Rt.vecEq / Rt.bytesEqGo / Rt.symEq: unguarded (flag-independent).
      "@rec"
    , "defun Rt.deepEq(a : val, bb : val) -> val {"
    , "  if (mkbool(tagis(a, 0)) && mkbool(tagis(bb, 0))) {"
    , "    return mkbool(payload(a, 0) == payload(bb, 0));"
    , "  }"
    , "  if (mkbool(tagis(a, 1)) && mkbool(tagis(bb, 1))) {"
    , "    return mkbool(len32(a) == len32(bb)) && call Rt.bytesEqGo(a, bb, mknum(0));"
    , "  }"
    , "  if (mkbool(tagis(a, 2)) && mkbool(tagis(bb, 2))) {"
    , "    return call Rt.symEq(a, bb, mknum(0));"
    , "  }"
    , "  if (mkbool(tagis(a, 3)) && mkbool(tagis(bb, 3))) {"
    , "    return mkbool(payload32(a, 0) == payload32(bb, 0));"
    , "  }"
    , "  if (mkbool(tagis(a, 12)) && mkbool(tagis(bb, 12))) {"
    , "    return mkbool(fload(a) f== fload(bb));"
    , "  }"
    , "  if (mkbool(tagis(a, 5))) {"
    , "    return mkbool(tagis(bb, 5));"
    , "  }"
    , "  if (mkbool(tagis(a, 4)) && mkbool(tagis(bb, 4))) {"
    , "    return call Rt.deepEq(vecload(payload(a, 0), 0), vecload(payload(bb, 0), 0)) && call Rt.deepEq(vecload(payload(a, 0), 1), vecload(payload(bb, 0), 1));"
    , "  }"
    , "  if (mkbool(tagis(a, 14)) && mkbool(tagis(bb, 14))) {"
    , "    return mkbool(len32(a) == len32(bb)) && call Rt.vecEq(a, bb, mknum(0));"
    , "  }"
    , "  if (mkbool(tagis(a, 10)) && mkbool(tagis(bb, 10))) {"
    , "    return mkbool(len32(a) == len32(bb)) && call Rt.vecEq(a, bb, mknum(0));"
    , "  }"
    , "  return false;"
    , "}"
    , ""
    , "@!rec"
    , "defun Rt.deepEq(a : val, bb : val) -> val {"
    , "  if (mkbool(tagis(a, 0)) && mkbool(tagis(bb, 0))) {"
    , "    return mkbool(payload(a, 0) == payload(bb, 0));"
    , "  }"
    , "  if (mkbool(tagis(a, 1)) && mkbool(tagis(bb, 1))) {"
    , "    return mkbool(len32(a) == len32(bb)) && call Rt.bytesEqGo(a, bb, mknum(0));"
    , "  }"
    , "  if (mkbool(tagis(a, 2)) && mkbool(tagis(bb, 2))) {"
    , "    return call Rt.symEq(a, bb, mknum(0));"
    , "  }"
    , "  if (mkbool(tagis(a, 3)) && mkbool(tagis(bb, 3))) {"
    , "    return mkbool(payload32(a, 0) == payload32(bb, 0));"
    , "  }"
    , "  if (mkbool(tagis(a, 12)) && mkbool(tagis(bb, 12))) {"
    , "    return mkbool(fload(a) f== fload(bb));"
    , "  }"
    , "  if (mkbool(tagis(a, 5))) {"
    , "    return mkbool(tagis(bb, 5));"
    , "  }"
    , "  if (mkbool(tagis(a, 4)) && mkbool(tagis(bb, 4))) {"
    , "    return call Rt.deepEq(vecload(payload(a, 0), 0), vecload(payload(bb, 0), 0)) && call Rt.deepEq(vecload(payload(a, 0), 1), vecload(payload(bb, 0), 1));"
    , "  }"
    , "  if (mkbool(tagis(a, 10)) && mkbool(tagis(bb, 10))) {"
    , "    return mkbool(len32(a) == len32(bb)) && call Rt.vecEq(a, bb, mknum(0));"
    , "  }"
    , "  return false;"
    , "}"
    , ""
    , -- -- Rt.bytesEqGo a b i: the string byte walk (lengths already equal).
      "defun Rt.bytesEqGo(a : val, bb : val, i : val) -> val {"
    , "  if (mkbool(payload(i, 0) >= len32(a))) {"
    , "    return true;"
    , "  }"
    , "  return mkbool(strbyte(a, payload(i, 0)) == strbyte(bb, payload(i, 0))) && call Rt.bytesEqGo(a, bb, mknum(payload(i, 0) + 1));"
    , "}"
    , ""
    , -- -- Rt.symEq a b i: the NUL-terminated name walk (symbol/symbol and
      -- symbol/prim; a prim's word 0 is its name pointer, same layout).
      "defun Rt.symEq(a : val, bb : val, i : val) -> val {"
    , "  if (mkbool(strbyte(a, payload(i, 0)) == 0)) {"
    , "    return mkbool(strbyte(bb, payload(i, 0)) == 0);"
    , "  }"
    , "  return mkbool(strbyte(a, payload(i, 0)) == strbyte(bb, payload(i, 0))) && call Rt.symEq(a, bb, mknum(payload(i, 0) + 1));"
    , "}"
    , ""
    , -- -- Rt.vecEq va vb i: elementwise deepEq (lengths already equal).
      "defun Rt.vecEq(a : val, bb : val, i : val) -> val {"
    , "  if (mkbool(payload(i, 0) >= len32(a))) {"
    , "    return true;"
    , "  }"
    , "  return call Rt.deepEq(vecload(payload(a, 0), payload(i, 0)), vecload(payload(bb, 0), payload(i, 0))) && call Rt.vecEq(a, bb, mknum(payload(i, 0) + 1));"
    , "}"
    , ""
    , -- -- Rt.= variant 1 of 4: @rec @eqPtrFast — the tag-14 tail AND the
      -- pointer fast path.  The four variants below are the 2x2 product of
      -- the two switches; each is the same 13-arm chain with exactly two
      -- variation points (the three symFast arms, the tag-14 arm).
      "@rec @eqPtrFast"
    , "defun Rt.=(a : val, bb : val) -> val {"
    , "  if (mkbool(tagis(a, 0)) && mkbool(tagis(bb, 0))) {"
    , "    return mkbool(payload(a, 0) == payload(bb, 0));"
    , "  }"
    , "  if (mkbool(tagis(a, 1)) && mkbool(tagis(bb, 1))) {"
    , "    return mkbool(len32(a) == len32(bb)) && call Rt.bytesEqGo(a, bb, mknum(0));"
    , "  }"
    , "  if (mkbool(tagis(a, 2)) && mkbool(tagis(bb, 2))) {"
    , "    return mkbool(payload(a, 0) == payload(bb, 0)) || call Rt.symEq(a, bb, mknum(0));"
    , "  }"
    , "  if (mkbool(tagis(a, 3)) && mkbool(tagis(bb, 3))) {"
    , "    return mkbool(payload32(a, 0) == payload32(bb, 0));"
    , "  }"
    , "  if ((mkbool(tagis(a, 0)) || mkbool(tagis(a, 12))) && (mkbool(tagis(bb, 0)) || mkbool(tagis(bb, 12)))) {"
    , "    return mkbool(fload(call Rt.asF(a)) f== fload(call Rt.asF(bb)));"
    , "  }"
    , "  if ((mkbool(tagis(a, 4)) && mkbool(tagis(bb, 2))) || (mkbool(tagis(a, 2)) && mkbool(tagis(bb, 4)))) {"
    , "    return false;"
    , "  }"
    , "  if (mkbool(tagis(a, 2)) && mkbool(tagis(bb, 8))) {"
    , "    return mkbool(payload(a, 0) == payload(bb, 0)) || call Rt.symEq(a, bb, mknum(0));"
    , "  }"
    , "  if (mkbool(tagis(a, 8)) && mkbool(tagis(bb, 2))) {"
    , "    return mkbool(payload(a, 0) == payload(bb, 0)) || call Rt.symEq(a, bb, mknum(0));"
    , "  }"
    , "  if (mkbool(tagis(a, 4)) && mkbool(tagis(bb, 4))) {"
    , "    return call Rt.deepEq(a, bb);"
    , "  }"
    , "  if (mkbool(tagis(a, 14)) && mkbool(tagis(bb, 14))) {"
    , "    return call Rt.deepEq(a, bb);"
    , "  }"
    , "  if (mkbool(tagis(a, 10)) && mkbool(tagis(bb, 10))) {"
    , "    return call Rt.deepEq(a, bb);"
    , "  }"
    , "  return mkbool(tagis(a, 5)) && mkbool(tagis(bb, 5));"
    , "}"
    , ""
    , -- -- Rt.= variant 2 of 4: @rec @!eqPtrFast — tag-14 tail, plain symEq.
      "@rec @!eqPtrFast"
    , "defun Rt.=(a : val, bb : val) -> val {"
    , "  if (mkbool(tagis(a, 0)) && mkbool(tagis(bb, 0))) {"
    , "    return mkbool(payload(a, 0) == payload(bb, 0));"
    , "  }"
    , "  if (mkbool(tagis(a, 1)) && mkbool(tagis(bb, 1))) {"
    , "    return mkbool(len32(a) == len32(bb)) && call Rt.bytesEqGo(a, bb, mknum(0));"
    , "  }"
    , "  if (mkbool(tagis(a, 2)) && mkbool(tagis(bb, 2))) {"
    , "    return call Rt.symEq(a, bb, mknum(0));"
    , "  }"
    , "  if (mkbool(tagis(a, 3)) && mkbool(tagis(bb, 3))) {"
    , "    return mkbool(payload32(a, 0) == payload32(bb, 0));"
    , "  }"
    , "  if ((mkbool(tagis(a, 0)) || mkbool(tagis(a, 12))) && (mkbool(tagis(bb, 0)) || mkbool(tagis(bb, 12)))) {"
    , "    return mkbool(fload(call Rt.asF(a)) f== fload(call Rt.asF(bb)));"
    , "  }"
    , "  if ((mkbool(tagis(a, 4)) && mkbool(tagis(bb, 2))) || (mkbool(tagis(a, 2)) && mkbool(tagis(bb, 4)))) {"
    , "    return false;"
    , "  }"
    , "  if (mkbool(tagis(a, 2)) && mkbool(tagis(bb, 8))) {"
    , "    return call Rt.symEq(a, bb, mknum(0));"
    , "  }"
    , "  if (mkbool(tagis(a, 8)) && mkbool(tagis(bb, 2))) {"
    , "    return call Rt.symEq(a, bb, mknum(0));"
    , "  }"
    , "  if (mkbool(tagis(a, 4)) && mkbool(tagis(bb, 4))) {"
    , "    return call Rt.deepEq(a, bb);"
    , "  }"
    , "  if (mkbool(tagis(a, 14)) && mkbool(tagis(bb, 14))) {"
    , "    return call Rt.deepEq(a, bb);"
    , "  }"
    , "  if (mkbool(tagis(a, 10)) && mkbool(tagis(bb, 10))) {"
    , "    return call Rt.deepEq(a, bb);"
    , "  }"
    , "  return mkbool(tagis(a, 5)) && mkbool(tagis(bb, 5));"
    , "}"
    , ""
    , -- -- Rt.= variant 3 of 4: @!rec @eqPtrFast — the pre-E tail, fast path.
      "@!rec @eqPtrFast"
    , "defun Rt.=(a : val, bb : val) -> val {"
    , "  if (mkbool(tagis(a, 0)) && mkbool(tagis(bb, 0))) {"
    , "    return mkbool(payload(a, 0) == payload(bb, 0));"
    , "  }"
    , "  if (mkbool(tagis(a, 1)) && mkbool(tagis(bb, 1))) {"
    , "    return mkbool(len32(a) == len32(bb)) && call Rt.bytesEqGo(a, bb, mknum(0));"
    , "  }"
    , "  if (mkbool(tagis(a, 2)) && mkbool(tagis(bb, 2))) {"
    , "    return mkbool(payload(a, 0) == payload(bb, 0)) || call Rt.symEq(a, bb, mknum(0));"
    , "  }"
    , "  if (mkbool(tagis(a, 3)) && mkbool(tagis(bb, 3))) {"
    , "    return mkbool(payload32(a, 0) == payload32(bb, 0));"
    , "  }"
    , "  if ((mkbool(tagis(a, 0)) || mkbool(tagis(a, 12))) && (mkbool(tagis(bb, 0)) || mkbool(tagis(bb, 12)))) {"
    , "    return mkbool(fload(call Rt.asF(a)) f== fload(call Rt.asF(bb)));"
    , "  }"
    , "  if ((mkbool(tagis(a, 4)) && mkbool(tagis(bb, 2))) || (mkbool(tagis(a, 2)) && mkbool(tagis(bb, 4)))) {"
    , "    return false;"
    , "  }"
    , "  if (mkbool(tagis(a, 2)) && mkbool(tagis(bb, 8))) {"
    , "    return mkbool(payload(a, 0) == payload(bb, 0)) || call Rt.symEq(a, bb, mknum(0));"
    , "  }"
    , "  if (mkbool(tagis(a, 8)) && mkbool(tagis(bb, 2))) {"
    , "    return mkbool(payload(a, 0) == payload(bb, 0)) || call Rt.symEq(a, bb, mknum(0));"
    , "  }"
    , "  if (mkbool(tagis(a, 4)) && mkbool(tagis(bb, 4))) {"
    , "    return call Rt.deepEq(a, bb);"
    , "  }"
    , "  if (mkbool(tagis(a, 10)) && mkbool(tagis(bb, 10))) {"
    , "    return call Rt.deepEq(a, bb);"
    , "  }"
    , "  return mkbool(tagis(a, 5)) && mkbool(tagis(bb, 5));"
    , "}"
    , ""
    , -- -- Rt.= variant 4 of 4: @!rec @!eqPtrFast — the pre-E tail, plain
      -- symEq (the QBE_NOREC=1 + QBE_NOEQPTRFAST=1 shape).
      "@!rec @!eqPtrFast"
    , "defun Rt.=(a : val, bb : val) -> val {"
    , "  if (mkbool(tagis(a, 0)) && mkbool(tagis(bb, 0))) {"
    , "    return mkbool(payload(a, 0) == payload(bb, 0));"
    , "  }"
    , "  if (mkbool(tagis(a, 1)) && mkbool(tagis(bb, 1))) {"
    , "    return mkbool(len32(a) == len32(bb)) && call Rt.bytesEqGo(a, bb, mknum(0));"
    , "  }"
    , "  if (mkbool(tagis(a, 2)) && mkbool(tagis(bb, 2))) {"
    , "    return call Rt.symEq(a, bb, mknum(0));"
    , "  }"
    , "  if (mkbool(tagis(a, 3)) && mkbool(tagis(bb, 3))) {"
    , "    return mkbool(payload32(a, 0) == payload32(bb, 0));"
    , "  }"
    , "  if ((mkbool(tagis(a, 0)) || mkbool(tagis(a, 12))) && (mkbool(tagis(bb, 0)) || mkbool(tagis(bb, 12)))) {"
    , "    return mkbool(fload(call Rt.asF(a)) f== fload(call Rt.asF(bb)));"
    , "  }"
    , "  if ((mkbool(tagis(a, 4)) && mkbool(tagis(bb, 2))) || (mkbool(tagis(a, 2)) && mkbool(tagis(bb, 4)))) {"
    , "    return false;"
    , "  }"
    , "  if (mkbool(tagis(a, 2)) && mkbool(tagis(bb, 8))) {"
    , "    return call Rt.symEq(a, bb, mknum(0));"
    , "  }"
    , "  if (mkbool(tagis(a, 8)) && mkbool(tagis(bb, 2))) {"
    , "    return call Rt.symEq(a, bb, mknum(0));"
    , "  }"
    , "  if (mkbool(tagis(a, 4)) && mkbool(tagis(bb, 4))) {"
    , "    return call Rt.deepEq(a, bb);"
    , "  }"
    , "  if (mkbool(tagis(a, 10)) && mkbool(tagis(bb, 10))) {"
    , "    return call Rt.deepEq(a, bb);"
    , "  }"
    , "  return mkbool(tagis(a, 5)) && mkbool(tagis(bb, 5));"
    , "}"
    , ""

    , -- ====================== T11 — wave-4 part 1: the NUMBER/STRING builders ======================
      --
      -- T11 (handoff-osier-tier2-t11) migrates NINE keys.  ALL
      -- self-recursion below is `call Rt.<own-key>` (RawCall) — including
      -- revGo / countL / fillGo, whose builders self-reference via callR,
      -- NOT recur (the T9 readFull lesson).  `?:` (the T9b value join)
      -- makes its FIRST surface appearance in dgs and numText: their DSL
      -- binders rAbs / signed hold an If in a LET VALUE position, spelled
      -- here as `val x = c ? a : b;` — the 1:1 `Let { x = If { .. } }`.
      --
      -- -- Rt.asF: the M4 numeric promote — a float is itself, a number
      -- widens to float.
      "defun Rt.asF(x : val) -> val {"
    , "  if (mkbool(tagis(x, 12))) {"
    , "    return x;"
    , "  }"
    , "  return mkflt(itof(payload(x, 0)));"
    , "}"
    , ""
    , -- -- Rt.toI32: the Bitwise operand conversion (prims.zig bitOperand) —
      -- float truncates toward zero, a number is itself, anything else 0.
      "defun Rt.toI32(x : val) -> val {"
    , "  if (mkbool(tagis(x, 12))) {"
    , "    return mknum(ftoi32(fload(x)));"
    , "  }"
    , "  if (mkbool(tagis(x, 0))) {"
    , "    return x;"
    , "  }"
    , "  return mknum(0);"
    , "}"
    , ""
    , -- -- Rt.dgs: the digits of n (n /= 0), LEAST-significant first, as a
      -- byte list.  Negative arithmetic throughout (n and r stay
      -- negative): r = n - (n/10)*10 is in [-9..-1] for negative n, so the
      -- digit is 0 - r — no i64 MIN overflow, exactly the shape std.fmt's
      -- {d} uses.  rAbs is the sign-fix binder — an If in a Let VALUE
      -- position in the DSL, here the `?:` join.
      "defun Rt.dgs(n : val) -> val {"
    , "  if (mkbool(payload(n, 0) == 0)) {"
    , "    return mknil;"
    , "  }"
    , "  val q = mknum(payload(n, 0) / 10);"
    , "  val r = mknum(payload(n, 0) - payload(q, 0) * 10);"
    , "  val rAbs = mkbool(payload(n, 0) < 0) ? mknum(0 - payload(r, 0)) : r;"
    , "  val digit = mknum(48 + payload(rAbs, 0));"
    , "  return call Rt.cons(digit, call Rt.dgs(q));"
    , "}"
    , ""
    , -- -- Rt.revGo: the accumulator walk behind reverse AND append
      -- (prims.zig primReverse/primAppend's two loops).  Self-call via
      -- RawCall (callR in the DSL), NOT recur.
      "defun Rt.revGo(l : val, acc : val) -> val {"
    , "  if (mkbool(tagis(l, 4))) {"
    , "    return call Rt.revGo(vecload(payload(l, 0), 1), call Rt.cons(vecload(payload(l, 0), 0), acc));"
    , "  }"
    , "  return acc;"
    , "}"
    , ""
    , -- -- Rt.bytesOf: s's bytes from index i as a byte list (cons + self
      -- RawCall, as above).
      "defun Rt.bytesOf(s : val, i : val) -> val {"
    , "  if (mkbool(payload(i, 0) >= len32(s))) {"
    , "    return mknil;"
    , "  }"
    , "  return call Rt.cons(mknum(strbyte(s, payload(i, 0))), call Rt.bytesOf(s, mknum(payload(i, 0) + 1)));"
    , "}"
    , ""
    , -- -- Rt.numText: a number as its decimal string, byte-exact with
      -- std.fmt's {d}: sign, digits most-significant first (dgs + revGo),
      -- 0 special-cased to "0".  `signed` — the sign-prepend binder — is
      -- the second `?:` join.
      "defun Rt.numText(n : val) -> val {"
    , "  if (mkbool(payload(n, 0) == 0)) {"
    , "    return call Rt.bytesToStr(call Rt.cons(mknum(48), mknil));"
    , "  }"
    , "  val digits = call Rt.revGo(call Rt.dgs(n), mknil);"
    , "  val signed = mkbool(payload(n, 0) < 0) ? call Rt.cons(mknum(45), digits) : digits;"
    , "  return call Rt.bytesToStr(signed);"
    , "}"
    , ""
    , -- -- Rt.bytesToStr: count the list, ONE RawAllocRaw, fill byte by
      -- byte (fillGo), wrap.  `bufN` boxes the buffer pointer as a NUMBER
      -- Value so the recursive filler can take it — the collector sees a
      -- number and never chases it, and no GC can run between the alloc
      -- and the last store (the filler allocs nothing).  The fillGo call
      -- is an EFFECT statement — the DSL's dead b 7 binder.
      "defun Rt.bytesToStr(bs : val) -> val {"
    , "  val count = call Rt.countL(bs);"
    , "  word bufW = allocraw(payload(count, 0) + 1);"
    , "  val bufN = mknum(bufW);"
    , "  call Rt.fillGo(bs, bufN, mknum(0));"
    , "  return mkstr(bufW, payload(count, 0));"
    , "}"
    , ""
    , -- -- Rt.countL: the list's length as a number (cons-cell walk, self
      -- RawCall, NOT recur).
      "defun Rt.countL(l : val) -> val {"
    , "  if (mkbool(tagis(l, 5))) {"
    , "    return mknum(0);"
    , "  }"
    , "  return mknum(payload(call Rt.countL(vecload(payload(l, 0), 1)), 0) + 1);"
    , "}"
    , ""
    , -- -- Rt.fillGo: store the list's bytes at buf[i++] (bufN boxes the
      -- raw pointer; see bytesToStr).  Self RawCall, NOT recur.
      "defun Rt.fillGo(l : val, bufN : val, i : val) -> val {"
    , "  if (mkbool(tagis(l, 5))) {"
    , "    return mknil;"
    , "  }"
    , "  bytestore(payload(bufN, 0), payload(i, 0), payload(vecload(payload(l, 0), 0), 0));"
    , "  return call Rt.fillGo(vecload(payload(l, 0), 1), bufN, mknum(payload(i, 0) + 1));"
    , "}"
    , ""

    , -- ====================== T12 — wave-4 part 2: the remaining builders + the @consArr guard family ======================
      --
      -- T12 (handoff-osier-tier2-t12) migrates SIX plain keys and the
      -- cons pair.  All six plain bodies are single expressions or flat
      -- diverging-if chains (the L6 else-nesting shape); every
      -- self/sibling call below is `call Rt.<key>` (RawCall), none
      -- recur.
      --
      -- Rt.cons / Rt.@p: the SECOND @flag-guarded family.  The DSL's
      -- consDefun took the consArr switch, so each key carries TWO
      -- variants — @consArr FIRST (active under the default flags, the
      -- T10 deepEq positional pattern), @!consArr LAST.  The bodies are
      -- WithRoots(params) around alloc + the two stores + the mkval,
      -- and differ ONLY in the mkval word list: under @consArr ONE
      -- vecaddr (the cdr pointer is derived as pair[1] by every
      -- reader), under @!consArr two.  The DSL's single three-binder
      -- Let lowers to the same bytes as the statement layer's nested
      -- 1-binder Lets (Qbe/Lower.lowerLetBinders folds a Let's binder
      -- list in order); the corpus is the judge.
      "@consArr"
    , "defun Rt.cons(car : val, cdr : val) -> val {"
    , "  return withroots [car, cdr] {"
    , "    word pair = allocvec(2);"
    , "    vecstore(pair, 0, car);"
    , "    vecstore(pair, 1, cdr);"
    , "    return mkval(4, vecaddr(pair, 0));"
    , "  };"
    , "}"
    , ""
    , "@!consArr"
    , "defun Rt.cons(car : val, cdr : val) -> val {"
    , "  return withroots [car, cdr] {"
    , "    word pair = allocvec(2);"
    , "    vecstore(pair, 0, car);"
    , "    vecstore(pair, 1, cdr);"
    , "    return mkval(4, vecaddr(pair, 0), vecaddr(pair, 1));"
    , "  };"
    , "}"
    , ""
    , -- -- Rt.@p: the IDENTICAL fused-pair body as cons (that is the whole
      -- of @p) — the compiled call sites route here, keyed Rt.@p.
      "@consArr"
    , "defun Rt.@p(car : val, cdr : val) -> val {"
    , "  return withroots [car, cdr] {"
    , "    word pair = allocvec(2);"
    , "    vecstore(pair, 0, car);"
    , "    vecstore(pair, 1, cdr);"
    , "    return mkval(4, vecaddr(pair, 0));"
    , "  };"
    , "}"
    , ""
    , "@!consArr"
    , "defun Rt.@p(car : val, cdr : val) -> val {"
    , "  return withroots [car, cdr] {"
    , "    word pair = allocvec(2);"
    , "    vecstore(pair, 0, car);"
    , "    vecstore(pair, 1, cdr);"
    , "    return mkval(4, vecaddr(pair, 0), vecaddr(pair, 1));"
    , "  };"
    , "}"
    , ""
    , -- -- Rt.cn2 x y: concatenate two STRING values (primCn's tail, after
      -- strOf has coerced the operands).
      "defun Rt.cn2(x : val, y : val) -> val {"
    , "  return call Rt.bytesToStr(call Rt.appendL(call Rt.bytesOf(x, mknum(0)), call Rt.bytesOf(y, mknum(0))));"
    , "}"
    , ""
    , -- -- Rt.appendL xs ys: primAppend's shape (reverse-reverse onto the
      -- tail), shared by cn/repeat.
      "defun Rt.appendL(xs : val, ys : val) -> val {"
    , "  return call Rt.revGo(call Rt.revGo(xs, mknil), ys);"
    , "}"
    , ""
    , -- -- Rt.symToStr s i: the null-terminated name at s's word 0 as a
      -- string.  `byte` is already the raw word (byteload); reading it
      -- again through payload would be a value-position payload read.
      "defun Rt.symToStr(s : val, i : val) -> val {"
    , "  word byte = byteload(payload(s, 0), payload(i, 0));"
    , "  if (mkbool(byte == 0)) {"
    , "    return call Rt.bytesToStr(mknil);"
    , "  }"
    , "  return call Rt.bytesToStr(call Rt.cons(mknum(byte), call Rt.nameBytes(s, mknum(payload(i, 0) + 1))));"
    , "}"
    , ""
    , -- -- Rt.nameBytes s i: the name's bytes from i as a list.
      "defun Rt.nameBytes(s : val, i : val) -> val {"
    , "  word byte = byteload(payload(s, 0), payload(i, 0));"
    , "  if (mkbool(byte == 0)) {"
    , "    return mknil;"
    , "  }"
    , "  return call Rt.cons(mknum(byte), call Rt.nameBytes(s, mknum(payload(i, 0) + 1)));"
    , "}"
    , ""
    , -- -- Rt.strOf x: primCn's per-operand coercion — string as-is, number
      -- via numText, symbol via its name, boolean/nil/composite as the C
      -- literals.
      "defun Rt.strOf(x : val) -> val {"
    , "  if (mkbool(tagis(x, 1))) {"
    , "    return x;"
    , "  }"
    , "  if (mkbool(tagis(x, 0))) {"
    , "    return call Rt.numText(x);"
    , "  }"
    , "  if (mkbool(tagis(x, 2))) {"
    , "    return call Rt.symToStr(x, mknum(0));"
    , "  }"
    , "  if (mkbool(tagis(x, 3))) {"
    , "    if (mkbool(payload32(x, 0) != 0)) {"
    , "      return \"true\";"
    , "    }"
    , "    return \"false\";"
    , "  }"
    , "  if (mkbool(tagis(x, 5))) {"
    , "    return \"[]\";"
    , "  }"
    , "  return \"[?]\";"
    , "}"
    , ""
    , -- -- Rt.floatCopy outN bufN i: copy byte i of the static float-text
      -- buffer (outN boxes the buffer pointer + 8 = data start) into the
      -- GC string at bufN, counting DOWN from len-1 to 0.  outN/bufN box
      -- pointers as numbers (the collector never chases them); the
      -- static BSS source is not moved by the GC.  Non-allocating ->
      -- frame-free.  Self RawCall, NOT recur.
      "defun Rt.floatCopy(outN : val, bufN : val, i : val) -> val {"
    , "  if (mkbool(payload(i, 0) < 0)) {"
    , "    return mknil;"
    , "  }"
    , "  bytestore(payload(bufN, 0), payload(i, 0), byteload(payload(outN, 0) + 8, payload(i, 0)));"
    , "  return call Rt.floatCopy(outN, bufN, mknum(payload(i, 0) - 1));"
    , "}"
    , ""
    , -- ====================== T13 — wave-5: the records / vector family ======================
      --
      -- T13 (handoff-osier-tier2-t13) migrates EIGHTEEN keys: the rec walk
      -- block from helperDefuns (assocGo .. recToChainGo, contiguous there),
      -- plus absvector / address-> / <-address / assoc / snd from primDefuns.
      -- All recursion is `call Rt.<key>` (RawCall), measured per defun —
      -- ZERO recur in the whole family.  `reclen` is the nil-aware length
      -- MACRO: it lowers to exactly the DSL's recLenOf tree
      -- (RMul (payload32 v 1) (RSub 1 (tagis v nil))), so every
      -- `recLenOf (v rec)` transcribes 1:1.  The `Rt.address->` /
      -- `Rt.<-address` keys are the first live exercise of `<-`/`->` in the
      -- key charset (T8b).  Everywhere the DSL boxed a raw address as a
      -- number (`ndN = mkNum (v nd)`) the stores/vecaddrs read it BACK
      -- through payload(ndN, 0) — the exact tree, not the raw binder.
      --
      -- -- Rt.assocGo k l: primAssoc's walk — the first pair whose car is a
      -- cons and whose key deep-equals k.  A non-list input is the halt arm
      -- (Zig's throwShen; module header GAPS).  Self RawCall, NOT recur.
      "defun Rt.assocGo(k : val, l : val) -> val {"
    , "  if (mkbool(tagis(l, 4))) {"
    , "    val pair = vecload(payload(l, 0), 0);"
    , "    if (mkbool(tagis(pair, 4)) && call Rt.deepEq(k, vecload(payload(pair, 0), 0))) {"
    , "      return pair;"
    , "    }"
    , "    return call Rt.assocGo(k, vecload(payload(l, 0), 1));"
    , "  }"
    , "  if (mkbool(tagis(l, 5))) {"
    , "    return mknil;"
    , "  }"
    , "  word h = rawcall rt_halt();"
    , "  return mknil;"
    , "}"
    , ""
    , -- -- Rt.recGet rec field: the tag-14 record read's WALK entry (closed-row
      -- sites load data[rank] directly; this is the open/absent/non-Var
      -- fallback).  A pure tail call into the walker.
      "defun Rt.recGet(rec : val, field : val) -> val {"
    , "  return call Rt.recGetGo(rec, field, mknum(0));"
    , "}"
    , ""
    , -- -- Rt.recGetGo rec field i: walk the static names array (word 2),
      -- byte-comparing each name against `field` via symEq (the 8-byte name
      -- pointer read out of the array IS a symbol Value — the layout symEq
      -- reads).  Absent field = the halt arm.  Self RawCall, NOT recur.
      "defun Rt.recGetGo(rec : val, field : val, i : val) -> val {"
    , "  if (mkbool(payload(i, 0) >= reclen(rec))) {"
    , "    word h = rawcall rt_halt();"
    , "    return mknil;"
    , "  }"
    , "  val nameSym = vecload(payload(rec, 2), payload(i, 0));"
    , "  if (call Rt.symEq(nameSym, field, mknum(0))) {"
    , "    return vecload(payload(rec, 0), payload(i, 0));"
    , "  }"
    , "  return call Rt.recGetGo(rec, field, mknum(payload(i, 0) + 1));"
    , "}"
    , ""
    , -- -- Rt.recUpd rec field newv: the tag-14 record UPDATE (the walk form):
      -- find the index, allocate the one array copy, copy all values,
      -- overwrite the found slot, wrap reusing the base's names pointer.
      -- `copied`/`overwrote` are the DSL's dead binders — effect statements.
      "defun Rt.recUpd(rec : val, field : val, newv : val) -> val {"
    , "  val find = call Rt.recUpdFind(rec, field, mknum(0));"
    , "  word nd = allocvec(reclen(rec));"
    , "  val ndN = mknum(nd);"
    , "  call Rt.recUpdCopy(rec, ndN, mknum(0));"
    , "  vecstore(payload(ndN, 0), payload(find, 0), newv);"
    , "  return mkval(14, vecaddr(payload(ndN, 0), 0), reclen(rec), payload(rec, 2));"
    , "}"
    , ""
    , -- -- Rt.recUpdFind rec field i: the field's index, or -1 when absent.
      -- Self RawCall, NOT recur.
      "defun Rt.recUpdFind(rec : val, field : val, i : val) -> val {"
    , "  if (mkbool(payload(i, 0) >= reclen(rec))) {"
    , "    return mknum(-1);"
    , "  }"
    , "  val nameSym = vecload(payload(rec, 2), payload(i, 0));"
    , "  if (call Rt.symEq(nameSym, field, mknum(0))) {"
    , "    return mknum(payload(i, 0));"
    , "  }"
    , "  return call Rt.recUpdFind(rec, field, mknum(payload(i, 0) + 1));"
    , "}"
    , ""
    , -- -- Rt.recUpdCopy rec newdata i: copy data[i] into the copy and tail-call
      -- on.  The dead `stored` binder is an effect statement.  Self RawCall.
      "defun Rt.recUpdCopy(rec : val, newdata : val, i : val) -> val {"
    , "  if (mkbool(payload(i, 0) >= reclen(rec))) {"
    , "    return mknil;"
    , "  }"
    , "  vecstore(payload(newdata, 0), payload(i, 0), vecload(payload(rec, 0), payload(i, 0)));"
    , "  return call Rt.recUpdCopy(rec, newdata, mknum(payload(i, 0) + 1));"
    , "}"
    , ""
    , -- -- Rt.recAppendFind rec field i: the SORTED position the new field must
      -- take — the first index whose name sorts AFTER `field` (symLess), else
      -- len; keeps every tag-14 data/names array canonical.  Self RawCall.
      "defun Rt.recAppendFind(rec : val, field : val, i : val) -> val {"
    , "  if (mkbool(payload(i, 0) >= reclen(rec))) {"
    , "    return mknum(payload(i, 0));"
    , "  }"
    , "  val nameSym = vecload(payload(rec, 2), payload(i, 0));"
    , "  if (call Rt.symLess(field, nameSym, mknum(0))) {"
    , "    return mknum(payload(i, 0));"
    , "  }"
    , "  return call Rt.recAppendFind(rec, field, mknum(payload(i, 0) + 1));"
    , "}"
    , ""
    , -- -- Rt.recAppendDataGo rec newdata packed: copy the base's data into the
      -- one-longer array, leaving a HOLE at the sorted insert position.
      -- `packed` = pos*65536 + j (records have < 65536 fields); `>>>` is the
      -- zero-fill shift (RShR).  `store` — the DSL's If in a Let VALUE
      -- position — is the T9b `?:` join, nested right (vecstore/mknil are
      -- all :val, the agreement rule).  Self RawCall, NOT recur.
      "defun Rt.recAppendDataGo(rec : val, newdata : val, packed : val) -> val {"
    , "  val j = mknum(payload(packed, 0) & 65535);"
    , "  val pos = mknum(payload(packed, 0) >>> 16);"
    , "  if (mkbool(payload(j, 0) > reclen(rec))) {"
    , "    return mknil;"
    , "  }"
    , "  val store = mkbool(payload(j, 0) < payload(pos, 0)) ? vecstore(payload(newdata, 0), payload(j, 0), vecload(payload(rec, 0), payload(j, 0))) : (mkbool(payload(j, 0) == payload(pos, 0)) ? mknil : vecstore(payload(newdata, 0), payload(j, 0), vecload(payload(rec, 0), payload(j, 0) - 1)));"
    , "  return call Rt.recAppendDataGo(rec, newdata, mknum(payload(packed, 0) + 1));"
    , "}"
    , ""
    , -- -- Rt.recAppendNamesGo rec newnames packed: the names-array twin of
      -- recAppendDataGo (word 2 instead of word 0).  Self RawCall, NOT recur.
      "defun Rt.recAppendNamesGo(rec : val, newnames : val, packed : val) -> val {"
    , "  val j = mknum(payload(packed, 0) & 65535);"
    , "  val pos = mknum(payload(packed, 0) >>> 16);"
    , "  if (mkbool(payload(j, 0) > reclen(rec))) {"
    , "    return mknil;"
    , "  }"
    , "  val store = mkbool(payload(j, 0) < payload(pos, 0)) ? vecstore(payload(newnames, 0), payload(j, 0), vecload(payload(rec, 2), payload(j, 0))) : (mkbool(payload(j, 0) == payload(pos, 0)) ? mknil : vecstore(payload(newnames, 0), payload(j, 0), vecload(payload(rec, 2), payload(j, 0) - 1)));"
    , "  return call Rt.recAppendNamesGo(rec, newnames, mknum(payload(packed, 0) + 1));"
    , "}"
    , ""
    , -- -- Rt.recAppend rec field newv: INSERT a NEW field (the `<-` insertion's
      -- absent case) at its SORTED position: two one-longer arrays, the shift
      -- walks, the value and field symbol stored, the wrap carrying BOTH
      -- vecaddrs.  The four copy/store binders are the DSL's dead ones —
      -- effect statements.
      "defun Rt.recAppend(rec : val, field : val, newv : val) -> val {"
    , "  val pos = call Rt.recAppendFind(rec, field, mknum(0));"
    , "  word nd = allocvec(reclen(rec) + 1);"
    , "  val ndN = mknum(nd);"
    , "  word nn = allocvec(reclen(rec) + 1);"
    , "  val nnN = mknum(nn);"
    , "  val packed = mknum(payload(pos, 0) * 65536);"
    , "  call Rt.recAppendDataGo(rec, ndN, packed);"
    , "  call Rt.recAppendNamesGo(rec, nnN, packed);"
    , "  vecstore(payload(ndN, 0), payload(pos, 0), newv);"
    , "  vecstore(payload(nnN, 0), payload(pos, 0), field);"
    , "  return mkval(14, vecaddr(payload(ndN, 0), 0), reclen(rec) + 1, vecaddr(payload(nnN, 0), 0));"
    , "}"
    , ""
    , -- -- Rt.recInsert rec field newv: the `<-` INSERTION-or-update — present
      -- field updates (recUpd), absent appends (recAppend).
      "defun Rt.recInsert(rec : val, field : val, newv : val) -> val {"
    , "  val find = call Rt.recUpdFind(rec, field, mknum(0));"
    , "  if (mkbool(payload(find, 0) >= 0)) {"
    , "    return call Rt.recUpd(rec, field, newv);"
    , "  }"
    , "  return call Rt.recAppend(rec, field, newv);"
    , "}"
    , ""
    , -- -- Rt.recToChain rec: convert a positional record to an assoc chain
      -- (the representation Prelude.removeFieldImpl walks); a non-record is
      -- itself.
      "defun Rt.recToChain(rec : val) -> val {"
    , "  if (mkbool(tagis(rec, 14))) {"
    , "    return call Rt.recToChainGo(rec, mknum(0), mknil);"
    , "  }"
    , "  return rec;"
    , "}"
    , ""
    , -- -- Rt.recToChainGo rec i acc: the walk — cons the (name, value) pair
      -- onto the accumulator back-to-front.  Calls the migrated cons pair
      -- (Rt.@p / Rt.cons).  Self RawCall, NOT recur.
      "defun Rt.recToChainGo(rec : val, i : val, acc : val) -> val {"
    , "  if (mkbool(payload(i, 0) >= reclen(rec))) {"
    , "    return acc;"
    , "  }"
    , "  return call Rt.recToChainGo(rec, mknum(payload(i, 0) + 1), call Rt.cons(call Rt.@p(vecload(payload(rec, 2), payload(i, 0)), vecload(payload(rec, 0), payload(i, 0))), acc));"
    , "}"
    , ""
    , -- -- Rt.absvector n: primAbsvector — valVector of n elements.  The i32
      -- truncation of n is RawAllocVector's word-typed argument (parity with
      -- C's (int)a.number); the len field stores n as the i64 word.  Elements
      -- are UNINITIALIZED on both sides.
      "defun Rt.absvector(cnt : val) -> val {"
    , "  word vec = allocvec(payload(cnt, 0));"
    , "  return mkvec(vec, payload(cnt, 0));"
    , "}"
    , ""
    , -- -- Rt.address-> v i x: primAddressSet — the barrier store at v.data[i];
      -- returns v.  (i's 64-bit payload feeds the word-typed index — the
      -- 32-bit truncation both sides share.)  The dead store binder is an
      -- effect statement.
      "defun Rt.address->(vec : val, i : val, x : val) -> val {"
    , "  vecstore(payload(vec, 0), payload(i, 0), x);"
    , "  return vec;"
    , "}"
    , ""
    , -- -- Rt.<-address v i: primAddressGet — v.data[i] (no bounds guard — the
      -- parity crash).
      "defun Rt.<-address(vec : val, i : val) -> val {"
    , "  return vecload(payload(vec, 0), payload(i, 0));"
    , "}"
    , ""
    , -- -- Rt.assoc k l: primAssoc — assocGo's walk (deepEq on keys).
      "defun Rt.assoc(k : val, l : val) -> val {"
    , "  return call Rt.assocGo(k, l);"
    , "}"
    , ""
    , -- -- Rt.snd x: primSnd — the cdr (no nil guard — the parity crash reads
      -- nil's zero payload as a pointer and faults, BOTH arms).
      "defun Rt.snd(x : val) -> val {"
    , "  return vecload(payload(x, 0), 1);"
    , "}"
    , ""
    , -- ====================== T14 — wave-6: fd / process + the string/value prims ======================
      --
      -- -- Rt.read-byte: one byte from a stream.  A STRING stream reads
      -- through the registry seat with -2 -> halt; a FILE stream reads 1
      -- byte through readFull with 1 -> the byte, anything else -> -1.
      -- `isStr` holds the COMPARE (the DSL binds isStringOf's cmpW
      -- result), so the cond boxes the bare binder.  The packed word is
      -- read with `payload`, the 64-BIT read (word 1 = is_input low |
      -- is_string high) — the DSL's isStringOf used RawPayload, NOT
      -- payload32: is_string * 2^32 must survive the compare, and an i32
      -- read would truncate it back to is_input (the Rt.close precedent).
      "defun Rt.read-byte(stream : val) -> val {"
    , "  word isStr = payload(stream, 1) > 1;"
    , "  if (mkbool(isStr)) {"
    , "    word i = payload(stream, 0);"
    , "    word r = rawcall rt_ss_readbyte(i);"
    , "    if (mkbool(r == -2)) {"
    , "      word h = rawcall rt_halt();"
    , "      return mknil;"
    , "    }"
    , "    return mknum(r);"
    , "  } else {"
    , "    word fd = payload(stream, 0);"
    , "    word bufW = allocraw(1);"
    , "    val nVal = call Rt.readFull(mknum(fd), mknum(bufW), mknum(1));"
    , "    return mkbool(payload(nVal, 0) == 1) ? mknum(byteload(bufW, 0)) : mknum(-1);"
    , "  }"
    , "}"
    , ""
    , -- -- Rt.open path dir: dir "in" (O_RDONLY; ENOENT -> a string stream
      -- of the path) or "out" (O_WRONLY|O_CREAT|O_TRUNC 0666); neither
      -- leaves the accumulator as number 0 (C's fall-through on a zeroed
      -- acc).  Each arm NUL-copies the path (the cStrOf four binders),
      -- openat's, and branches on fd < 0; the ENOENT arm discriminates on
      -- errno (ANY openat failure notes and ""s in read-file-as-string's
      -- Zig twin — here a failed non-ENOENT in-open is plain `false`).
      -- mkval(11, f, i + 4294967296 * s) is the DSL's mkStream packing
      -- word for word 1.
      "defun Rt.open(path : val, dir : val) -> val {"
    , "  if (call Rt.=(dir, \"in\")) {"
    , "    word len = len32(path);"
    , "    word bufW = allocraw(len + 1);"
    , "    val bufN = mknum(bufW);"
    , "    call Rt.cStrFill(bufN, path, mknum(0));"
    , "    word fd = rawcall openat(-100, bufW, 0, 0);"
    , "    if (mkbool(fd < 0)) {"
    , "      if (mkbool(byteload(rawcall __errno_location(), 0) == 2)) {"
    , "        word idx = rawcall rt_ss_in(bufW, len32(path));"
    , "        if (mkbool(idx < 0)) {"
    , "          word h = rawcall rt_halt();"
    , "          return mknil;"
    , "        }"
    , "        return mkval(11, idx, 1 + 4294967296 * 1);"
    , "      }"
    , "      return false;"
    , "    }"
    , "    return mkval(11, fd, 1 + 4294967296 * 0);"
    , "  } else {"
    , "    if (call Rt.=(dir, \"out\")) {"
    , "      word len = len32(path);"
    , "      word bufW = allocraw(len + 1);"
    , "      val bufN = mknum(bufW);"
    , "      call Rt.cStrFill(bufN, path, mknum(0));"
    , "      word fd = rawcall openat(-100, bufW, 577, 438);"
    , "      return mkbool(fd < 0) ? false : mkval(11, fd, 0 + 4294967296 * 0);"
    , "    }"
    , "    return mknum(0);"
    , "  }"
    , "}"
    , ""
    , -- -- Rt.intern: intern the string's bytes (255-byte cap, owned by the
      -- seat) into the symbol table; the symbol Value wraps the canonical
      -- name pointer.
      "defun Rt.intern(str : val) -> val {"
    , "  word dataPtr = payload(str, 0);"
    , "  word len = len32(str);"
    , "  word canon = rawcall rt_sym_intern(dataPtr, len);"
    , "  return mkval(2, canon);"
    , "}"
    , ""
    , -- -- Rt.value sym: the open-addressed values-table lookup, blitting
      -- the slot's Value out (the seat never returns null — the bare-symbol
      -- fallback is done inside rt_value_slot).
      "defun Rt.value(sym : val) -> val {"
    , "  word namePtr = payload(sym, 0);"
    , "  word slotPtr = rawcall rt_value_slot(namePtr);"
    , "  return vecload(slotPtr, 0);"
    , "}"
    , ""
    , -- -- Rt.str x: the two REACHABLE primStr arms.  FLOAT (tag 12):
      -- render through rt_float_text into the static BSS buffer, then COPY
      -- into a GC string (wload reads the buffer's length word) — the copy
      -- is what closes the host-IO hole.  NUMBER (tag 0): Rt.numText.
      -- Anything else halts.
      "defun Rt.str(x : val) -> val {"
    , "  if (mkbool(tagis(x, 12))) {"
    , "    word outPtr = rawcall rt_float_text(payload(x, 0));"
    , "    val lenN = mknum(wload(outPtr, 0));"
    , "    val outN = mknum(outPtr);"
    , "    word bufW = allocraw(payload(lenN, 0));"
    , "    val bufN = mknum(bufW);"
    , "    call Rt.floatCopy(outN, bufN, mknum(payload(lenN, 0) - 1));"
    , "    return mkstr(bufW, payload(lenN, 0));"
    , "  }"
    , "  if (mkbool(tagis(x, 0))) {"
    , "    return call Rt.numText(x);"
    , "  }"
    , "  word h = rawcall rt_halt();"
    , "  return mknil;"
    , "}"
    , ""
    , -- -- Rt.getcwd _: getcwd into a PATH_MAX (4096) GC buffer and return
      -- it AS the string with its NUL-measured length (reusing the buffer
      -- avoids a second alloc, which would MOVE it — cStrLenGo's
      -- contract).  Failure (getcwd NULL) -> "".
      "defun Rt.getcwd(dummy : val) -> val {"
    , "  word bufW = allocraw(4096);"
    , "  word r = rawcall getcwd(bufW, 4096);"
    , "  if (mkbool(r == 0)) {"
    , "    return \"\";"
    , "  }"
    , "  val len = call Rt.cStrLenGo(mknum(bufW), mknum(0));"
    , "  return mkstr(bufW, payload(len, 0));"
    , "}"
    , ""
    , -- -- Rt.cd path: chdir to the NUL-terminated copy of `path` (the
      -- cStrOf four binders; chdir runs before any further allocation, so
      -- the buffer is valid at the call); boolean success.
      "defun Rt.cd(path : val) -> val {"
    , "  word len = len32(path);"
    , "  word bufW = allocraw(len + 1);"
    , "  val bufN = mknum(bufW);"
    , "  call Rt.cStrFill(bufN, path, mknum(0));"
    , "  word rc = rawcall chdir(bufW);"
    , "  return mkbool(rc == 0);"
    , "}"
    , ""
    , -- -- Rt.getenv name: getenv of the NUL-terminated copy of `name`,
      -- copied into a GC string (the env pointer is libc-owned and stable
      -- across the alloc); absent -> "".
      "defun Rt.getenv(name : val) -> val {"
    , "  word len = len32(name);"
    , "  word bufW = allocraw(len + 1);"
    , "  val bufN = mknum(bufW);"
    , "  call Rt.cStrFill(bufN, name, mknum(0));"
    , "  word r = rawcall getenv(bufW);"
    , "  if (mkbool(r == 0)) {"
    , "    return \"\";"
    , "  }"
    , "  val len2 = call Rt.cStrLenGo(mknum(r), mknum(0));"
    , "  word dstW = allocraw(payload(len2, 0) + 1);"
    , "  val dstN = mknum(dstW);"
    , "  call Rt.cStrCopyGo(mknum(r), dstN, mknum(0));"
    , "  return mkstr(dstW, payload(len2, 0));"
    , "}"
    , ""
    , -- -- Rt.setenv name value: setenv(name, value, 1) with BOTH copies
      -- packed into ONE GC buffer (name at 0, value at nameLen+1), so the
      -- two NUL-terminated pointers are live at the single call without a
      -- second allocation (which would move the first buffer).  Always
      -- returns true.  The alloc size and valPtrW keep the DSL's exact
      -- grouping: (nameLen + valueLen) + 2, bufW + (nameLen + 1).
      "defun Rt.setenv(name : val, value : val) -> val {"
    , "  word nameLen = len32(name);"
    , "  word valueLen = len32(value);"
    , "  word bufW = allocraw(nameLen + valueLen + 2);"
    , "  val bufN = mknum(bufW);"
    , "  call Rt.cStrFill(bufN, name, mknum(0));"
    , "  word valPtrW = bufW + (nameLen + 1);"
    , "  val valPtrN = mknum(valPtrW);"
    , "  call Rt.cStrFill(valPtrN, value, mknum(0));"
    , "  rawcall setenv(bufW, valPtrW, 1);"
    , "  return true;"
    , "}"
    , ""

    , -- ====================== T15 — wave-7: the glob family ======================
      --
      -- -- Rt.globLastSlash ptrN iN: the index of the LAST '/' in the pattern,
      -- searching BACKWARD from iN (entered at len-1); -1 at the top.
      -- Self-tail (recur): the in-frame jmp @body loop.
      "defun Rt.globLastSlash(ptrN : val, iN : val) -> val {"
    , "  if (mkbool(payload(iN, 0) < 0)) {"
    , "    return mknum(-1);"
    , "  }"
    , "  word byte = byteload(payload(ptrN, 0), payload(iN, 0));"
    , "  if (mkbool(byte == 47)) {"
    , "    return mknum(payload(iN, 0));"
    , "  }"
    , "  recur(ptrN, mknum(payload(iN, 0) - 1));"
    , "}"
    , ""
    , -- -- Rt.globIsDot ptrN / Rt.globIsDotDot ptrN: byte-exact "." / ".."
      -- tests on a NUL-terminated C string.  Non-recursive.  The dotdot
      -- chain nests RIGHT in the DSL (and2 a (and2 b c)) — explicit parens,
      -- the surface `&&` parses left-assoc.
      "defun Rt.globIsDot(ptrN : val) -> val {"
    , "  word c0 = byteload(payload(ptrN, 0), 0);"
    , "  word c1 = byteload(payload(ptrN, 0), 1);"
    , "  return mkbool(c0 == 46) && mkbool(c1 == 0);"
    , "}"
    , ""
    , "defun Rt.globIsDotDot(ptrN : val) -> val {"
    , "  word c0 = byteload(payload(ptrN, 0), 0);"
    , "  word c1 = byteload(payload(ptrN, 0), 1);"
    , "  word c2 = byteload(payload(ptrN, 0), 2);"
    , "  return mkbool(c0 == 46) && (mkbool(c1 == 46) && mkbool(c2 == 0));"
    , "}"
    , ""
    , -- -- Rt.globScanGo stateN: the readdir/fnmatch loop over the 5-word
      -- C-heap state block (DIR*, base, table, skip-dotfiles, count), capped
      -- at 1024 matches; each match dupe'd onto the C heap (malloc len+1 +
      -- cStrCopyGo), the pointer stored at tbl[n].  The dotfile guard keeps
      -- the DSL's RAW `||` inside the `&&` (explicit parens).  The dupe-OOM
      -- check is the DSL's If-in-LET-VALUE with haltV — spelled as the
      -- mid-block if with BOTH branches diverging (the lowerer dead-binds
      -- it at a fresh binder, the continuation as the Let body).  Self-tail
      -- (recur) at all three sites.
      "defun Rt.globScanGo(stateN : val) -> val {"
    , "  word dW = wload(payload(stateN, 0), 0);"
    , "  word baseW = wload(payload(stateN, 0), 1);"
    , "  word tblW = wload(payload(stateN, 0), 2);"
    , "  word guardW = wload(payload(stateN, 0), 3);"
    , "  word nW = wload(payload(stateN, 0), 4);"
    , "  if (mkbool(nW >= 1024)) {"
    , "    return mknum(nW);"
    , "  }"
    , "  word entW = rawcall readdir(dW);"
    , "  if (mkbool(entW == 0)) {"
    , "    return mknum(nW);"
    , "  }"
    , "  word nameW = entW + 19;"
    , "  word fmW = rawcall fnmatch(baseW, nameW, 0);"
    , "  if (mkbool(fmW != 0)) {"
    , "    recur(stateN);"
    , "  }"
    , "  val nameDot = call Rt.globIsDot(mknum(nameW));"
    , "  val nameDD = call Rt.globIsDotDot(mknum(nameW));"
    , "  if ((nameDot || nameDD) && mkbool(guardW != 0)) {"
    , "    recur(stateN);"
    , "  }"
    , "  val lenN = call Rt.cStrLenGo(mknum(nameW), mknum(0));"
    , "  word pW = rawcall malloc(payload(lenN, 0) + 1);"
    , "  if (mkbool(pW == 0)) {"
    , "    word h = rawcall rt_halt();"
    , "    return mknil;"
    , "  } else {"
    , "    return mknum(0);"
    , "  }"
    , "  call Rt.cStrCopyGo(mknum(nameW), mknum(pW), mknum(0));"
    , "  wstore(tblW, nW, pW);"
    , "  wstore(payload(stateN, 0), 4, nW + 1);"
    , "  recur(stateN);"
    , "}"
    , ""
    , -- -- Rt.globStrLess aN bN iN: strcmp order over two NUL-terminated C
      -- strings (unsigned bytes; a prefix sorts before its extension).
      -- Self-tail (recur).
      "defun Rt.globStrLess(aN : val, bN : val, iN : val) -> val {"
    , "  word ca = byteload(payload(aN, 0), payload(iN, 0));"
    , "  word cb = byteload(payload(bN, 0), payload(iN, 0));"
    , "  if (mkbool(ca < cb)) {"
    , "    return true;"
    , "  }"
    , "  if (mkbool(ca > cb)) {"
    , "    return false;"
    , "  }"
    , "  if (mkbool(ca == 0)) {"
    , "    return false;"
    , "  }"
    , "  recur(aN, bN, mknum(payload(iN, 0) + 1));"
    , "}"
    , ""
    , -- -- Rt.globSortShift tblN jN keyN: the insertion-sort inner shift —
      -- slide tbl[j] right while it sorts after the key; returns the index
      -- the key belongs at.  Self-tail (recur).
      "defun Rt.globSortShift(tblN : val, jN : val, keyN : val) -> val {"
    , "  if (mkbool(payload(jN, 0) < 0)) {"
    , "    return mknum(payload(jN, 0));"
    , "  }"
    , "  word curW = wload(payload(tblN, 0), payload(jN, 0));"
    , "  val lessB = call Rt.globStrLess(keyN, mknum(curW), mknum(0));"
    , "  if (lessB) {"
    , "    wstore(payload(tblN, 0), payload(jN, 0) + 1, curW);"
    , "    recur(tblN, mknum(payload(jN, 0) - 1), keyN);"
    , "  }"
    , "  return mknum(payload(jN, 0));"
    , "}"
    , ""
    , -- -- Rt.globSortGo tblN iN nN: insertion sort of tbl[0..n).  Self-tail
      -- (recur).
      "defun Rt.globSortGo(tblN : val, iN : val, nN : val) -> val {"
    , "  if (mkbool(payload(iN, 0) >= payload(nN, 0))) {"
    , "    return mknum(payload(nN, 0));"
    , "  }"
    , "  word keyW = wload(payload(tblN, 0), payload(iN, 0));"
    , "  val jN = call Rt.globSortShift(tblN, mknum(payload(iN, 0) - 1), mknum(keyW));"
    , "  wstore(payload(tblN, 0), payload(jN, 0) + 1, keyW);"
    , "  recur(tblN, mknum(payload(iN, 0) + 1), nN);"
    , "}"
    , ""
    , -- -- Rt.globBuildGo tblN iN acc: the result list, inside-out from the
      -- sorted table — copy each C-heap match into a fresh GC string (len,
      -- alloc, cStrCopyGo, mkStr), free the C copy, cons.  ALLOCATING: the
      -- cons chain is where safepoints live.  The cons chain's tree is
      -- LOAD-BEARING exactly as written (the DSL doc's evaluation-order
      -- note) — transcribed 1:1, no reorder.  Self-tail (recur).
      "defun Rt.globBuildGo(tblN : val, iN : val, acc : val) -> val {"
    , "  if (mkbool(payload(iN, 0) < 0)) {"
    , "    return acc;"
    , "  }"
    , "  word pW = wload(payload(tblN, 0), payload(iN, 0));"
    , "  val lenN = call Rt.cStrLenGo(mknum(pW), mknum(0));"
    , "  word bufW = allocraw(payload(lenN, 0) + 1);"
    , "  call Rt.cStrCopyGo(mknum(pW), mknum(bufW), mknum(0));"
    , "  rawcall free(pW);"
    , "  recur(tblN, mknum(payload(iN, 0) - 1), call Rt.cons(call Rt.intern(\"cons\"), call Rt.cons(call Rt.cons(call Rt.intern(\"string\"), call Rt.cons(mkstr(bufW, payload(lenN, 0)), mknil)), call Rt.cons(acc, mknil))));"
    , "}"
    , ""
    , -- -- Rt.glob pattern: split at the LAST '/', opendir/readdir/fnmatch
      -- the base over the directory, cap 1024, sort, build the tagged list.
      -- One 8240-byte C scratch block (malloc; OOM -> rt_halt, LOUD): [0]
      -- the "." literal, [2..5) the ".." literal, [8..8200) the table,
      -- [8200..8240) the scan state block.  The head is the cStrOf four
      -- binders; the '/' is NUL'd IN PLACE inside the slash arm only — the
      -- DSL's If-in-LET-VALUE with a store-then-mknum(0) then-branch, again
      -- the both-branches-diverge spelling.  opendir failure -> nil.
      "defun Rt.glob(pattern : val) -> val {"
    , "  word len = len32(pattern);"
    , "  word patW = allocraw(len + 1);"
    , "  val patN = mknum(patW);"
    , "  call Rt.cStrFill(patN, pattern, mknum(0));"
    , "  val siN = call Rt.globLastSlash(mknum(patW), mknum(len32(pattern) - 1));"
    , "  word cbufW = rawcall malloc(8240);"
    , "  if (mkbool(cbufW == 0)) {"
    , "    word h = rawcall rt_halt();"
    , "    return mknil;"
    , "  } else {"
    , "    return mknum(0);"
    , "  }"
    , "  bytestore(cbufW, 0, 46);"
    , "  bytestore(cbufW, 1, 0);"
    , "  bytestore(cbufW, 2, 46);"
    , "  bytestore(cbufW, 3, 46);"
    , "  bytestore(cbufW, 4, 0);"
    , "  word tblW = cbufW + 8;"
    , "  word stateW = cbufW + 8200;"
    , "  val hasS = mkbool(payload(siN, 0) >= 0);"
    , "  val dirN = hasS ? mknum(patW) : mknum(cbufW);"
    , "  val baseN = hasS ? mknum(patW + (payload(siN, 0) + 1)) : mknum(patW);"
    , "  if (hasS) {"
    , "    bytestore(patW, payload(siN, 0), 0);"
    , "    return mknum(0);"
    , "  } else {"
    , "    return mknum(0);"
    , "  }"
    , "  word dW = rawcall opendir(payload(dirN, 0));"
    , "  if (mkbool(dW == 0)) {"
    , "    word fN = rawcall free(cbufW);"
    , "    return mknil;"
    , "  } else {"
    , "    val baseDot = mkbool(rawcall fnmatch(payload(baseN, 0), cbufW, 0) == 0);"
    , "    val baseDD = mkbool(rawcall fnmatch(payload(baseN, 0), cbufW + 2, 0) == 0);"
    , "    wstore(stateW, 0, dW);"
    , "    wstore(stateW, 1, payload(baseN, 0));"
    , "    wstore(stateW, 2, tblW);"
    , "    wstore(stateW, 3, payload((baseDot || baseDD) ? mknum(0) : mknum(1), 0));"
    , "    wstore(stateW, 4, 0);"
    , "    val nN = call Rt.globScanGo(mknum(stateW));"
    , "    rawcall closedir(dW);"
    , "    call Rt.globSortGo(mknum(tblW), mknum(1), nN);"
    , "    val res = call Rt.globBuildGo(mknum(tblW), mknum(payload(nN, 0) - 1), call Rt.cons(call Rt.intern(\"cons\"), mknil));"
    , "    rawcall free(cbufW);"
    , "    return res;"
    , "  }"
    , "}"
    , ""
    , -- ====================== T16 — wave-8: the ep* exec-plan DECODE family ======================
      --
      -- Twenty keys moved to Mid/RtSource: the blob decode walk (RtLayout's ep*
      -- constants transcribed as LITERALS — prog[0/1], chain{op,pipe}, pipe[0/1],
      -- cmd{argv,argc,redirs,nredirs,sub}, redir{kind,fd,path,dupfd,body,tmpfd=6
      -- words}, the epOp*/epKind* codes, the cbuf literal offsets 4..12/16/24/32..96).
      -- Rt.epCmd was NOT in T16: its ago/rgo binders (RtPrims epCmdDefun)
      -- are Ifs in LET-VALUE positions whose else carries a Let-chain (malloc +
      -- OOM check + store + epArgvGo/epRedirsGo) and whose VALUE the continuation
      -- reads (iff (ago < 0) ..) — unspellable then: ?: needs expression branches,
      -- both-diverge needs both branches returning, else-nesting needs a diverging
      -- then.  T23's block-branch if closed the class and T24 migrated it (the
      -- T24 block below); tagCountState was written out at its subState binder.  The three epUnwrap template instances are written out
      -- EXPLICITLY (the Elm template died): Rt.epNum (+16, tag 0), Rt.epStr (+8,
      -- tag 1), Rt.epSymOf (+24, tag 2).  Recursion MEASURED per defun: SELF-TAIL
      -- recur in epSymIs/epCount/epElem/epProgGo/epPipeGo/epArgvGo/epRedirsGo/
      -- epCountStdin/epFreeChains (two sites)/epFreeCmds/epFreeArgv/epFreeRedirs;
      -- no self-call in epNum/epStr/epSymOf/epProg/epChain/epPipeline/epRedir/
      -- epFreeCmd.  The tdl-state chain (the DSL's tagCountState helper, an If
      -- chain in a LET VALUE) is the T9b ?: join nested right; the OOM checks are
      -- the T15 both-branches-diverge spelling (haltV; return mknum(0)); a bare
      -- call in a branch value (epFreeCmd's iff arms) is `return call Rt.f(..);`.
      --
      -- -- Rt.epSymIs sym litN i: byte-compare the symbol's text against the
      -- -- cbuf literal at byte offset litN, from index i.  Self-tail (recur).
      "defun Rt.epSymIs(sym : val, litN : val, i : val) -> val {"
    , "  word la = strbyte(sym, payload(i, 0));"
    , "  word lb = byteload(payload(litN, 0), payload(i, 0));"
    , "  if (mkbool(lb == 0)) {"
    , "    return mkbool(la == 0);"
    , "  }"
    , "  if (mkbool(la == lb)) {"
    , "    recur(sym, litN, mknum(payload(i, 0) + 1));"
    , "  }"
    , "  return false;"
    , "}"
    , ""
    , -- -- Rt.epCount vv stN accN: the tagged list's length (Zig tdlLen), or -1
      -- -- malformed.  st[2] is the caller's limit — the walk bails at
      -- -- acc > limit so absurd inputs cannot walk unbounded.  Self-tail (recur).
      "defun Rt.epCount(vv : val, stN : val, accN : val) -> val {"
    , "  word cbufW = wload(payload(stN, 0), 0);"
    , "  word limW = wload(payload(stN, 0), 2);"
    , "  val stV = mkbool(tagis(vv, 4) == 0) ? mknum(2) : (mkbool(tagis(vecload(payload(vv, 0), 0), 2) == 0) ? mknum(2) : (call Rt.epSymIs(vecload(payload(vv, 0), 0), mknum(cbufW), mknum(0)) ? (mkbool(tagis(vecload(payload(vv, 0), 1), 5) != 0) ? mknum(0) : (mkbool(tagis(vecload(payload(vv, 0), 1), 4) != 0) ? mknum(1) : mknum(2))) : mknum(2)));"
    , "  if (mkbool(payload(stV, 0) == 2)) {"
    , "    return mknum(-1);"
    , "  }"
    , "  if (mkbool(payload(stV, 0) == 0)) {"
    , "    return accN;"
    , "  }"
    , "  val t1 = vecload(payload(vecload(payload(vv, 0), 1), 0), 1);"
    , "  if (mkbool(payload(accN, 0) > limW)) {"
    , "    return accN;"
    , "  }"
    , "  if (mkbool(tagis(t1, 4) == 0)) {"
    , "    return mknum(-1);"
    , "  }"
    , "  recur(vecload(payload(t1, 0), 0), stN, mknum(payload(accN, 0) + 1));"
    , "}"
    , ""
    , -- -- Rt.epElem vv iN tgtN: the tgt'th element of the tagged list, or mknil
      -- -- (a sentinel every consumer's tag check rejects).  Structural walk only:
      -- -- every caller ran epCount over the same spine first.  Self-tail (recur).
      "defun Rt.epElem(vv : val, iN : val, tgtN : val) -> val {"
    , "  if (mkbool(tagis(vv, 4) == 0)) {"
    , "    return mknil;"
    , "  }"
    , "  if (mkbool(tagis(vecload(payload(vv, 0), 1), 5) != 0)) {"
    , "    return mknil;"
    , "  }"
    , "  if (mkbool(tagis(vecload(payload(vv, 0), 1), 4) == 0)) {"
    , "    return mknil;"
    , "  }"
    , "  if (mkbool(payload(iN, 0) == payload(tgtN, 0))) {"
    , "    return vecload(payload(vecload(payload(vv, 0), 1), 0), 0);"
    , "  }"
    , "  val t1 = vecload(payload(vecload(payload(vv, 0), 1), 0), 1);"
    , "  if (mkbool(tagis(t1, 4) == 0)) {"
    , "    return mknil;"
    , "  }"
    , "  recur(vecload(payload(t1, 0), 0), mknum(payload(iN, 0) + 1), tgtN);"
    , "}"
    , ""
    , -- -- Rt.epNum / Rt.epStr / Rt.epSymOf vv cbufN: the epUnwrap template
      -- -- written out — [sym X] + [wantTag V] -> V, or mknil.  epNum's literal
      -- -- offset is cbuf word 4 (+16 bytes), epStr's word 2 (+8), epSymOf's
      -- -- word 3 (+24); wantTag number/string/symbol = 0/1/2.
      "defun Rt.epNum(vv : val, cbufN : val) -> val {"
    , "  if (mkbool(tagis(vv, 4) == 0)) {"
    , "    return mknil;"
    , "  }"
    , "  if (mkbool(tagis(vecload(payload(vv, 0), 0), 2) == 0)) {"
    , "    return mknil;"
    , "  }"
    , "  if (call Rt.epSymIs(vecload(payload(vv, 0), 0), mknum(payload(cbufN, 0) + 16), mknum(0))) {"
    , "    if (mkbool(tagis(vecload(payload(vv, 0), 1), 4) == 0)) {"
    , "      return mknil;"
    , "    }"
    , "    if (mkbool(tagis(vecload(payload(vecload(payload(vv, 0), 1), 0), 0), 0) == 0)) {"
    , "      return mknil;"
    , "    }"
    , "    return vecload(payload(vecload(payload(vv, 0), 1), 0), 0);"
    , "  }"
    , "  return mknil;"
    , "}"
    , "defun Rt.epStr(vv : val, cbufN : val) -> val {"
    , "  if (mkbool(tagis(vv, 4) == 0)) {"
    , "    return mknil;"
    , "  }"
    , "  if (mkbool(tagis(vecload(payload(vv, 0), 0), 2) == 0)) {"
    , "    return mknil;"
    , "  }"
    , "  if (call Rt.epSymIs(vecload(payload(vv, 0), 0), mknum(payload(cbufN, 0) + 8), mknum(0))) {"
    , "    if (mkbool(tagis(vecload(payload(vv, 0), 1), 4) == 0)) {"
    , "      return mknil;"
    , "    }"
    , "    if (mkbool(tagis(vecload(payload(vecload(payload(vv, 0), 1), 0), 0), 1) == 0)) {"
    , "      return mknil;"
    , "    }"
    , "    return vecload(payload(vecload(payload(vv, 0), 1), 0), 0);"
    , "  }"
    , "  return mknil;"
    , "}"
    , "defun Rt.epSymOf(vv : val, cbufN : val) -> val {"
    , "  if (mkbool(tagis(vv, 4) == 0)) {"
    , "    return mknil;"
    , "  }"
    , "  if (mkbool(tagis(vecload(payload(vv, 0), 0), 2) == 0)) {"
    , "    return mknil;"
    , "  }"
    , "  if (call Rt.epSymIs(vecload(payload(vv, 0), 0), mknum(payload(cbufN, 0) + 24), mknum(0))) {"
    , "    if (mkbool(tagis(vecload(payload(vv, 0), 1), 4) == 0)) {"
    , "      return mknil;"
    , "    }"
    , "    if (mkbool(tagis(vecload(payload(vecload(payload(vv, 0), 1), 0), 0), 2) == 0)) {"
    , "      return mknil;"
    , "    }"
    , "    return vecload(payload(vecload(payload(vv, 0), 1), 0), 0);"
    , "  }"
    , "  return mknil;"
    , "}"
    , ""
    , -- -- Rt.epProg vv stN: decodeProgram — the tagged chain list -> a malloc'd
      -- -- prog record [nchains, chains*] (16 bytes), or -1 malformed (every
      -- -- failure path frees its own decoded prefix first).  An EMPTY program is
      -- -- legal (runs nothing, exit 0).  prog[0] IS the running count — the
      -- -- partial-free discipline epFreeChains frees against.  No self-call.
      "defun Rt.epProg(vv : val, stN : val) -> val {"
    , "  wstore(payload(stN, 0), 2, 256);"
    , "  val cnt = call Rt.epCount(vv, stN, mknum(0));"
    , "  if (mkbool(payload(cnt, 0) < 0) || mkbool(payload(cnt, 0) > 256)) {"
    , "    return mknum(-1);"
    , "  }"
    , "  word progW = rawcall malloc(16);"
    , "  if (mkbool(progW == 0)) {"
    , "    word h = rawcall rt_halt();"
    , "    return mknil;"
    , "  } else {"
    , "    return mknum(0);"
    , "  }"
    , "  wstore(progW, 0, 0);"
    , "  wstore(progW, 1, 0);"
    , "  if (mkbool(payload(cnt, 0) == 0)) {"
    , "    return mknum(progW);"
    , "  }"
    , "  word chainsW = rawcall malloc(payload(cnt, 0) * 16);"
    , "  if (mkbool(chainsW == 0)) {"
    , "    word h = rawcall rt_halt();"
    , "    return mknil;"
    , "  } else {"
    , "    return mknum(0);"
    , "  }"
    , "  wstore(progW, 1, chainsW);"
    , "  val go = call Rt.epProgGo(vv, stN, mknum(progW));"
    , "  if (mkbool(payload(go, 0) < 0)) {"
    , "    call Rt.epFreeChains(mknum(progW), mknum(chainsW), mknum(0));"
    , "    return mknum(-1);"
    , "  }"
    , "  return mknum(progW);"
    , "}"
    , ""
    , -- -- Rt.epProgGo vv stN progN: the chain fill loop; prog[0] IS the running
      -- -- count.  Self-tail (recur); frame-free, non-allocating.
      "defun Rt.epProgGo(vv : val, stN : val, progN : val) -> val {"
    , "  word cbufW = wload(payload(stN, 0), 0);"
    , "  word iW = wload(payload(progN, 0), 0);"
    , "  word chainsW = wload(payload(progN, 0), 1);"
    , "  val stV = mkbool(tagis(vv, 4) == 0) ? mknum(2) : (mkbool(tagis(vecload(payload(vv, 0), 0), 2) == 0) ? mknum(2) : (call Rt.epSymIs(vecload(payload(vv, 0), 0), mknum(cbufW), mknum(0)) ? (mkbool(tagis(vecload(payload(vv, 0), 1), 5) != 0) ? mknum(0) : (mkbool(tagis(vecload(payload(vv, 0), 1), 4) != 0) ? mknum(1) : mknum(2))) : mknum(2)));"
    , "  if (mkbool(payload(stV, 0) == 2)) {"
    , "    return mknum(-1);"
    , "  }"
    , "  if (mkbool(payload(stV, 0) == 0)) {"
    , "    return mknum(0);"
    , "  }"
    , "  val t1 = vecload(payload(vecload(payload(vv, 0), 1), 0), 1);"
    , "  word chAddr = chainsW + (iW * 16);"
    , "  val r = call Rt.epChain(vecload(payload(vecload(payload(vv, 0), 1), 0), 0), stN, mknum(chAddr));"
    , "  if (mkbool(payload(r, 0) < 0)) {"
    , "    return mknum(-1);"
    , "  }"
    , "  wstore(payload(progN, 0), 0, iW + 1);"
    , "  recur(vecload(payload(t1, 0), 0), stN, progN);"
    , "}"
    , ""
    , -- -- Rt.epChain e stN chAddrN: decodeChain — [op Pipeline], len 2, op one
      -- -- of seq/and/or (cbuf words 4/5/6, byte offsets 32/40/48); the op is
      -- -- validated BEFORE the pipeline decode, so a bad-op chain never
      -- -- allocates.  No self-call.
      "defun Rt.epChain(e : val, stN : val, chAddrN : val) -> val {"
    , "  wstore(payload(stN, 0), 2, 8);"
    , "  val cnt = call Rt.epCount(e, stN, mknum(0));"
    , "  word cbufW = wload(payload(stN, 0), 0);"
    , "  if (mkbool(payload(cnt, 0) != 2)) {"
    , "    return mknum(-1);"
    , "  }"
    , "  val opv = call Rt.epElem(e, mknum(0), mknum(0));"
    , "  val pipev = call Rt.epElem(e, mknum(0), mknum(1));"
    , "  val xsym = call Rt.epSymOf(opv, mknum(cbufW));"
    , "  if (mkbool(tagis(xsym, 2) == 0)) {"
    , "    return mknum(-1);"
    , "  }"
    , "  val isSeq = call Rt.epSymIs(xsym, mknum(cbufW + 32), mknum(0));"
    , "  val isAnd = call Rt.epSymIs(xsym, mknum(cbufW + 40), mknum(0));"
    , "  val isOr = call Rt.epSymIs(xsym, mknum(cbufW + 48), mknum(0));"
    , "  val opV = isSeq ? mknum(0) : (isAnd ? mknum(1) : (isOr ? mknum(2) : mknum(-1)));"
    , "  if (mkbool(payload(opV, 0) < 0)) {"
    , "    return mknum(-1);"
    , "  }"
    , "  val pipeN = call Rt.epPipeline(pipev, stN);"
    , "  if (mkbool(payload(pipeN, 0) < 0)) {"
    , "    return mknum(-1);"
    , "  }"
    , "  wstore(payload(chAddrN, 0), 0, payload(opV, 0));"
    , "  wstore(payload(chAddrN, 0), 1, payload(pipeN, 0));"
    , "  return mknum(0);"
    , "}"
    , ""
    , -- -- Rt.epPipeline vv stN: decodePipeline — >= 1 command, <= 64; the
      -- -- malloc'd pipe record [ncmds, cmds*] (16 bytes) or -1 (own partial
      -- -- state freed).  No self-call.
      "defun Rt.epPipeline(vv : val, stN : val) -> val {"
    , "  wstore(payload(stN, 0), 2, 64);"
    , "  val cnt = call Rt.epCount(vv, stN, mknum(0));"
    , "  if (mkbool(payload(cnt, 0) < 1) || mkbool(payload(cnt, 0) > 64)) {"
    , "    return mknum(-1);"
    , "  }"
    , "  word pipeW = rawcall malloc(16);"
    , "  if (mkbool(pipeW == 0)) {"
    , "    word h = rawcall rt_halt();"
    , "    return mknil;"
    , "  } else {"
    , "    return mknum(0);"
    , "  }"
    , "  wstore(pipeW, 0, 0);"
    , "  wstore(pipeW, 1, 0);"
    , "  word cmdsW = rawcall malloc(payload(cnt, 0) * 40);"
    , "  if (mkbool(cmdsW == 0)) {"
    , "    word h = rawcall rt_halt();"
    , "    return mknil;"
    , "  } else {"
    , "    return mknum(0);"
    , "  }"
    , "  wstore(pipeW, 1, cmdsW);"
    , "  val go = call Rt.epPipeGo(vv, stN, mknum(pipeW));"
    , "  if (mkbool(payload(go, 0) < 0)) {"
    , "    call Rt.epFreeCmds(mknum(pipeW), mknum(cmdsW), mknum(0));"
    , "    return mknum(-1);"
    , "  }"
    , "  return mknum(pipeW);"
    , "}"
    , ""
    , -- -- Rt.epPipeGo vv stN pipeN: the command fill loop; pipe[0] IS the
      -- -- running count.  Self-tail (recur); frame-free.
      "defun Rt.epPipeGo(vv : val, stN : val, pipeN : val) -> val {"
    , "  word cbufW = wload(payload(stN, 0), 0);"
    , "  word iW = wload(payload(pipeN, 0), 0);"
    , "  word cmdsW = wload(payload(pipeN, 0), 1);"
    , "  val stV = mkbool(tagis(vv, 4) == 0) ? mknum(2) : (mkbool(tagis(vecload(payload(vv, 0), 0), 2) == 0) ? mknum(2) : (call Rt.epSymIs(vecload(payload(vv, 0), 0), mknum(cbufW), mknum(0)) ? (mkbool(tagis(vecload(payload(vv, 0), 1), 5) != 0) ? mknum(0) : (mkbool(tagis(vecload(payload(vv, 0), 1), 4) != 0) ? mknum(1) : mknum(2))) : mknum(2)));"
    , "  if (mkbool(payload(stV, 0) == 2)) {"
    , "    return mknum(-1);"
    , "  }"
    , "  if (mkbool(payload(stV, 0) == 0)) {"
    , "    return mknum(0);"
    , "  }"
    , "  val t1 = vecload(payload(vecload(payload(vv, 0), 1), 0), 1);"
    , "  word cAddr = cmdsW + (iW * 40);"
    , "  val r = call Rt.epCmd(vecload(payload(vecload(payload(vv, 0), 1), 0), 0), stN, mknum(cAddr));"
    , "  if (mkbool(payload(r, 0) < 0)) {"
    , "    return mknum(-1);"
    , "  }"
    , "  wstore(payload(pipeN, 0), 0, iW + 1);"
    , "  recur(vecload(payload(t1, 0), 0), stN, pipeN);"
    , "}"
    , ""
    , -- -- Rt.epArgvGo vv stN cAddrN: dupeZ each argv string into cmd's char*
      -- -- array (argc at cAddr[1] is the running count); on a malformed element
      -- -- it frees the decoded prefix itself and returns -1.  Self-tail (recur).
      "defun Rt.epArgvGo(vv : val, stN : val, cAddrN : val) -> val {"
    , "  word cbufW = wload(payload(stN, 0), 0);"
    , "  word argvW = wload(payload(cAddrN, 0), 0);"
    , "  word jW = wload(payload(cAddrN, 0), 1);"
    , "  val stV = mkbool(tagis(vv, 4) == 0) ? mknum(2) : (mkbool(tagis(vecload(payload(vv, 0), 0), 2) == 0) ? mknum(2) : (call Rt.epSymIs(vecload(payload(vv, 0), 0), mknum(cbufW), mknum(0)) ? (mkbool(tagis(vecload(payload(vv, 0), 1), 5) != 0) ? mknum(0) : (mkbool(tagis(vecload(payload(vv, 0), 1), 4) != 0) ? mknum(1) : mknum(2))) : mknum(2)));"
    , "  if (mkbool(payload(stV, 0) == 2)) {"
    , "    call Rt.epFreeArgv(mknum(wload(payload(cAddrN, 0), 0)), mknum(0), mknum(wload(payload(cAddrN, 0), 1)));"
    , "    wstore(payload(cAddrN, 0), 0, 0);"
    , "    return mknum(-1);"
    , "  }"
    , "  if (mkbool(payload(stV, 0) == 0)) {"
    , "    return mknum(0);"
    , "  }"
    , "  val sN = call Rt.epStr(vecload(payload(vecload(payload(vv, 0), 1), 0), 0), mknum(cbufW));"
    , "  if (mkbool(tagis(sN, 1) == 0)) {"
    , "    call Rt.epFreeArgv(mknum(wload(payload(cAddrN, 0), 0)), mknum(0), mknum(wload(payload(cAddrN, 0), 1)));"
    , "    wstore(payload(cAddrN, 0), 0, 0);"
    , "    return mknum(-1);"
    , "  }"
    , "  word bufW = rawcall malloc(len32(sN) + 1);"
    , "  if (mkbool(bufW == 0)) {"
    , "    word h = rawcall rt_halt();"
    , "    return mknil;"
    , "  } else {"
    , "    return mknum(0);"
    , "  }"
    , "  call Rt.cStrFill(mknum(bufW), sN, mknum(0));"
    , "  wstore(argvW, jW, bufW);"
    , "  wstore(payload(cAddrN, 0), 1, jW + 1);"
    , "  val t1 = vecload(payload(vecload(payload(vv, 0), 1), 0), 1);"
    , "  if (mkbool(tagis(t1, 4) == 0)) {"
    , "    call Rt.epFreeArgv(mknum(wload(payload(cAddrN, 0), 0)), mknum(0), mknum(wload(payload(cAddrN, 0), 1)));"
    , "    wstore(payload(cAddrN, 0), 0, 0);"
    , "    return mknum(-1);"
    , "  }"
    , "  recur(vecload(payload(t1, 0), 0), stN, cAddrN);"
    , "}"
    , ""
    , -- -- Rt.epRedirsGo vv stN cAddrN: decode each redir into cmd's word array
      -- -- (nredirs at cAddr[3] is the running count); frees its own prefix +
      -- -- array on failure.  Self-tail (recur); frame-free.
      "defun Rt.epRedirsGo(vv : val, stN : val, cAddrN : val) -> val {"
    , "  word cbufW = wload(payload(stN, 0), 0);"
    , "  word arrW = wload(payload(cAddrN, 0), 2);"
    , "  word jW = wload(payload(cAddrN, 0), 3);"
    , "  val stV = mkbool(tagis(vv, 4) == 0) ? mknum(2) : (mkbool(tagis(vecload(payload(vv, 0), 0), 2) == 0) ? mknum(2) : (call Rt.epSymIs(vecload(payload(vv, 0), 0), mknum(cbufW), mknum(0)) ? (mkbool(tagis(vecload(payload(vv, 0), 1), 5) != 0) ? mknum(0) : (mkbool(tagis(vecload(payload(vv, 0), 1), 4) != 0) ? mknum(1) : mknum(2))) : mknum(2)));"
    , "  if (mkbool(payload(stV, 0) == 2)) {"
    , "    call Rt.epFreeRedirs(mknum(wload(payload(cAddrN, 0), 2)), mknum(0), mknum(wload(payload(cAddrN, 0), 3)));"
    , "    wstore(payload(cAddrN, 0), 2, 0);"
    , "    return mknum(-1);"
    , "  }"
    , "  if (mkbool(payload(stV, 0) == 0)) {"
    , "    return mknum(0);"
    , "  }"
    , "  word rAddr = arrW + (jW * 48);"
    , "  val r = call Rt.epRedir(vecload(payload(vecload(payload(vv, 0), 1), 0), 0), stN, mknum(rAddr));"
    , "  val t1 = vecload(payload(vecload(payload(vv, 0), 1), 0), 1);"
    , "  if (mkbool(payload(r, 0) < 0)) {"
    , "    call Rt.epFreeRedirs(mknum(wload(payload(cAddrN, 0), 2)), mknum(0), mknum(wload(payload(cAddrN, 0), 3)));"
    , "    wstore(payload(cAddrN, 0), 2, 0);"
    , "    return mknum(-1);"
    , "  }"
    , "  wstore(payload(cAddrN, 0), 3, jW + 1);"
    , "  if (mkbool(tagis(t1, 4) == 0)) {"
    , "    call Rt.epFreeRedirs(mknum(wload(payload(cAddrN, 0), 2)), mknum(0), mknum(wload(payload(cAddrN, 0), 3)));"
    , "    wstore(payload(cAddrN, 0), 2, 0);"
    , "    return mknum(-1);"
    , "  }"
    , "  recur(vecload(payload(t1, 0), 0), stN, cAddrN);"
    , "}"
    , ""
    , -- -- Rt.epRedir e stN rAddrN: decodeRedir — [op fd target], len 3, op one
      -- -- of in/out/append/dup/hdoc/hstr (cbuf words 7..12, byte offsets
      -- -- 56..96); fd must be 0 for in/hdoc/hstr and 1|2 for out/append/dup; a
      -- -- dup targets a NUMBER fd 1|2, the others a [string S], dupeZ'd — hstr
      -- -- appends the trailing newline (one malloc, the same bytes out).  All
      -- -- SIX words stored only on success (tmpfd pre-set -1); the kind select
      -- -- and the fdOk test are the ?: join; the hstr newline and the three
      -- -- record stores are the both-diverge / term-if spellings.  No self-call.
      "defun Rt.epRedir(e : val, stN : val, rAddrN : val) -> val {"
    , "  wstore(payload(stN, 0), 2, 8);"
    , "  val cnt = call Rt.epCount(e, stN, mknum(0));"
    , "  word cbufW = wload(payload(stN, 0), 0);"
    , "  if (mkbool(payload(cnt, 0) != 3)) {"
    , "    return mknum(-1);"
    , "  }"
    , "  val opv = call Rt.epElem(e, mknum(0), mknum(0));"
    , "  val fdv = call Rt.epElem(e, mknum(0), mknum(1));"
    , "  val tgv = call Rt.epElem(e, mknum(0), mknum(2));"
    , "  val xsym = call Rt.epSymOf(opv, mknum(cbufW));"
    , "  if (mkbool(tagis(xsym, 2) == 0)) {"
    , "    return mknum(-1);"
    , "  }"
    , "  val isIn = call Rt.epSymIs(xsym, mknum(cbufW + 56), mknum(0));"
    , "  val isOut = call Rt.epSymIs(xsym, mknum(cbufW + 64), mknum(0));"
    , "  val isAppend = call Rt.epSymIs(xsym, mknum(cbufW + 72), mknum(0));"
    , "  val isDup = call Rt.epSymIs(xsym, mknum(cbufW + 80), mknum(0));"
    , "  val isHdoc = call Rt.epSymIs(xsym, mknum(cbufW + 88), mknum(0));"
    , "  val isHstr = call Rt.epSymIs(xsym, mknum(cbufW + 96), mknum(0));"
    , "  val kindV = isIn ? mknum(0) : (isOut ? mknum(1) : (isAppend ? mknum(2) : (isDup ? mknum(3) : (isHdoc ? mknum(4) : (isHstr ? mknum(5) : mknum(-1))))));"
    , "  val fdN = call Rt.epNum(fdv, mknum(cbufW));"
    , "  val fdOk = (isIn || (isHdoc || isHstr)) ? mkbool(payload(fdN, 0) == 0) : (mkbool(payload(fdN, 0) == 1) || mkbool(payload(fdN, 0) == 2));"
    , "  if (mkbool(payload(kindV, 0) < 0)) {"
    , "    return mknum(-1);"
    , "  }"
    , "  if (mkbool(tagis(fdN, 0) == 0)) {"
    , "    return mknum(-1);"
    , "  }"
    , "  if (fdOk) {"
    , "    if (isDup) {"
    , "      val dfdN = call Rt.epNum(tgv, mknum(cbufW));"
    , "      if (mkbool(tagis(dfdN, 0) == 0)) {"
    , "        return mknum(-1);"
    , "      }"
    , "      if (mkbool(payload(dfdN, 0) == 1) || mkbool(payload(dfdN, 0) == 2)) {"
    , "        wstore(payload(rAddrN, 0), 0, payload(kindV, 0));"
    , "        wstore(payload(rAddrN, 0), 1, payload(fdN, 0));"
    , "        wstore(payload(rAddrN, 0), 2, 0);"
    , "        wstore(payload(rAddrN, 0), 3, payload(dfdN, 0));"
    , "        wstore(payload(rAddrN, 0), 4, 0);"
    , "        wstore(payload(rAddrN, 0), 5, -1);"
    , "        return mknum(0);"
    , "      }"
    , "      return mknum(-1);"
    , "    } else {"
    , "      val sN = call Rt.epStr(tgv, mknum(cbufW));"
    , "      if (mkbool(tagis(sN, 1) == 0)) {"
    , "        return mknum(-1);"
    , "      }"
    , "      word bufW = rawcall malloc(len32(sN) + payload(isHstr ? mknum(1) : mknum(0), 0));"
    , "      if (mkbool(bufW == 0)) {"
    , "        word h = rawcall rt_halt();"
    , "        return mknil;"
    , "      } else {"
    , "        return mknum(0);"
    , "      }"
    , "      call Rt.cStrFill(mknum(bufW), sN, mknum(0));"
    , "      if (isHstr) {"
    , "        bytestore(bufW, len32(sN), 10);"
    , "        bytestore(bufW, len32(sN) + 1, 0);"
    , "        return mknil;"
    , "      } else {"
    , "        return mknil;"
    , "      }"
    , "      if (isHdoc || isHstr) {"
    , "        wstore(payload(rAddrN, 0), 0, payload(kindV, 0));"
    , "        wstore(payload(rAddrN, 0), 1, payload(fdN, 0));"
    , "        wstore(payload(rAddrN, 0), 2, 0);"
    , "        wstore(payload(rAddrN, 0), 3, 0);"
    , "        wstore(payload(rAddrN, 0), 4, bufW);"
    , "        wstore(payload(rAddrN, 0), 5, -1);"
    , "        return mknum(0);"
    , "      } else {"
    , "        wstore(payload(rAddrN, 0), 0, payload(kindV, 0));"
    , "        wstore(payload(rAddrN, 0), 1, payload(fdN, 0));"
    , "        wstore(payload(rAddrN, 0), 2, bufW);"
    , "        wstore(payload(rAddrN, 0), 3, 0);"
    , "        wstore(payload(rAddrN, 0), 4, 0);"
    , "        wstore(payload(rAddrN, 0), 5, -1);"
    , "        return mknum(0);"
    , "      }"
    , "    }"
    , "  }"
    , "  return mknum(-1);"
    , "}"
    , ""
    , -- -- Rt.epCountStdin arrN jN accN: redirs[0..j) with fd == 0, counting j
      -- -- DOWN (the caller passes nredirs).  Self-tail (recur); a NULL array is
      -- -- legal (count 0).  The fd==0 compare rides INSIDE the acc addend —
      -- -- the DSL's cmpW-as-operand, parenthesized.
      "defun Rt.epCountStdin(arrN : val, jN : val, accN : val) -> val {"
    , "  if (mkbool(payload(jN, 0) <= 0)) {"
    , "    return accN;"
    , "  }"
    , "  word fdW = wload(payload(arrN, 0), ((payload(jN, 0) - 1) * 6) + 1);"
    , "  recur(arrN, mknum(payload(jN, 0) - 1), mknum(payload(accN, 0) + (fdW == 0)));"
    , "}"
    , ""
    , -- -- Rt.epFreeChains progN chainsN iN: free chains[i..n) then both records;
      -- -- each chain's pipe (chains[i*2+1]) freed by epFreeCmds.  Self-tail
      -- -- (recur) at BOTH sites (the pipe!=0 arm and the fall-through).
      "defun Rt.epFreeChains(progN : val, chainsN : val, iN : val) -> val {"
    , "  word nW = wload(payload(progN, 0), 0);"
    , "  if (mkbool(payload(iN, 0) >= nW)) {"
    , "    rawcall free(payload(chainsN, 0));"
    , "    rawcall free(payload(progN, 0));"
    , "    return mknil;"
    , "  }"
    , "  word pipeW = wload(payload(chainsN, 0), (payload(iN, 0) * 2) + 1);"
    , "  if (mkbool(pipeW != 0)) {"
    , "    call Rt.epFreeCmds(mknum(pipeW), mknum(wload(pipeW, 1)), mknum(0));"
    , "    recur(progN, chainsN, mknum(payload(iN, 0) + 1));"
    , "  }"
    , "  recur(progN, chainsN, mknum(payload(iN, 0) + 1));"
    , "}"
    , ""
    , -- -- Rt.epFreeCmds pipeN cmdsN iN: free each cmd record (40-byte stride),
      -- -- then both records.  Self-tail (recur).
      "defun Rt.epFreeCmds(pipeN : val, cmdsN : val, iN : val) -> val {"
    , "  word nW = wload(payload(pipeN, 0), 0);"
    , "  if (mkbool(payload(iN, 0) >= nW)) {"
    , "    rawcall free(payload(cmdsN, 0));"
    , "    rawcall free(payload(pipeN, 0));"
    , "    return mknil;"
    , "  }"
    , "  call Rt.epFreeCmd(mknum(payload(cmdsN, 0) + (payload(iN, 0) * 40)));"
    , "  recur(pipeN, cmdsN, mknum(payload(iN, 0) + 1));"
    , "}"
    , ""
    , -- -- Rt.epFreeCmd cmdAddrN: free one cmd's argv, redirs and sub (the sub's
      -- -- chains AND record via epFreeChains — no separate record free).  The
      -- -- three null-guard arms are bare call VALUES in the DSL's iff arms —
      -- -- spelled `return call Rt.f(..);` so the branch keeps the bare call
      -- -- (no Let), the both-diverge dead binder taking the If.
      "defun Rt.epFreeCmd(cmdAddrN : val) -> val {"
    , "  word argvW = wload(payload(cmdAddrN, 0), 0);"
    , "  if (mkbool(argvW != 0)) {"
    , "    return call Rt.epFreeArgv(mknum(argvW), mknum(0), mknum(wload(payload(cmdAddrN, 0), 1)));"
    , "  } else {"
    , "    return mknil;"
    , "  }"
    , "  word redirsW = wload(payload(cmdAddrN, 0), 2);"
    , "  if (mkbool(redirsW != 0)) {"
    , "    return call Rt.epFreeRedirs(mknum(redirsW), mknum(0), mknum(wload(payload(cmdAddrN, 0), 3)));"
    , "  } else {"
    , "    return mknil;"
    , "  }"
    , "  word subW = wload(payload(cmdAddrN, 0), 4);"
    , "  if (mkbool(subW != 0)) {"
    , "    return call Rt.epFreeChains(mknum(subW), mknum(wload(subW, 1)), mknum(0));"
    , "  } else {"
    , "    return mknil;"
    , "  }"
    , "  return mknil;"
    , "}"
    , ""
    , -- -- Rt.epFreeArgv arrN jN nN: free argv[0..n) then the array.  Self-tail
      -- -- (recur); free(0) is a C no-op.
      "defun Rt.epFreeArgv(arrN : val, jN : val, nN : val) -> val {"
    , "  if (mkbool(payload(jN, 0) >= payload(nN, 0))) {"
    , "    rawcall free(payload(arrN, 0));"
    , "    return mknil;"
    , "  }"
    , "  rawcall free(wload(payload(arrN, 0), payload(jN, 0)));"
    , "  recur(arrN, mknum(payload(jN, 0) + 1), nN);"
    , "}"
    , ""
    , -- -- Rt.epFreeRedirs arrN jN nN: free redirs[0..n)'s path (word 2) and
      -- -- body (word 4) — the 6-word stride — then the array.  Self-tail (recur).
      "defun Rt.epFreeRedirs(arrN : val, jN : val, nN : val) -> val {"
    , "  if (mkbool(payload(jN, 0) >= payload(nN, 0))) {"
    , "    rawcall free(payload(arrN, 0));"
    , "    return mknil;"
    , "  }"
    , "  rawcall free(wload(payload(arrN, 0), (payload(jN, 0) * 6) + 2));"
    , "  rawcall free(wload(payload(arrN, 0), (payload(jN, 0) * 6) + 4));"
    , "  recur(arrN, mknum(payload(jN, 0) + 1), nN);"
    , "}"
    , ""
    , -- ====================== T17 — wave-9: the exec-plan RUN machinery ======================
      --
      -- TWENTY keys moved to Mid/RtSource: the exec-plan prims (Rt.exec-plan,
      -- Rt.exec-run, Rt.mkTmpAt) and seventeen of the eighteen helperDefuns run
      -- builders (envHome, isChildBuiltin, echoGo, childPwd, childBuiltin,
      -- applyOneRedir, applyRedirects, bodyWriteGo, openBodyTmpfile, wireCmdGo,
      -- wirePipeGo, closeCmdTmpfds, closePipeTmpfds, closePipesGo, closeOthersGo,
      -- runBuiltinInprocess, execGo).  Rt.childCd was NOT here — the SAME wall
      -- that held Rt.epCmd in T16: its second `dirN` binder is an If in a LET
      -- VALUE position whose ELSE carries a Let-chain (ln = cStrLenGo dirN) and
      -- whose VALUE the third dirN binder and `ln` read — unspellable then (?
      -- needs expression branches, both-diverge needs both branches returning,
      -- else-nesting needs a diverging then).  T24 migrated it (the T24 block at
      -- the end of this list), and runLits/runOff/rLoad/rStore died with it.
      --
      -- Recursion MEASURED per defun: execGo self-references at TWENTY-THREE
      -- sites, ALL the recur shape (App { GRef own-key, force = False } — the
      -- in-frame jmp @body loop; the brief's recur-vs-call question is answered
      -- recur here, unlike the T10-T12 callR families): self 0 x4, self 1,
      -- self 2 x2, self 3 x3, self 4 x2, self 5 x9, self 6 x2.  applyRedirects /
      -- bodyWriteGo / wireCmdGo / wirePipeGo / closeCmdTmpfds / closePipeTmpfds /
      -- closePipesGo / closeOthersGo / echoGo are self-tail recur too; the rest
      -- make no self-call.
      --
      -- The RtLayout blob offsets and the runLits cbuf offsets are LITERALS in
      -- the surface text (COMPUTED by replicating runLitsPacked: echo=104,
      -- true=109, false=114, :=120, cd=122, pwd=125, -n=129, HOME=132, " "=137,
      -- /=139, InputErr=141, \n=173, OutputErr=175, shensh:=200, notfound=209,
      -- cannotexec=222, cd:=240, pwdErr=245, out=266, err=289, hdoc=312,
      -- cbufSize=336; the decode tag words cons/string/number/symbol/seq/and/or/
      -- in/out/append/dup/hdoc/hstr packed the DSL's way — the lit folder folds
-- over the REVERSED byte list, so the FIRST name byte is the LOW byte of the
-- word (little-endian stores)).  The state-block slots
      -- are the rCbuf..rEchoI constants (cbuf0 outfd1 errfd2 inChild3 prog4 pipe5
      -- last6 i7 n8 npipes9 pfds10 pids11 forked12 forkFail13 exit14 scrA15 scrB16
      -- status17 scrC18 j19 echoI20; the waitpid status offset is 8*17 = 136, the
      -- exec-plan state block is 8*21 = 168 bytes).
      --
      -- Shapes throughout: the malloc-OOM checks and the dead conditional closes
      -- are the T15/T16 both-branches-diverge spelling (Let { b = If { .. } } at
      -- a fresh binder, the continuation as the dead body); the READ let-value
      -- Ifs with expression branches (exec-plan's errfdW, childBuiltin's isMinusN,
      -- mode1's a0/isB, runBuiltinInprocess's rc/fin, echoGo's b7/b8,
      -- closeOthersGo's b5) are the T9b ?: join.  execGo's seven modes are the
      -- dispatch if-chain's blocks, nested exactly as the DSL splices them; the
      -- 3-arg lean ABI still holds (execGo itself is 2-ary — the modes are a
      -- dispatch on its second argument, not extra params).
      --
      -- -- Rt.envHome stN: getenv("HOME") or 0 (unset/empty), as a raw pointer
      -- -- boxed.  No self-call.
      "defun Rt.envHome(stN : val) -> val {"
    , "  word cbufW = wload(payload(stN, 0), 0);"
    , "  word h = rawcall getenv(cbufW + 132);"
    , "  if (mkbool(h == 0)) {"
    , "    return mknum(0);"
    , "  } else {"
    , "    val ln = call Rt.cStrLenGo(mknum(h), mknum(0));"
    , "    if (mkbool(payload(ln, 0) == 0)) {"
    , "      return mknum(0);"
    , "    } else {"
    , "      return mknum(h);"
    , "    }"
    , "  }"
    , "}"
    , ""
    , -- -- -- Rt.isChildBuiltin a0N stN: a0 is one of echo/true/false/:/cd/pwd (the
      -- -- exact names Zig's is_child_builtin matches; no path parts).  The six
      -- -- cStrEqLit tests are the DSL's RIGHT-nested or2 chain — explicit parens
      -- -- against the left-assoc || parse.  No self-call.
      "defun Rt.isChildBuiltin(a0N : val, stN : val) -> val {"
    , "  word cbufW = wload(payload(stN, 0), 0);"
    , "  return call Rt.cStrEqLit(a0N, mknum(cbufW + 104), mknum(0)) || (call Rt.cStrEqLit(a0N, mknum(cbufW + 109), mknum(0)) || (call Rt.cStrEqLit(a0N, mknum(cbufW + 114), mknum(0)) || (call Rt.cStrEqLit(a0N, mknum(cbufW + 120), mknum(0)) || (call Rt.cStrEqLit(a0N, mknum(cbufW + 122), mknum(0)) || call Rt.cStrEqLit(a0N, mknum(cbufW + 125), mknum(0))))));"
    , "}"
    , ""
    , -- -- -- Rt.echoGo argvN argcN stN: childBuiltin's echo loop.  Loop state lives
      -- -- in stN: echoI (slot 20) = current arg index, scrA (15) = first arg
      -- -- index, scrB (16) = nl (0/1).  echoI is a DEDICATED slot — i (7) is the
      -- -- program-loop chain cursor, and this loop runs inside it.  Self-tail
      -- -- (recur); returns 0 when the args are written.  The two dead conditional
      -- -- writes are the T9b ?: join at dead binders (the DSL's b7/b8).
      "defun Rt.echoGo(argvN : val, argcN : val, stN : val) -> val {"
    , "  word iW = wload(payload(stN, 0), 20);"
    , "  word cbufW = wload(payload(stN, 0), 0);"
    , "  if (mkbool(iW >= payload(argcN, 0))) {"
    , "    val nlOut = mkbool(wload(payload(stN, 0), 16) == 1) ? call Rt.wRaw(mknum(1), mknum(cbufW + 173), mknum(1)) : mknil;"
    , "    return mknum(0);"
    , "  } else {"
    , "    val spOut = mkbool(iW > wload(payload(stN, 0), 15)) ? call Rt.wRaw(mknum(1), mknum(cbufW + 137), mknum(1)) : mknil;"
    , "    word argN = wload(payload(argvN, 0), iW);"
    , "    call Rt.wStr(mknum(1), mknum(argN));"
    , "    wstore(payload(stN, 0), 20, iW + 1);"
    , "    recur(argvN, argcN, stN);"
    , "  }"
    , "}"
    , ""
    , -- -- -- Rt.childPwd stN: the pwd builtin arm (getcwd into a 4096 buf; PATH_MAX
      -- -- here is 4096 like every other Mid buffer).  No self-call.
      "defun Rt.childPwd(stN : val) -> val {"
    , "  word cbufW = wload(payload(stN, 0), 0);"
    , "  word pbuf = rawcall malloc(4096);"
    , "  if (mkbool(pbuf == 0)) {"
    , "    word h = rawcall rt_halt();"
    , "    return mknil;"
    , "  } else {"
    , "    return mknum(0);"
    , "  }"
    , "  word got = rawcall getcwd(pbuf, 4096);"
    , "  if (mkbool(got != 0)) {"
    , "    val plen = call Rt.cStrLenGo(mknum(pbuf), mknum(0));"
    , "    call Rt.wRaw(mknum(1), mknum(pbuf), plen);"
    , "    call Rt.wRaw(mknum(1), mknum(cbufW + 173), mknum(1));"
    , "    rawcall free(pbuf);"
    , "    return mknum(0);"
    , "  } else {"
    , "    call Rt.wRaw(mknum(2), mknum(cbufW + 245), mknum(20));"
    , "    rawcall free(pbuf);"
    , "    return mknum(1);"
    , "  }"
    , "}"
    , ""
    , -- -- -- Rt.childBuiltin argcN argvN stN: echo/true/false/:/cd/pwd in-process.
      -- -- -1 when argv[0] is not a builtin (the caller falls through to execvp).
      -- -- The -n rearm (scrB 0 / scrA 2 / echoI 2) is the both-diverge spelling of
      -- -- the DSL's dead b23 If.  Rt.childCd was DSL-side in T17; T24 migrated it.
      "defun Rt.childBuiltin(argcN : val, argvN : val, stN : val) -> val {"
    , "  if (mkbool(payload(argcN, 0) == 0)) {"
    , "    return mknum(-1);"
    , "  } else {"
    , "    word a0 = wload(payload(argvN, 0), 0);"
    , "    word cbufW = wload(payload(stN, 0), 0);"
    , "    val isEcho = call Rt.cStrEqLit(mknum(a0), mknum(cbufW + 104), mknum(0));"
    , "    val isTrue = call Rt.cStrEqLit(mknum(a0), mknum(cbufW + 109), mknum(0));"
    , "    val isFalse = call Rt.cStrEqLit(mknum(a0), mknum(cbufW + 114), mknum(0));"
    , "    val isColon = call Rt.cStrEqLit(mknum(a0), mknum(cbufW + 120), mknum(0));"
    , "    val isCd = call Rt.cStrEqLit(mknum(a0), mknum(cbufW + 122), mknum(0));"
    , "    val isPwd = call Rt.cStrEqLit(mknum(a0), mknum(cbufW + 125), mknum(0));"
    , "    if (isEcho) {"
    , "      wstore(payload(stN, 0), 16, 1);"
    , "      wstore(payload(stN, 0), 15, 1);"
    , "      wstore(payload(stN, 0), 20, 1);"
    , "      word arg1 = wload(payload(argvN, 0), 1);"
    , "      val isMinusN = mkbool(payload(argcN, 0) > 1) ? call Rt.cStrEqLit(mknum(arg1), mknum(cbufW + 129), mknum(0)) : false;"
    , "      if (isMinusN) {"
    , "        wstore(payload(stN, 0), 16, 0);"
    , "        wstore(payload(stN, 0), 15, 2);"
    , "        wstore(payload(stN, 0), 20, 2);"
    , "        return mknil;"
    , "      } else {"
    , "        return mknil;"
    , "      }"
    , "      return call Rt.echoGo(argvN, argcN, stN);"
    , "    } else {"
    , "      if (isTrue) {"
    , "        return mknum(0);"
    , "      } else {"
    , "        if (isFalse) {"
    , "          return mknum(1);"
    , "        } else {"
    , "          if (isColon) {"
    , "            return mknum(0);"
    , "          } else {"
    , "            if (isCd) {"
    , "              return call Rt.childCd(argvN, argcN, stN);"
    , "            } else {"
    , "              if (isPwd) {"
    , "                return call Rt.childPwd(stN);"
    , "              } else {"
    , "                return mknum(-1);"
    , "              }"
    , "            }"
    , "          }"
    , "        }"
    , "      }"
    , "    }"
    , "  }"
    , "}"
    , ""
    , -- -- -- Rt.applyOneRedir redirN stN: one redir record's apply (in/out/append/
      -- -- dup/hdoc/hstr), Zig's apply_redirects switch.  Kind codes 0..5, the
      -- -- 6-word record (kind0 fd1 path2 dupfd3 body4 tmpfd5).  0 ok / -1 failure
      -- -- (the caller _exits or returns 1).  The four arms are the DSL's Elm-level
      -- -- inArm/outAppendArm/dupArm/hArm splices — tail-if blocks with let-chain
      -- -- branches; outAppendArm is written out twice (577 = O_CREAT|O_TRUNC|
      -- -- O_WRONLY, 1089 = O_CREAT|O_APPEND|O_WRONLY, 438 = 0666).  No self-call.
      "defun Rt.applyOneRedir(redirN : val, stN : val) -> val {"
    , "  word kindW = wload(payload(redirN, 0), 0);"
    , "  word fdN = wload(payload(redirN, 0), 1);"
    , "  word cbufW = wload(payload(stN, 0), 0);"
    , "  if (mkbool(kindW == 0)) {"
    , "    word pathW = wload(payload(redirN, 0), 2);"
    , "    word ofd = rawcall openat(-100, pathW, 0, 0);"
    , "    if (mkbool(ofd < 0)) {"
    , "      call Rt.wStr(mknum(2), mknum(cbufW + 141));"
    , "      call Rt.wStr(mknum(2), mknum(pathW));"
    , "      call Rt.wRaw(mknum(2), mknum(cbufW + 173), mknum(1));"
    , "      return mknum(-1);"
    , "    } else {"
    , "      word rc2 = rawcall dup2(ofd, fdN);"
    , "      rawcall close(ofd);"
    , "      if (mkbool(rc2 < 0)) {"
    , "        return mknum(-1);"
    , "      } else {"
    , "        return mknum(0);"
    , "      }"
    , "    }"
    , "  } else {"
    , "    if (mkbool(kindW == 1)) {"
    , "      word pathW = wload(payload(redirN, 0), 2);"
    , "      word ofd = rawcall openat(-100, pathW, 577, 438);"
    , "      if (mkbool(ofd < 0)) {"
    , "        call Rt.wStr(mknum(2), mknum(cbufW + 175));"
    , "        call Rt.wStr(mknum(2), mknum(pathW));"
    , "        call Rt.wRaw(mknum(2), mknum(cbufW + 173), mknum(1));"
    , "        return mknum(-1);"
    , "      } else {"
    , "        word rc2 = rawcall dup2(ofd, fdN);"
    , "        rawcall close(ofd);"
    , "        if (mkbool(rc2 < 0)) {"
    , "          return mknum(-1);"
    , "        } else {"
    , "          return mknum(0);"
    , "        }"
    , "      }"
    , "    } else {"
    , "      if (mkbool(kindW == 2)) {"
    , "        word pathW = wload(payload(redirN, 0), 2);"
    , "        word ofd = rawcall openat(-100, pathW, 1089, 438);"
    , "        if (mkbool(ofd < 0)) {"
    , "          call Rt.wStr(mknum(2), mknum(cbufW + 175));"
    , "          call Rt.wStr(mknum(2), mknum(pathW));"
    , "          call Rt.wRaw(mknum(2), mknum(cbufW + 173), mknum(1));"
    , "          return mknum(-1);"
    , "        } else {"
    , "          word rc2 = rawcall dup2(ofd, fdN);"
    , "          rawcall close(ofd);"
    , "          if (mkbool(rc2 < 0)) {"
    , "            return mknum(-1);"
    , "          } else {"
    , "            return mknum(0);"
    , "          }"
    , "        }"
    , "      } else {"
    , "        if (mkbool(kindW == 3)) {"
    , "          word dupfdW = wload(payload(redirN, 0), 3);"
    , "          word rcD = rawcall dup2(dupfdW, fdN);"
    , "          if (mkbool(rcD < 0)) {"
    , "            return mknum(-1);"
    , "          } else {"
    , "            return mknum(0);"
    , "          }"
    , "        } else {"
    , "          word tmpN = wload(payload(redirN, 0), 5);"
    , "          word rcH = rawcall dup2(tmpN, fdN);"
    , "          rawcall close(tmpN);"
    , "          wstore(payload(redirN, 0), 5, -1);"
    , "          if (mkbool(rcH < 0)) {"
    , "            return mknum(-1);"
    , "          } else {"
    , "            return mknum(0);"
    , "          }"
    , "        }"
    , "      }"
    , "    }"
    , "  }"
    , "}"
    , ""
    , -- -- -- Rt.applyRedirects cmdN stN iN: walk cmd.redirs[0..nredirs) left-to-right
      -- -- (Zig's sequential dup2 application), the 6-word stride.  Self-tail
      -- -- (recur); 0 / -1.
      "defun Rt.applyRedirects(cmdN : val, stN : val, iN : val) -> val {"
    , "  word nredirs = wload(payload(cmdN, 0), 3);"
    , "  if (mkbool(payload(iN, 0) >= nredirs)) {"
    , "    return mknum(0);"
    , "  } else {"
    , "    word arrN = wload(payload(cmdN, 0), 2);"
    , "    word redirN = arrN + (payload(iN, 0) * 48);"
    , "    val rc = call Rt.applyOneRedir(mknum(redirN), stN);"
    , "    if (mkbool(payload(rc, 0) < 0)) {"
    , "      return mknum(-1);"
    , "    } else {"
    , "      recur(cmdN, stN, mknum(payload(iN, 0) + 1));"
    , "    }"
    , "  }"
    , "}"
    , ""
    , -- -- -- Rt.bodyWriteGo bodyN bodyLenN stN: openBodyTmpfile's write loop.
      -- -- stN[scrA] (15) = byte offset, stN[scrB] (16) = tmpfile fd.  Self-tail
      -- -- (recur); returns the fd (rewound) or -1.  The EINTR retry is errno 4
      -- -- (errnoOf = byteload(rawcall __errno_location(), 0), the T14 spelling).
      "defun Rt.bodyWriteGo(bodyN : val, bodyLenN : val, stN : val) -> val {"
    , "  word offW = wload(payload(stN, 0), 15);"
    , "  word fdW = wload(payload(stN, 0), 16);"
    , "  if (mkbool(offW >= payload(bodyLenN, 0))) {"
    , "    rawcall lseek(fdW, 0, 0);"
    , "    return mknum(fdW);"
    , "  } else {"
    , "    word w = rawcall write(fdW, payload(bodyN, 0) + offW, payload(bodyLenN, 0) - offW);"
    , "    if (mkbool(w < 0)) {"
    , "      if (mkbool(byteload(rawcall __errno_location(), 0) == 4)) {"
    , "        recur(bodyN, bodyLenN, stN);"
    , "      } else {"
    , "        rawcall close(fdW);"
    , "        return mknum(-1);"
    , "      }"
    , "    } else {"
    , "      wstore(payload(stN, 0), 15, offW + w);"
    , "      recur(bodyN, bodyLenN, stN);"
    , "    }"
    , "  }"
    , "}"
    , ""
    , -- -- -- Rt.openBodyTmpfile bodyN stN: pre-open a heredoc/herestring body as an
      -- -- unlinked tmpfile, rewound.  bodyN is the blob's body C string; the
      -- -- template literal is in the cbuf (offset 312).  -1 on failure.  No
      -- -- self-call.
      "defun Rt.openBodyTmpfile(bodyN : val, stN : val) -> val {"
    , "  word cbufW = wload(payload(stN, 0), 0);"
    , "  word tpl = rawcall malloc(24);"
    , "  if (mkbool(tpl == 0)) {"
    , "    word h = rawcall rt_halt();"
    , "    return mknil;"
    , "  } else {"
    , "    return mknum(0);"
    , "  }"
    , "  call Rt.cStrCopyGo(mknum(cbufW + 312), mknum(tpl), mknum(0));"
    , "  word fd = rawcall mkstemp(tpl);"
    , "  rawcall unlink(tpl);"
    , "  rawcall free(tpl);"
    , "  val blen = call Rt.cStrLenGo(bodyN, mknum(0));"
    , "  if (mkbool(fd < 0)) {"
    , "    return mknum(-1);"
    , "  } else {"
    , "    wstore(payload(stN, 0), 15, 0);"
    , "    wstore(payload(stN, 0), 16, fd);"
    , "    return call Rt.bodyWriteGo(bodyN, blen, stN);"
    , "  }"
    , "}"
    , ""
    , -- -- -- Rt.wireCmdGo cmdN stN jN: wire one cmd's hdoc/hstr bodies (kinds 4/5).
      -- -- Self-tail (recur).  0 ok / -1 tmpfile failure (the already-opened fds
      -- -- stay owned by the redirs; the caller closes via closePipeTmpfds).
      "defun Rt.wireCmdGo(cmdN : val, stN : val, jN : val) -> val {"
    , "  word nredirs = wload(payload(cmdN, 0), 3);"
    , "  if (mkbool(payload(jN, 0) >= nredirs)) {"
    , "    return mknum(0);"
    , "  } else {"
    , "    word arrN = wload(payload(cmdN, 0), 2);"
    , "    word redirN = arrN + (payload(jN, 0) * 48);"
    , "    word kindW = wload(redirN, 0);"
    , "    val isH = mkbool(kindW == 4) || mkbool(kindW == 5);"
    , "    if (isH) {"
    , "      word bodyN = wload(redirN, 4);"
    , "      val fd = call Rt.openBodyTmpfile(mknum(bodyN), stN);"
    , "      wstore(redirN, 5, payload(fd, 0));"
    , "      if (mkbool(payload(fd, 0) < 0)) {"
    , "        return mknum(-1);"
    , "      } else {"
    , "        recur(cmdN, stN, mknum(payload(jN, 0) + 1));"
    , "      }"
    , "    } else {"
    , "      recur(cmdN, stN, mknum(payload(jN, 0) + 1));"
    , "    }"
    , "  }"
    , "}"
    , ""
    , -- -- -- Rt.wirePipeGo pipeN stN iN: wire every cmd's hdoc/hstr bodies
      -- -- (pre-fork), the 5-word cmd stride.  Self-tail (recur); 0 / -1.
      "defun Rt.wirePipeGo(pipeN : val, stN : val, iN : val) -> val {"
    , "  word ncmds = wload(payload(pipeN, 0), 0);"
    , "  if (mkbool(payload(iN, 0) >= ncmds)) {"
    , "    return mknum(0);"
    , "  } else {"
    , "    word arrN = wload(payload(pipeN, 0), 1);"
    , "    word cmdN = arrN + (payload(iN, 0) * 40);"
    , "    val rc = call Rt.wireCmdGo(mknum(cmdN), stN, mknum(0));"
    , "    if (mkbool(payload(rc, 0) < 0)) {"
    , "      return mknum(-1);"
    , "    } else {"
    , "      recur(pipeN, stN, mknum(payload(iN, 0) + 1));"
    , "    }"
    , "  }"
    , "}"
    , ""
    , -- -- -- Rt.closeCmdTmpfds cmdN iN: close (and -1) a cmd's opened tmpfds.
      -- -- Self-tail (recur) over redirs; the dead conditional close is the
      -- -- both-diverge spelling (the DSL's b8).
      "defun Rt.closeCmdTmpfds(cmdN : val, iN : val) -> val {"
    , "  word nredirs = wload(payload(cmdN, 0), 3);"
    , "  if (mkbool(payload(iN, 0) >= nredirs)) {"
    , "    return mknil;"
    , "  } else {"
    , "    word arrN = wload(payload(cmdN, 0), 2);"
    , "    word redirN = arrN + (payload(iN, 0) * 48);"
    , "    word tmpN = wload(redirN, 5);"
    , "    if (mkbool(tmpN >= 0)) {"
    , "      rawcall close(tmpN);"
    , "      wstore(redirN, 5, -1);"
    , "      return mknil;"
    , "    } else {"
    , "      return mknil;"
    , "    }"
    , "    recur(cmdN, mknum(payload(iN, 0) + 1));"
    , "  }"
    , "}"
    , ""
    , -- -- -- Rt.closePipeTmpfds pipeN iN: close every cmd's tmpfds.  Self-tail
      -- -- (recur) over cmds.
      "defun Rt.closePipeTmpfds(pipeN : val, iN : val) -> val {"
    , "  word ncmds = wload(payload(pipeN, 0), 0);"
    , "  if (mkbool(payload(iN, 0) >= ncmds)) {"
    , "    return mknil;"
    , "  } else {"
    , "    word arrN = wload(payload(pipeN, 0), 1);"
    , "    word cmdN = arrN + (payload(iN, 0) * 40);"
    , "    call Rt.closeCmdTmpfds(mknum(cmdN), mknum(0));"
    , "    recur(pipeN, mknum(payload(iN, 0) + 1));"
    , "  }"
    , "}"
    , ""
    , -- -- -- Rt.closePipesGo pfdsN jN boundN: close pipe fd pair j (pfds word j
      -- -- holds [fd0 | fd1] packed, fd0 in the low 32 bits).  Self-tail (recur)
      -- -- over j < bound.
      "defun Rt.closePipesGo(pfdsN : val, jN : val, boundN : val) -> val {"
    , "  if (mkbool(payload(jN, 0) >= payload(boundN, 0))) {"
    , "    return mknil;"
    , "  } else {"
    , "    word w = wload(payload(pfdsN, 0), payload(jN, 0));"
    , "    rawcall close(w & 4294967295);"
    , "    rawcall close(w / 4294967296);"
    , "    recur(pfdsN, mknum(payload(jN, 0) + 1), boundN);"
    , "  }"
    , "}"
    , ""
    , -- -- -- Rt.closeOthersGo cmdsArrN stN jN: the child's "close other stages'
      -- -- heredoc tmpfds": closeCmdTmpfds on every cmd except stN[scrC] (18).
      -- -- ncmds comes from stN[n] (8).  Self-tail (recur) over j; the guard is
      -- -- the T9b ?: join at a dead binder (the DSL's b5).
      "defun Rt.closeOthersGo(cmdsArrN : val, stN : val, jN : val) -> val {"
    , "  if (mkbool(payload(jN, 0) >= wload(payload(stN, 0), 8))) {"
    , "    return mknil;"
    , "  } else {"
    , "    word cmdN = payload(cmdsArrN, 0) + (payload(jN, 0) * 40);"
    , "    val skip = mkbool(payload(jN, 0) != wload(payload(stN, 0), 18)) ? call Rt.closeCmdTmpfds(mknum(cmdN), mknum(0)) : mknil;"
    , "    recur(cmdsArrN, stN, mknum(payload(jN, 0) + 1));"
    , "  }"
    , "}"
    , ""
    , -- -- -- Rt.runBuiltinInprocess cmdN stN: save fds 0/1/2, dup2 outfd/errfd,
      -- -- apply redirects, run the builtin, restore.  Only ever called with
      -- -- inChild (the subshell single-builtin arm).  The three dead conditional
      -- -- saves are the both-diverge spelling; the rc rebind and fin are the
      -- -- T9b ?: join (both branches expressions, both read).  No self-call.
      "defun Rt.runBuiltinInprocess(cmdN : val, stN : val) -> val {"
    , "  word sav0 = rawcall dup(0);"
    , "  word sav1 = rawcall dup(1);"
    , "  word sav2 = rawcall dup(2);"
    , "  if (mkbool(sav0 < 0) || (mkbool(sav1 < 0) || mkbool(sav2 < 0))) {"
    , "    if (mkbool(sav0 >= 0)) {"
    , "      rawcall close(sav0);"
    , "      return mknil;"
    , "    } else {"
    , "      return mknil;"
    , "    }"
    , "    if (mkbool(sav1 >= 0)) {"
    , "      rawcall close(sav1);"
    , "      return mknil;"
    , "    } else {"
    , "      return mknil;"
    , "    }"
    , "    if (mkbool(sav2 >= 0)) {"
    , "      rawcall close(sav2);"
    , "      return mknil;"
    , "    } else {"
    , "      return mknil;"
    , "    }"
    , "    return mknum(-1);"
    , "  } else {"
    , "    word outfdW = wload(payload(stN, 0), 1);"
    , "    word errfdW = wload(payload(stN, 0), 2);"
    , "    rawcall dup2(outfdW, 1);"
    , "    rawcall dup2(errfdW, 2);"
    , "    val rc = call Rt.applyRedirects(cmdN, stN, mknum(0));"
    , "    word argcN = wload(payload(cmdN, 0), 1);"
    , "    word argvN = wload(payload(cmdN, 0), 0);"
    , "    val rc2 = mkbool(payload(rc, 0) < 0) ? mknum(1) : call Rt.childBuiltin(mknum(argcN), mknum(argvN), stN);"
    , "    val fin = mkbool(payload(rc2, 0) < 0) ? mknum(127) : rc2;"
    , "    rawcall dup2(sav0, 0);"
    , "    rawcall close(sav0);"
    , "    rawcall dup2(sav1, 1);"
    , "    rawcall close(sav1);"
    , "    rawcall dup2(sav2, 2);"
    , "    rawcall close(sav2);"
    , "    return fin;"
    , "  }"
    , "}"
    , ""
    , -- -- -- Rt.execGo stN modeN: the RUN state machine (Zig runProgram/runPipeline
      -- -- as ONE self-tail defun — the 3-arg lean ABI forbids the mutually
      -- -- recursive pair as separate defun calls with their 5-word state).  The
      -- -- seven modes are the dispatch if-chain's blocks, in the DSL's splice
      -- -- order (0,1,2,3,4,6, else 5).  Modes: 0 program loop (chains, &&/||/;
      -- -- short-circuit) - 1 pipeline dispatch (subshell / in-process builtin /
      -- -- multi-cmd) - 2 pipe-creation loop - 3 fork loop (the child work is
      -- -- INLINE and ends in _exit) - 4 wait loop - 5 funnel (exitCode -> mode 0
      -- -- or return/_exit) - 6 kill loop (fork-fail cleanup).  THE
      -- -- CHILD-AFTER-FORK discipline: the pid==0 branches touch only libc + the
      -- -- C-heap blob/state and end in _exit — no GC safepoint.  Self-references:
      -- -- TWENTY-THREE recur sites, all branch-final.
      "defun Rt.execGo(stN : val, modeN : val) -> val {"
    , "  if (mkbool(payload(modeN, 0) == 0)) {"
    , "    word progW = wload(payload(stN, 0), 4);"
    , "    word nchains = wload(progW, 0);"
    , "    if (mkbool(wload(payload(stN, 0), 7) >= nchains)) {"
    , "      if (mkbool(wload(payload(stN, 0), 3) == 0)) {"
    , "        return mknum(wload(payload(stN, 0), 6));"
    , "      } else {"
    , "        rawcall _exit(wload(payload(stN, 0), 6));"
    , "        return mknil;"
    , "      }"
    , "    } else {"
    , "      word chainsArr = wload(progW, 1);"
    , "      word chainN = chainsArr + (wload(payload(stN, 0), 7) * 16);"
    , "      word opW = wload(chainN, 0);"
    , "      word pipeNw = wload(chainN, 1);"
    , "      if (mkbool(wload(payload(stN, 0), 7) > 0) && ((mkbool(opW == 1) && mkbool(wload(payload(stN, 0), 6) != 0)) || (mkbool(opW == 2) && mkbool(wload(payload(stN, 0), 6) == 0)))) {"
    , "        wstore(payload(stN, 0), 7, wload(payload(stN, 0), 7) + 1);"
    , "        recur(stN, mknum(0));"
    , "      } else {"
    , "        wstore(payload(stN, 0), 5, pipeNw);"
    , "        recur(stN, mknum(1));"
    , "      }"
    , "    }"
    , "  } else {"
    , "    if (mkbool(payload(modeN, 0) == 1)) {"
    , "      word pipeW = wload(payload(stN, 0), 5);"
    , "      word ncmds = wload(pipeW, 0);"
    , "      word cmdsArr = wload(pipeW, 1);"
    , "      wstore(payload(stN, 0), 8, ncmds);"
    , "      word sub0 = wload(cmdsArr, 4);"
    , "      word argc0 = wload(cmdsArr, 1);"
    , "      word argv0 = wload(cmdsArr, 0);"
    , "      val a0 = mkbool(argc0 > 0) ? mknum(wload(argv0, 0)) : mknum(0);"
    , "      val isB = mkbool(argc0 > 0) ? call Rt.isChildBuiltin(a0, stN) : false;"
    , "      word inChildW = wload(payload(stN, 0), 3);"
    , "      if (mkbool(ncmds == 1) && mkbool(sub0 != 0)) {"
    , "        val wireRc = call Rt.wirePipeGo(mknum(pipeW), stN, mknum(0));"
    , "        if (mkbool(payload(wireRc, 0) < 0)) {"
    , "          call Rt.closePipeTmpfds(mknum(pipeW), mknum(0));"
    , "          wstore(payload(stN, 0), 14, -1);"
    , "          recur(stN, mknum(5));"
    , "        } else {"
    , "          word pid = rawcall fork();"
    , "          if (mkbool(pid < 0)) {"
    , "            call Rt.closePipeTmpfds(mknum(pipeW), mknum(0));"
    , "            wstore(payload(stN, 0), 14, -1);"
    , "            recur(stN, mknum(5));"
    , "          } else {"
    , "            if (mkbool(pid == 0)) {"
    , "              word outfdW = wload(payload(stN, 0), 1);"
    , "              word errfdW = wload(payload(stN, 0), 2);"
    , "              rawcall dup2(outfdW, 1);"
    , "              rawcall dup2(errfdW, 2);"
    , "              val arrRc = call Rt.applyRedirects(mknum(cmdsArr), stN, mknum(0));"
    , "              if (mkbool(payload(arrRc, 0) < 0)) {"
    , "                rawcall _exit(1);"
    , "                return mknil;"
    , "              } else {"
    , "                if (mkbool(outfdW > 2)) {"
    , "                  rawcall close(outfdW);"
    , "                  return mknil;"
    , "                } else {"
    , "                  return mknil;"
    , "                }"
    , "                if (mkbool(errfdW > 2) && mkbool(errfdW != outfdW)) {"
    , "                  rawcall close(errfdW);"
    , "                  return mknil;"
    , "                } else {"
    , "                  return mknil;"
    , "                }"
    , "                wstore(payload(stN, 0), 1, 1);"
    , "                wstore(payload(stN, 0), 2, 2);"
    , "                wstore(payload(stN, 0), 3, 1);"
    , "                wstore(payload(stN, 0), 4, sub0);"
    , "                wstore(payload(stN, 0), 6, 0);"
    , "                wstore(payload(stN, 0), 7, 0);"
    , "                recur(stN, mknum(0));"
    , "              }"
    , "            } else {"
    , "              call Rt.closePipeTmpfds(mknum(pipeW), mknum(0));"
    , "              wstore(payload(stN, 0), 17, 0);"
    , "              rawcall waitpid(pid, payload(stN, 0) + 136, 0);"
    , "              val code = call Rt.waitStatusCode(mknum(wload(payload(stN, 0), 17)));"
    , "              wstore(payload(stN, 0), 14, payload(code, 0));"
    , "              recur(stN, mknum(5));"
    , "            }"
    , "          }"
    , "        }"
    , "      } else {"
    , "        if (mkbool(inChildW == 1) && (mkbool(ncmds == 1) && (mkbool(sub0 == 0) && (mkbool(argc0 > 0) && isB)))) {"
    , "          val wireRc = call Rt.wirePipeGo(mknum(pipeW), stN, mknum(0));"
    , "          if (mkbool(payload(wireRc, 0) < 0)) {"
    , "            call Rt.closePipeTmpfds(mknum(pipeW), mknum(0));"
    , "            wstore(payload(stN, 0), 14, -1);"
    , "            recur(stN, mknum(5));"
    , "          } else {"
    , "            val code = call Rt.runBuiltinInprocess(mknum(cmdsArr), stN);"
    , "            call Rt.closeCmdTmpfds(mknum(cmdsArr), mknum(0));"
    , "            wstore(payload(stN, 0), 14, payload(code, 0));"
    , "            recur(stN, mknum(5));"
    , "          }"
    , "        } else {"
    , "          val wireRc = call Rt.wirePipeGo(mknum(pipeW), stN, mknum(0));"
    , "          if (mkbool(payload(wireRc, 0) < 0)) {"
    , "            call Rt.closePipeTmpfds(mknum(pipeW), mknum(0));"
    , "            wstore(payload(stN, 0), 14, -1);"
    , "            recur(stN, mknum(5));"
    , "          } else {"
    , "            word npipes = ncmds - 1;"
    , "            word pfds = rawcall malloc(npipes * 8);"
    , "            if (mkbool(pfds == 0)) {"
    , "              word h = rawcall rt_halt();"
    , "              return mknil;"
    , "            } else {"
    , "              return mknum(0);"
    , "            }"
    , "            wstore(payload(stN, 0), 9, npipes);"
    , "            wstore(payload(stN, 0), 10, pfds);"
    , "            wstore(payload(stN, 0), 19, 0);"
    , "            recur(stN, mknum(2));"
    , "          }"
    , "        }"
    , "      }"
    , "    } else {"
    , "      if (mkbool(payload(modeN, 0) == 2)) {"
    , "        word npipes = wload(payload(stN, 0), 9);"
    , "        word pfds = wload(payload(stN, 0), 10);"
    , "        if (mkbool(wload(payload(stN, 0), 19) >= npipes)) {"
    , "          word pids = rawcall malloc(wload(payload(stN, 0), 8) * 8);"
    , "          if (mkbool(pids == 0)) {"
    , "            word h = rawcall rt_halt();"
    , "            return mknil;"
    , "          } else {"
    , "            return mknum(0);"
    , "          }"
    , "          wstore(payload(stN, 0), 11, pids);"
    , "          wstore(payload(stN, 0), 12, 0);"
    , "          wstore(payload(stN, 0), 13, 0);"
    , "          wstore(payload(stN, 0), 19, 0);"
    , "          recur(stN, mknum(3));"
    , "        } else {"
    , "          word r = rawcall pipe(pfds + (wload(payload(stN, 0), 19) * 8));"
    , "          if (mkbool(r < 0)) {"
    , "            call Rt.closePipesGo(mknum(pfds), mknum(0), mknum(wload(payload(stN, 0), 19)));"
    , "            call Rt.closePipeTmpfds(mknum(wload(payload(stN, 0), 5)), mknum(0));"
    , "            rawcall free(pfds);"
    , "            wstore(payload(stN, 0), 14, -1);"
    , "            recur(stN, mknum(5));"
    , "          } else {"
    , "            wstore(payload(stN, 0), 19, wload(payload(stN, 0), 19) + 1);"
    , "            recur(stN, mknum(2));"
    , "          }"
    , "        }"
    , "      } else {"
    , "        if (mkbool(payload(modeN, 0) == 3)) {"
    , "          word cmdsArr = wload(wload(payload(stN, 0), 5), 1);"
    , "          word nW = wload(payload(stN, 0), 8);"
    , "          word iW = wload(payload(stN, 0), 19);"
    , "          if (mkbool(iW >= nW)) {"
    , "            call Rt.closePipesGo(mknum(wload(payload(stN, 0), 10)), mknum(0), mknum(wload(payload(stN, 0), 9)));"
    , "            call Rt.closePipeTmpfds(mknum(wload(payload(stN, 0), 5)), mknum(0));"
    , "            rawcall free(wload(payload(stN, 0), 10));"
    , "            if (mkbool(wload(payload(stN, 0), 13) == 1)) {"
    , "              wstore(payload(stN, 0), 19, 0);"
    , "              recur(stN, mknum(6));"
    , "            } else {"
    , "              wstore(payload(stN, 0), 19, 0);"
    , "              recur(stN, mknum(4));"
    , "            }"
    , "          } else {"
    , "            word pid = rawcall fork();"
    , "            if (mkbool(pid < 0)) {"
    , "              wstore(payload(stN, 0), 13, 1);"
    , "              wstore(payload(stN, 0), 19, nW);"
    , "              recur(stN, mknum(3));"
    , "            } else {"
    , "              if (mkbool(pid == 0)) {"
    , "                word cmdN = cmdsArr + (iW * 40);"
    , "                word outfdW = wload(payload(stN, 0), 1);"
    , "                word errfdW = wload(payload(stN, 0), 2);"
    , "                word pfds = wload(payload(stN, 0), 10);"
    , "                word npipes = wload(payload(stN, 0), 9);"
    , "                rawcall dup2(outfdW, 1);"
    , "                rawcall dup2(errfdW, 2);"
    , "                if (mkbool(iW > 0)) {"
    , "                  rawcall dup2(wload(pfds, iW - 1) & 4294967295, 0);"
    , "                  return mknil;"
    , "                } else {"
    , "                  return mknil;"
    , "                }"
    , "                if (mkbool(iW < (nW - 1))) {"
    , "                  rawcall dup2(wload(pfds, iW) / 4294967296, 1);"
    , "                  return mknil;"
    , "                } else {"
    , "                  return mknil;"
    , "                }"
    , "                call Rt.closePipesGo(mknum(pfds), mknum(0), mknum(npipes));"
    , "                wstore(payload(stN, 0), 18, iW);"
    , "                call Rt.closeOthersGo(mknum(cmdsArr), stN, mknum(0));"
    , "                val arrRc = call Rt.applyRedirects(mknum(cmdN), stN, mknum(0));"
    , "                if (mkbool(payload(arrRc, 0) < 0)) {"
    , "                  rawcall _exit(1);"
    , "                  return mknil;"
    , "                } else {"
    , "                  word subW = wload(cmdN, 4);"
    , "                  if (mkbool(subW != 0)) {"
    , "                    if (mkbool(outfdW > 2)) {"
    , "                      rawcall close(outfdW);"
    , "                      return mknil;"
    , "                    } else {"
    , "                      return mknil;"
    , "                    }"
    , "                    if (mkbool(errfdW > 2) && mkbool(errfdW != outfdW)) {"
    , "                      rawcall close(errfdW);"
    , "                      return mknil;"
    , "                    } else {"
    , "                      return mknil;"
    , "                    }"
    , "                    wstore(payload(stN, 0), 1, 1);"
    , "                    wstore(payload(stN, 0), 2, 2);"
    , "                    wstore(payload(stN, 0), 3, 1);"
    , "                    wstore(payload(stN, 0), 4, subW);"
    , "                    wstore(payload(stN, 0), 6, 0);"
    , "                    wstore(payload(stN, 0), 7, 0);"
    , "                    recur(stN, mknum(0));"
    , "                  } else {"
    , "                    if (mkbool(outfdW > 2)) {"
    , "                      rawcall close(outfdW);"
    , "                      return mknil;"
    , "                    } else {"
    , "                      return mknil;"
    , "                    }"
    , "                    if (mkbool(errfdW > 2) && mkbool(errfdW != outfdW)) {"
    , "                      rawcall close(errfdW);"
    , "                      return mknil;"
    , "                    } else {"
    , "                      return mknil;"
    , "                    }"
    , "                    word argcW = wload(cmdN, 1);"
    , "                    word argvW = wload(cmdN, 0);"
    , "                    val bcode = call Rt.childBuiltin(mknum(argcW), mknum(argvW), stN);"
    , "                    if (mkbool(payload(bcode, 0) >= 0)) {"
    , "                      rawcall _exit(payload(bcode, 0));"
    , "                      return mknil;"
    , "                    } else {"
    , "                      word a0 = wload(argvW, 0);"
    , "                      word cbufW = wload(payload(stN, 0), 0);"
    , "                      rawcall execvp(a0, argvW);"
    , "                      if (mkbool(byteload(rawcall __errno_location(), 0) == 2)) {"
    , "                        call Rt.wStr(mknum(2), mknum(cbufW + 200));"
    , "                        call Rt.wStr(mknum(2), mknum(a0));"
    , "                        call Rt.wStr(mknum(2), mknum(cbufW + 209));"
    , "                        rawcall _exit(127);"
    , "                        return mknil;"
    , "                      } else {"
    , "                        call Rt.wStr(mknum(2), mknum(cbufW + 200));"
    , "                        call Rt.wStr(mknum(2), mknum(a0));"
    , "                        call Rt.wStr(mknum(2), mknum(cbufW + 222));"
    , "                        rawcall _exit(126);"
    , "                        return mknil;"
    , "                      }"
    , "                    }"
    , "                  }"
    , "                }"
    , "              } else {"
    , "                word pids = wload(payload(stN, 0), 11);"
    , "                wstore(pids, iW, pid);"
    , "                wstore(payload(stN, 0), 12, wload(payload(stN, 0), 12) + 1);"
    , "                wstore(payload(stN, 0), 19, iW + 1);"
    , "                recur(stN, mknum(3));"
    , "              }"
    , "            }"
    , "          }"
    , "        } else {"
    , "          if (mkbool(payload(modeN, 0) == 4)) {"
    , "            word iW = wload(payload(stN, 0), 19);"
    , "            word nW = wload(payload(stN, 0), 8);"
    , "            if (mkbool(iW >= nW)) {"
    , "              rawcall free(wload(payload(stN, 0), 11));"
    , "              recur(stN, mknum(5));"
    , "            } else {"
    , "              word pidW = wload(wload(payload(stN, 0), 11), iW);"
    , "              wstore(payload(stN, 0), 17, 0);"
    , "              rawcall waitpid(pidW, payload(stN, 0) + 136, 0);"
    , "              val code = call Rt.waitStatusCode(mknum(wload(payload(stN, 0), 17)));"
    , "              if (mkbool(iW == (nW - 1))) {"
    , "                wstore(payload(stN, 0), 14, payload(code, 0));"
    , "                return mknil;"
    , "              } else {"
    , "                return mknil;"
    , "              }"
    , "              wstore(payload(stN, 0), 19, iW + 1);"
    , "              recur(stN, mknum(4));"
    , "            }"
    , "          } else {"
    , "            if (mkbool(payload(modeN, 0) == 6)) {"
    , "              word iW = wload(payload(stN, 0), 19);"
    , "              word forkedW = wload(payload(stN, 0), 12);"
    , "              if (mkbool(iW >= forkedW)) {"
    , "                rawcall free(wload(payload(stN, 0), 11));"
    , "                wstore(payload(stN, 0), 14, -1);"
    , "                recur(stN, mknum(5));"
    , "              } else {"
    , "                word pW = wload(wload(payload(stN, 0), 11), iW);"
    , "                rawcall kill(pW, 9);"
    , "                rawcall waitpid(pW, 0, 0);"
    , "                wstore(payload(stN, 0), 19, iW + 1);"
    , "                recur(stN, mknum(6));"
    , "              }"
    , "            } else {"
    , "              if (mkbool(wload(payload(stN, 0), 14) < 0)) {"
    , "                if (mkbool(wload(payload(stN, 0), 3) == 0)) {"
    , "                  return mknum(-1);"
    , "                } else {"
    , "                  rawcall _exit(-1);"
    , "                  return mknil;"
    , "                }"
    , "              } else {"
    , "                wstore(payload(stN, 0), 6, wload(payload(stN, 0), 14));"
    , "                wstore(payload(stN, 0), 7, wload(payload(stN, 0), 7) + 1);"
    , "                recur(stN, mknum(0));"
    , "              }"
    , "            }"
    , "          }"
    , "        }"
    , "      }"
    , "    }"
    , "  }"
    , "}"
    , ""
    , -- -- -- Rt.mkTmpAt litPtrN: mkstemp a copy of the template literal at litPtrN,
      -- -- unlink it, return the fd (Zig's execRunDecoded/openBodyTmpfile tmpfile
      -- -- step).  The malloc'd template copy is freed on BOTH paths (a leak is
      -- -- invisible to every oracle).  No self-call.
      "defun Rt.mkTmpAt(litPtrN : val) -> val {"
    , "  word tpl = rawcall malloc(24);"
    , "  if (mkbool(tpl == 0)) {"
    , "    word h = rawcall rt_halt();"
    , "    return mknil;"
    , "  } else {"
    , "    return mknum(0);"
    , "  }"
    , "  call Rt.cStrCopyGo(litPtrN, mknum(tpl), mknum(0));"
    , "  word fd = rawcall mkstemp(tpl);"
    , "  rawcall unlink(tpl);"
    , "  rawcall free(tpl);"
    , "  return mknum(fd);"
    , "}"
    , ""
    , -- -- -- Rt.exec-plan (1 arg: the tagged plan Value): DECODE (3B-2a) into the
      -- -- C-heap blob via the T16 ep* family, then the RUN (3B-2b) via Rt.execGo,
      -- -- then the SLURP+RESULT via Rt.exec-run (3B-2c).  The whole DECODE head is
      -- -- SAFEPOINT-FREE: the 13 decode tag words ride as WORD stores (the names
      -- -- NUL-padded to 8 bytes, first byte low — little-endian) and the run
      -- -- literals as BYTE stores after byte 104, so no Lit LString interning
      -- -- happens before the run.  The run state block, the literal cbuf and the
      -- -- blob are all C-heap, so no safepoint can move them across the run; the
      -- -- Rt.exec-run call's allocations (slurp GC strings + the tagged tree) are
      -- -- why this defun stays FRAMED (its rtDeps edge to the allocating
      -- -- Rt.exec-run classifies it).  MALLOC/FREE PAIRING: every failure arm
      -- -- frees exactly what its level owns, then halts LOUD (the glob precedent).
      -- -- No self-call.
      "defun Rt.exec-plan(plan : val) -> val {"
    , "  word cbufW = rawcall malloc(336);"
    , "  if (mkbool(cbufW == 0)) {"
    , "    word h = rawcall rt_halt();"
    , "    return mknil;"
    , "  } else {"
    , "    return mknum(0);"
    , "  }"
    , "  word stW = rawcall malloc(24);"
    , "  if (mkbool(stW == 0)) {"
    , "    word h = rawcall rt_halt();"
    , "    return mknil;"
    , "  } else {"
    , "    return mknum(0);"
    , "  }"
    , "  word rstW = rawcall malloc(168);"
    , "  if (mkbool(rstW == 0)) {"
    , "    word h = rawcall rt_halt();"
    , "    return mknil;"
    , "  } else {"
    , "    return mknum(0);"
    , "  }"
    , "  wstore(cbufW, 0, 1936617315);"
    , "  wstore(cbufW, 1, 113723913172083);"
    , "  wstore(cbufW, 2, 125779768604014);"
    , "  wstore(cbufW, 3, 119225648511347);"
    , "  wstore(cbufW, 4, 7431539);"
    , "  wstore(cbufW, 5, 6581857);"
    , "  wstore(cbufW, 6, 29295);"
    , "  wstore(cbufW, 7, 28265);"
    , "  wstore(cbufW, 8, 7632239);"
    , "  wstore(cbufW, 9, 110425311047777);"
    , "  wstore(cbufW, 10, 7370084);"
    , "  wstore(cbufW, 11, 1668244584);"
    , "  wstore(cbufW, 12, 1920234344);"
    , "  bytestore(cbufW, 104, 101);"
    , "  bytestore(cbufW, 105, 99);"
    , "  bytestore(cbufW, 106, 104);"
    , "  bytestore(cbufW, 107, 111);"
    , "  bytestore(cbufW, 108, 0);"
    , "  bytestore(cbufW, 109, 116);"
    , "  bytestore(cbufW, 110, 114);"
    , "  bytestore(cbufW, 111, 117);"
    , "  bytestore(cbufW, 112, 101);"
    , "  bytestore(cbufW, 113, 0);"
    , "  bytestore(cbufW, 114, 102);"
    , "  bytestore(cbufW, 115, 97);"
    , "  bytestore(cbufW, 116, 108);"
    , "  bytestore(cbufW, 117, 115);"
    , "  bytestore(cbufW, 118, 101);"
    , "  bytestore(cbufW, 119, 0);"
    , "  bytestore(cbufW, 120, 58);"
    , "  bytestore(cbufW, 121, 0);"
    , "  bytestore(cbufW, 122, 99);"
    , "  bytestore(cbufW, 123, 100);"
    , "  bytestore(cbufW, 124, 0);"
    , "  bytestore(cbufW, 125, 112);"
    , "  bytestore(cbufW, 126, 119);"
    , "  bytestore(cbufW, 127, 100);"
    , "  bytestore(cbufW, 128, 0);"
    , "  bytestore(cbufW, 129, 45);"
    , "  bytestore(cbufW, 130, 110);"
    , "  bytestore(cbufW, 131, 0);"
    , "  bytestore(cbufW, 132, 72);"
    , "  bytestore(cbufW, 133, 79);"
    , "  bytestore(cbufW, 134, 77);"
    , "  bytestore(cbufW, 135, 69);"
    , "  bytestore(cbufW, 136, 0);"
    , "  bytestore(cbufW, 137, 32);"
    , "  bytestore(cbufW, 138, 0);"
    , "  bytestore(cbufW, 139, 47);"
    , "  bytestore(cbufW, 140, 0);"
    , "  bytestore(cbufW, 141, 73);"
    , "  bytestore(cbufW, 142, 110);"
    , "  bytestore(cbufW, 143, 112);"
    , "  bytestore(cbufW, 144, 117);"
    , "  bytestore(cbufW, 145, 116);"
    , "  bytestore(cbufW, 146, 32);"
    , "  bytestore(cbufW, 147, 114);"
    , "  bytestore(cbufW, 148, 101);"
    , "  bytestore(cbufW, 149, 100);"
    , "  bytestore(cbufW, 150, 105);"
    , "  bytestore(cbufW, 151, 114);"
    , "  bytestore(cbufW, 152, 101);"
    , "  bytestore(cbufW, 153, 99);"
    , "  bytestore(cbufW, 154, 116);"
    , "  bytestore(cbufW, 155, 32);"
    , "  bytestore(cbufW, 156, 102);"
    , "  bytestore(cbufW, 157, 105);"
    , "  bytestore(cbufW, 158, 108);"
    , "  bytestore(cbufW, 159, 101);"
    , "  bytestore(cbufW, 160, 32);"
    , "  bytestore(cbufW, 161, 110);"
    , "  bytestore(cbufW, 162, 111);"
    , "  bytestore(cbufW, 163, 116);"
    , "  bytestore(cbufW, 164, 32);"
    , "  bytestore(cbufW, 165, 102);"
    , "  bytestore(cbufW, 166, 111);"
    , "  bytestore(cbufW, 167, 117);"
    , "  bytestore(cbufW, 168, 110);"
    , "  bytestore(cbufW, 169, 100);"
    , "  bytestore(cbufW, 170, 58);"
    , "  bytestore(cbufW, 171, 32);"
    , "  bytestore(cbufW, 172, 0);"
    , "  bytestore(cbufW, 173, 10);"
    , "  bytestore(cbufW, 174, 0);"
    , "  bytestore(cbufW, 175, 79);"
    , "  bytestore(cbufW, 176, 117);"
    , "  bytestore(cbufW, 177, 116);"
    , "  bytestore(cbufW, 178, 112);"
    , "  bytestore(cbufW, 179, 117);"
    , "  bytestore(cbufW, 180, 116);"
    , "  bytestore(cbufW, 181, 32);"
    , "  bytestore(cbufW, 182, 114);"
    , "  bytestore(cbufW, 183, 101);"
    , "  bytestore(cbufW, 184, 100);"
    , "  bytestore(cbufW, 185, 105);"
    , "  bytestore(cbufW, 186, 114);"
    , "  bytestore(cbufW, 187, 101);"
    , "  bytestore(cbufW, 188, 99);"
    , "  bytestore(cbufW, 189, 116);"
    , "  bytestore(cbufW, 190, 32);"
    , "  bytestore(cbufW, 191, 102);"
    , "  bytestore(cbufW, 192, 97);"
    , "  bytestore(cbufW, 193, 105);"
    , "  bytestore(cbufW, 194, 108);"
    , "  bytestore(cbufW, 195, 101);"
    , "  bytestore(cbufW, 196, 100);"
    , "  bytestore(cbufW, 197, 58);"
    , "  bytestore(cbufW, 198, 32);"
    , "  bytestore(cbufW, 199, 0);"
    , "  bytestore(cbufW, 200, 115);"
    , "  bytestore(cbufW, 201, 104);"
    , "  bytestore(cbufW, 202, 101);"
    , "  bytestore(cbufW, 203, 110);"
    , "  bytestore(cbufW, 204, 115);"
    , "  bytestore(cbufW, 205, 104);"
    , "  bytestore(cbufW, 206, 58);"
    , "  bytestore(cbufW, 207, 32);"
    , "  bytestore(cbufW, 208, 0);"
    , "  bytestore(cbufW, 209, 58);"
    , "  bytestore(cbufW, 210, 32);"
    , "  bytestore(cbufW, 211, 110);"
    , "  bytestore(cbufW, 212, 111);"
    , "  bytestore(cbufW, 213, 116);"
    , "  bytestore(cbufW, 214, 32);"
    , "  bytestore(cbufW, 215, 102);"
    , "  bytestore(cbufW, 216, 111);"
    , "  bytestore(cbufW, 217, 117);"
    , "  bytestore(cbufW, 218, 110);"
    , "  bytestore(cbufW, 219, 100);"
    , "  bytestore(cbufW, 220, 10);"
    , "  bytestore(cbufW, 221, 0);"
    , "  bytestore(cbufW, 222, 58);"
    , "  bytestore(cbufW, 223, 32);"
    , "  bytestore(cbufW, 224, 99);"
    , "  bytestore(cbufW, 225, 97);"
    , "  bytestore(cbufW, 226, 110);"
    , "  bytestore(cbufW, 227, 110);"
    , "  bytestore(cbufW, 228, 111);"
    , "  bytestore(cbufW, 229, 116);"
    , "  bytestore(cbufW, 230, 32);"
    , "  bytestore(cbufW, 231, 101);"
    , "  bytestore(cbufW, 232, 120);"
    , "  bytestore(cbufW, 233, 101);"
    , "  bytestore(cbufW, 234, 99);"
    , "  bytestore(cbufW, 235, 117);"
    , "  bytestore(cbufW, 236, 116);"
    , "  bytestore(cbufW, 237, 101);"
    , "  bytestore(cbufW, 238, 10);"
    , "  bytestore(cbufW, 239, 0);"
    , "  bytestore(cbufW, 240, 99);"
    , "  bytestore(cbufW, 241, 100);"
    , "  bytestore(cbufW, 242, 58);"
    , "  bytestore(cbufW, 243, 32);"
    , "  bytestore(cbufW, 244, 0);"
    , "  bytestore(cbufW, 245, 112);"
    , "  bytestore(cbufW, 246, 119);"
    , "  bytestore(cbufW, 247, 100);"
    , "  bytestore(cbufW, 248, 58);"
    , "  bytestore(cbufW, 249, 32);"
    , "  bytestore(cbufW, 250, 99);"
    , "  bytestore(cbufW, 251, 97);"
    , "  bytestore(cbufW, 252, 110);"
    , "  bytestore(cbufW, 253, 110);"
    , "  bytestore(cbufW, 254, 111);"
    , "  bytestore(cbufW, 255, 116);"
    , "  bytestore(cbufW, 256, 32);"
    , "  bytestore(cbufW, 257, 103);"
    , "  bytestore(cbufW, 258, 101);"
    , "  bytestore(cbufW, 259, 116);"
    , "  bytestore(cbufW, 260, 32);"
    , "  bytestore(cbufW, 261, 99);"
    , "  bytestore(cbufW, 262, 119);"
    , "  bytestore(cbufW, 263, 100);"
    , "  bytestore(cbufW, 264, 10);"
    , "  bytestore(cbufW, 265, 0);"
    , "  bytestore(cbufW, 266, 47);"
    , "  bytestore(cbufW, 267, 116);"
    , "  bytestore(cbufW, 268, 109);"
    , "  bytestore(cbufW, 269, 112);"
    , "  bytestore(cbufW, 270, 47);"
    , "  bytestore(cbufW, 271, 115);"
    , "  bytestore(cbufW, 272, 104);"
    , "  bytestore(cbufW, 273, 101);"
    , "  bytestore(cbufW, 274, 110);"
    , "  bytestore(cbufW, 275, 115);"
    , "  bytestore(cbufW, 276, 104);"
    , "  bytestore(cbufW, 277, 45);"
    , "  bytestore(cbufW, 278, 111);"
    , "  bytestore(cbufW, 279, 117);"
    , "  bytestore(cbufW, 280, 116);"
    , "  bytestore(cbufW, 281, 46);"
    , "  bytestore(cbufW, 282, 88);"
    , "  bytestore(cbufW, 283, 88);"
    , "  bytestore(cbufW, 284, 88);"
    , "  bytestore(cbufW, 285, 88);"
    , "  bytestore(cbufW, 286, 88);"
    , "  bytestore(cbufW, 287, 88);"
    , "  bytestore(cbufW, 288, 0);"
    , "  bytestore(cbufW, 289, 47);"
    , "  bytestore(cbufW, 290, 116);"
    , "  bytestore(cbufW, 291, 109);"
    , "  bytestore(cbufW, 292, 112);"
    , "  bytestore(cbufW, 293, 47);"
    , "  bytestore(cbufW, 294, 115);"
    , "  bytestore(cbufW, 295, 104);"
    , "  bytestore(cbufW, 296, 101);"
    , "  bytestore(cbufW, 297, 110);"
    , "  bytestore(cbufW, 298, 115);"
    , "  bytestore(cbufW, 299, 104);"
    , "  bytestore(cbufW, 300, 45);"
    , "  bytestore(cbufW, 301, 101);"
    , "  bytestore(cbufW, 302, 114);"
    , "  bytestore(cbufW, 303, 114);"
    , "  bytestore(cbufW, 304, 46);"
    , "  bytestore(cbufW, 305, 88);"
    , "  bytestore(cbufW, 306, 88);"
    , "  bytestore(cbufW, 307, 88);"
    , "  bytestore(cbufW, 308, 88);"
    , "  bytestore(cbufW, 309, 88);"
    , "  bytestore(cbufW, 310, 88);"
    , "  bytestore(cbufW, 311, 0);"
    , "  bytestore(cbufW, 312, 47);"
    , "  bytestore(cbufW, 313, 116);"
    , "  bytestore(cbufW, 314, 109);"
    , "  bytestore(cbufW, 315, 112);"
    , "  bytestore(cbufW, 316, 47);"
    , "  bytestore(cbufW, 317, 115);"
    , "  bytestore(cbufW, 318, 104);"
    , "  bytestore(cbufW, 319, 101);"
    , "  bytestore(cbufW, 320, 110);"
    , "  bytestore(cbufW, 321, 115);"
    , "  bytestore(cbufW, 322, 104);"
    , "  bytestore(cbufW, 323, 45);"
    , "  bytestore(cbufW, 324, 104);"
    , "  bytestore(cbufW, 325, 100);"
    , "  bytestore(cbufW, 326, 111);"
    , "  bytestore(cbufW, 327, 99);"
    , "  bytestore(cbufW, 328, 46);"
    , "  bytestore(cbufW, 329, 88);"
    , "  bytestore(cbufW, 330, 88);"
    , "  bytestore(cbufW, 331, 88);"
    , "  bytestore(cbufW, 332, 88);"
    , "  bytestore(cbufW, 333, 88);"
    , "  bytestore(cbufW, 334, 88);"
    , "  bytestore(cbufW, 335, 0);"
    , "  wstore(stW, 0, cbufW);"
    , "  wstore(stW, 1, 0);"
    , "  wstore(stW, 2, 0);"
    , "  val progN = call Rt.epProg(plan, mknum(stW));"
    , "  val outfdW = call Rt.mkTmpAt(mknum(cbufW + 266));"
    , "  val errfdW = mkbool(payload(outfdW, 0) >= 0) ? call Rt.mkTmpAt(mknum(cbufW + 289)) : mknum(-1);"
    , "  if (mkbool(payload(progN, 0) < 0)) {"
    , "    rawcall free(rstW);"
    , "    rawcall free(stW);"
    , "    rawcall free(cbufW);"
    , "    word h = rawcall rt_halt();"
    , "    return mknil;"
    , "  } else {"
    , "    if (mkbool(payload(outfdW, 0) < 0) || mkbool(payload(errfdW, 0) < 0)) {"
    , "      if (mkbool(payload(outfdW, 0) >= 0)) {"
    , "        rawcall close(payload(outfdW, 0));"
    , "        return mknil;"
    , "      } else {"
    , "        return mknil;"
    , "      }"
    , "      if (mkbool(payload(errfdW, 0) >= 0)) {"
    , "        rawcall close(payload(errfdW, 0));"
    , "        return mknil;"
    , "      } else {"
    , "        return mknil;"
    , "      }"
    , "      word chainsW = wload(payload(progN, 0), 1);"
    , "      call Rt.epFreeChains(progN, mknum(chainsW), mknum(0));"
    , "      rawcall free(rstW);"
    , "      rawcall free(stW);"
    , "      rawcall free(cbufW);"
    , "      word h = rawcall rt_halt();"
    , "      return mknil;"
    , "    } else {"
    , "      wstore(rstW, 0, cbufW);"
    , "      wstore(rstW, 1, payload(outfdW, 0));"
    , "      wstore(rstW, 2, payload(errfdW, 0));"
    , "      wstore(rstW, 3, 0);"
    , "      wstore(rstW, 4, payload(progN, 0));"
    , "      wstore(rstW, 6, 0);"
    , "      wstore(rstW, 7, 0);"
    , "      val codeN = call Rt.execGo(mknum(rstW), mknum(0));"
    , "      word chainsW = wload(payload(progN, 0), 1);"
    , "      call Rt.epFreeChains(progN, mknum(chainsW), mknum(0));"
    , "      rawcall free(rstW);"
    , "      rawcall free(stW);"
    , "      rawcall free(cbufW);"
    , "      if (mkbool(payload(codeN, 0) < 0)) {"
    , "        rawcall close(payload(outfdW, 0));"
    , "        rawcall close(payload(errfdW, 0));"
    , "        word h = rawcall rt_halt();"
    , "        return mknil;"
    , "      } else {"
    , "        val res = call Rt.exec-run(outfdW, errfdW, codeN);"
    , "        return res;"
    , "      }"
    , "    }"
    , "  }"
    , "}"
    , ""
    , -- -- -- Rt.exec-run outfd errfd code: the SLURP+RESULT half of Zig's
      -- -- execRunDecoded/rt_exec_run seat (3B-2c): slurp both capture tmpfiles,
      -- -- close them, build the TAGGED [code out err] result.  Arity 3 (the
      -- -- lean-ABI cap).  ALLOCATION MODEL (the read-file-as-string discipline):
      -- -- the slurp accumulators live on the C HEAP — the state block (words
      -- -- 0..4 = fd/tmp/acc/len/cap) and the memGo block (words 6..8) share ONE
      -- -- 72-byte malloc plus ONE 65536 tmp, reused for BOTH slurps (words 2/3/4
      -- -- RESET before each — a stale cap would let readFileGo's grow check skip
      -- -- and write past the fresh small acc); Rt.readFileGo is called as-is.  Each
      -- -- slurp: lseek(fd,0,0) first (the tmpfile offset sits at EOF after the run)
      -- -- and lseek failure skips the read so buf/len stay 0.  The result build:
      -- -- ONE RawAllocRaw(len+1) + memGo copy + NUL store per stream (free(buf) —
      -- -- a no-op free(0) on the empty arm — then mkstr consumes the dst into a
      -- -- FRAME SLOT before the next allocation; the moving-GC window has NO
      -- -- safepoint inside it), then the cons tree in Zig's root-dance ORDER
      -- -- (tag_out, tag_err, empty, err_list, out_list, tag_code, final) — each
      -- -- intermediate a rooted frame slot.  blk/tmp malloc OOM is LOUD (rt_halt);
      -- -- tmp OOM frees the block FIRST (the pairing).  The dead conditional
      -- -- rewinds are the both-diverge spelling (the DSL's b11/b18).  No self-call.
      "defun Rt.exec-run(outfdN : val, errfdN : val, codeN : val) -> val {"
    , "  word blkW = rawcall malloc(72);"
    , "  if (mkbool(blkW == 0)) {"
    , "    word h = rawcall rt_halt();"
    , "    return mknil;"
    , "  } else {"
    , "    return mknum(0);"
    , "  }"
    , "  val blkN = mknum(blkW);"
    , "  word tmpW = rawcall malloc(65536);"
    , "  if (mkbool(tmpW == 0)) {"
    , "    rawcall free(blkW);"
    , "    word h = rawcall rt_halt();"
    , "    return mknil;"
    , "  } else {"
    , "    return mknum(0);"
    , "  }"
    , "  wstore(blkW, 2, 0);"
    , "  wstore(blkW, 3, 0);"
    , "  wstore(blkW, 4, 0);"
    , "  word oLS = rawcall lseek(payload(outfdN, 0), 0, 0);"
    , "  if (mkbool(oLS >= 0)) {"
    , "    wstore(blkW, 0, payload(outfdN, 0));"
    , "    wstore(blkW, 1, tmpW);"
    , "    call Rt.readFileGo(blkN);"
    , "    return mknil;"
    , "  } else {"
    , "    return mknil;"
    , "  }"
    , "  word oBuf = wload(blkW, 2);"
    , "  word oLen = wload(blkW, 3);"
    , "  wstore(blkW, 2, 0);"
    , "  wstore(blkW, 3, 0);"
    , "  wstore(blkW, 4, 0);"
    , "  word eLS = rawcall lseek(payload(errfdN, 0), 0, 0);"
    , "  if (mkbool(eLS >= 0)) {"
    , "    wstore(blkW, 0, payload(errfdN, 0));"
    , "    wstore(blkW, 1, tmpW);"
    , "    call Rt.readFileGo(blkN);"
    , "    return mknil;"
    , "  } else {"
    , "    return mknil;"
    , "  }"
    , "  word eBuf = wload(blkW, 2);"
    , "  word eLen = wload(blkW, 3);"
    , "  rawcall close(payload(outfdN, 0));"
    , "  rawcall close(payload(errfdN, 0));"
    , "  word oDst = allocraw(oLen + 1);"
    , "  wstore(blkW, 6, oBuf);"
    , "  wstore(blkW, 7, oDst);"
    , "  wstore(blkW, 8, oLen);"
    , "  call Rt.memGo(mknum(blkW + 48), mknum(0));"
    , "  bytestore(oDst, oLen, 0);"
    , "  rawcall free(oBuf);"
    , "  val oStr = mkstr(oDst, oLen);"
    , "  word eDst = allocraw(eLen + 1);"
    , "  wstore(blkW, 6, eBuf);"
    , "  wstore(blkW, 7, eDst);"
    , "  wstore(blkW, 8, eLen);"
    , "  call Rt.memGo(mknum(blkW + 48), mknum(0));"
    , "  bytestore(eDst, eLen, 0);"
    , "  rawcall free(eBuf);"
    , "  val eStr = mkstr(eDst, eLen);"
    , "  rawcall free(tmpW);"
    , "  rawcall free(blkW);"
    , "  val tagOut = call Rt.cons(call Rt.intern(\"string\"), call Rt.cons(oStr, mknil));"
    , "  val tagErr = call Rt.cons(call Rt.intern(\"string\"), call Rt.cons(eStr, mknil));"
    , "  val emptyV = call Rt.cons(call Rt.intern(\"cons\"), mknil);"
    , "  val errLst = call Rt.cons(call Rt.intern(\"cons\"), call Rt.cons(tagErr, call Rt.cons(emptyV, mknil)));"
    , "  val outLst = call Rt.cons(call Rt.intern(\"cons\"), call Rt.cons(tagOut, call Rt.cons(errLst, mknil)));"
    , "  val tagCode = call Rt.cons(call Rt.intern(\"number\"), call Rt.cons(mknum(payload(codeN, 0)), mknil));"
    , "  return call Rt.cons(call Rt.intern(\"cons\"), call Rt.cons(tagCode, call Rt.cons(outLst, mknil)));"
    , "}"
    -- -- Rt.readFileGo was NOT in T22's list (nor T16's/T17's Rt.epCmd
    -- and Rt.childCd): each has an If in a LET-VALUE position whose
    -- branches carry LETS and whose value the continuation reads (growB;
    -- epCmd's ago/rgo; childCd's second dirN, whose ELSE chains
    -- ln = cStrLenGo dirN and whose value the third dirN and ln read) —
    -- the grammar could not spell them until T23's block-branch if.  ALL
    -- THREE migrated in T24: see the T24 block at the end of this list.

    -- ===== T18 (handoff-osier-tier2-t18): the WHOLE MARK-SWEEP COLLECTOR
    -- (Mid.RtGc's 12 defuns — the SECOND DSL copy, the dedup payoff the
    -- plan names).  MEASURED over the builders: the collector's recursion
    -- is ALL plain RawCall self-edges (gcAllocGo/gcMarkRoots/
    -- gcScanValueArray/gcDrain/gcSweep — the midGc-gated callR form, each
    -- declared in rtDeps), ZERO recur/App — so every self-call spells
    -- `call Rt.x(..)`.  Every defun is frame-free by construction (no
    -- allocating node — TestMain's gc partition row pins it, still green:
    -- the surface carries no LString/allocvec/allocraw/withroots).
    -- The three dead-value Ifs (gcAlloc's proactive threshold, gcDrain's
    -- kind==1 scan, gcMarkRoots's kind dispatch) spell with the
    -- BOTH-DIVERGE form (both branches `return`; the continuation
    -- follows) — the T15/T16 precedent, lowering to Let{dead = If{..}}.
    -- The right-nested arithmetic (tag32's 4-byte read, totalWords) and
    -- the right-nested && in gcMarkPtr are PAREN-EXPLICIT — the surface
    -- operators are left-associative and the DSL nesting is not.
    -- rt_glob_addr is spelled `rawcall rt_glob_addr()` — its J3 row was
    -- MISSING from Ast.rawcallArity and was added (one row, T18).
    -- THE die MESSAGES CARRY THE "qbe-rt: " PREFIX IN THE RAWSTR.  The Zig
    -- seat this fold replaces (rt_midgc_die, deleted at U2) called
    -- dieLoud(msgs[code]), and dieLoud's OWN format is "qbe-rt: {s}\n"
    -- (rt.zig:1221-1226) — so the wire bytes were "qbe-rt: midgc: ...\n".
    -- Rt.die's own format is msg ++ "\n" with NO prefix (it is ALSO the
    -- rt_die replacement, and rt.zig's rt_die at :784-787 writes span(msg)
    -- then "\n"), so the prefix belongs HERE, in the call-site strings —
    -- baking it into Rt.die would double it on the non-exhaustive-pattern
    -- path and break THAT seat's parity.
    , "defun Rt.gcInit(dummy : val) -> val {"
    , "  word glob = rawcall rt_glob_addr();"
    , "  word region = wload(glob, 0);"
    , "  if (mkbool(region != 0)) {"
    , "    return mknum(region);"
    , "  } else {"
    , "    word heapBytes = rawcall rt_gc_heap_bytes();"
    , "    word regionSize = heapBytes + heapBytes / 8;"
    , "    word base = rawcall mmap(0, regionSize, 3, 34, -1, 0);"
    , "    if (mkbool(base < 0)) {"
    , "      call Rt.die(rawstr(\"qbe-rt: midgc: mmap failed\"));"
    , "      return mknil;"
    , "    } else {"
    , "      word heapStart = base + (528 + heapBytes / 8);"
    , "      word markEnd = 64 + ((heapBytes / 8) / 8);"
    , "      wstore(glob, 0, base);"
    , "      wstore(base, 0, 331941693251);"
    , "      wstore(base, 1, 0);"
    , "      wstore(base, 2, heapStart);"
    , "      wstore(base, 3, heapStart);"
    , "      wstore(base, 4, base + regionSize);"
    , "      wstore(base, 5, 64);"
    , "      wstore(base, 6, markEnd);"
    , "      wstore(base, 10, heapBytes);"
    , "      wstore(base, 11, 0);"
    , "      return mknum(base);"
    , "    }"
    , "  }"
    , "}"
    , "defun Rt.allocVector(count : val) -> val {"
    , "  val region = call Rt.gcInit(mknum(0));"
    , "  word countW = payload(count, 0);"
    , "  return call Rt.gcAlloc(region, mknum(1), mknum(countW));"
    , "}"
    , "defun Rt.allocRaw(nbytes : val) -> val {"
    , "  val region = call Rt.gcInit(mknum(0));"
    , "  word nbytesW = payload(nbytes, 0);"
    , "  word bodyWords = (nbytesW + 7) / 8;"
    , "  return call Rt.gcAlloc(region, mknum(0), mknum(bodyWords));"
    , "}"
    , "defun Rt.gcAlloc(region : val, kind : val, count : val) -> val {"
    , "  word kindW = payload(kind, 0);"
    , "  word countW = payload(count, 0);"
    , "  word regionW = payload(region, 0);"
    , "  word total = 2 + (countW + 4 * countW * kindW);"
    , "  word heapBytes = wload(regionW, 10);"
    , "  word allocated = wload(regionW, 11);"
    , "  wstore(regionW, 7, total);"
    , "  wstore(regionW, 8, kindW);"
    , "  wstore(regionW, 9, countW);"
    , "  if (mkbool(allocated > heapBytes / 4)) {"
    , "    call Rt.collect(mknum(0));"
    , "    wstore(regionW, 11, 0);"
    , "    return mknil;"
    , "  } else {"
    , "    return mknil;"
    , "  }"
    , "  val first = call Rt.gcAllocGo(region, mknum(regionW + 8));"
    , "  word firstW = payload(first, 0);"
    , "  if (mkbool(firstW == 0)) {"
    , "    word cursor = wload(regionW, 3);"
    , "    word heapEnd = wload(regionW, 4);"
    , "    if (mkbool(cursor + total * 8 < heapEnd)) {"
    , "      wstore(cursor, -2, kindW * 2);"
    , "      wstore(cursor, -1, countW);"
    , "      wstore(regionW, 3, cursor + total * 8);"
    , "      wstore(regionW, 11, wload(regionW, 11) + total * 8);"
    , "      return mknum(cursor);"
    , "    } else {"
    , "      call Rt.collect(mknum(0));"
    , "      wstore(regionW, 11, 0);"
    , "      val retry = call Rt.gcAllocGo(region, mknum(regionW + 8));"
    , "      word retryW = payload(retry, 0);"
    , "      if (mkbool(retryW == 0)) {"
    , "        call Rt.die(rawstr(\"qbe-rt: midgc: out of memory\"));"
    , "        return mknil;"
    , "      } else {"
    , "        wstore(regionW, 11, wload(regionW, 11) + total * 8);"
    , "        return mknum(retryW);"
    , "      }"
    , "    }"
    , "  } else {"
    , "    wstore(regionW, 11, wload(regionW, 11) + total * 8);"
    , "    return mknum(firstW);"
    , "  }"
    , "}"
    , "defun Rt.gcAllocGo(region : val, linkAddr : val) -> val {"
    , "  word p = wload(payload(linkAddr, 0), 0);"
    , "  word total = wload(payload(region, 0), 7);"
    , "  word kind = wload(payload(region, 0), 8);"
    , "  word count = wload(payload(region, 0), 9);"
    , "  if (mkbool(p == 0)) {"
    , "    return mknum(0);"
    , "  } else {"
    , "    word flags = wload(p, -2);"
    , "    word fkind = flags / 2;"
    , "    word fcount = wload(p, -1);"
    , "    word ftotal = 2 + (fcount + 4 * fcount * fkind);"
    , "    if (mkbool(ftotal == total)) {"
    , "      wstore(payload(linkAddr, 0), 0, wload(p, 0));"
    , "      wstore(p, -2, kind * 2);"
    , "      wstore(p, -1, count);"
    , "      return mknum(p);"
    , "    } else {"
    , "      return call Rt.gcAllocGo(region, mknum(p));"
    , "    }"
    , "  }"
    , "}"
    , "defun Rt.collect(dummy : val) -> val {"
    , "  word glob = rawcall rt_glob_addr();"
    , "  word region = wload(glob, 0);"
    , "  if (mkbool(wload(region, 0) == 331941693251)) {"
    , "    wstore(region, 5, 64);"
    , "    call Rt.gcMarkRoots(mknum(0));"
    , "    call Rt.gcDrain(mknum(0));"
    , "    wstore(region, 1, 0);"
    , "    call Rt.gcSweep(mknum(wload(region, 2)));"
    , "    return mknil;"
    , "  } else {"
    , "    call Rt.die(rawstr(\"qbe-rt: midgc: collect before init\"));"
    , "    return mknil;"
    , "  }"
    , "}"
    , "defun Rt.gcMarkRoots(i : val) -> val {"
    , "  word iW = payload(i, 0);"
    , "  word nRoots = rawcall rt_gc_roots_len();"
    , "  if (mkbool(iW >= nRoots)) {"
    , "    return mknil;"
    , "  } else {"
    , "    word kind = rawcall rt_gc_root_kind(iW);"
    , "    word slot = rawcall rt_gc_root_slot(iW);"
    , "    word np = rawcall rt_gc_root_np(iW);"
    , "    if (mkbool(kind == 0)) {"
    , "      return call Rt.gcMarkPtr(mknum(wload(slot, 0)));"
    , "    } else {"
    , "      if (mkbool(kind == 1)) {"
    , "        return call Rt.gcMarkValue(mknum(slot));"
    , "      } else {"
    , "        if (mkbool(kind == 3)) {"
    , "          return call Rt.gcMarkValue(mknum(slot));"
    , "        } else {"
    , "          if (mkbool(kind == 2)) {"
    , "            word count = byteload(np, 0) + (byteload(np, 1) * 256 + (byteload(np, 2) * 65536 + byteload(np, 3) * 16777216));"
    , "            return call Rt.gcScanValueArray(mknum(slot), mknum(count));"
    , "          } else {"
    , "            call Rt.die(rawstr(\"qbe-rt: midgc: unknown root kind\"));"
    , "            return mknil;"
    , "          }"
    , "        }"
    , "      }"
    , "    }"
    , "    return call Rt.gcMarkRoots(mknum(iW + 1));"
    , "  }"
    , "}"
    , "defun Rt.gcScanValueArray(base : val, cnt : val) -> val {"
    , "  word baseW = payload(base, 0);"
    , "  word cntW = payload(cnt, 0);"
    , "  if (mkbool(cntW == 0)) {"
    , "    return mknil;"
    , "  } else {"
    , "    call Rt.gcMarkValue(mknum(baseW));"
    , "    return call Rt.gcScanValueArray(mknum(baseW + 40), mknum(cntW - 1));"
    , "  }"
    , "}"
    , "defun Rt.gcDrain(dummy : val) -> val {"
    , "  word glob = rawcall rt_glob_addr();"
    , "  word region = wload(glob, 0);"
    , "  word top = wload(region, 5);"
    , "  if (mkbool(top > 64)) {"
    , "    word newTop = top - 1;"
    , "    word p = wload(region, newTop);"
    , "    word flags = wload(p, -2);"
    , "    word kind = flags / 2;"
    , "    word count = wload(p, -1);"
    , "    wstore(region, 5, newTop);"
    , "    if (mkbool(kind == 1)) {"
    , "      return call Rt.gcScanValueArray(mknum(p), mknum(count));"
    , "    } else {"
    , "      return mknil;"
    , "    }"
    , "    return call Rt.gcDrain(mknum(0));"
    , "  } else {"
    , "    return mknil;"
    , "  }"
    , "}"
    , "defun Rt.gcSweep(cursor : val) -> val {"
    , "  word cursorW = payload(cursor, 0);"
    , "  word glob = rawcall rt_glob_addr();"
    , "  word region = wload(glob, 0);"
    , "  word heapCursor = wload(region, 3);"
    , "  if (mkbool(cursorW >= heapCursor)) {"
    , "    return mknil;"
    , "  } else {"
    , "    word flags = wload(cursorW, -2);"
    , "    word kind = flags / 2;"
    , "    word count = wload(cursorW, -1);"
    , "    word total = 2 + (count + 4 * count * kind);"
    , "    word marked = flags - flags / 2 * 2;"
    , "    if (mkbool(marked == 1)) {"
    , "      wstore(cursorW, -2, flags - 1);"
    , "      return call Rt.gcSweep(mknum(cursorW + total * 8));"
    , "    } else {"
    , "      wstore(cursorW, 0, wload(region, 1));"
    , "      wstore(region, 1, cursorW);"
    , "      return call Rt.gcSweep(mknum(cursorW + total * 8));"
    , "    }"
    , "  }"
    , "}"
    , "defun Rt.gcMarkPtr(p : val) -> val {"
    , "  word ptr = payload(p, 0);"
    , "  word glob = rawcall rt_glob_addr();"
    , "  word region = wload(glob, 0);"
    , "  word heapStart = wload(region, 2);"
    , "  word heapEnd = wload(region, 4);"
    , "  if (mkbool(ptr != 0) && (mkbool(ptr >= heapStart) && mkbool(ptr < heapEnd))) {"
    , "    word flags = wload(ptr, -2);"
    , "    word marked = flags - flags / 2 * 2;"
    , "    word top = wload(region, 5);"
    , "    word markEnd = wload(region, 6);"
    , "    if (mkbool(marked == 0)) {"
    , "      if (mkbool(top < markEnd)) {"
    , "        wstore(ptr, -2, flags + 1);"
    , "        wstore(region, top, ptr);"
    , "        wstore(region, 5, top + 1);"
    , "        return mknil;"
    , "      } else {"
    , "        call Rt.die(rawstr(\"qbe-rt: midgc: mark stack overflow\"));"
    , "        return mknil;"
    , "      }"
    , "    } else {"
    , "      return mknil;"
    , "    }"
    , "  } else {"
    , "    return mknil;"
    , "  }"
    , "}"
    , "defun Rt.gcMarkValue(vaddr : val) -> val {"
    , "  word tag = byteload(payload(vaddr, 0), 0) + (byteload(payload(vaddr, 0), 1) * 256 + (byteload(payload(vaddr, 0), 2) * 65536 + byteload(payload(vaddr, 0), 3) * 16777216));"
    , "  word vaddrW = payload(vaddr, 0);"
    , "  if (mkbool(tag == 1)) {"
    , "    return call Rt.gcMarkPtr(mknum(wload(vaddrW, 1)));"
    , "  } else {"
    , "    if (mkbool(tag == 4)) {"
    , "      return call Rt.gcMarkPtr(mknum(wload(vaddrW, 1)));"
    , "    } else {"
    , "      if (mkbool(tag == 6)) {"
    , "        call Rt.gcMarkPtr(mknum(wload(vaddrW, 1)));"
    , "        return call Rt.gcMarkPtr(mknum(wload(vaddrW, 3)));"
    , "      } else {"
    , "        if (mkbool(tag == 9)) {"
    , "          return call Rt.gcMarkPtr(mknum(wload(vaddrW, 1)));"
    , "        } else {"
    , "          if (mkbool(tag == 10)) {"
    , "            return call Rt.gcMarkPtr(mknum(wload(vaddrW, 1)));"
    , "          } else {"
    , "            if (mkbool(tag == 14)) {"
    , "              call Rt.gcMarkPtr(mknum(wload(vaddrW, 1)));"
    , "              return call Rt.gcMarkPtr(mknum(wload(vaddrW, 3)));"
    , "            } else {"
    , "              if (mkbool(tag == 13)) {"
    , "                call Rt.die(rawstr(\"qbe-rt: midgc: unknown value tag in mark walk\"));"
    , "                return mknil;"
    , "              } else {"
    , "                if (mkbool(tag > 14)) {"
    , "                  call Rt.die(rawstr(\"qbe-rt: midgc: unknown value tag in mark walk\"));"
    , "                  return mknil;"
    , "                } else {"
    , "                  return mknil;"
    , "                }"
    , "              }"
    , "            }"
    , "          }"
    , "        }"
    , "      }"
    , "    }"
    , "  }"
    , "}"

    , -- ====================== T20 — the never-scheduled family, part 1:
      -- arithmetic + comparisons + tag predicates ======================
      --
      -- THIRTEEN keys NO wave T8-T18 ever scheduled (T19's holdout
      -- inventory, "spellable today"): Rt.+ - * / f/, the four
      -- comparisons, and the four tag predicates.  Each body is the SAME
      -- tree shape as its deleted RtPrims builder:
      --   * Rt.+ / Rt.- / Rt.* — `iff (or2 (mkBool (tagIs a 12)) (mkBool
      --     (tagIs bb 12))) (mkFlt (fbin .. (flOf (callR "Rt.asF" ..))
      --     ..)) (mkNum (ibin ..))`: EITHER float promotes and computes
      --     in f64 over `fload(call Rt.asF(..))`, else the BARE i64 op
      --     (shen semantics, no numeric guard — the metacircular
      --     interpreter relies on the wrap).  The if is the defun's TERM
      --     with an else, so L5 spells the DSL's bare If — no dead
      --     binder, no else-nesting.
      --   * Rt./ — bare integer divTrunc, no guard at all (a zero
      --     divisor SIGFPEs both backends — parity by crash).
      --   * Rt.f/ — ALWAYS f64 division (IEEE: x/0.0 = Infinity).
      --   * Rt.< <= > >= — cmpDefun: BOTH operands numeric (tag 0 or 12)
      --     or the answer is `false`; either float promotes to the f64
      --     compare, else the signed i64 compare.  The NESTED term-if
      --     spells the DSL's iff-in-iff (each branch returns, so both
      --     levels lower as bare Ifs).  The outer cond is the same
      --     `(tag 0 || tag 12) && (tag 0 || tag 12)` shape T10's Rt.=
      --     arms already pin.
      --   * Rt.number? / string? / cons? / empty? — predDefun's
      --     List.foldr OR-chain spelled out per defun; number? (tags
      --     [0, 12]) keeps the fold's RIGHT-nested shape with explicit
      --     parens (the left-assoc `||` parse would move the Ifs —
      --     the T15 globScanGo precedent).
      -- Rt.+, Rt.*, Rt./, Rt.f/ and the four `?` keys needed THREE more
      -- key characters (`* / ?`) in Parse's key charset — the T8b (`-
      -- + = < >`) and T12 (`@`) precedent, read only in the two key
      -- positions, both followed by `(`; the expression lexer (and the
      -- `?:` join) is untouched.
      --
      -- Recursion MEASURED per defun: NONE — no builder in this wave
      -- references itself or any non-migrated key; the only Rt calls are
      -- `call Rt.asF(..)` (migrated T11), an EXISTING surface defun.

      "defun Rt.+(a : val, bb : val) -> val {"
    , "  if (mkbool(tagis(a, 12)) || mkbool(tagis(bb, 12))) {"
    , "    return mkflt(fload(call Rt.asF(a)) f+ fload(call Rt.asF(bb)));"
    , "  } else {"
    , "    return mknum(payload(a, 0) + payload(bb, 0));"
    , "  }"
    , "}"
    , "defun Rt.-(a : val, bb : val) -> val {"
    , "  if (mkbool(tagis(a, 12)) || mkbool(tagis(bb, 12))) {"
    , "    return mkflt(fload(call Rt.asF(a)) f- fload(call Rt.asF(bb)));"
    , "  } else {"
    , "    return mknum(payload(a, 0) - payload(bb, 0));"
    , "  }"
    , "}"
    , "defun Rt.*(a : val, bb : val) -> val {"
    , "  if (mkbool(tagis(a, 12)) || mkbool(tagis(bb, 12))) {"
    , "    return mkflt(fload(call Rt.asF(a)) f* fload(call Rt.asF(bb)));"
    , "  } else {"
    , "    return mknum(payload(a, 0) * payload(bb, 0));"
    , "  }"
    , "}"
    , "defun Rt./(a : val, bb : val) -> val {"
    , "  return mknum(payload(a, 0) / payload(bb, 0));"
    , "}"
    , "defun Rt.f/(a : val, bb : val) -> val {"
    , "  return mkflt(fload(call Rt.asF(a)) f/ fload(call Rt.asF(bb)));"
    , "}"
    , "defun Rt.<(a : val, bb : val) -> val {"
    , "  if ((mkbool(tagis(a, 0)) || mkbool(tagis(a, 12))) && (mkbool(tagis(bb, 0)) || mkbool(tagis(bb, 12)))) {"
    , "    if (mkbool(tagis(a, 12)) || mkbool(tagis(bb, 12))) {"
    , "      return mkbool(fload(call Rt.asF(a)) f< fload(call Rt.asF(bb)));"
    , "    } else {"
    , "      return mkbool(payload(a, 0) < payload(bb, 0));"
    , "    }"
    , "  } else {"
    , "    return false;"
    , "  }"
    , "}"
    , "defun Rt.<=(a : val, bb : val) -> val {"
    , "  if ((mkbool(tagis(a, 0)) || mkbool(tagis(a, 12))) && (mkbool(tagis(bb, 0)) || mkbool(tagis(bb, 12)))) {"
    , "    if (mkbool(tagis(a, 12)) || mkbool(tagis(bb, 12))) {"
    , "      return mkbool(fload(call Rt.asF(a)) f<= fload(call Rt.asF(bb)));"
    , "    } else {"
    , "      return mkbool(payload(a, 0) <= payload(bb, 0));"
    , "    }"
    , "  } else {"
    , "    return false;"
    , "  }"
    , "}"
    , "defun Rt.>(a : val, bb : val) -> val {"
    , "  if ((mkbool(tagis(a, 0)) || mkbool(tagis(a, 12))) && (mkbool(tagis(bb, 0)) || mkbool(tagis(bb, 12)))) {"
    , "    if (mkbool(tagis(a, 12)) || mkbool(tagis(bb, 12))) {"
    , "      return mkbool(fload(call Rt.asF(a)) f> fload(call Rt.asF(bb)));"
    , "    } else {"
    , "      return mkbool(payload(a, 0) > payload(bb, 0));"
    , "    }"
    , "  } else {"
    , "    return false;"
    , "  }"
    , "}"
    , "defun Rt.>=(a : val, bb : val) -> val {"
    , "  if ((mkbool(tagis(a, 0)) || mkbool(tagis(a, 12))) && (mkbool(tagis(bb, 0)) || mkbool(tagis(bb, 12)))) {"
    , "    if (mkbool(tagis(a, 12)) || mkbool(tagis(bb, 12))) {"
    , "      return mkbool(fload(call Rt.asF(a)) f>= fload(call Rt.asF(bb)));"
    , "    } else {"
    , "      return mkbool(payload(a, 0) >= payload(bb, 0));"
    , "    }"
    , "  } else {"
    , "    return false;"
    , "  }"
    , "}"
    , "defun Rt.number?(a : val) -> val {"
    , "  return mkbool(tagis(a, 0)) || (mkbool(tagis(a, 12)) || false);"
    , "}"
    , "defun Rt.string?(a : val) -> val {"
    , "  return mkbool(tagis(a, 1)) || false;"
    , "}"
    , "defun Rt.cons?(a : val) -> val {"
    , "  return mkbool(tagis(a, 4)) || false;"
    , "}"
    , "defun Rt.empty?(a : val) -> val {"
    , "  return mkbool(tagis(a, 5)) || false;"
    , "}"

    , -- ====================== T21 — the never-scheduled family, part 2:
      -- bitwise + string prims ======================
      --
      -- FOURTEEN keys NO wave T8-T20 ever scheduled (T19's holdout
      -- inventory, "spellable today"): the seven-key Bitwise family and
      -- seven string prims.  Each body is the SAME tree shape as its
      -- deleted RtPrims builder:
      --   * Rt.bitwise-and/or/xor — bit2Defun's `mknum(payload(call
      --     Rt.toI32(a), 0) OP payload(call Rt.toI32(bb), 0))`: operands
      --     through toI32, the op at word width (the DSL's iand/ior/ixor
      --     RawBin), one mknum wrap.
      --   * Rt.bitwise-not — bitNotDefun's RawUn RBitNot, spelled
      --     `bitnot` over the same payload(toI32(a), 0) operand.
      --   * Rt.bitwise-shift-left/right/right-zf — shl/sar/shr:
      --     `value << (count & 31)` (RShl/RShAr/RShR; `>>` the
      --     arithmetic, `>>>` the zero-fill), the count masked mod 32
      --     by `& 31` — `&` binds TIGHTER than the shifts in the
      --     C-convention precedence table (Parse rows 5 vs 8), and the
      --     parens are written anyway.  ZINC RTL operand order kept:
      --     a1 = count (leftmost param), a2 = value.
      --   * Rt.c-strlen — `mknum(len32(s))`, the i32 len field.
      --   * Rt.char-code — the bounds test `0 <= i && i < len` boxed
      --     per arm (mkbool over the raw compares), `strbyte` the byte
      --     read, else `mknum(-1)`; the DSL's and2 -> the surface `&&`
      --     (EShortOr's twin), the defun-tail if spells the bare If.
      --   * Rt.substring — primSubstring's clamps: the st0/ln0 binders
      --     hold Ifs in LET-VALUE positions whose branches are
      --     EXPRESSIONS (mknum / the raw val param) — the T9b `?:`
      --     join, nested right per row-0's associativity (numText
      --     precedent); `end` is a plain mknum of the two payloads;
      --     the tail is bytesToStr over subGo.
      --   * Rt.cn — `call Rt.cn2(call Rt.strOf(a), call Rt.strOf(bb))`,
      --     no let, no if.
      --   * Rt.repeat — the `cnt <= 0 || len < 0` guard as the tail if,
      --     the empty string literal as the then-value.
      --   * Rt.shen.str->bytes / Rt.shen.bytes->string — the tag guard
      --     (string / nil-or-cons) as the tail if; the halt arm is
      --     `word h = rawcall rt_halt();` + `return mknil;` — the DSL's
      --     haltV dead binder (L2's fresh-binder Let; binder ids are
      --     dict keys, not emitted — F1), the T8 rt_halt-0 spelling.
      --
      -- Rt.subGo / Rt.repGo / Rt.bytesBuild (the walk helpers
      -- substring / repeat / str->bytes call) are STILL DSL-BODIED:
      -- J2's extern table resolves them without a new row —
      -- Rt.externArities is DERIVED from the DSL program, so a key
      -- not yet migrated is seeded automatically (Rt.elm's
      -- externArities note).  Recursion MEASURED per defun: NONE — no
      -- builder in this wave references itself; the only Rt calls are
      -- toI32/bytesToStr/cn2/strOf (surface since T11/T12) and the
      -- three walk helpers above (plain RawCall edges rtDeps already
      -- carries).
      --
      -- NO parser change: every key character is already in the T8b/
      -- T12/T20 charset (letters, digits, `.`, and `- > ? * / + = < @`);
      -- `Rt.shen.str->bytes` lexes exactly as `Rt.address->` did in
      -- T13.  Newly-dead RtPrims helpers deleted with the builders:
      -- iand/ior/ixor (bit2Defun's op arguments + the shift masks),
      -- shlW/sarW/shrW (the shift RawBins), and the RawUnOp(..)
      -- import (bitNotDefun was its only user).

      "defun Rt.bitwise-and(a : val, bb : val) -> val {"
    , "  return mknum(payload(call Rt.toI32(a), 0) & payload(call Rt.toI32(bb), 0));"
    , "}"
    , "defun Rt.bitwise-or(a : val, bb : val) -> val {"
    , "  return mknum(payload(call Rt.toI32(a), 0) | payload(call Rt.toI32(bb), 0));"
    , "}"
    , "defun Rt.bitwise-xor(a : val, bb : val) -> val {"
    , "  return mknum(payload(call Rt.toI32(a), 0) ^ payload(call Rt.toI32(bb), 0));"
    , "}"
    , "defun Rt.bitwise-not(a : val) -> val {"
    , "  return mknum(bitnot(payload(call Rt.toI32(a), 0)));"
    , "}"
    , "defun Rt.bitwise-shift-left(count : val, value : val) -> val {"
    , "  return mknum(payload(call Rt.toI32(value), 0) << (payload(call Rt.toI32(count), 0) & 31));"
    , "}"
    , "defun Rt.bitwise-shift-right(count : val, value : val) -> val {"
    , "  return mknum(payload(call Rt.toI32(value), 0) >> (payload(call Rt.toI32(count), 0) & 31));"
    , "}"
    , "defun Rt.bitwise-shift-right-zf(count : val, value : val) -> val {"
    , "  return mknum(payload(call Rt.toI32(value), 0) >>> (payload(call Rt.toI32(count), 0) & 31));"
    , "}"
    , "defun Rt.c-strlen(s : val) -> val {"
    , "  return mknum(len32(s));"
    , "}"
    , "defun Rt.char-code(s : val, i : val) -> val {"
    , "  if (mkbool(0 <= payload(i, 0)) && mkbool(payload(i, 0) < len32(s))) {"
    , "    return mknum(strbyte(s, payload(i, 0)));"
    , "  } else {"
    , "    return mknum(-1);"
    , "  }"
    , "}"
    , "defun Rt.substring(s : val, st : val, ln : val) -> val {"
    , "  val st0 = mkbool(payload(st, 0) < 0) ? mknum(0) : (mkbool(payload(st, 0) > len32(s)) ? mknum(len32(s)) : st);"
    , "  val ln0 = mkbool(payload(ln, 0) < 0) ? mknum(0) : (mkbool((payload(st0, 0) + payload(ln, 0)) > len32(s)) ? mknum(len32(s) - payload(st0, 0)) : ln);"
    , "  val end = mknum(payload(st0, 0) + payload(ln0, 0));"
    , "  return call Rt.bytesToStr(call Rt.subGo(s, st0, end));"
    , "}"
    , "defun Rt.cn(a : val, bb : val) -> val {"
    , "  return call Rt.cn2(call Rt.strOf(a), call Rt.strOf(bb));"
    , "}"
    , "defun Rt.repeat(cnt : val, s : val) -> val {"
    , "  if (mkbool(payload(cnt, 0) <= 0) || mkbool(len32(s) <= 0)) {"
    , "    return \"\";"
    , "  } else {"
    , "    return call Rt.bytesToStr(call Rt.repGo(s, cnt));"
    , "  }"
    , "}"
    , "defun Rt.shen.str->bytes(s : val) -> val {"
    , "  if (mkbool(tagis(s, 1))) {"
    , "    return call Rt.bytesBuild(s, mknum(len32(s)), mknil);"
    , "  } else {"
    , "    word h = rawcall rt_halt();"
    , "    return mknil;"
    , "  }"
    , "}"
    , "defun Rt.shen.bytes->string(bs : val) -> val {"
    , "  if (mkbool(tagis(bs, 5)) || mkbool(tagis(bs, 4))) {"
    , "    return call Rt.bytesToStr(bs);"
    , "  } else {"
    , "    word h = rawcall rt_halt();"
    , "    return mknil;"
    , "  }"
    , "}"
    , -- ====================== T22 — the never-scheduled family, part 3
      -- (FINAL): the constructor layer + the residual helpers
      -- ======================
      --
      -- NINE keys — the last of T19's never-scheduled holdouts; the
      -- tier-2 remainder after T22 was then ONLY the three wall-class
      -- defuns (readFileGo's growB, epCmd's ago/rgo, childCd's dirN#2),
      -- all migrated in T24 (the block at the end of this list).  Each
      -- body is the SAME tree shape as its deleted RtPrims builder:
      --   * Rt.con — allocvec of cnt+1 slots, the tag at [0] (the
      --     vecstore effect statement = the DSL's dead b6 binder), the
      --     staged args copied by the conFill effect call (dead b7),
      --     wrapped `mkvec(dataW, cntW + 1)` = RawMkValue tagVector.
      --   * Rt.conFill — the 1-based copy walk: the idx==0 guard as
      --     the defun-tail if (mknil arm), the vecstore(vecload(..))
      --     as an effect statement (dead b7), the self-call a plain
      --     `call` — every recursion in this wave is the DSL's callR
      --     RawCall, NOT recur (MEASURED per defun).
      --   * Rt.closure — allocvec of cnt slots (NO tag slot), code_len
      --     read as `wload(descW, 1)` (the Desc's arity word at offset
      --     8: arity low half), the captures copied by the closureFill
      --     effect call, wrapped `mkval(6, descW, arityW, dataW, cntW)`
      --     = RawMkValue tagLambda words verbatim.
      --   * Rt.closureFill — conFill's 0-BASED twin: env[i] = cap[i],
      --     so BOTH the store index and the load index are idx-1.
      --   * Rt.subGo — substring's copy walk: the i>=e guard as the
      --     tail if, then `call Rt.cons(mknum(strbyte(..)), call
      --     Rt.subGo(..))` (consV WAS callR "Rt.cons" exactly).
      --   * Rt.repGo — the i<=0 guard (the DSL's RCles), then appendL
      --     over bytesOf and the self-call.
      --   * Rt.bytesBuild — the back-to-front walk: the i<=0 guard
      --     (RCles again) returns `acc` (the bare param), the cons
      --     rides in the self-call's third argument.
      --   * Rt.symLess — symEq's LESS-THAN twin: two boxed byte reads
      --     (mknum(strbyte(..))), then the nested term-if chain (the
      --     T20 comparisons' shape): ca==0 -> cb!=0; cb==0 ->
      --     mkbool(0); ca<cb -> mkbool(1); ca>cb -> mkbool(0); else
      --     the self-call at i+1.
      --   * Rt.read-file-as-string — primReadFileAsString: the cStrOf
      --     four binders written out (payload32(path, 1) is the DSL's
      --     lenOf — the i32 len FIELD at word 1, NOT payload(., 0)),
      --     openat(-100, bufW, 0, 0); the open-fail arm is the
      --     stderr-note lets + `return "";`; the malloc OOM checks are
      --     Ifs in LET-VALUE positions whose branches are LETs and
      --     whose values are DEAD — spelled as the T15 both-diverge
      --     mid-block if (`word h = rawcall rt_halt(); return mknil;`
      --     IS the DSL's haltV; `return mknum(0);` its dead mknum(0)
      --     else; tmp OOM frees the block first, the pairing); then
      --     the five state-block wstores, the readFileGo call, and
      --     the ONE exit (memGo, the NUL bytestore, free/free/free/
      --     close, mkstr).  Its copy-on-grow helper Rt.readFileGo
      --     STAYS DSL-side (the growB wall, unchanged).
      -- Deleted with their only readers: cStrOf, lenOf, mkVec, consV,
      -- byteOf, trueV, falseV (zero-ref verified after the wave).
      "defun Rt.con(tag : val, argsPtr : val, cnt : val) -> val {"
    , "  word dataW = allocvec(payload(cnt, 0) + 1);"
    , "  word cntW = payload(cnt, 0);"
    , "  vecstore(dataW, 0, tag);"
    , "  call Rt.conFill(mknum(dataW), argsPtr, mknum(cntW));"
    , "  return mkvec(dataW, cntW + 1);"
    , "}"
    , ""
    , "defun Rt.conFill(data : val, argsPtr : val, idx : val) -> val {"
    , "  word dataW = payload(data, 0);"
    , "  word argsW = payload(argsPtr, 0);"
    , "  word idxW = payload(idx, 0);"
    , "  if (mkbool(idxW == 0)) {"
    , "    return mknil;"
    , "  } else {"
    , "    vecstore(dataW, idxW, vecload(argsW, idxW - 1));"
    , "    return call Rt.conFill(mknum(dataW), mknum(argsW), mknum(idxW - 1));"
    , "  }"
    , "}"
    , ""
    , "defun Rt.closure(desc : val, capBase : val, cnt : val) -> val {"
    , "  word dataW = allocvec(payload(cnt, 0));"
    , "  word cntW = payload(cnt, 0);"
    , "  word descW = payload(desc, 0);"
    , "  word arityW = wload(descW, 1);"
    , "  call Rt.closureFill(mknum(dataW), capBase, mknum(cntW));"
    , "  return mkval(6, descW, arityW, dataW, cntW);"
    , "}"
    , ""
    , "defun Rt.closureFill(data : val, capBase : val, idx : val) -> val {"
    , "  word dataW = payload(data, 0);"
    , "  word capW = payload(capBase, 0);"
    , "  word idxW = payload(idx, 0);"
    , "  if (mkbool(idxW == 0)) {"
    , "    return mknil;"
    , "  } else {"
    , "    vecstore(dataW, idxW - 1, vecload(capW, idxW - 1));"
    , "    return call Rt.closureFill(mknum(dataW), mknum(capW), mknum(idxW - 1));"
    , "  }"
    , "}"
    , ""
    , "defun Rt.subGo(s : val, i : val, e : val) -> val {"
    , "  if (mkbool(payload(i, 0) >= payload(e, 0))) {"
    , "    return mknil;"
    , "  } else {"
    , "    return call Rt.cons(mknum(strbyte(s, payload(i, 0))), call Rt.subGo(s, mknum(payload(i, 0) + 1), e));"
    , "  }"
    , "}"
    , ""
    , "defun Rt.repGo(s : val, i : val) -> val {"
    , "  if (mkbool(payload(i, 0) <= 0)) {"
    , "    return mknil;"
    , "  } else {"
    , "    return call Rt.appendL(call Rt.bytesOf(s, mknum(0)), call Rt.repGo(s, mknum(payload(i, 0) - 1)));"
    , "  }"
    , "}"
    , ""
    , "defun Rt.bytesBuild(s : val, i : val, acc : val) -> val {"
    , "  if (mkbool(payload(i, 0) <= 0)) {"
    , "    return acc;"
    , "  } else {"
    , "    return call Rt.bytesBuild(s, mknum(payload(i, 0) - 1), call Rt.cons(mknum(strbyte(s, payload(i, 0) - 1)), acc));"
    , "  }"
    , "}"
    , ""
    , "defun Rt.symLess(a : val, bb : val, i : val) -> val {"
    , "  val ca = mknum(strbyte(a, payload(i, 0)));"
    , "  val cb = mknum(strbyte(bb, payload(i, 0)));"
    , "  if (mkbool(payload(ca, 0) == 0)) {"
    , "    return mkbool(payload(cb, 0) != 0);"
    , "  } else {"
    , "    if (mkbool(payload(cb, 0) == 0)) {"
    , "      return mkbool(0);"
    , "    } else {"
    , "      if (mkbool(payload(ca, 0) < payload(cb, 0))) {"
    , "        return mkbool(1);"
    , "      } else {"
    , "        if (mkbool(payload(ca, 0) > payload(cb, 0))) {"
    , "          return mkbool(0);"
    , "        } else {"
    , "          return call Rt.symLess(a, bb, mknum(payload(i, 0) + 1));"
    , "        }"
    , "      }"
    , "    }"
    , "  }"
    , "}"
    , ""
    , "defun Rt.read-file-as-string(path : val) -> val {"
    , "  word lenW = payload32(path, 1);"
    , "  word bufW = allocraw(lenW + 1);"
    , "  val bufN = mknum(bufW);"
    , "  call Rt.cStrFill(bufN, path, mknum(0));"
    , "  word fdW = rawcall openat(-100, bufW, 0, 0);"
    , "  if (mkbool(fdW < 0)) {"
    , "    val msg = \"runtime: cannot open file for read-file-as-string\\n\";"
    , "    word w12 = rawcall write(2, payload(msg, 0), payload32(msg, 1));"
    , "    return \"\";"
    , "  } else {"
    , "    word blkW = rawcall malloc(72);"
    , "    if (mkbool(blkW == 0)) {"
    , "      word h = rawcall rt_halt();"
    , "      return mknil;"
    , "    } else {"
    , "      return mknum(0);"
    , "    }"
    , "    val blkN = mknum(blkW);"
    , "    word tmpW = rawcall malloc(65536);"
    , "    if (mkbool(tmpW == 0)) {"
    , "      word f15 = rawcall free(blkW);"
    , "      word h = rawcall rt_halt();"
    , "      return mknil;"
    , "    } else {"
    , "      return mknum(0);"
    , "    }"
    , "    wstore(blkW, 0, fdW);"
    , "    wstore(blkW, 1, tmpW);"
    , "    wstore(blkW, 2, 0);"
    , "    wstore(blkW, 3, 0);"
    , "    wstore(blkW, 4, 0);"
    , "    call Rt.readFileGo(blkN);"
    , "    word len22 = wload(blkW, 3);"
    , "    word accW = wload(blkW, 2);"
    , "    word dstW = allocraw(len22 + 1);"
    , "    wstore(blkW, 6, accW);"
    , "    wstore(blkW, 7, dstW);"
    , "    wstore(blkW, 8, len22);"
    , "    call Rt.memGo(mknum(blkW + 48), mknum(0));"
    , "    bytestore(dstW, len22, 0);"
    , "    word f30 = rawcall free(accW);"
    , "    word f31 = rawcall free(tmpW);"
    , "    word f32 = rawcall free(blkW);"
    , "    word f33 = rawcall close(fdW);"
    , "    return mkstr(dstW, len22);"
    , "  }"
    , "}"
-- ====================== T24 (handoff-osier-tier2-t24) — the LAST THREE WALL-CLASS HOLDOUTS ======================
--
-- Rt.readFileGo / Rt.epCmd / Rt.childCd — the three keys whose If-bound-in-a-
-- LET-VALUE bodies the grammar could not spell until T23 landed the BLOCK-
-- BRANCH if EXPRESSION (`val x = if (c) { .. } else { .. };`, EIfBlock,
-- lowering through the term-if's own machinery).  The T23 acceptance rows
-- (TestMain's growB and dirN#2 canon-equal rows) are the templates; each body
-- below is a 1:1 tree transcription of its deleted RtPrims builder and the
-- corpus hash is the judge.
--
-- SHAPE NOTES (load-bearing — the choice of spelling IS the tree):
--   * a wall If whose VALUE the continuation reads (growB, ago, rgo, dirN#2)
--     spells as the EIfBlock bind — `Let { x = If { .. } }`, the DSL shape;
--   * a chain-tail If whose BOTH arms return (epCmd's acnt/rcnt bounds, the
--     subState dispatch) spells as the TERM if — a both-diverging TERM-if
--     lowers to a BARE If (the DSL's value-position shape); the STATEMENT-if
--     would DEAD-BIND it (an extra Let) — the wrong tree;
--   * a one-sided diverging if mid-block else-nests (the continuation is the
--     false path) — the read-error/EOF/OOM-stop/argv-empty tails;
--   * the dead-value halt/freeArgv Ifs are the T15 both-diverge statement-if
--     (`word h = rawcall rt_halt();` then / `return mknum(0);` else; a bare
--     call branch value is `return call Rt.f(..);` — TRet of the call, NO
--     Let, the dead binder takes the If — the T16 epFreeCmd rule);
--   * tagCountState was written OUT at the subState binder (the T16 epUnwrap
--     precedent): the same tree was already corpus-green as epCount's T9b ?:
--     join (the `val stV = ..` line in epCount above) and is copied verbatim
--     with vv -> subv;
--   * runOff's cbuf literal offsets are frozen as literals — re-derived from
--     HEAD's runLits (fold from 104: "echo" 104, "/" 139, "\n" 173, "cd: "
--     240, "pwd: cannot get cwd\n" 245; cbuf size 336) and MATCHED to T17's
--     numbers and to the already-migrated surface sites (childBuiltin's
--     cbufW + 104..125 literals, echoGo/childBuiltin's cbufW + 173,
--     exec-plan's malloc(336)).
--
-- Recursion MEASURED per defun: readFileGo SELF-TAIL recur (the DSL body's
-- one `App { GRef own-key }`); epCmd and childCd have NO self-call.
--
-- -- Rt.readFileGo blkN: Zig's `while (true)` read loop, one self-tail
-- -- in-frame loop over the 72-byte C block (blkN boxes the block pointer:
-- -- word 0 = fd, 1 = tmp, 2 = acc, 3 = len, 4 = cap; 6/7/8 the memGo dst
-- -- block).  growB is the T23 acceptance row's spelling, verbatim.
    , ""
    , "defun Rt.readFileGo(blkN : val) -> val {"
    , "  word fdW = wload(payload(blkN, 0), 0);"
    , "  word tmpW = wload(payload(blkN, 0), 1);"
    , "  val nV = call Rt.readFull(mknum(fdW), mknum(tmpW), mknum(65536));"
    , "  if (mkbool(payload(nV, 0) < 0)) {"
    , "    return mknil;"
    , "  }"
    , "  if (mkbool(payload(nV, 0) == 0)) {"
    , "    return mknil;"
    , "  }"
    , "  word lenW = wload(payload(blkN, 0), 3);"
    , "  word capW = wload(payload(blkN, 0), 4);"
    , "  word neededW = lenW + payload(nV, 0);"
    , "  val growB = if (mkbool(neededW > capW)) {"
    , "    word newcapW = neededW + (capW * 2 - neededW) * (capW * 2 > neededW);"
    , "    word mW = rawcall malloc(newcapW);"
    , "    if (mkbool(mW == 0)) { return mknum(1); }"
    , "    word oldW = wload(payload(blkN, 0), 2);"
    , "    wstore(payload(blkN, 0), 6, oldW);"
    , "    wstore(payload(blkN, 0), 7, mW);"
    , "    wstore(payload(blkN, 0), 8, lenW);"
    , "    call Rt.memGo(mknum(payload(blkN, 0) + 48), mknum(0));"
    , "    rawcall free(oldW);"
    , "    wstore(payload(blkN, 0), 2, mW);"
    , "    wstore(payload(blkN, 0), 4, newcapW);"
    , "    return mknum(0);"
    , "  } else {"
    , "    return mknum(0);"
    , "  };"
    , "  if (mkbool(payload(growB, 0) == 1)) {"
    , "    return mknil;"
    , "  }"
    , "  word accW = wload(payload(blkN, 0), 2);"
    , "  wstore(payload(blkN, 0), 6, tmpW);"
    , "  wstore(payload(blkN, 0), 7, accW + lenW);"
    , "  wstore(payload(blkN, 0), 8, payload(nV, 0));"
    , "  call Rt.memGo(mknum(payload(blkN, 0) + 48), mknum(0));"
    , "  wstore(payload(blkN, 0), 3, neededW);"
    , "  recur(blkN);"
    , "}"
    , ""
    , -- -- Rt.epCmd e stN cAddrN — decodeCmd: [Argv Redirs Sub], len 3.  The
      -- -- ago/rgo wall Ifs spell as EIfBlock binds (their values the
      -- -- continuation reads); the bounds/subState Ifs are TERM-ifs (both arms
      -- -- return -> the BARE If); the halt/freeArgv dead-value Ifs are the T15
      -- -- both-diverge spelling (freeArgv's call as `return call ..`, T16's
      -- -- epFreeCmd rule); tagCountState is written out at subState (epCount's
      -- -- ?: join, copied).  RtLayout offsets as literals: cmd argv0/argc1/
      -- -- redirs2/nredirs3/sub4, prog chains 1, redir 6 words.  UNWIND (the
      -- -- Elm helper) is written out at each of its FIVE sites, STDINGUARD at
      -- -- both of its sites — the surface has no intra-defun abstraction.
      "defun Rt.epCmd(e : val, stN : val, cAddrN : val) -> val {"
    , "  wstore(payload(stN, 0), 2, 8);"
    , "  val cnt = call Rt.epCount(e, stN, mknum(0));"
    , "  word cbufW = wload(payload(stN, 0), 0);"
    , "  if (mkbool(payload(cnt, 0) != 3)) { return mknum(-1); }"
    , "  val argvv = call Rt.epElem(e, mknum(0), mknum(0));"
    , "  val redirsv = call Rt.epElem(e, mknum(0), mknum(1));"
    , "  val subv = call Rt.epElem(e, mknum(0), mknum(2));"
    , "  wstore(payload(cAddrN, 0), 0, 0);"
    , "  wstore(payload(cAddrN, 0), 1, 0);"
    , "  wstore(payload(cAddrN, 0), 2, 0);"
    , "  wstore(payload(cAddrN, 0), 3, 0);"
    , "  wstore(payload(cAddrN, 0), 4, 0);"
    , "  wstore(payload(stN, 0), 2, 256);"
    , "  val acnt = call Rt.epCount(argvv, stN, mknum(0));"
    , "  if (mkbool(payload(acnt, 0) < 0) || mkbool(payload(acnt, 0) > 256)) { return mknum(-1); }"
    , "  val ago = if (mkbool(payload(acnt, 0) == 0)) {"
    , "    return mknum(0);"
    , "  } else {"
    , "    word argvW = rawcall malloc(payload(acnt, 0) * 8 + 8);"
    , "    if (mkbool(argvW == 0)) {"
    , "      word h = rawcall rt_halt();"
    , "      return mknil;"
    , "    } else {"
    , "      return mknum(0);"
    , "    }"
    , "    wstore(payload(cAddrN, 0), 0, argvW);"
    , "    val agoGo = call Rt.epArgvGo(argvv, stN, cAddrN);"
    , "    if (mkbool(payload(agoGo, 0) < 0)) {"
    , "      wstore(payload(cAddrN, 0), 0, 0);"
    , "      return mknum(-1);"
    , "    }"
    , "    wstore(argvW, payload(acnt, 0), 0);"
    , "    return mknum(0);"
    , "  };"
    , "  if (mkbool(payload(ago, 0) < 0)) { return mknum(-1); }"
    , "  wstore(payload(stN, 0), 2, 64);"
    , "  val rcnt = call Rt.epCount(redirsv, stN, mknum(0));"
    , "  if (mkbool(payload(rcnt, 0) < 0) || mkbool(payload(rcnt, 0) > 64)) {"
    , "    if (mkbool(wload(payload(cAddrN, 0), 0) != 0)) {"
    , "      return call Rt.epFreeArgv(mknum(wload(payload(cAddrN, 0), 0)), mknum(0), mknum(wload(payload(cAddrN, 0), 1)));"
    , "    } else {"
    , "      return mknil;"
    , "    }"
    , "    wstore(payload(cAddrN, 0), 0, 0);"
    , "    return mknum(-1);"
    , "  } else {"
    , "    val rgo = if (mkbool(payload(rcnt, 0) == 0)) {"
    , "      return mknum(0);"
    , "    } else {"
    , "      word redirsW = rawcall malloc(payload(rcnt, 0) * 48);"
    , "      if (mkbool(redirsW == 0)) {"
    , "        word h = rawcall rt_halt();"
    , "        return mknil;"
    , "      } else {"
    , "        return mknum(0);"
    , "      }"
    , "      wstore(payload(cAddrN, 0), 2, redirsW);"
    , "      val rgoGo = call Rt.epRedirsGo(redirsv, stN, cAddrN);"
    , "      if (mkbool(payload(rgoGo, 0) < 0)) {"
    , "        wstore(payload(cAddrN, 0), 2, 0);"
    , "        if (mkbool(wload(payload(cAddrN, 0), 0) != 0)) {"
    , "          return call Rt.epFreeArgv(mknum(wload(payload(cAddrN, 0), 0)), mknum(0), mknum(wload(payload(cAddrN, 0), 1)));"
    , "        } else {"
    , "          return mknil;"
    , "        }"
    , "        wstore(payload(cAddrN, 0), 0, 0);"
    , "        return mknum(-1);"
    , "      }"
    , "      return mknum(0);"
    , "    };"
    , "    if (mkbool(payload(rgo, 0) < 0)) { return mknum(-1); }"
    , "    val subState = mkbool(tagis(subv, 4) == 0) ? mknum(2) : (mkbool(tagis(vecload(payload(subv, 0), 0), 2) == 0) ? mknum(2) : (call Rt.epSymIs(vecload(payload(subv, 0), 0), mknum(cbufW), mknum(0)) ? (mkbool(tagis(vecload(payload(subv, 0), 1), 5) != 0) ? mknum(0) : (mkbool(tagis(vecload(payload(subv, 0), 1), 4) != 0) ? mknum(1) : mknum(2))) : mknum(2)));"
    , "    if (mkbool(payload(subState, 0) == 2)) {"
    , "      if (mkbool(wload(payload(cAddrN, 0), 4) != 0)) {"
    , "        return call Rt.epFreeChains(mknum(wload(payload(cAddrN, 0), 4)), mknum(wload(wload(payload(cAddrN, 0), 4), 1)), mknum(0));"
    , "      } else {"
    , "        return mknil;"
    , "      }"
    , "      if (mkbool(wload(payload(cAddrN, 0), 2) != 0)) {"
    , "        return call Rt.epFreeRedirs(mknum(wload(payload(cAddrN, 0), 2)), mknum(0), mknum(wload(payload(cAddrN, 0), 3)));"
    , "      } else {"
    , "        return mknil;"
    , "      }"
    , "      wstore(payload(cAddrN, 0), 2, 0);"
    , "      if (mkbool(wload(payload(cAddrN, 0), 0) != 0)) {"
    , "        return call Rt.epFreeArgv(mknum(wload(payload(cAddrN, 0), 0)), mknum(0), mknum(wload(payload(cAddrN, 0), 1)));"
    , "      } else {"
    , "        return mknil;"
    , "      }"
    , "      wstore(payload(cAddrN, 0), 0, 0);"
    , "      return mknum(-1);"
    , "    }"
    , "    if (mkbool(payload(subState, 0) == 0)) {"
    , "      if (mkbool(wload(payload(cAddrN, 0), 0) == 0)) {"
    , "        if (mkbool(wload(payload(cAddrN, 0), 4) != 0)) {"
    , "          return call Rt.epFreeChains(mknum(wload(payload(cAddrN, 0), 4)), mknum(wload(wload(payload(cAddrN, 0), 4), 1)), mknum(0));"
    , "        } else {"
    , "          return mknil;"
    , "        }"
    , "        if (mkbool(wload(payload(cAddrN, 0), 2) != 0)) {"
    , "          return call Rt.epFreeRedirs(mknum(wload(payload(cAddrN, 0), 2)), mknum(0), mknum(wload(payload(cAddrN, 0), 3)));"
    , "        } else {"
    , "          return mknil;"
    , "        }"
    , "        wstore(payload(cAddrN, 0), 2, 0);"
    , "        if (mkbool(wload(payload(cAddrN, 0), 0) != 0)) {"
    , "          return call Rt.epFreeArgv(mknum(wload(payload(cAddrN, 0), 0)), mknum(0), mknum(wload(payload(cAddrN, 0), 1)));"
    , "        } else {"
    , "          return mknil;"
    , "        }"
    , "        wstore(payload(cAddrN, 0), 0, 0);"
    , "        return mknum(-1);"
    , "      }"
    , "      val nstdin = call Rt.epCountStdin(mknum(wload(payload(cAddrN, 0), 2)), mknum(wload(payload(cAddrN, 0), 3)), mknum(0));"
    , "      if (mkbool(payload(nstdin, 0) > 1)) {"
    , "        if (mkbool(wload(payload(cAddrN, 0), 4) != 0)) {"
    , "          return call Rt.epFreeChains(mknum(wload(payload(cAddrN, 0), 4)), mknum(wload(wload(payload(cAddrN, 0), 4), 1)), mknum(0));"
    , "        } else {"
    , "          return mknil;"
    , "        }"
    , "        if (mkbool(wload(payload(cAddrN, 0), 2) != 0)) {"
    , "          return call Rt.epFreeRedirs(mknum(wload(payload(cAddrN, 0), 2)), mknum(0), mknum(wload(payload(cAddrN, 0), 3)));"
    , "        } else {"
    , "          return mknil;"
    , "        }"
    , "        wstore(payload(cAddrN, 0), 2, 0);"
    , "        if (mkbool(wload(payload(cAddrN, 0), 0) != 0)) {"
    , "          return call Rt.epFreeArgv(mknum(wload(payload(cAddrN, 0), 0)), mknum(0), mknum(wload(payload(cAddrN, 0), 1)));"
    , "        } else {"
    , "          return mknil;"
    , "        }"
    , "        wstore(payload(cAddrN, 0), 0, 0);"
    , "        return mknum(-1);"
    , "      }"
    , "      return mknum(0);"
    , "    } else {"
    , "      if (mkbool(wload(payload(cAddrN, 0), 0) != 0)) {"
    , "        if (mkbool(wload(payload(cAddrN, 0), 4) != 0)) {"
    , "          return call Rt.epFreeChains(mknum(wload(payload(cAddrN, 0), 4)), mknum(wload(wload(payload(cAddrN, 0), 4), 1)), mknum(0));"
    , "        } else {"
    , "          return mknil;"
    , "        }"
    , "        if (mkbool(wload(payload(cAddrN, 0), 2) != 0)) {"
    , "          return call Rt.epFreeRedirs(mknum(wload(payload(cAddrN, 0), 2)), mknum(0), mknum(wload(payload(cAddrN, 0), 3)));"
    , "        } else {"
    , "          return mknil;"
    , "        }"
    , "        wstore(payload(cAddrN, 0), 2, 0);"
    , "        if (mkbool(wload(payload(cAddrN, 0), 0) != 0)) {"
    , "          return call Rt.epFreeArgv(mknum(wload(payload(cAddrN, 0), 0)), mknum(0), mknum(wload(payload(cAddrN, 0), 1)));"
    , "        } else {"
    , "          return mknil;"
    , "        }"
    , "        wstore(payload(cAddrN, 0), 0, 0);"
    , "        return mknum(-1);"
    , "      }"
    , "      word depthW = wload(payload(stN, 0), 1);"
    , "      if (mkbool(depthW >= 32)) {"
    , "        if (mkbool(wload(payload(cAddrN, 0), 4) != 0)) {"
    , "          return call Rt.epFreeChains(mknum(wload(payload(cAddrN, 0), 4)), mknum(wload(wload(payload(cAddrN, 0), 4), 1)), mknum(0));"
    , "        } else {"
    , "          return mknil;"
    , "        }"
    , "        if (mkbool(wload(payload(cAddrN, 0), 2) != 0)) {"
    , "          return call Rt.epFreeRedirs(mknum(wload(payload(cAddrN, 0), 2)), mknum(0), mknum(wload(payload(cAddrN, 0), 3)));"
    , "        } else {"
    , "          return mknil;"
    , "        }"
    , "        wstore(payload(cAddrN, 0), 2, 0);"
    , "        if (mkbool(wload(payload(cAddrN, 0), 0) != 0)) {"
    , "          return call Rt.epFreeArgv(mknum(wload(payload(cAddrN, 0), 0)), mknum(0), mknum(wload(payload(cAddrN, 0), 1)));"
    , "        } else {"
    , "          return mknil;"
    , "        }"
    , "        wstore(payload(cAddrN, 0), 0, 0);"
    , "        return mknum(-1);"
    , "      }"
    , "      wstore(payload(stN, 0), 1, depthW + 1);"
    , "      val subN = call Rt.epProg(subv, stN);"
    , "      wstore(payload(stN, 0), 1, depthW);"
    , "      if (mkbool(payload(subN, 0) < 0)) {"
    , "        if (mkbool(wload(payload(cAddrN, 0), 4) != 0)) {"
    , "          return call Rt.epFreeChains(mknum(wload(payload(cAddrN, 0), 4)), mknum(wload(wload(payload(cAddrN, 0), 4), 1)), mknum(0));"
    , "        } else {"
    , "          return mknil;"
    , "        }"
    , "        if (mkbool(wload(payload(cAddrN, 0), 2) != 0)) {"
    , "          return call Rt.epFreeRedirs(mknum(wload(payload(cAddrN, 0), 2)), mknum(0), mknum(wload(payload(cAddrN, 0), 3)));"
    , "        } else {"
    , "          return mknil;"
    , "        }"
    , "        wstore(payload(cAddrN, 0), 2, 0);"
    , "        if (mkbool(wload(payload(cAddrN, 0), 0) != 0)) {"
    , "          return call Rt.epFreeArgv(mknum(wload(payload(cAddrN, 0), 0)), mknum(0), mknum(wload(payload(cAddrN, 0), 1)));"
    , "        } else {"
    , "          return mknil;"
    , "        }"
    , "        wstore(payload(cAddrN, 0), 0, 0);"
    , "        return mknum(-1);"
    , "      }"
    , "      wstore(payload(cAddrN, 0), 4, payload(subN, 0));"
    , "      val nstdin = call Rt.epCountStdin(mknum(wload(payload(cAddrN, 0), 2)), mknum(wload(payload(cAddrN, 0), 3)), mknum(0));"
    , "      if (mkbool(payload(nstdin, 0) > 1)) {"
    , "        if (mkbool(wload(payload(cAddrN, 0), 4) != 0)) {"
    , "          return call Rt.epFreeChains(mknum(wload(payload(cAddrN, 0), 4)), mknum(wload(wload(payload(cAddrN, 0), 4), 1)), mknum(0));"
    , "        } else {"
    , "          return mknil;"
    , "        }"
    , "        if (mkbool(wload(payload(cAddrN, 0), 2) != 0)) {"
    , "          return call Rt.epFreeRedirs(mknum(wload(payload(cAddrN, 0), 2)), mknum(0), mknum(wload(payload(cAddrN, 0), 3)));"
    , "        } else {"
    , "          return mknil;"
    , "        }"
    , "        wstore(payload(cAddrN, 0), 2, 0);"
    , "        if (mkbool(wload(payload(cAddrN, 0), 0) != 0)) {"
    , "          return call Rt.epFreeArgv(mknum(wload(payload(cAddrN, 0), 0)), mknum(0), mknum(wload(payload(cAddrN, 0), 1)));"
    , "        } else {"
    , "          return mknil;"
    , "        }"
    , "        wstore(payload(cAddrN, 0), 0, 0);"
    , "        return mknum(-1);"
    , "      }"
    , "      return mknum(0);"
    , "    }"
    , "  }"
    , "}"
    , ""
    , -- -- Rt.childCd argvN argcN stN — the cd builtin arm (Zig's two-pass dir
      -- -- resolution: argv[1] or HOME, then the cbuf "/" literal, PATH_MAX
      -- -- guard, chdir).  dirN#2 is the T23 acceptance row's spelling verbatim
      -- -- (shadowed rebinding reads the previous binder in its own
      -- -- initializer; the one-sided diverging if inside the branch
      -- -- else-nests); dirN#1/#3 are pure-expression branches -> the T9b ?:
      -- -- join; the frozen cbuf offsets are 139 ("/"), 240 ("cd: "), 173
      -- -- ("\n").
      "defun Rt.childCd(argvN : val, argcN : val, stN : val) -> val {"
    , "  word cbufW = wload(payload(stN, 0), 0);"
    , "  val dirN = mkbool(payload(argcN, 0) > 1) ? mknum(wload(payload(argvN, 0), 1)) : mknum(0);"
    , "  val dirN = if (mkbool(payload(dirN, 0) == 0)) {"
    , "    return call Rt.envHome(stN);"
    , "  } else {"
    , "    val ln = call Rt.cStrLenGo(dirN, mknum(0));"
    , "    if (mkbool(payload(ln, 0) == 0)) { return call Rt.envHome(stN); }"
    , "    return dirN;"
    , "  };"
    , "  val dirN = mkbool(payload(dirN, 0) == 0) ? mknum(cbufW + 139) : dirN;"
    , "  val ln = call Rt.cStrLenGo(dirN, mknum(0));"
    , "  if (mkbool(payload(ln, 0) >= 4096)) {"
    , "    return mknum(1);"
    , "  }"
    , "  word bufW = rawcall malloc(4096);"
    , "  if (mkbool(bufW == 0)) {"
    , "    word h = rawcall rt_halt();"
    , "    return mknil;"
    , "  } else {"
    , "    return mknum(0);"
    , "  }"
    , "  call Rt.cStrCopyGo(dirN, mknum(bufW), mknum(0));"
    , "  word rc = rawcall chdir(bufW);"
    , "  rawcall free(bufW);"
    , "  if (mkbool(rc == 0)) {"
    , "    return mknum(0);"
    , "  }"
    , "  call Rt.wStr(mknum(2), mknum(cbufW + 240));"
    , "  call Rt.wStr(mknum(2), dirN);"
    , "  call Rt.wRaw(mknum(2), mknum(cbufW + 173), mknum(1));"
    , "  return mknum(1);"
    , "}"
    , -- ====================== stage 6 U2 — the raw-word-ABI die/halt family ======================
      -- Rt.die / Rt.halt are rawAbi defuns (Mid.Rt.rawAbi): WORD params, WORD
      -- result, frame-free.  Both write a static message to stderr (`rawstr` —
      -- a content-keyed NUL-terminated data def, NO allocation, so a die path
      -- cannot recurse into the collector it is reporting on) then exit(1).
      -- Byte-parity with rt.zig's dieLoud: werr(msg); werr("\n"); exit(1).
      -- These are T25-APPENDED keys (no DSL position): the splice appends them
      -- after the prim half, ordered by key (Rt.die before Rt.halt).
      "defun Rt.die(msg : word) -> word {"
    , "  val len = call Rt.cStrLenGo(mknum(msg), mknum(0));"
    , "  rawcall write(2, msg, payload(len, 0));"
    , "  rawcall write(2, rawstr(\"\\n\"), 1);"
    , "  rawcall exit(1);"
    , "  return 0;"
    , "}"
    , "defun Rt.halt() -> word {"
      -- The DOUBLED prefix is deliberate, not a typo: the Zig seat this
      -- defun replaces (tools/qbe/rt.zig rt_halt) called dieLoud(msg) with a
      -- msg that ALREADY carried "qbe-rt: ", so the frozen default-route
      -- bytes (tests/elm-fixtures/expected/execmal.txt) are
      -- "qbe-rt: qbe-rt: halt (...)\n".  U2's hatch contract requires the
      -- MIDDRIVER arm to match the default route byte for byte, so the
      -- cosmetic Zig bug is reproduced VERBATIM here; it is not fixed on
      -- either side at U2 (fixing it moves the golden).
    , "  word m = rawstr(\"qbe-rt: qbe-rt: halt (a Mid prim reached its halt arm)\");"
    , "  val len = call Rt.cStrLenGo(mknum(m), mknum(0));"
    , "  rawcall write(2, m, payload(len, 0));"
    , "  rawcall write(2, rawstr(\"\\n\"), 1);"
    , "  rawcall exit(1);"
    , "  return 0;"
    , "}"
    , -- ====================== stage 6 A3b — the meta walk (Rt.cStrEq + Rt.cStrEqGo + Rt.metaGo) ======================
      -- Rt.cStrEq(a,b) — a DYNAMIC cStr-vs-cStr byte compare, WORD in / WORD
      -- out (a rawAbi defun, Mid.Rt.rawAbi — the meta walk compares two raw
      -- pointers, so a word ABI keeps the call site unboxed).  The byte walk
      -- is delegated to Rt.cStrEqGo, a val-ABI helper: rawAbi defuns CANNOT
      -- self-tail (lowerTailWord rejects a tail App/If, the A3a D-A wall), and
      -- the lean ABI bounds val defuns to maxDirectArity=3 params (Lower.elm
      -- :1140) — so the loop lives in a 3-ary val defun that `recur`s.
      --
      -- DEVIATION from the plan's "lengths via cStrLenGo + word-chunk loop":
      -- that sketch needs a 5-ary accumulator helper, which the 3-param lean
      -- ABI cannot spell, and a naive word-chunk compare reads past the NUL
      -- terminator and FALSE-NEGATIVES on equal strings with differing
      -- trailing bytes.  The NUL-terminated byte compare (the EXACT
      -- Rt.cStrEqLit shape above) is correct for the empty string (both NUL
      -- at once) and unequal lengths (one hits NUL first) with no length
      -- pass — byte-parity-identical on the found/not-found result.
      "defun Rt.cStrEq(a : word, b : word) -> word {"
    , "  val eq = call Rt.cStrEqGo(mknum(a), mknum(b), mknum(0));"
    , "  return payload(eq, 0);"
    , "}"
    , ""
    , -- Rt.cStrEqGo — the NUL-terminated byte walk (Rt.cStrEqLit's shape, two
      -- dynamic pointers).  Self-tail (recur): frame-free, non-allocating, so
      -- no safepoint can move a/b.
      "defun Rt.cStrEqGo(a : val, b : val, i : val) -> val {"
    , "  word xa = byteload(payload(a, 0), payload(i, 0));"
    , "  word xb = byteload(payload(b, 0), payload(i, 0));"
    , "  if (mkbool(xb == 0)) {"
    , "    return mkbool(xa == 0);"
    , "  }"
    , "  if (mkbool(xa == xb)) {"
    , "    recur(a, b, mknum(payload(i, 0) + 1));"
    , "  }"
    , "  return false;"
    , "}"
    , ""
    , -- Rt.metaGo — walk the 24-byte qbe_meta rows (name@0, code@8, arity@16,
      -- 4 B pad — Mid.Qbe.Lower.metaTable).  The 5-word C-block carries the
      -- FIXED state ([0]=base, [1]=entry, [2]=n, [3]=code, [4]=arity — the
      -- Rt.memGo block idiom, which is how 3+ words of loop state fit the
      -- 3-param lean ABI); `i` is the index param.  Each row's name is
      -- compared against the entry via Rt.cStrEq; a match wstores the row's
      -- code pointer and arity into blk[3]/blk[4] (A4a's entry dispatch reads
      -- them) and returns mkbool(1) (early return — the found flag needs no
      -- accumulator, and the notmeta bytes depend only on found/not-found, so
      -- the early exit is byte-parity-invisible).  Exhaustion returns
      -- mkbool(0).  Self-tail (recur); frame-free, non-allocating.
      "defun Rt.metaGo(blk : val, i : val) -> val {"
    , "  word nW = wload(payload(blk, 0), 2);"
    , "  if (mkbool(payload(i, 0) >= nW)) {"
    , "    return mkbool(0);"
    , "  }"
    , "  word baseW = wload(payload(blk, 0), 0);"
    , "  word entryW = wload(payload(blk, 0), 1);"
    , "  word row = baseW + (payload(i, 0) * 24);"
    , "  word nameW = wload(row, 0);"
    , "  word eq = call Rt.cStrEq(nameW, entryW);"
    , "  if (mkbool(eq != 0)) {"
    , "    wstore(payload(blk, 0), 3, wload(row, 1));"
    , "    wstore(payload(blk, 0), 4, wload(row, 2));"
    , "    return mkbool(1);"
    , "  }"
    , "  recur(blk, mknum(payload(i, 0) + 1));"
    , "}"
    , ""
    , -- ====================== stage 6 A4a — the entry-arg parse loop ======================
      -- Rt.parseArgsGo — the arg loop (the D-A wall: a rawAbi defun cannot
      -- carry a tail If, so the loop lives in a frame-free val defun that
      -- `recur`s, the Rt.metaGo shape).  blk is a 3-word C-block
      -- ([0]=buf, [1]=argv, [2]=entry_nargs — entry_nargs is 0 in argv
      -- mode, so the loop is a no-op there); j is the index.  Each
      -- iteration: argPtr = buf + 40*j (the [max_arity]Value slot), argStr
      -- = wload(argv, 2+j), then rawcall rt_parse_arg(argPtr, argStr) —
      -- the A2 seat stores the Zig-heap Value at argPtr and returns 0, or
      -- writes the SAME stderr line and returns 2 (propagated as mknum(2),
      -- so Rt.main owns the exit).  Self-tail (recur); frame-free.
      --
      -- CROSS-HEAP NOTE (R10): rt_parse_arg allocates a ZIG-heap Value
      -- (valNumber/valFloat) into the malloc'd buf, which is NOT rooted
      -- DURING this loop — exactly rt.zig main's argv_buf (rooted only
      -- after the loop, by rt_root_push_value_array).  Sound by the SAME
      -- small-n argument as the shipped default: at most max_arity=16
      -- small nursery allocations, so no scavenge fires before the root
      -- push; the helper itself holds no Values across the seat call.
      "defun Rt.parseArgsGo(blk : val, j : val) -> val {"
    , "  word nargsW = wload(payload(blk, 0), 2);"
    , "  if (mkbool(payload(j, 0) >= nargsW)) {"
    , "    return mknum(0);"
    , "  }"
    , "  word bufW = wload(payload(blk, 0), 0);"
    , "  word argvW = wload(payload(blk, 0), 1);"
    , "  word argPtr = bufW + (payload(j, 0) * 40);"
    , "  word argStr = wload(argvW, 2 + payload(j, 0));"
    , "  word rc = rawcall rt_parse_arg(argPtr, argStr);"
    , "  if (mkbool(rc != 0)) {"
    , "    return mknum(2);"
    , "  }"
    , "  recur(blk, mknum(payload(j, 0) + 1));"
    , "}"
    , ""
    , -- ====================== stage 6 A3a — the driver entry Rt.main (first slice) ======================
      -- Rt.main is a rawAbi defun (Mid.Rt.rawAbi): WORD params (argc, argv),
      -- WORD result (the exit code crt0 reads back), exported as `main`
      -- (Lower's export-name override, stage 6 A1).  This slice lands the
      -- usage error, the too-many-args error and the rlimit net — byte-parity
      -- with tools/qbe/rt.zig's main (rt.zig:1745-1756 + 1762-1782).  A3b
      -- continues after the marker with rt_boot + the meta walk.
      --
      -- TWO SHAPE DEVIATIONS, each measured on the lowerer and stated:
      -- (D-A) the conditionals are EIfBlock EXPRESSIONS (`word x = if (c) {..}
      -- else {..};`, branches `return 0;` — the WORD this -> word defun's J6
      -- pins every return to), NOT mid-block `if` STATEMENTS: `lowerTailWord`
      -- (Lower.elm:1467) lowers a rawAbi tail through the raw-word path and
      -- REJECTS a tail `If`, and a statement-`if` else-nests its continuation
      -- so the `If` lands in the TAIL — the one place rawAbi cannot lower it.
      -- An EIfBlock lands its `If` in a BINDER value position (lowered via
      -- lowerVal/lowerIf, the growB shape at RtSource:4170), never the tail.
      -- (D-B) the rlimit buffer is `rawcall malloc(16)`, NOT `allocraw(16)`:
      -- `allocraw` lowers to rt_raw_alloc -> g.allocRaw (the Zig Gc), which is
      -- only valid AFTER rt_boot has run Gc.init — and rt.zig's rlimit net
      -- runs BEFORE boot, over a stack-local rlim struct (rt.zig:1749-1751).
      -- The Mid surface has no stack local, so a libc malloc'd 16-byte block
      -- (cur@0, max@8 — rlim_t is u64 on x86_64) is the faithful no-collector
      -- translation, sound before boot.  The re-plan's "allocRaw(16)" was a
      -- projection; this is the correction.
      --
      -- Byte-parity facts (frozen goldens, tools/qbe/golden/err-usage.txt and
      -- err-toomany.txt): BOTH errors are a SINGLE write of the whole message
      -- (rt.zig's werr does write(2, msg.ptr, msg.len) — the trailing "\n" is
      -- part of the literal, NOT a second write), then exit(2).  The usage
      -- path must NOT boot a collector (byte-parity with the pre-A2 driver);
      -- neither error path does — both exit before the A3b boot marker.
      "defun Rt.main(argc : word, argv : word) -> word {"
    , "  word usage = rawstr(\"usage: <prog> <entry-name> [int|float-arg ...]\\n\");"
    , "  word toomany = rawstr(\"qbe-rt: >16 entry args not supported\\n\");"
    , "  word u = if (mkbool(argc < 2)) {"
    , "    val len = call Rt.cStrLenGo(mknum(usage), mknum(0));"
    , "    rawcall write(2, usage, payload(len, 0));"
    , "    rawcall exit(2);"
    , "    return 0;"
    , "  } else {"
    , "    return 0;"
    , "  };"
    , "  word nargs = argc - 2;"
    , "  word argvMode = rawcall getenv(rawstr(\"AOTRUN_ARGV\"));"
    , "  word t = if (mkbool(argvMode == 0) && mkbool(nargs > 16)) {"
    , "    val len2 = call Rt.cStrLenGo(mknum(toomany), mknum(0));"
    , "    rawcall write(2, toomany, payload(len2, 0));"
    , "    rawcall exit(2);"
    , "    return 0;"
    , "  } else {"
    , "    return 0;"
    , "  };"
    , -- the rlimit net (rt.zig:1745-1756, verbatim shape): raise RLIMIT_STACK
      -- soft limit to 64 MiB unless QBE_NO_RLIMIT is set; best-effort — every
      -- failure arm is silently swallowed, matching Zig's `else |_| {}`.
      "  word lim = rawcall malloc(16);"
    , "  word qnl = rawcall getenv(rawstr(\"QBE_NO_RLIMIT\"));"
    , "  word rl = if (mkbool(qnl == 0)) {"
    , "    word rc = rawcall getrlimit(3, lim);"
    , "    word rl2 = if (mkbool(rc == 0)) {"
    , "      word cur = wload(lim, 0);"
    , "      word rl3 = if (mkbool(cur < 67108864)) {"
    , "        wstore(lim, 0, 67108864);"
    , "        rawcall setrlimit(3, lim);"
    , "        return 0;"
    , "      } else {"
    , "        return 0;"
    , "      };"
    , "      return 0;"
    , "    } else {"
    , "      return 0;"
    , "    };"
    , "    return 0;"
    , "  } else {"
    , "    return 0;"
    , "  };"
    , -- ====================== stage 6 A3b — the meta walk + not-in-meta error ======================
      -- Byte-parity with rt.zig main's meta scan (rt.zig:1834-1846) and its
      -- not-in-meta error (rt.zig:1848-1852).  qbe_meta and qbe_meta_len are
      -- the EXPORTED data symbols Mid.Qbe.Lower.metaTable emits; `rawsym` is
      -- the surface's only route to `Il.Sym <name>` VERBATIM (the A1b RawSym
      -- node — documented as a FUNCTION-symbol address, but the mechanism is
      -- symbol-type-agnostic and yields exactly `$qbe_meta`/`$qbe_meta_len`,
      -- a data symbol's ADDRESS as a word).  wload of qbe_meta reads its ONE
      -- word — the `l $meta_rows` pointer — the row base; wload of
      -- qbe_meta_len reads the count.  entry = argv[1] (argc >= 2 already).
      --
      -- rt_boot() is DELIBERATELY NOT called here: the meta walk and the
      -- not-in-meta error are allocation-free (the byte compare is a
      -- frame-free val loop, no safepoint), so the collector is not needed
      -- for byte-parity — rt.zig's notmeta path boots first but prints
      -- nothing by default.  A4a inserts rt_boot() at this position (its
      -- position IS load-bearing for the args/entry dispatch that follows).
      --
      -- The not-in-meta error is THREE writes (prefix + entry name + suffix)
      -- — the exact byte stream rt.zig's bufPrint + werr emits in one write
      -- (golden err-notmeta.txt: "qbe-rt: entry 'NoSuch.entry' not in
      -- qbe_meta\n", 45 bytes = 15 + 12 + 18).
      "  word entry = wload(argv, 1);"
    , "  word base = wload(rawsym(\"qbe_meta\"), 0);"
    , "  word metaN = wload(rawsym(\"qbe_meta_len\"), 0);"
    , "  word mblk = rawcall malloc(40);"
    , "  wstore(mblk, 0, base);"
    , "  wstore(mblk, 1, entry);"
    , "  wstore(mblk, 2, metaN);"
    , "  val found = call Rt.metaGo(mknum(mblk), mknum(0));"
    , "  word nf = if (mkbool(payload(found, 0) == 0)) {"
    , "    word pre = rawstr(\"qbe-rt: entry '\");"
    , "    val plen = call Rt.cStrLenGo(mknum(pre), mknum(0));"
    , "    rawcall write(2, pre, payload(plen, 0));"
    , "    val elen = call Rt.cStrLenGo(mknum(entry), mknum(0));"
    , "    rawcall write(2, entry, payload(elen, 0));"
    , "    word suf = rawstr(\"' not in qbe_meta\\n\");"
    , "    val slen = call Rt.cStrLenGo(mknum(suf), mknum(0));"
    , "    rawcall write(2, suf, payload(slen, 0));"
    , "    rawcall exit(2);"
    , "    return 0;"
    , "  } else {"
    , "    return 0;"
    , "  };"
    , -- ====================== stage 6 A4a — boot + args + argv + entry dispatch + bounce ======================
      -- The matched row's code pointer + arity were wstored by Rt.metaGo into
      -- blk[3]/blk[4] (the walk is allocation-free, so this read needs no
      -- collector).  code is a raw word; arity is the i32 the dispatch chains.
      "  word code = wload(mblk, 3);"
    , "  word arity = wload(mblk, 4);"
    , -- rt_boot() (no args — the A2 seat; boot ORDER Gc.init -> internInit ->
      -- streams is load-bearing and is the seat's own position).  Returns 0,
      -- or 1 after the SAME stderr line as the pre-A2 main (gc-init-failed).
      -- Its position HERE (before any generated code, after the
      -- allocation-free meta walk + notmeta error) preserves the
      -- "read the knobs once" discipline; the order transposition vs rt.zig
      -- (which boots BEFORE the meta scan) is observationally inert — the
      -- walk allocates nothing and prints nothing.
      "  word brc = rawcall rt_boot();"
    , "  word bt = if (mkbool(brc != 0)) { rawcall exit(1); return 0; } else { return 0; };"
    , -- THE ARGV BUFFER (rt.zig's argv_buf [max_arity]Value + the live count):
      -- a 648-byte malloc'd block — 16 40-byte Value slots at 0..639, an
      -- 8-byte live-count word at 640 (word index 80).  The parsed Values are
      -- ZIG-heap (rt_parse_arg's valNumber/valFloat), so the buffer is rooted
      -- via rt_root_push_value_array AFTER the loop — the SAME mechanism
      -- rt.zig main uses (g.rootPushValueArray(&argv_buf, &live)); the count
      -- is read at scan time, so it is wstored BEFORE the push.  Rt.main is a
      -- rawAbi defun (RtRawWord -> PAlloc, frame-FREE — the plan's "FRAMED
      -- and allocating" note was the pre-A3a projection; A3a's rawAbi landing
      -- made it frame-free, so the frame does NOT root the buffer: the
      -- explicit root is the WHOLE contract).  The root is never popped (the
      -- driver exits after Rt.main returns; rt.zig's main pops it via defer,
      -- the Mid driver has no defer — one inert shadow-stack entry).
      "  word abuf = rawcall malloc(648);"
    , "  word entry_nargs = payload(mkbool(argvMode != 0) ? mknum(0) : mknum(nargs), 0);"
    , "  word pblk = rawcall malloc(24);"
    , "  wstore(pblk, 0, abuf);"
    , "  wstore(pblk, 1, argv);"
    , "  wstore(pblk, 2, entry_nargs);"
    , "  val prc = call Rt.parseArgsGo(mknum(pblk), mknum(0));"
    , "  word pre = if (mkbool(payload(prc, 0) != 0)) { rawcall exit(2); return 0; } else { return 0; };"
    , "  wstore(abuf, 80, entry_nargs);"
    , "  rawcall rt_root_push_value_array(abuf, abuf + 640);"
    , -- *argv* pseudo-global (AOTRUN_ARGV): the D3 seat owns the WHOLE region
      -- (buildArgvList cdr-first AND both valueSet arms).  argvMode is the raw
      -- getenv pointer (0 = unset); the seat's `!= 0` test reads it correctly.
      "  rawcall rt_argv_install(argvMode, nargs, argv);"
    , -- arg pointers (the 40-byte stride over the Value buffer).
      "  word a1 = abuf + 40;"
    , "  word a2 = abuf + 80;"
    , "  word a3 = abuf + 120;"
    , "  word a4 = abuf + 160;"
    , "  word a5 = abuf + 200;"
    , "  word a6 = abuf + 240;"
    , "  word a7 = abuf + 280;"
    , "  word a8 = abuf + 320;"
    , "  word a9 = abuf + 360;"
    , "  word a10 = abuf + 400;"
    , "  word a11 = abuf + 440;"
    , "  word a12 = abuf + 480;"
    , "  word a13 = abuf + 520;"
    , "  word a14 = abuf + 560;"
    , "  word a15 = abuf + 600;"
    , -- ====================== stage 6 A4a — the 17-arm entry dispatch ======================
      -- BYTE-PARITY with rt.zig main's `callArity(m.arity, m.code, null,
      -- &argv_buf)` = bounce(callArityRet(arity, f, e, buf)): each arm calls
      -- the Mid-emitted rt_callN DISPATCHER (NOT q_Rt_x2ecallN — that was the
      -- re-plan's mislabel; the symbols are literally `rt_callN`, Lower's
      -- rtCallFuncs) for an 80-byte :ret, then rt_bounce chases any .tail to
      -- the :val.  code + payload(slot) pointers + Con 0 env are all WORDS.
      -- Each arm is an EIfBlock EXPRESSION dead-bound to a word (the A3a D-A
      -- shape: rawAbi bodies cannot carry a tail If, and `return 0` is the
      -- branch VALUE — the join stores it in the dead slot and the chain
      -- continues, so EXACTLY the matching arm runs its calls once).  The
      -- bounce result is DEAD here — A4b is program/print.
      "  word d0 = if (mkbool(arity == 0)) {"
    , "    word r0 = aggcall ret rawsym(\"rt_call0\")(code, 0);"
    , "    val res0 = aggcall val rawsym(\"rt_bounce\")(r0);"
    , "    return 0;"
    , "  } else {"
    , "    return 0;"
    , "  };"
    , "  word d1 = if (mkbool(arity == 1)) {"
    , "    word r1 = aggcall ret rawsym(\"rt_call1\")(code, 0, abuf);"
    , "    val res1 = aggcall val rawsym(\"rt_bounce\")(r1);"
    , "    return 0;"
    , "  } else {"
    , "    return 0;"
    , "  };"
    , "  word d2 = if (mkbool(arity == 2)) {"
    , "    word r2 = aggcall ret rawsym(\"rt_call2\")(code, 0, abuf, a1);"
    , "    val res2 = aggcall val rawsym(\"rt_bounce\")(r2);"
    , "    return 0;"
    , "  } else {"
    , "    return 0;"
    , "  };"
    , "  word d3 = if (mkbool(arity == 3)) {"
    , "    word r3 = aggcall ret rawsym(\"rt_call3\")(code, 0, abuf, a1, a2);"
    , "    val res3 = aggcall val rawsym(\"rt_bounce\")(r3);"
    , "    return 0;"
    , "  } else {"
    , "    return 0;"
    , "  };"
    , "  word d4 = if (mkbool(arity == 4)) {"
    , "    word r4 = aggcall ret rawsym(\"rt_call4\")(code, 0, abuf, a1, a2, a3);"
    , "    val res4 = aggcall val rawsym(\"rt_bounce\")(r4);"
    , "    return 0;"
    , "  } else {"
    , "    return 0;"
    , "  };"
    , "  word d5 = if (mkbool(arity == 5)) {"
    , "    word r5 = aggcall ret rawsym(\"rt_call5\")(code, 0, abuf, a1, a2, a3, a4);"
    , "    val res5 = aggcall val rawsym(\"rt_bounce\")(r5);"
    , "    return 0;"
    , "  } else {"
    , "    return 0;"
    , "  };"
    , "  word d6 = if (mkbool(arity == 6)) {"
    , "    word r6 = aggcall ret rawsym(\"rt_call6\")(code, 0, abuf, a1, a2, a3, a4, a5);"
    , "    val res6 = aggcall val rawsym(\"rt_bounce\")(r6);"
    , "    return 0;"
    , "  } else {"
    , "    return 0;"
    , "  };"
    , "  word d7 = if (mkbool(arity == 7)) {"
    , "    word r7 = aggcall ret rawsym(\"rt_call7\")(code, 0, abuf, a1, a2, a3, a4, a5, a6);"
    , "    val res7 = aggcall val rawsym(\"rt_bounce\")(r7);"
    , "    return 0;"
    , "  } else {"
    , "    return 0;"
    , "  };"
    , "  word d8 = if (mkbool(arity == 8)) {"
    , "    word r8 = aggcall ret rawsym(\"rt_call8\")(code, 0, abuf, a1, a2, a3, a4, a5, a6, a7);"
    , "    val res8 = aggcall val rawsym(\"rt_bounce\")(r8);"
    , "    return 0;"
    , "  } else {"
    , "    return 0;"
    , "  };"
    , "  word d9 = if (mkbool(arity == 9)) {"
    , "    word r9 = aggcall ret rawsym(\"rt_call9\")(code, 0, abuf, a1, a2, a3, a4, a5, a6, a7, a8);"
    , "    val res9 = aggcall val rawsym(\"rt_bounce\")(r9);"
    , "    return 0;"
    , "  } else {"
    , "    return 0;"
    , "  };"
    , "  word d10 = if (mkbool(arity == 10)) {"
    , "    word r10 = aggcall ret rawsym(\"rt_call10\")(code, 0, abuf, a1, a2, a3, a4, a5, a6, a7, a8, a9);"
    , "    val res10 = aggcall val rawsym(\"rt_bounce\")(r10);"
    , "    return 0;"
    , "  } else {"
    , "    return 0;"
    , "  };"
    , "  word d11 = if (mkbool(arity == 11)) {"
    , "    word r11 = aggcall ret rawsym(\"rt_call11\")(code, 0, abuf, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10);"
    , "    val res11 = aggcall val rawsym(\"rt_bounce\")(r11);"
    , "    return 0;"
    , "  } else {"
    , "    return 0;"
    , "  };"
    , "  word d12 = if (mkbool(arity == 12)) {"
    , "    word r12 = aggcall ret rawsym(\"rt_call12\")(code, 0, abuf, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11);"
    , "    val res12 = aggcall val rawsym(\"rt_bounce\")(r12);"
    , "    return 0;"
    , "  } else {"
    , "    return 0;"
    , "  };"
    , "  word d13 = if (mkbool(arity == 13)) {"
    , "    word r13 = aggcall ret rawsym(\"rt_call13\")(code, 0, abuf, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12);"
    , "    val res13 = aggcall val rawsym(\"rt_bounce\")(r13);"
    , "    return 0;"
    , "  } else {"
    , "    return 0;"
    , "  };"
    , "  word d14 = if (mkbool(arity == 14)) {"
    , "    word r14 = aggcall ret rawsym(\"rt_call14\")(code, 0, abuf, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13);"
    , "    val res14 = aggcall val rawsym(\"rt_bounce\")(r14);"
    , "    return 0;"
    , "  } else {"
    , "    return 0;"
    , "  };"
    , "  word d15 = if (mkbool(arity == 15)) {"
    , "    word r15 = aggcall ret rawsym(\"rt_call15\")(code, 0, abuf, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14);"
    , "    val res15 = aggcall val rawsym(\"rt_bounce\")(r15);"
    , "    return 0;"
    , "  } else {"
    , "    return 0;"
    , "  };"
    , "  word d16 = if (mkbool(arity == 16)) {"
    , "    word r16 = aggcall ret rawsym(\"rt_call16\")(code, 0, abuf, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15);"
    , "    val res16 = aggcall val rawsym(\"rt_bounce\")(r16);"
    , "    return 0;"
    , "  } else {"
    , "    return 0;"
    , "  };"
    , -- MARKER: A4b continues here — isProgram (rt_is_program), runProgram
      -- (rt_run_program), print (rt_print_value + newline), exit 0 — verbatim
      -- rt.zig main:1767-1790.  The bounce result is the dead `resN` slot of
      -- the matching arm; A4b restructures the dispatch to expose it.
      "  return 0;"
    , "}"
    ]
