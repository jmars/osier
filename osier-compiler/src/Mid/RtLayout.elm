module Mid.RtLayout exposing
    ( abiAlign
    , bodyWords
    , heapBodyStride, heapBodyUnitOffset, heapHeaderBytes, heapHeaderOffset, heapKindMask, heapKindScanned, heapKindShift, heapPtrTag
    , i32Bytes
    , descArityOffset, descCacheOffset, descCodeOffset, descNcapsOffset, descQbeFields
    , descTotalBytes, direntNameOffset
    , epChainOpIdx, epChainPipeIdx, epChainWords
    , epCmdArgcIdx, epCmdArgvIdx, epCmdNredirsIdx, epCmdRedirsIdx, epCmdSubIdx, epCmdWords
    , epKindAppend, epKindDup, epKindHdoc, epKindHstr, epKindIn, epKindOut
    , epOpAnd, epOpOr, epOpSeq
    , epPipeCmdArrIdx, epPipeCmdCountIdx
    , epProgChainsIdx, epProgCountIdx
    , epRedirBodyIdx, epRedirDupfdIdx, epRedirFdIdx, epRedirKindIdx, epRedirPathIdx, epRedirTmpfdIdx, epRedirWords
    , lenFieldOffset, lenFieldWord
    , maxArity
    , metaArityOffset, metaCodeOffset, metaNameOffset, metaSizeBytes
    , payloadBase, payloadWordOffset
    , tagBigInt, tagBoolean, tagCons, tagError, tagFloat, tagLambda, tagMark, tagNil, tagNumber, tagPrim, tagRecord, tagStream, tagString, tagSymbol, tagVector
    , untagMask
    , ValLayout, valLayout
    , WordTagShape(..), wordHeapCodes, wordLitAllocSeat, wordMkAllocSeat, wordTagShape
    , bigLiteralFitsFixnum, wordFixnumLimit, wordLayout
    , valQbeFields, valSizeBytes, valuePayloadWords, valueTagBytes, wordBytes
    )

-- Mid.RtLayout — THE ONE PLACE the cross-ABI layout is written down
-- (handoff-osier-zigretire-plan STAGE 2).
--
-- WHY THIS MODULE EXISTS.  The heap/value layout is a contract between three
-- parties: the Zig runtime (`vendor/osier-rt/src/gc/types.zig` scans a Value;
-- `tools/qbe/rt.zig` reads the `:desc`/`qbe_meta`/`Ret` shapes the generated
-- code builds), the QBE IL this compiler EMITS (`Mid.Qbe.Il`'s `:val`/`:ret`/
-- `:desc` type definitions, `Mid.Qbe.Lower`'s stores at fixed offsets), and —
-- after Phase 4b — the Mid-written collector.  Before this module every one
-- of those carried its OWN copy of the numbers.  This repo has already paid
-- for the failure mode that produces ("the mechanism is right but the thing
-- that reads it is wrong"): a mismatch links cleanly and then reads another
-- struct's bytes at the wrong offset, silently.
--
-- THE DIRECTION OF TRUTH.  These values are the DEFINITION; the emitted IL is
-- DERIVED from them (`Mid.Qbe.Il.valType`/`descType` are built out of the
-- field projections below, `Mid.Qbe.Lower` reads `valSizeBytes`, `maxArity`
-- and the tag numbers, `Mid.RtPrims` reads the tag numbers), and the ZIG side
-- is checked against them:
--
--   * `tools/qbe/layout-census.sh --values` parses THIS file and compares the
--     result against the values `vendor/osier-rt/src/gc/types.zig` and
--     `tools/qbe/rt.zig` actually compile to (a probe program printing
--     `@sizeOf`/`@offsetOf`/`@intFromEnum`) — a mismatch is LOUD.
--   * `tools/qbe/layout-census.sh --gen` writes the same numbers into
--     `vendor/osier-rt/src/gc/layout_gen.zig`, and both `types.zig` and
--     `tools/qbe/rt.zig` carry a `comptime` block asserting their own
--     declarations equal it — so `zig build gate` (the collector's own suite,
--     step 6 of tools/osier-numbers.sh) fails to COMPILE on a mismatch.
--   * `tools/qbe/abi-fingerprint.sh`'s `gc:layout` component is the digest of
--     the census values, not of the Zig declaration text.
--
-- WHAT THIS FILE MAY NOT BECOME: a description of what the code does.  Every
-- number below is stated once and the three readers are brought to it; a
-- change here is a change to all three, and the two oracles above say so.
--
-- THE PARSE CONTRACT (layout-census.sh reads this file as text): every
-- CONSTANT below is written in the strict form
--
--     name =
--         <digits>
--
-- at top level, and the census demands that the set of names it parses EQUALS
-- its own expected list — a renamed or added constant is a census failure,
-- never a silent skip.  Functions and list projections are deliberately NOT
-- in that form; they are derived from the constants and carry no numbers of
-- their own.


-- ============================ Value / ValTag ============================
-- `Mid.Qbe.Il.valType` is `align 8 { w, l, l, l, l }` = 4 + 4*8 = 36, rounded
-- up to the 8-byte alignment = 40.  `types.zig`'s `Value` is an extern
-- struct whose `tag: ValTag` (a u32) is followed by the payload union — the
-- same 40 bytes, the same alignment.
--
-- The payload words are at offset 8 + 8i.  i32 FIELDS (a string's/vector's
-- `len`, a boolean's payload) are the LOW half of payload WORD 1 — offset 16.
-- A 64-bit read of such a field reads garbage in the high half: the extern
-- struct store never writes those bytes and heap memory is recycled (this is
-- exactly what `RawPayload32` exists for).


valueTagBytes : Int
valueTagBytes =
    4


abiAlign : Int
abiAlign =
    8


-- The two scalar widths the emitted data definitions are built out of: an
-- `l` word (a pointer on this LP64 ABI — the payload words, the descriptor's
-- code/cache words) and an `i32` field (the tags, arity and capture counts,
-- and the string/vector `len`).  They are here because Lower's `data` item
-- lists pad to the struct sizes above with them, so a change to either is a
-- change to the emitted bytes.
wordBytes : Int
wordBytes =
    8


i32Bytes : Int
i32Bytes =
    4


valSizeBytes : Int
valSizeBytes =
    40


payloadBase : Int
payloadBase =
    8


valuePayloadWords : Int
valuePayloadWords =
    4


lenFieldWord : Int
lenFieldWord =
    1


lenFieldOffset : Int
lenFieldOffset =
    16


-- The ValTag integers, in C enum order (zinctypes.h -> types.zig ValTag).
-- The value 13 is DELIBERATELY unused: the first Phase-3/E pass had
-- record = 13, the refinement corrected it to 14 and left the gap.  Every
-- consumer switches on the ENUM's values, never on the integer range, and
-- nothing does arithmetic on these — but they ARE a cross-ABI number (the
-- emitted `storew %d, <tag>` and the Zig `@intFromEnum` must agree), so they
-- live here with the rest.


tagNumber : Int
tagNumber =
    0


tagString : Int
tagString =
    1


tagSymbol : Int
tagSymbol =
    2


tagBoolean : Int
tagBoolean =
    3


tagCons : Int
tagCons =
    4


tagNil : Int
tagNil =
    5


tagLambda : Int
tagLambda =
    6


tagMark : Int
tagMark =
    7


tagPrim : Int
tagPrim =
    8


tagError : Int
tagError =
    9


tagVector : Int
tagVector =
    10


tagStream : Int
tagStream =
    11


tagFloat : Int
tagFloat =
    12


tagRecord : Int
tagRecord =
    14


-- ============ AREA 4: THE BOXED INTEGER'S KIND CODE AND ITS SCAN DECISION ============
-- A boxed integer is the i61 overflow path's heap cell: a result whose i64 value
-- does not fit the word arm's i61 fixnum is stored here instead of being refused.
-- Its KIND CODE is 13, the ValTag enum's DELIBERATE GAP (the first Phase-3/E pass
-- had record = 13, the refinement moved record to 14 and left 13 unwritten).
-- Choosing the gap rather than extending past 14 keeps the code inside the
-- numbering every reader already switches on, and nothing switches on 13 today.
--
-- ITS SCAN BIT IS FALSE, AND THAT IS A DECISION RATHER THAN AN INHERITANCE.  The
-- body of a boxed integer is ONE raw i64 word — the number itself, not a Value
-- and not a pointer — so it must NOT appear in `heapKindScanned`'s scanned set.
-- The alternative (letting the collector scan it) would walk an integer as a
-- pointer: the silent-corruption class this arm exists to prevent.  `Rt.kindHdr`
-- derives header bit 1 from `heapKindScanned`, so the header says raw by
-- construction and there is no second statement to drift.
tagBigInt : Int
tagBigInt =
    13



-- ==================== THE GC-HEADER KIND CONTRACT (VR3c, AREA 1) ====================
-- WHAT THIS SETTLES, AND WHY IT HAD TO BE SETTLED HERE.  Under the word arm
-- EVERY heap object's tag is `...001` (see `wordLayout` below), so the value's
-- own word cannot say WHICH object it points at — a cons, a string, a vector,
-- a float cell, a closure.  The disambiguation is the object's 2-WORD GC
-- HEADER, which does not move (valrep2 §2(a): the block map, the class ladder,
-- the remembered set and the forwarding stomp all stay where they are).  The
-- header's fields, in bits:
--
--   bit 0        MARK      set by the marker, cleared by the sweep
--   bit 1        SCAN KIND 1 = the body is `count` Values, 0 = `count` raw words
--   bits 2..23   CLASS     the size class (`kind*2 + cls*4`, the ladder's own
--                          packing — widened from 2..21 to the DOCUMENTED
--                          22 bits when the 2^20 ceiling fired at the
--                          selfhost's default heap: at 32 GiB the +4 GiB
--                          ladder arm wants ~1.18M classes, which needs 21
--                          bits, so bits 22..23 are NOT spare past ~64 GiB
--                          ceilings.  22 bits = 4,194,304 classes x 32 KiB
--                          = a hard ceiling of 128 GiB, which `gcInit`
--                          refuses to exceed BY NAME)
--   bits 24..27  KIND CODE this contract (a 4-bit code; see below)
--   bit 61       RS        the remembered set
--   bit 62       FORWARDED the young space's evacuation mark
--
-- THE KIND CODE IS THE OBJECT'S VALTAG INTEGER.  Not a second numbering: the
-- codes below ARE `tagString`/`tagCons`/... — the same integers the val arm
-- writes into a Value's tag word and switches on everywhere.  A word-arm
-- `tagis(v, 4)` therefore becomes "read the header, compare the code with 4",
-- and the two arms name the same constructors with the same numbers.
--
-- WHY A NEW FIELD AND NOT A WIDER `kind`.  The scan kind is ONE bit and the
-- class ladder starts at bit 2; widening the kind would MOVE the class, which
-- the invariant forbids.  Bits 24..27 are above every legal class and are
-- written by nothing on the val arm.
--
-- CODE 0 HAS EXACTLY ONE OWNER: NO CODE.  A header whose code is 0 is a
-- VAL-ARM header, and no word-arm allocator writes 0 (`runtime.mid`'s seats:
-- allocVector 10, allocCons 4, allocRaw 1, allocKind caller-supplied — with
-- `Rt.kindHdr` the only writer of the field).  That is the part that is LANDED
-- and checkable.  The REFUSAL is a promissory note and is stated as one: the
-- only reader that will test for 0 is the word arm's `tagis`, which belongs to
-- the emitter (VR3b3), so no runtime reader does it yet.  Saying "refuses BY
-- NAME" without that qualifier would claim a seat nobody sits in.
--
-- THE SCAN BIT IS DERIVED FROM THE CODE, not carried twice: `heapKindScanned`
-- below is the one statement of which codes have Value bodies (cons, lambda,
-- error, vector, record).  The strings/symbols/floats/prims/streams have raw
-- bodies.
--
-- THE BODY-SIZE RULE, in words: `bodyWords` below.  On the val arm a body unit
-- is `1 + 4*kind` words (a 40-byte Value or one raw word), so a cons is
-- 2 + 2*5 = 12 words = 96 B; on the word arm `valuePayloadWords` is 0, so a
-- unit is ONE word and a cons is 2 + 2 = 4 words = 32 B (16 B of 2-word header
-- plus 16 B of body).  The emitted `runtime.mid` arithmetic is the SAME
-- expression in both arms, with the layout's own `valuePayloadWords` folded in.
--
-- THE PIN.  `runtime.mid` states this contract once, in the word-arm splice
-- region, as `// KIND-CONTRACT: <name> <code> <scanned|raw>` rows plus the
-- field's shift and mask; TestMain parses those rows and compares them with
-- THIS file's numbers and with `heapKindScanned`.  A stale duplicate on either
-- side FAILS a test instead of silently reading another object's bytes.


heapKindShift : Int
heapKindShift =
    24


heapKindMask : Int
heapKindMask =
    15


-- Which codes have VALUE bodies (`count` Values, scanned by the collector) and
-- which have raw ones.  The val arm's header carries the same distinction in
-- bit 1; under the word arm the allocator derives bit 1 from the code through
-- this predicate, so the two statements cannot drift.
heapKindScanned : Int -> Bool
heapKindScanned code =
    code == tagCons || code == tagLambda || code == tagError || code == tagVector || code == tagRecord


-- The body-size rule, in words: TWO header words plus `count` body units, a
-- unit being `1 + valuePayloadWords*scanKind` words.  MEASURED against
-- `runtime.mid`'s gcAlloc: val `2 + (countW + 4 * countW * kindW)` ==
-- `bodyWords valLayout count 1`, and the word arm's `2 + countW` ==
-- `bodyWords wordLayout count 1`.  TestMain pins both directions.
--
-- Everything below in this section is a FUNCTION, never a new constant: the
-- parse contract above (layout-census.sh) demands that the set of top-level
-- `name = <digits>` constants EQUALS its expected list, so a new number stated
-- as a constant would be a census failure.  These are all DERIVED from the
-- constants above, which is the point of them anyway.
bodyWords : ValLayout -> Int -> Int -> Int
bodyWords layout count scanKind =
    2 + count * (1 + layout.valuePayloadWords * scanKind)



-- ============ THE WORD ARM'S HEAP ACCESS SHAPE (VR3b3 AREAS A, B, D) ============
-- THE ONE STATEMENT of how a word-arm HEAP OBJECT is reached, so the emitter's
-- construction sites (area A), its payload reads (area B) and its tag tests
-- (area C) cannot each invent a different arithmetic.  The three steps are
-- ALWAYS these three, in this order:
--
--   1. UNTAG.  The Value word's low bits are the tag (`tagMask`), and a heap
--      object's tag is `heapPtrTag` (`...001`), so `w AND untagMask` IS THE
--      BODY ADDRESS.  On the val arm `untagMask` is all ones: the tag is a
--      whole word and nothing is masked, which is why the val arm's readers
--      never call this and the word arm's always do.
--   2. THE HEADER IS *BEFORE* THE BODY, at `heapHeaderOffset` (= -16).  The
--      2-word GC header is the same two words in both arms (VR3c AREA 1: the
--      header does not move; only the body strides do), and it is DERIVED from
--      `bodyWords layout 0 0` — "what a zero-body object costs" — so the header
--      size and the body-size rule cannot drift.
--   3. STEP INTO THE BODY.  `heapBodyUnitOffset layout i` — body unit `i`, a
--      unit being one Value slot (`heapBodyStride`): 8 bytes on the word arm,
--      40 on the val arm.  This is the HEAP-BODY shape and it is deliberately
--      NOT `payloadWordOffset`, which is the shape of a 40-byte Value RECORD (a
--      tag word then payload words).
--
-- THE CONVENTION IS THE RUNTIME'S, AND THE EMITTER ALIGNS TO IT (VR3b3 FIX,
-- BLOCKER 1 — the owner's decision, and the reason is asymmetry of risk rather
-- than preference).  `runtime.mid`'s `gcAlloc` writes the header at
-- `cursor - 2`/`- 1` words and returns `mknum(cursor)` on EVERY path, so a
-- seat's return value is the BODY address with the header 16 bytes BEFORE it;
-- the VAL arm consumes it exactly that way and is corpus-proven at 159/159,
-- and the word arm's `gcScavValue` twin re-tags `newbody + 1`.  So on the word
-- arm a heap Value's untagged word IS THE BODY, not a block base.  The runtime
-- side stays (changing it would put the whole working arm at risk to
-- accommodate new code); this module states the emitter's side of the one
-- convention so no site re-derives it.
--
-- WHAT IS NOT HERE.  The header's KIND CODE field (`heapKindShift`/
-- `heapKindMask`, above) is read from the header word this section steps past,
-- and `wordTagShape` below says which word shape a VALTAG has.  The collector's
-- scan-vs-raw rule is still `heapKindScanned` and still bit 1 of the header;
-- nothing in this section moves either.


-- The byte size of the GC header — the same two words in both arms.
heapHeaderBytes : ValLayout -> Int
heapHeaderBytes layout =
    bodyWords layout 0 0 * layout.wordBytes


-- The tag a word-arm HEAP OBJECT carries in its Value word's low bits.  On the
-- word instance every heap tag field reads this one number (`heapTagIsKind`
-- says the tag does not name the kind); on the val instance this function is
-- never read — every call site is inside a word-arm branch — and `tagCons` is
-- 4 there, i.e. a KIND, which is why a reader must branch on `heapTagIsKind`
-- before it may treat a tag as a pointer tag.
heapPtrTag : ValLayout -> Int
heapPtrTag layout =
    layout.tagCons


-- The mask that strips the low tag bits from a Value word: all ones on the val
-- arm (nothing is masked there), `complement tagMask` on the word arm.
untagMask : ValLayout -> Int
untagMask layout =
    0 - (layout.tagMask + 1)


-- One body unit, in bytes: a Value slot (8 on the word arm, 40 on the val arm).
heapBodyStride : ValLayout -> Int
heapBodyStride layout =
    layout.wordBytes * (1 + layout.valuePayloadWords)


-- THE HEADER'S OFFSET RELATIVE TO THE BODY — NEGATIVE, because the header
-- precedes the body (see THE CONVENTION above).  THE ONE STATEMENT of the
-- `-16` a kind read applies, so no site re-invents it and no site can apply
-- `+16` by analogy with a block-based convention.
--
-- WHY THIS IS A FUNCTION AND NOT `heapHeaderBytes` NEGATED AT EACH SITE: the
-- sign is the whole content of the convention.  MEASURED (VR3b3, found by
-- RUNNING): the first emitted kind read subtracted `heapHeaderBytes` from a
-- BLOCK base and so read the word BEFORE the object, saw code 0 and refused a
-- perfectly good cons — while a text pin blessed the arithmetic.
heapHeaderOffset : ValLayout -> Int
heapHeaderOffset layout =
    0 - heapHeaderBytes layout


-- The byte offset of body unit `i` RELATIVE TO THE BODY ADDRESS — what a seat
-- RETURNS (`Rt.allocRaw`/`allocKind`/`allocVector`/`allocCons` all return
-- `mknum(body)`) and what `payload(v, 0)` yields on the word arm.
heapBodyUnitOffset : ValLayout -> Int -> Int
heapBodyUnitOffset layout word =
    word * heapBodyStride layout


-- THE CODES WHOSE WORD-ARM OBJECT IS A HEAP BLOCK — i.e. the VALTAGS that are
-- not immediates.  Stated ONCE here because three readers need it and a fourth
-- copy would be the drift this module exists to prevent: the emitter's tag
-- tests (area C), its payload reads (area B) and the kind-contract test.
--
-- IT IS NOT `heapKindScanned`.  Scanned = "the body is Values"; this list =
-- "the object is a heap block at all".  A string (1) and a float (12) are heap
-- blocks with RAW bodies, so they are here and not there; an error (9) is
-- scanned (a code-9 block's body would be Values) and on the word arm it is an
-- IMMEDIATE instead — see `wordTagShape`, and the tension is named there.
wordHeapCodes : List Int
wordHeapCodes =
    [ tagString, tagSymbol, tagCons, tagLambda, tagPrim, tagVector, tagStream, tagFloat, tagRecord, tagBigInt ]


-- WHICH WORD SHAPE A VALTAG HAS, which is what a word-arm tag test dispatches
-- on (area C) and what a construction site must produce (area A).
--
-- THE VALTAGS ARE UNCHANGED — the contract above says the codes ARE the ValTag
-- integers — but the WORD ENCODING of a valtag is not the valtag: a nil is
-- valtag 5 and the word immediate `...010` (2), an error is valtag 9 and the
-- word immediate `...101` (5), a boolean is valtag 3 and TWO immediates
-- (`...011` true, `...100` false) because there is no payload word to carry the
-- flag.  Those numbers are the word INSTANCE's own fields, read here rather
-- than restated, so a change to the encoding moves this function with it.
--
--   WordImmediate tags  the low-3-bit tags that name this valtag.  A boolean
--                       has two; every other immediate exactly one.
--
--                       THE BOOLEAN WRITE ASSUMES THE TWO ARE ADJACENT
--                       (`tagFalse == tagTrue + 1`) because it computes
--                       `tagTrue + (w == 0)` branch-free (VR3b3 FIX F5: the
--                       assumption was silent; it is now a PINNED property -
--                       TestMain asserts the adjacency, so a future encoding
--                       with a gap fails a test instead of writing the wrong
--                       immediate).
--   WordHeapCode code   the object is a heap block and `code` is its header
--                       kind code — i.e. the valtag itself.
--   WordNoForm why      the valtag has no word-arm encoding (the mark tag, the
--                       deliberately unused 13, anything outside the ValTag
--                       enum): a word-arm reader must refuse it BY NAME rather
--                       than test for a number nothing writes.
type WordTagShape
    = WordImmediate (List Int)
    | WordHeapCode Int
    | WordNoForm String


wordTagShape : Int -> WordTagShape
wordTagShape code =
    if code == tagNumber then
        WordImmediate [ wordLayout.tagNumber ]

    else if code == tagBoolean then
        -- `booleanSplit` is the instance's own statement that true and false are
        -- two immediates (word) rather than one tag plus a payload bit (val).
        if wordLayout.booleanSplit then
            WordImmediate [ wordLayout.tagTrue, wordLayout.tagFalse ]

        else
            WordImmediate [ wordLayout.tagBoolean ]

    else if code == tagNil then
        WordImmediate [ wordLayout.tagNil ]

    else if code == tagError then
        -- THE ONE CONTRACT TENSION THIS FUNCTION EXPOSES, stated rather than
        -- smoothed over: `heapKindScanned` lists error (9) because the VAL
        -- arm's error is a heap object with a Value body, while `wordLayout`
        -- encodes an error as the IMMEDIATE `...101` (5).  The instance is the
        -- authority for the ENCODING, so an error is an immediate here; a
        -- word-arm reader that ever needs a code-9 BLOCK would have to revisit
        -- this line (nothing allocates one today: `Rt.allocKind`'s callers pass
        -- 1, 4, 10 and the caller-supplied code, and the emitter passes the
        -- codes it constructs).
        WordImmediate [ wordLayout.tagError ]

    else if List.member code wordHeapCodes then
        WordHeapCode code

    else if code == tagMark then
        WordNoForm "the MARK tag (7) is a value-arm collector tag, not a word-arm constructor"

    else
        WordNoForm ("valtag " ++ String.fromInt code ++ " has no word-arm encoding (the ValTag enum has a gap at 13 and no code above record = 14)")


-- ============ WHICH `mk*` CODES ALLOCATE ON THE WORD ARM (perf word-arm-floats) ============
--
-- THE QUESTION, and why it must be answered ONCE.  A `mk*` node is the val arm's
-- tag-word-plus-payload write into a frame slot, which allocates NOTHING.  Under
-- the word arm the same node is a HEAP CELL, and building one may call an
-- allocation seat — a call injected by the EMITTER, so it is invisible in the
-- `.mid` tree.  `Mid.Rt.unsafeSafepoint` classifies a `RawMkValue` from that
-- tree, and it treated every `mk*` as a NON-safepoint.  That is correct exactly
-- when the writer allocates nothing; where it allocates, a defun whose only
-- allocation is the cell classifies FRAME-FREE and DROPS ITS ROOTS — silently.
-- The classifier cannot see the emitter, so the fact lives HERE and the
-- classifier reads it (WORKLIST item 5's standing instruction).
--
-- THE ENUMERATION IS OVER THE WRITERS, not over the codes:
--
--   * `tagFloat` (12) -> `storeWordFloatCell` -> `Rt.allocFloat`.  ALLOCATES.
--     The double is a `d`-class operand and cannot cross the lean ABI, so the
--     emitter has to allocate the cell itself, fill body unit 0 and tag it.
--   * `tagString` (1) -> `storeWordStringCell` -> NOTHING.  Since perf
--     word-arm-rawroot a word-arm string's bytes are INLINE in the cell
--     `Rt.allocRaw` already allocated and `mkstr` only writes body unit 0 (the
--     byte base) and the length.  THE `mkstr` HALF OF THE OLD WORKLIST NOTE IS
--     STALE, and this is the sixth stale claim this arc has found: it was true
--     of the TWO-BLOCK shape that unit removed, where `mkstr` allocated the cell
--     after the caller had filled a separate byte block.
--   * every other heap code -> `storeWordCell`'s ONE-WORD arm -> NOTHING: the
--     caller has already allocated and filled the body (the seat-return
--     convention), so the writer only ORs in the heap pointer tag.  `mkval(2,
--     body)` — the runtime's own symbol construction — is that shape, which is
--     why a symbol LITERAL has its own allocating writer and this list has no
--     symbol row.
--   * the IMMEDIATE codes (`mknum`/`mkbool`) -> shifts, nothing.
--
-- IT RETURNS THE SEAT RATHER THAN A BOOL so that a TestMain row can assert WHICH
-- seat the rule claims, and so a future allocating code's row documents itself.
--
-- AREA 4, THE THIRD PLACE THE RULE HOLDS: `tagNumber` IS NOW AN ALLOCATING CODE.
-- A word-arm fixnum is an i61, so a `mknum` whose word is DYNAMIC and falls
-- outside i61 has to BOX the value onto the heap instead of dropping its top
-- three bits — and boxing allocates.  That is not visible in the `.mid` tree
-- (`storeWordCell`'s fixnum arm injects the allocation), so this table is where
-- the classifier learns it.  THE ANSWER IS THE HONEST ONE RATHER THAN AN
-- OVER-APPROXIMATION IN THE WRONG DIRECTION: a mknum node really can allocate,
-- so a defun holding one is ROOTED.  The cost is a registered frame on defuns
-- whose fixnum never overflows; the alternative is a dropped root on the one
-- that does.  (`wordLitAllocSeat` carries the same row for the literal node —
-- the second time the reviewer's "look one node over" rule paid for itself.)
wordMkAllocSeat : Int -> Maybe String
wordMkAllocSeat code =
    if code == tagFloat then
        Just "Rt.allocFloat"

    else if code == tagNumber then
        Just "Rt.boxInt"

    else
        Nothing


-- ============ WHICH LITERAL WRITERS ALLOCATE ON THE WORD ARM (perf word-arm-floats review) ============
--
-- THE SAME QUESTION AS `wordMkAllocSeat`, ONE IR NODE OVER, and it has to be
-- asked separately because the answer is DIFFERENT for two of the codes.  A
-- `mk*` node's words are a BODY THE CALLER ALLOCATED (the seat-return
-- convention), so `mkval(2, body)` tags and allocates nothing.  A LITERAL has no
-- caller: its writer allocates the cell itself, so
--
--   * `LFloat`  -> `storeWordFloatCell`     -> `Rt.allocFloat`  ALLOCATES
--   * `LSymbol` -> `storeWordSymbolLiteral` -> `Rt.allocSym`    ALLOCATES
--     (and this one is PRE-EXISTING since R1: `storeWordSymbolLiteral`'s own
--     docstring says it allocates "and that is why it is not in storeWordCell")
--   * `LString` -> `storeWordStringLiteral` -> `Rt.allocRaw`    ALLOCATES
--     (two units, NO inline bytes — the bytes stay the static `str:` symbol)
--   * `LNumberBig` -> the SAME boxing seat as a dynamic `mknum`: an i61 fixnum
--     cannot hold it, so the literal is boxed onto the heap.  ALLOCATES.
--   * `LNumber`/`LBoolean` -> immediates, nothing.
--
-- WHY THIS MATTERS AND WHY IT IS HERE.  `Mid.Rt.safepoint`'s `Lit` arm answered
-- `True` for `LString` and `False` for EVERY other literal.  Under the word arm
-- that is false for floats (armed by the unit that admitted them: the classifier
-- now accepts `Lit (LFloat _)`, so a `.mid` defun could hold one) and false for
-- symbols (armed since R1, and nobody noticed because no `.mid` body contains
-- one).  A defun whose only allocation is such a literal would classify
-- FRAME-FREE and DROP ITS ROOTS — the exact trap `wordMkAllocSeat` discharges
-- for the `mk*` node.
--
-- THE VAL ARM IS NOT IN THIS TABLE, deliberately: there a literal is a tag word
-- plus payload writes and allocates nothing, so `Mid.Rt` reads this ONLY when
-- the arm is the word one.  (`LString` keeps its blanket `True` on BOTH arms
-- because that answer is in the val arm's frozen classification — see the
-- walker's note; over-approximating a frame is safe, under-approximating is the
-- defect.)
wordLitAllocSeat : Int -> Maybe String
wordLitAllocSeat code =
    if code == tagFloat then
        Just "Rt.allocFloat"

    else if code == tagSymbol then
        Just "Rt.allocSym"

    else if code == tagString then
        Just "Rt.allocRaw"

    else
        Nothing


-- ============ WHERE A WORD-ARM STRING KEEPS ITS LENGTH (VR3b3 AREA D) ============
-- IN THE CELL, at body unit `lenFieldWord` (1) — the SAME unit the val arm's
-- `lenFieldOffset` names inside a 40-byte Value, reached by the block shape
-- above.  So the two arms state ONE number (`lenFieldWord`) and reach it two
-- ways:
--
--   val   `payload32(s, 1)` = the i32 at `s + lenFieldOffset` (16) of a Value
--         record whose payload word 1 is the length.
--   word  `payload32(s, 1)` = the i32 low half of body unit 1 of the BODY `s`
--         names, i.e. `(s AND untagMask) + 8`.
--
-- WHY THIS IS THE ANSWER AND NOT A CHOICE.  A word-arm string is a HEAP BLOCK
-- with a RAW body (code 1, `heapKindScanned` false), so its body is not a Value
-- and the length cannot be a Value word: it is a raw word in the body, which is
-- exactly what body unit 1 is.  Body unit 0 is the byte pointer.  That is the
-- same two-field record the val arm carries, one indirection cheaper — which is
-- why the runtime's `payload32(str, 1)`/`payload(str, 0)` reads need NO twin at
-- all: `payload`/`payload32` are layout-derived, so porting THEM (area B) ports
-- every string site in `runtime.mid` at once.
--
-- ======== AND WHERE ITS BYTES ARE: INLINE, IN THE SAME BLOCK (perf word-arm-rawroot) ========
-- Units 2.. are the string's BYTES: `count = 2 + ceil(bytes / 8)`.  So a
-- word-arm string is ONE block, and body unit 0 is the byte pointer TO ITS OWN
-- BYTES (`body + heapBodyUnitOffset layout 2`), which is what makes the shape
-- sound with a collector that never walks a raw body:
--
--   * NOTHING IS REACHABLE THROUGH THE BODY.  The alternative — a separate
--     code-1 byte block named by unit 0 — was the shape until this unit, and it
--     was unsound TWICE: the block was reachable ONLY through a body the
--     collector does not scan (`gcScavDrain` scanCount 0, `gcMarkValue`), and
--     the pointer was a RAW WORD held across `mkstr`'s own allocation, so the
--     bytes could be reclaimed during construction as well.  MEASURED, silently,
--     rc=0: 154 of 6000 surviving `String.join` strings at QBE_HEAP_MB=1 and
--     5699 at DEFAULT knobs, where the val arm answers 6000.
--   * THE SELF-ADDRESS IS RE-DERIVED, NOT TRACED.  Unit 0 is a self-address, so
--     the ONE moment it can go stale is promotion, and `Rt.gcScavPtr` rewrites
--     it there — behind the ownership test (`unit 0 == old body + 2 units`),
--     because a LITERAL's cell names the static data symbol instead and must not
--     be rewritten.
--   * `mkstr` THEREFORE ALLOCATES NOTHING: `Rt.allocRaw` reserves the two units
--     WITH the bytes and returns the BYTE BASE, and the emitter's
--     `storeWordStringCell` only writes the length and the tag.  Every
--     `allocraw(...)` site in `runtime.mid` is unchanged — `word buf = allocraw(n)`
--     is the byte base it always was.
--
-- PINNED BY: TestMain's kind-contract rows (the placement is stated here), the
-- emitter's emitted string cell text on BOTH arms, and TWO arithmetic
-- identities that say the arms name the same field of the same logical record:
--   val   `payloadWordOffset valLayout lenFieldWord == lenFieldOffset` (16 = 16)
--   word  `heapBodyUnitOffset wordLayout lenFieldWord == 8` (body unit 1)
-- (VR3b3 FIX F1: this comment previously claimed
-- `lenFieldOffset == heapBodyOffset valLayout lenFieldWord`, i.e. 16 == 56 —
-- a FALSE identity, in the module whose whole job is the one true set of
-- numbers.  The real pins are the two rows above.)  There is deliberately NO
-- second constant for the word arm's length word: `lenFieldWord` IS it.



-- ==================== THE VALUE LAYOUT, AS A VALUE (VR3a) ====================
-- The constants above are the VAL arm's numbers.  `valLayout` is the ONE
-- INSTANCE the emitters read, and it is built FROM those constants — every
-- field IS the constant above it, so this record holds no second copy of any
-- number and `valLayout.valSizeBytes == 40` is true by construction.
--
-- WHY A RECORD.  The representation is a compile-time choice: `wordLayout`
-- below is the SECOND instance (VR3b1, the word arm) and `QBE_VALREP` selects
-- it.  A reader that names a top-level constant cannot be switched; a reader
-- that takes a `ValLayout` can.  So the EMIT PATH threads the record and never
-- consults the constants directly: `Mid.Qbe.Lower`'s `S.layout`,
-- `Mid.Qbe.Il`'s `Module.layout` (what `Print`/`Encode` read),
-- `Mid.Qbe.Liveness`'s opts record, and the two top-level IL builders
-- `Lower.rtCallFuncs`/`Lower.rtCallTwoRange` (which take it as a parameter
-- because they are not inside the state record).
--
-- WHAT BELONGS HERE, AND THE THREE BOUNDARIES.
--
--   1. THIS IS "THE NUMBERS THIS REPRESENTATION USES", NOT "THE NUMBERS FOR A
--      VALUE".  The `tag*` fields are the ValTag ENUM INTEGERS of the 40-byte
--      representation — what the emitted `storew %d` writes and what the Zig
--      `@intFromEnum` agrees with.  VR3b does NOT renumber them: the word
--      representation ENCODES the tag in a Value's LOW 3 BITS (`(w & 7)`), so
--      a tag test becomes an `and`+compare, and `valueTagBytes`/`payloadBase`
--      go to 0.  Fields marked FLIPS below must be REINTERPRETED, not merely
--      re-valued, when the second instance is written.
--   2. NOTHING HERE MAY SIZE A P8 MAP.  The per-site root maps index SLOT
--      INDICES and the registry entry is frozen at 4 words (p8-design §5), so
--      the only thing VR3 changes about a map is the frame STRIDE, outside
--      this record.  No field here is an input to a map's shape — do not add
--      one.
--   3. THE desc/meta AGGREGATES ARE NOT VALUES AND DO NOT FLIP, so they
--      stay OUT of this record: a record mixing "flips with the
--      representation" and "never flips" is exactly the silent-mismatch shape
--      this module's header was written to prevent.  THE ONE COUPLING THAT
--      SURVIVED — the `:ret` aggregate's first field IS a Value, so its kind
--      offset was `valSizeBytes` — is GONE with the type (AREA 6; see the Ret
--      section below).  `desc*`/`meta*`/`ep*`/`dirent*` carry no Value at all
--      and stay put.


type alias ValLayout =
    { valSizeBytes : Int -- FLIPS 40 -> 8 (the cell IS a word)
    , valuePayloadWords : Int -- FLIPS 4 -> 0
    , payloadBase : Int -- FLIPS 8 -> 0 (no tag word before the payload)
    , wordBytes : Int -- UNCHANGED: the `l` width every offset is counted in
    , valueTagBytes : Int -- FLIPS 4 -> 0 (the tag moves into the low 3 bits)
    , valQbeFields : List String -- FLIPS { w, l, l, l, l } -> { l }
    , maxArity : Int -- UNCHANGED: the rt_callN dispatch bound, not a cell size
    , tagMask : Int -- FLIPS 0 -> 7 (VR3b2): the LOW-BIT MASK that extracts the tag (0 = the tag is a whole word)
    , tagBits : Int -- FLIPS 0 -> 3 (VR3b3): the WIDTH of that mask, for the one reader that must SHIFT
                    -- (a fixnum's payload is the value word ARITHMETIC-SHIFTED DOWN, and QBE has no
                    -- shift-by-mask).  DERIVED from `tagMask` and pinned against it — a mask and a
                    -- width are two statements of one fact, which is why the mask is the primary.
    , tagTrue : Int -- FLIPS 12 -> 3 (VR3b2): see `booleanSplit`
    , tagFalse : Int -- FLIPS 12 -> 4 (VR3b2): see `booleanSplit`
    , booleanSplit : Bool -- FLIPS False -> True (VR3b2): two IMMEDIATES vs one tag + a payload bit
    , heapTagIsKind : Bool -- FLIPS False -> True (VR3b2): the tag names the kind vs the 2-word header does
    , heapKindShift : Int -- FLIPS 0 -> 24 (VR3c AREA 1): the header's KIND CODE field starts here (0 = there is NO kind field: the tag word IS the kind, so a reader branches on `heapTagIsKind` first — the `tagMask` rule)
    , heapKindMask : Int -- FLIPS 0 -> 15 (VR3c AREA 1): the kind code's width mask, meaningless on the val arm for the same reason
    , tagNumber : Int -- REINTERPRETED by VR3b (low-3-bit encoding), not renumbered
    , -- THE `tag*` FIELDS ARE THE WORD ENCODING OF A VALTAG, NOT THE VALTAG.
      -- On the val arm they ARE the valtag integers; on the word arm every HEAP
      -- code collapses to `heapPtrTag` (1) because the constructor moved into
      -- the header, so `wordLayout.tagRecord` is 1, not 14.  A site that needs
      -- the KIND CODE (a header write, a `wordTagShape` argument) must use the
      -- module CONSTANT — `RtLayout.tagRecord` — never `s.layout.tagRecord`.
      -- MEASURED (perf word-arm-records R2): the record build wrote
      -- `s.layout.tagRecord`, which on this arm is the STRING code, so the
      -- cell writer took the string branch, refused, and the site emitted the
      -- POISON word — a silent-wrong record that the probe caught.
      tagString : Int
    , tagSymbol : Int
    , tagBoolean : Int
    , tagCons : Int
    , tagNil : Int
    , tagLambda : Int
    , tagMark : Int
    , tagPrim : Int
    , tagError : Int
    , tagVector : Int
    , tagStream : Int
    , tagFloat : Int
    , tagRecord : Int
    }


valLayout : ValLayout
valLayout =
    { valSizeBytes = valSizeBytes
    , valuePayloadWords = valuePayloadWords
    , payloadBase = payloadBase
    , wordBytes = wordBytes
    , valueTagBytes = valueTagBytes
    , valQbeFields = valQbeFields
    , maxArity = maxArity
    , tagMask = 0
    , tagBits = 0
    , tagTrue = tagBoolean
    , tagFalse = tagBoolean
    , booleanSplit = False
    , heapTagIsKind = False
    , heapKindShift = 0
    , heapKindMask = 0
    , tagNumber = tagNumber
    , tagString = tagString
    , tagSymbol = tagSymbol
    , tagBoolean = tagBoolean
    , tagCons = tagCons
    , tagNil = tagNil
    , tagLambda = tagLambda
    , tagMark = tagMark
    , tagPrim = tagPrim
    , tagError = tagError
    , tagVector = tagVector
    , tagStream = tagStream
    , tagFloat = tagFloat
    , tagRecord = tagRecord
    }



-- ==================== THE WORD ARM (VR3b1): THE SECOND INSTANCE ====================
-- `wordLayout` is the 8-byte TAGGED-WORD representation of
-- handoff-valrep2-plan §2(a): ONE WORD per value, and the LOW 3 BITS are the
-- tag (a cell is 8-aligned, so those bits are free in a pointer):
--
--     ...000  fixnum        i61; an i64 result that does not fit is BOXED onto
--                           the heap (one overflow check per arithmetic op,
--                           the V8/SMI shape)
--     ...001  heap pointer  EVERY heap object — cons, string, symbol, vector,
--                           float cell, lambda/closure, record, stream, prim.
--                           The object's KIND stays in the 2-word GC HEADER,
--                           which DOES NOT MOVE; only the body strides shrink.
--     ...010  nil
--     ...011  true   } the record carries ONE boolean tag, so only `true` has
--     ...100  false  } a field today (see WHAT IS NOT EXPRESSIBLE, below)
--     ...101  error
--     ...110, ...111        reserved
--
-- BODY STRIDES: a cons cell is 32 B (the 2-word/16-byte header plus 2 body
-- words), a vector is 8n+16, a values-table row is 16 B, a frame slot is 8 B.
-- (VR3c AREA 1 CORRECTED this line: it read "a cons cell is 24 B", which is
-- 16 B of header plus ONE body word — the arithmetic of a 1-word header.  The
-- header is two words in both arms, so the word-arm cons is 32 B; `bodyWords`
-- above is the one statement of the rule and TestMain pins it.)  The 2-word GC
-- header (mark/kind/class/RS/forwarding) is UNTOUCHED — that is what keeps the
-- collector's block map and class ladder out of this flip.
--
-- THE TWO THINGS THIS RECORD COULD NOT EXPRESS, WIDENED AT VR3b2 (as VR3b1's
-- note demanded before a single tag test was ported).  Both are stated as
-- per-instance FACTS, not as flags a reader may ignore:
--
--   * THE TRUE/FALSE SPLIT.  The val arm has ONE boolean tag plus a payload
--     word (`booleanSplit = False`, and `tagTrue`/`tagFalse` both spell
--     `tagBoolean` because the split does not exist there).  The word arm has
--     TWO immediates (`booleanSplit = True`, `tagTrue = 3`, `tagFalse = 4`), so
--     a boolean test is `(w & 7) == 3` and a boolean WRITE is an immediate —
--     there is no payload word to read.  `tagBoolean` on the word instance is
--     the TRUE immediate and nothing else; a reader that tests it for false is
--     reading a field that cannot express false, which is why `booleanSplit`
--     exists and must be tested first.
--   * THE HEAP KIND.  `...001` says "a heap object"; WHICH object (cons,
--     string, vector, record, float cell, closure, stream, prim) is read from
--     the object's 2-word GC header, which does not move.  So under the word
--     arm every `tagCons`/`tagString`/... field READS 1 (the shared heap tag)
--     and a heap-object TAG TEST is not a tag test at all: it is a header-KIND
--     read (`heapTagIsKind = True`).
--
--     THE KIND CODE ITSELF IS NOT A FIELD OF THIS RECORD, and that is
--     deliberate (VR3c AREA 1): the code IS the object's ValTag integer, i.e.
--     the TOP-LEVEL `tagCons`/`tagString`/... constants at the head of this
--     file — NOT `wordLayout.tagCons`, which is the low-3-bit tag 1 that every
--     heap object shares.  Overloading the record's tag fields with the codes
--     would put two meanings on one field, so the codes stay in the one
--     numbering both arms already use and `heapKindShift`/`heapKindMask` (this
--     record) locate the header field that carries them.  See THE GC-HEADER
--     KIND CONTRACT above: the code set, the scan-bit derivation
--     (`heapKindScanned`) and the body-size rule (`bodyWords`).
--
-- `tagMask` is the mask that makes both statements usable: 0 on the val arm
-- (the tag is a whole word, so masking it would be a bug — a reader must branch
-- on the field), 7 on the word arm (`(w & 7)` is the tag).  It is a MASK and
-- not a bit count because every reader of it wants the mask, and a width that
-- each caller turns into a mask is a second place to be wrong.
--
-- THE WORKLIST — every construct the emitter and the Mid runtime still carry
-- for the 40-byte representation, i.e. everything VR3b2/VR3c must port before
-- the knob can be turned on.  This list IS the unit's deliverable:
--
--   1. THE FRAME SLOT STRIDE.  PORTED (perf VR3b2).  The prologue/epilogue
--      blits, the `valSizeBytes * nslots` alloc, the slot address table, the
--      param and capture blits and slot 0/1's materialisation (PLeaf) all read
--      the instance, so a Value copy is an 8-byte blit and the frame is 8 bytes
--      a slot.  Pinned in TestMain by the `id` probe on BOTH arms.  The `:val`
--      PARAMETER ABI moved with it: MEASURED on the vendored qbe, a 40-byte
--      aggregate param arrives BY VALUE ON THE STACK and an 8-byte one IN A
--      REGISTER, so a `:val` CALL ARGUMENT built from an `l` operand is that
--      operand's ADDRESS only at 40 bytes — `rt_callN`/`rt_call2r` load each
--      pointer before passing it under the word arm.
--   2. TAG WRITES AND TESTS.  THE IMMEDIATE HALF IS PORTED (perf VR3b2).
--      `readTag` (Mid.Qbe.Lower) is the ONE place a tag is read: val =
--      `loadw` of the tag word, word = `loadl` + `and tagMask`.  Ported on top
--      of it: the boolean condition test in `lowerIf` and the shared
--      `jmpfFalse` helper (`&&`, `||`, `/=`, one match arm); and the WRITES for
--      the immediates in `lowerLitWord` (a fixnum `n * 8` inside i61, and a
--      BOXED cell outside it since perf word-arm-area4 — `bigLiteralFitsFixnum`
--      decides on the DIGITS and `boxWordInt` builds the code-13 cell;
--      `true`/`false` = tagTrue/tagFalse) plus `storeNil`.  THE HEAP-OBJECT HALF IS PORTED (perf
--      word-arm-area3rt/word-arm-surface): every heap tag collapses to
--      `...001`, so a heap-object test is a 2-word-HEADER KIND read
--      (`heapTagIsKind`), and `wordTagIs` is the ONE reader of it — it
--      dispatches on `wordTagShape`, answering an IMMEDIATE valtag with a
--      word-tag compare and a heap one with a kind compare, and refusing a
--      valtag that has no word encoding by name.  `readTag` is still the one
--      place a tag is READ; `wordTagIs` is the one place a VALTAG is tested.
--      NOT PORTED: `storeValueCell`'s heap writes — whether a CODE is writable
--      is `wordCellRefusal`'s single statement (a body the emitter lays out
--      itself would put val-arm raw pointers into a body the collector scans).
--      The .mid surface lane's `RawTagIs`/`RawMkValue` are also un-ported
--      (Mid.RtLang.LowerToIr names `valLayout` at 9 sites — VR3a's finding;
--      that lane lowers BEFORE Lower runs, so its tag integers are baked into
--      the Mid.Ir under any knob).
--   3. PAYLOAD ACCESS.  Every `payloadWordOffset` read/write: cons car/cdr,
--      string/vector `len`, record fields, float payload, argv, the exec-plan
--      blob.  Under the word arm a field is a plain 8-byte load at 8i, and a
--      fixnum's value is the word arithmetic-shifted.
--   4. ARITHMETIC.  PORTED (perf word-arm-arith), and ported as a
--      CLASSIFICATION rather than by writing inline tag/untag: `lowerArith`/
--      `lowerCompare`/`lowerNumEq`'s generic tails are a VAL-ARM SHAPE (the tag
--      word at `slot + 0`, the payload at `slot + 8`), so under the word arm
--      each of the three SKIPS its tail and calls the runtime through
--      `rtPrimSlots` — `Rt.+`/`-`/`*`/`/`/`<`/`=` read their operands with
--      `payload`/`payload32`/`tagis` and write with `mknum`, so they are
--      arm-clean by construction.  `+ - *` WRAP at i64 (L3) for every result
--      inside i61; a result outside it is a LOUD named refusal from `mknum`'s
--      round-trip check, because the i61 overflow/boxing path is NOT ported
--      (below).  `//` (prim `/`) was already on this route — `Rt./` carries
--      L3-U2's two named halts (zero divisor, INT64_MIN // -1) and they are
--      NOT duplicated here; `negate` is Mid/FromAst's `0 - x` desugar, so it
--      needs no prim.  There is NO `%`/modulo operator in this language at all
--      (`binaryPrims` maps `//` to the prim `/` and defines none), so nothing
--      was ported for one.
--      THE i61 OVERFLOW/BOXING PATH IS PORTED (perf word-arm-area4), and it is
--      the piece that makes this item COMPLETE for integers.  `storeWordCell`'s
--      fixnum arm keeps its ROUND-TRIP check (`w << 3 >> 3 == w`, the ONE check
--      per arithmetic write, and on this arm every `+ - * / ^` closes with a
--      `mknum`, so there is no inline arithmetic left for a second check to
--      guard) and its FAILURE BRANCH is now `Rt.boxInt` instead of `Rt.die`: a
--      code-13 cell whose one body word is the raw i64.  Code 13 is the ValTag
--      gap, its scan bit is RAW by decision (`heapKindScanned` does not list
--      it), and `wordNumberTagIs` is what makes `tagis(v, 0)` answer for BOTH
--      encodings — without that the printer and `=` would stop seeing a boxed
--      value.  The round trip is also what makes the change SAFE for the
--      seat-return convention: a `mknum(ptr)` word is a user-space address
--      (below 2^47), so it round-trips and never boxes.
--      SEMANTICS: an op computes its result with i64 WRAP (L3) and boxing only
--      changes WHERE the i64 lives, so i61-plus-a-boxed-fallback REPRODUCES
--      wrap and does NOT widen the range.
--      NOT PORTED: the inline tag/untag (the runtime call is the route here,
--      not a slower spelling of it — a fast path would be a second arithmetic
--      to keep in step), and CHAR/STRING ORDERING (`"a" < "b"`), whose inline byte loop
--      reads a Value's byte pointer at `slot + 8` and its length at
--      `slot + 16` — it REFUSES by name at `lowerCompare`'s string branch,
--      because `Rt.<` answers False for every non-number and routing it there
--      would be the silent Char-ordering mislower that branch exists to
--      prevent.  FLOATS are item 5.
--   5. FLOATS.  PORTED (perf word-arm-floats): the heap-boxed `[hdr | f64]`
--      cell, the literal that builds it, `f/`, and the READ the whole class
--      stands on.
--      THE CELL AND THE LITERAL ARE ONE WRITER.  `storeWordFloatCell` (built by
--      perf word-arm-area3rt for the runtime's `mkflt` lane) allocates through
--      `Rt.allocFloat`, stores the f64 at body unit 0 and tags the body; the
--      literal arm of `lowerLitWord` loads the double from the shared `flt:`
--      static data item and hands it to that writer, so the two arms' literal
--      paths differ only in WHO writes the Value (`reboxFloat` there, the cell
--      writer here).
--      THE FRESH DEFECT THE ADMISSION EXPOSED WAS THE READ, NOT THE CELL:
--      `RawLoadFlt` (`fload`) read `slot + 8` unconditionally — the val arm's
--      payload shape, which on this arm is THE NEXT FRAME SLOT — and every float
--      reader in the runtime goes through it (`Rt.asF`, `Rt.toI32`,
--      `Rt.fRender` hence `Rt.floatText` and the printer, and the float arms of
--      `Rt.+ - * f/ < <= > >= =`).  It is forked to `wordFloatPayload`: untag,
--      body unit 0, `loadd`, with a NAMED `Rt.die` for a word that is not a heap
--      object.  MEASURED with the fork off: SIGABRT (134), empty stdout.
--      THE `mk*` SAFEPOINT TRAP IS DISCHARGED, AND THE INSTRUCTION THIS ENTRY
--      CARRIED IS NOW A FACT IN ONE PLACE.  `Mid.Rt.unsafeSafepoint` treats a
--      `RawMkValue` as a non-safepoint only when the arm's cell writer allocates
--      nothing; the arm is threaded into the walker (`loadArm` -> `loadText` ->
--      `directArm`/`safepoint`/`unsafeSafepoint`) and the answer is
--      `wordMkAllocSeat`, which names `Rt.allocFloat` for `tagFloat` and NOTHING
--      for every other code — `mkstr` allocates nothing since perf
--      word-arm-rawroot put the bytes inline in the block `Rt.allocRaw` already
--      made, which is the part of this entry's old wording that had gone stale.
--      A row pins it per arm in both directions, on the real defun (`Rt.asF`:
--      ROOTED on the word arm, frame-free on the val arm) as well as on
--      synthetic `mkflt`/`mkstr` probes.  THE CHURN LADDER IS COVERAGE, NOT THE
--      PROOF, and that is measured: with the arm reverted to non-safepoint, all
--      four `flt` rungs stay GREEN, because every current `.mid` `mkflt` site
--      consumes its live value BEFORE the allocation (safe by order).
--      THE THIRD PLACE THE `mk*`-AS-SAFEPOINT RULE HOLDS, and it is item 4's
--      arrival that made it the third: a `mknum` can now BOX, so
--      `wordMkAllocSeat` answers `Rt.boxInt` for `tagNumber` too and a defun
--      whose only allocation is a `mknum` is ROOTED.  The literal node needed
--      its own answer as well, because the table is keyed by CODE and the two
--      number literal FORMS differ — see `Mid.Rt.safepoint`'s `LNumberBig` arm,
--      which reads the SAME `bigLiteralFitsFixnum` the emitter does.
--      STILL NOT PORTED IN THIS AREA: the raw-`d` LOCAL lane (`isFloatExp`
--      denies it under this arm, because `reboxFloat` writes the 40-byte shape).
--   6. THE `:ret` AGGREGATE.  Its FIRST FIELD IS A VALUE, so its tail offsets
--      move with `valSizeBytes` (they are DERIVED below); plus the 80-byte sret
--      path, slot 1's `.tail` metadata and rt_bounce.
--   7. THE Rt SURFACE (`runtime.mid`).  PARTLY PORTED.  The blanket area-7
--      refusal this entry used to describe is GONE (perf VR3b3 replaced it with
--      a per-defun pre-walk: `wordRtUnported` names the DEFUN and the CONSTRUCT
--      the arm stops at), so the entry's job is now to say which strides are
--      twinned and which are not.
--      PORTED: gcAlloc's `2 + count + 4*count*kind` sizing (the word arm's
--      `2 + count`), the six header writers, gcPromoteAlloc, gcScav/
--      gcScavValueArray/copyWordsGo, the values-table builder and walk, the
--      allocation seats (`allocKind`/`allocCons`/`allocSym`), the closure CELL
--      (`Rt.closure`, `Rt.applyPartGo`'s cell), and — perf word-arm-closures —
--      `Rt.globalClosure`'s CELL — the per-descriptor closure cache — which
--      had never been EXECUTED and was measurably wrong (it answered a
--      fixnum-shaped closure and wrote its header eight bytes off).  It is
--      reachable WITHOUT the `GRef` construct: `lowerApp` materialises a global
--      closure for any UNDER-APPLIED global head, and `App` is admitted.
--      THE CALL STAGING: `Rt.stage-apply`'s block, `Rt.apply-tail`'s shape
--      guard and `state->args`, `Rt.applyGo`/`Rt.applyTailGo`'s
--      `args + rem*40`, and `Rt.applyPartGo`'s three-range interleave.  That
--      last group is the one VR3c's frontier note called "VR3d's"; there is no
--      VR3d, and closures cannot RUN without it, so this unit took it.
--      THE STRING FAMILY IS CLOSED (perf word-arm-rawroot item 1).  A word-arm
--      string's BYTES are now INLINE in its own cell (units 2..; unit 0 is the
--      cell's own byte base, unit 1 the length), so the two-block shape that was
--      unsound in two independent ways is gone: the byte block was reachable
--      only through a body the collector never walks, AND the byte pointer was a
--      raw word held across `mkstr`'s own allocation.  `Rt.allocRaw` reserves the
--      two units WITH the bytes and returns the byte base; `mkstr` allocates
--      nothing; `Rt.gcScavPtr` re-derives the self-address on promotion behind
--      the ownership test (a literal's cell names static data).  MEASURED,
--      silently rc=0, before: 154 of 6000 surviving `String.join` strings at
--      QBE_HEAP_MB=1 and 5699 at DEFAULT knobs (the val arm answers 6000 both
--      ways); after: 6000, and tools/qbe/word-arm-gcchurn/str.elm is the row.
--      `Rt.globBuildGo`'s `bufW` (the class's fourth pair-instance) is CLOSED on
--      BOTH ARMS NOW, and the two arms were not the same defect: `mkstr` allocates
--      nothing, and the string value is bound BEFORE the two `Rt.intern` calls on
--      the recur line.  WORD ARM: `intern`'s HIT path allocates a symbol cell
--      (`allocKind(2, 1)`), so the buffer really was live across two scavenge
--      points — a live window, fixed by the binding.  VAL ARM: `intern`'s HIT
--      path returns `mkval(2, hit)` and its MISS path (`intInsert` ->
--      `intInsertAt`) mallocs its name and returns `mkval(2, store)` — MEASURED,
--      `q_Rt_x2eintern`'s transitive closure in the val-arm artifact is 11 defuns
--      and contains NO `gcAlloc` (its only callers there are allocRaw and
--      allocVector), so this arm CANNOT collect inside `intern` and the window
--      was EMPTY — empty BY INVARIANT (intern staying allocation-free), not by
--      order, with the two arms one edit away from agreeing.  The binding makes
--      the safety STRUCTURAL on both arms, which is why it is now ONE shared
--      statement instead of two arm splices (perf word-arm-rawroot item 3 FIX's
--      review, SHOULD-FIX; it moves the val-arm emit, so it carries its own
--      re-freeze: 125 of 159 corpus groups, the set that DEFINES the changed
--      defuns, by set equality).
--      IT STILL HAS NO COLLECTING ROW, and that is a REACHABILITY fact, not an
--      omission: the only route to `Rt.glob` is the effect host's TaskGlob, and a
--      `Platform.worker` program does not lower on the WORD arm at all — MEASURED,
--      `err qbe: unknown global referenced: M.main` for tests/elm-fixtures/
--      execglob.elm, execenv.elm and progio.elm under QBE_VALREP=word (the VAL
--      arm compiles and runs execglob, which is how the order above was read).
--      The row is owed by the unit that twins the EXEC-PLAN / EFFECT-HOST blob
--      below.
--      `Rt.recAppend` IS FIXED (perf word-arm-rawroot item 3 FIX, a0c80c5), and
--      the entry it replaces was WRONG IN THE DIRECTION THAT MISDIRECTS, so the
--      correction is stated rather than quietly rewritten.  What this entry said
--      (b306ef0): "NOT REACHABLE FROM THE SURFACE ... LATENT on the val arm",
--      justified by a measurement showing that `{ r | c = i }` — the `=` UPDATE
--      syntax — is a TYPE ERROR on a missing field.  THE MEASUREMENT WAS REAL AND
--      THE INFERENCE WAS TOO WIDE: the surface ALSO has RECORD INSERTION
--      `{ r | x <- v }` (Type/Infer.elm's free row extension; committed fixture
--      tests/elm-fixtures/insrec.elm), and a ROW-POLYMORPHIC `ins r i = { r | x
--      <- i }` makes the update's base a non-closed Var, so Lower takes the WALK
--      arm (applyUpdates -> `recInsert` -> MISS -> this defun) — the very miss
--      arm the entry claimed no admitted construct could build.  THE LESSON,
--      recorded because it is the class this repo keeps paying for: before
--      re-drawing a "latent / not reachable" line, enumerate the SURFACE
--      SYNTAXES that reach the defun, not the one that was tried.
--      SO IT WAS LIVE ON THE VAL (DEFAULT) ARM, and it SEGFAULTED: 6000
--      insertions kept reachable and CONTENT-compared gave QBE_HEAP_MB=1
--      SEGFAULT (rc 139), h2 SEGFAULT (rc 139), h4/h8 5999 of 6000 (one silently
--      wrong record), default 6000 of 6000.  The control that isolates it: the
--      same churn with `y <- i` on an EXISTING field always HITs (`Rt.recUpd`,
--      ONE allocvec, no window) -> 6000 of 6000 at h1 and h2.
--      TWO DEFECTS IN ONE SHAPE, and they had to be fixed together:
--      (1) `word nd = allocvec(..); val ndN = mknum(nd); word nn = allocvec(..)`
--          held `nd` as a RAW WORD across the second allocation, and `mknum` does
--          NOT root it — a FIXNUM is not relocated;
--      (2) the fills came LAST, so once (1) was fixed the array was ROOTED BUT
--          EMPTY when the second allocation collected: promotion copies an
--          unwritten body (the allocator does not zero a block, and a forwarded
--          young body's word 0 is the POISON 15) and the drain walks that garbage
--          as Values — MEASURED, loudly: "scavenge read a POISONED (forwarded
--          young) body" at h1/h2/h8.  THE ROOT TURNED A SILENT WRONG ANSWER INTO
--          A LOUD ONE, which is what exposed the second half; a fix that only
--          roots the cell is INCOMPLETE.
--          PRECISION, so nobody leans on loudness later: that is the COMMON case,
--          NOT a guarantee.  `gcScavPtr` poisons a forwarded body's word 0 with
--          15, and a garbage cell-0 tag in {0, 2, 3, 5, 7, 8, 11, 12} scavenges as
--          a NO-OP and stays SILENT; the loud fire needs the recycled word to be
--          exactly 15 (dead young memory retains the old poison, which churn
--          reliably supplies).  THE STRENGTH OF THIS FIX IS FIX-BY-ORDER — fill
--          before the next allocation — not the poison walk, which is only an
--          instrument that happened to fire.
--      `Rt.recUpd` NOW USES THE SAME HOLDER (its review's NICE-TO-HAVE): it was
--      SAFE BY ORDER — ONE `allocvec`, fill before any allocation, pinned by the
--      control row — but `mknum(nd)` is the exact textual shape that was a silent
--      reclaim here, so the day it grows a second allocation it becomes the same
--      bug.  Uniform discipline instead of a local argument.
--      THE SHAPE NOW: root each cell as a `:val` binder (`mkval(10, ..)` — a
--      frame slot the frame-enter root array scans), FILL IT through
--      `vecbody(..)` while nothing can allocate, and only THEN allocate the
--      second cell; every later read goes through `vecbody(..)` because a root's
--      ADDRESS MAY MOVE.  The corpus moved by exactly 5 groups (insrec, mxint,
--      records, rowgadt_setx, scopedup — the set of groups whose .ssa mentions
--      `recAppend`, by set equality over all 159) and the re-freeze is
--      deliberate and attributable.  ROW: tools/qbe/fixtures/recinschurn.elm +
--      qbe-check's `run_heap_ladder` (h1/h2/h4/default), proven fail-able.
--      PORTED SINCE (perf word-arm-corpusrun): the ARGV INSTALL
--      (`Rt.parseArgsGo`'s `bufW + j*40` and `Rt.main`'s `a1 .. a15`).  This
--      entry used to call it "a separate lane, reached-but-unexercised" — and
--      the frontier doc's P bullet went further and called it CORRECT on both
--      arms.  BOTH READINGS WERE WRONG, in the direction that drops live
--      values: the pitch is read by a KIND-2 GC ROOT whose count is `nargs`
--      and whose scan stride is the layout's, so at a 40-byte pitch the word
--      arm's root covered `[abuf, abuf + 8*nargs)` while the args sat at
--      `40 * j` — arg 1 was outside the root for `nargs <= 5`.  Twinned in the
--      same unit that MEASURED it (both sides, both arms, pinned by two
--      TestMain rows and by the corpus run's 120 argument vectors); the
--      frontier's "THE ENTRY-ARGS ROOT GAP" section carries the verdict, the
--      evidence and the part no collection can reach today.
--      NOT PORTED: the EXEC-PLAN / EFFECT-HOST blob (its stride is
--      `sizeof(val)` as the .mid front end computes it, i.e. 40 under ANY
--      knob — see the frontier note at `Rt.kindHdr`); and the printer internals
--      where they read a payload without the layout-derived accessors.
--   8. THE C FFI GLUE.  The tag/untag at the boundary — a fixnum's payload IS
--      the C i64 after untag, and Values never cross raw (the extern
--      declarations already encode C widths, so nothing there moves).
--   9. THE MID.Ir CONSTRUCT LANE (perf word-arm-surface) — the SURFACE of the
--      Mid language, as opposed to item 7's runtime.  `Mid.Qbe.Lower`'s
--      `wordArmUnported` is the belt: a defun carrying an un-ported construct
--      refuses BEFORE its body walk, and the entry names the construct and the
--      area.  PORTED: literals, `Var`, `Let`, `If`/`&&`/`||`, `Loop`,
--      `App`, and — via their desugars — `ListLit`, `Tup` and `Case` (the
--      aggregate prims `cons`/`@p`/`emptylist`/`assoc`/`snd` reach the
--      runtime's own twinned defuns through `rtPrimSlots`, which is
--      arm-independent by construction), plus the payload chases behind them
--      (`fieldBase`, one accessor: the val arm's payload word HOLDS a pointer,
--      the word arm's IS the element).  SYMBOL LITERALS are PORTED (perf
--      word-arm-records R1): a word-arm symbol is a code-2 block whose body is
--      ONE raw word, the NUL-terminated name pointer — the shape `Rt.intern`
--      already builds, so a literal and an interned symbol agree (`symEq`/
--      `symLess`/`pvZ` walk the bytes and no length reader exists; a two-word
--      literal would have made a future one an OVERRUN on the interned shape).
--      The CODE is the constructor on this arm, so the cell comes from
--      `Rt.allocSym` (code 2) and never from the string seat (code 1) — a
--      symbol indistinguishable from a string is the mixed-representation read
--      this arm exists to prevent.
--      CLOSURES ARE PORTED (perf word-arm-closures): `Lam` (an inner lambda ->
--      `lowerClosure`: contiguous capture staging in ROOTED frame slots, the
--      closure's own QBE function through `lowerFunBody ... RtGeneric`, one
--      `Rt.closure(desc, capBase, K)`) and `GRef` (a value position ->
--      `lowerGRefValue`'s `Rt.globalClosure(desc)`; a forced one is a direct
--      call).  What made them one class and not two: a closure's ENV ARRAY is
--      the only thing the two arms disagree about, and both emitters already
--      spell its stride as `valSizeBytes` (`captureBlits`, `capBlitsPro`) — the
--      emitter needed no change at all.  The RUNTIME did: the closure CELL was
--      twinned (Rt.closure / Rt.applyPartGo) but the CALL STAGING was not
--      (`Rt.stage-apply`'s block, `Rt.apply-tail`'s `+40` shape guard,
--      `Rt.applyGo`/`Rt.applyTailGo`'s `args + rem*40`, `Rt.applyPartGo`'s
--      three-range interleave), and `Rt.globalClosure`'s twin had never been
--      EXECUTED — it returned a fixnum-shaped closure and wrote its header
--      eight bytes off.  See item 7's correction below.
--      RECORDS: THE BLOCK, THE BUILD AND THE READ ARE PORTED (perf
--      word-arm-records R2/R3).  The layout is ONE code-14 heap block whose
--      body is `[data_0 .. data_{n-1} | namesBase]` — the field VALUES in
--      canonical order, then ONE raw word, the address of the field-NAMES array
--      — with the header count `n + 1`.  NAMES LAST is load-bearing: it keeps
--      `vecload(vecbody(rec), i) == data[i]` on BOTH arms, so the positional
--      read (`recordAccessBody`) needs no fork at all and every arm fork is
--      confined to the NAMES side.  The price is that every record LENGTH
--      reader answers `veclen - 1` (`Rt.pvRec`, `Rt.recEqGo`, `Rt.recGetGo`);
--      a bare `veclen` bound reads the names word as a field and, on a WRITE,
--      runs into the NEXT heap block.  `Rt.allocRecord` owns the `+ 1` and
--      `Rt.recGetGo`'s word splice owns the names-base read
--      (`vecload(vecbody(rec), veclen(rec) - 1)`) — there is no third
--      spelling.  Kind 14 was already in `heapKindScanned`, so the collector
--      needed no change.
--      THE RECORD FAMILY IS **NOT** COMPLETE, AND THE CLAIM THAT IT WAS IS
--      WITHDRAWN (perf word-arm-records R4 review BLOCKER 3).  The READ, BUILD
--      and UPDATE constructs all EMIT and the one-shot fixtures are green on
--      both arms, but the word arm's `Rt.recAppend` FAILS UNDER CHURN at
--      QBE_HEAP_MB=1, and that row is now WIRED so the claim cannot drift again:
--      `tools/qbe/word-arm-gcchurn/rec.elm` (6000 insertions, each kept
--      reachable and content-compared through a whole-record `==` AND a field
--      read) prints 6000/6000/0 on the val arm at both heaps, 6000/6000/0 on the
--      word arm at DEFAULT knobs, and SEGFAULTS on the word arm at h1.
--      WHAT WAS FOUND AND FIXED BY IT: an old-to-young store with no write
--      barrier (the names block allocated AFTER the record, so a promotion at
--      the names allocation left the record old and its names base young) —
--      fixed by allocating the names block FIRST; and, before that, a
--      rooted-but-unfilled body word promoted as garbage — fixed by filling the
--      record before any further allocation.  WHAT IS STILL OPEN: the h1
--      failure survives both, and survives the names block being SCANNED
--      instead of raw (which segfaults for a different reason: a name pointer is
--      not a Value-shaped word), so the remaining window is neither the fill
--      order nor the scan bit nor the allocation order.  THREE ATTEMPTS HAVE
--      FAILED; the next one should start from the churn row, not from a
--      hypothesis.
--      **RESOLVED (perf word-arm-records H1 FIX).**  The three attempts failed
--      because each worked INSIDE the defun: the defect was the defun's FRAME
--      CLASS.  `runtime.allocating`'s fixed point was seeded only from `direct`
--      bodies (a defun containing an `allocvec` PRIM), and in the Rt lane a
--      `call` is an EDGE — so no seat was reachable from the seed, every seat
--      CALLER classified `RtLeanFree`, and `Rt.recAppend`'s `rec` sat in an
--      unrooted `alloc8` frame the scavenger cannot see.  FIXED at the root:
--      `Mid.Rt.allocationSeats` is a separate growth source for the fixed point
--      and `allocSeatDeps` carries the seat call edges (its own table, because
--      `rtDeps` also drives emit-reachability and the seats are WORD-ONLY).
--      MEASURED after: `rec/h1 h2 h4 default` all `6000/6000/0` on BOTH arms,
--      `recupd/h1 h2 h4 default` all `20000/20000/0`, corpus .ssa BYTE-IDENTICAL
--      159/159 (no re-freeze).  THE CLASS AUDIT — every word-arm Rt defun that
--      allocates, with its MEASURED frame class and verdict — is in `Mid/Rt.elm`
--      above `allocSeatDeps`, and it is taken PER ARM AND DIFFED — `allocating`
--      is computed from the spliced program each arm loads, so the two arms are
--      DIFFERENT SETS and a single-arm dump cannot see the class, which IS an arm
--      asymmetry.  Two defuns differ between the arms: `Rt.mkStream` (ROOTED on
--      the word arm and the one seat that MUST be — it reads its `:val` params
--      after its own `allocKind` call) and `Rt.absvector` (frame-free on the word
--      arm, safe by non-use, and MISSING from the first version of the table
--      because that dump was not per-arm).  The oracle that pins the class:
--      `q_Rt_x2erecAppend`/`q_Rt_x2erecUpd` must open with a pooled-frame call and
--      no `alloc8`, and every seat key is asserted over the WORD load's
--      `allocating` with `Rt.mkStream` as the stated exception.
--
--      A LANDMINE FOR THE NEXT UNIT (perf word-arm-records H1 review FINDING 6,
--      recorded not fixed): the seat split also feeds `noCollect`
--      (`Lower.elm`'s complement of `allocating`), so a FRAME-FREE seat caller is
--      "cannot collect" for `Liveness` on the word arm — INCLUDING when a SURFACE
--      defun calls it.  Surface defuns are saved today by an UNDOCUMENTED
--      accident: a lean seat call passes a frame-slot ADDRESS, `escapesOf` counts
--      that as an escape, and the frame is kept.  MEASURED with two adversarial
--      word-arm probes (a nested record literal, and a record held across
--      `vectorMake` — scratch `osier-scratch/absvec/`): both emit `frame-enter`
--      and pass 6000/6000/0 at h1 with 12 scavenges.  If the lean ABI ever stops
--      passing slot addresses, that protection vanishes with NO oracle naming it.
--      The fix is one comment at `noCollect`/`escapesOf` pinning the dependency,
--      or a row; it belongs to the unit that next touches either.
--      THE READ, BUILD AND UPDATE HALF, stated with the same honesty (perf
--      word-arm-records R3/R4).  The UPDATE
--      half landed as the same one-block build: `lowerRecordUpdateClosed`'s tag
--      tests go through a `recordTagBranch` seat (`wordTagIs` here, the val
--      arm's `Load W` + `Cmp` there), its field COPY goes through `fieldBase 0`
--      + `elemAddr` instead of the val arm's `slot + 8` payload indirection and
--      `* valSizeBytes` stride, its allocation is `Rt.allocRecord(n)` and its
--      wrap is the literal build's.  The runtime's nine twins
--      (`recUpd`/`recUpdFind`/`recUpdCopy`/`recAppend`/`recAppendFind`/
--      `recAppendDataGo`/`recAppendNamesGo`/`recToChain`/`recToChainGo`) bound by
--      `veclen - 1` and MASK the names base (`nw - (nw & 7)`), because a
--      literal's names array is a static `...000` address the collector's body
--      walk skips as a fixnum while a runtime-built one MUST be stored `base + 1`
--      (`gcScavValue` does NOTHING for tag 0 — the block would be reclaimed and
--      the record left with a dangling names base, silently).  A runtime-built
--      names block is a code-1 raw word array, and the naming lie is stated at
--      the site: code 1 buys the SCAN BIT, which is the only property the
--      collector reads.  `Rt.recInsert` needs no twin (it forwards).
--      THE RECORD-SIDE CENSUS IS CLOSED (perf word-arm-records THE CEILING,
--      Part B).  FOURTEEN record shapes probed directly on the word arm —
--      literal, walk read, positional read, closed update, open-row update,
--      insertion, duplicate labels, `{ x, y }` pattern, `Record.remove`, a
--      nested literal, a record in a list, `==` on records, `{}` field access,
--      and a field of a call result — and THIRTEEN EMIT.  The one refusal,
--      `{}.x`, is `err type error at 2:8: missing field x` on BOTH arms: a
--      LANGUAGE rule, not an arm refusal, so it is not this arm's to port.  So
--      there is NO remaining record-side construct refused by name, which is
--      what the empty `wordArmDefunRefusals` below says and what the behavioural
--      rows confirm: `word-arm-diff` 21/21 and the `rec`/`recupd` heap ladders
--      green on both arms at h1/h2/h4/default WITH real collections (val
--      36/28/18/0 and 46/36/26/3, word 30/18/8/0 and 44/32/20/1).
--      `wordArmDefunRefusals` IS EMPTY — the refusal LIST is empty, which is a
--      statement about the classifier's by-name gate and NOT about correctness.
--      The correctness statement is the paragraph above (the record churn
--      ladders, green WITH real collections on both arms).  PROVENANCE OF THIS
--      PARAGRAPH: it was written when the churn row WAS red at h1 — the review's
--      blocker 3 caught the empty list and the COMPLETE claim sitting above a
--      red fixture, and the distinction was correct THEN.  It was reconciled in
--      the same arc: the H1 close-out fixed the classification gap, the churn
--      row went green, and the ladders now carry real collections on both arms.
--      If a future change reddens the churn row again, this paragraph must be
--      re-marked at the same time — an empty refusal list and a red fixture must
--      never coexist unnoticed, which is exactly what happened here once.
--      NOT PORTED, refused by name: `StreamRef` — AND IT IS THE ONLY ONE.  A
--      float literal, `f/` and `let`-destructuring all left this list in perf
--      word-arm-floats and perf word-arm-letdestr, each as an ADMISSION whose
--      stated reason had gone stale.  `StreamRef` is here as the classifier's
--      remaining control rather than as a planned port: its site is
--      `lowerLit (LSymbol v)` + `rtPrimSlots "value"`, i.e. ported pieces, but
--      the 14 corpus groups whose defuns contain one have never been RUN on this
--      arm, and admitting a construct on emit-only evidence is the mistake the
--      let-destructuring unit paid for.  See `wordArmUnportedList`'s `App` arm
--      for what enabling the argument walk would cost.
--      `Con` AND `MTagEq` LEFT THIS LIST (perf word-arm-frontier), and the way
--      they left is the entry's own lesson.  Both were blanket refusals whose
--      STATED REASON had gone stale under them — `Con`'s said "its vector is
--      written through `storeValueCell`", which is true only of the HEAP arm of
--      that writer and `lowerCon` calls it with `tagNumber` (an IMMEDIATE, whose
--      word-arm arm is the `shl 3` `mknum` wrap the closure ABI already uses),
--      and `MTagEq`'s said "the tag is materialised as a `symbol` literal",
--      which R1 had already ported.  MEASURED BEFORE PORTING: the two classes
--      were 41 and 39 of the 51 blocked corpus groups by first refusal, and
--      admitting both moved the word arm from 74 to 88 compiling groups out of
--      159 — the largest single move this arm has had.  What actually remained
--      was ONE accessor-sized decision, not a representation: `lowerMatch`'s
--      MTagEq inline compares PAYLOAD POINTERS at `slot + 8`, which on this arm
--      is the NEXT FRAME SLOT, so this arm runs the runtime's `=` instead (byte
--      equality, correct without the `sym:` pointer-identity licence the inline
--      rests on).  `Con` needed NO emitter change at all.  THE LESSON, stated
--      because this is the third class to leave a stale refusal behind it (the
--      arithmetic family was the first): a blanket refusal is a claim about the
--      ARM at the time it was written, and nothing re-tests it — so a construct
--      that reaches the top of the refusal ranking must be RE-MEASURED, not
--      re-read.
--      THE FRONTIER, MEASURED AGAIN AFTER THE FLOAT/F/ PORT (perf
--      word-arm-floats, `tools/qbe/word-arm-refusals.sh --groups`): 118 groups
--      compile on both arms (74 -> 88 -> 107 -> 118 over this arc's four ports),
--      34 refuse identically on both, and SEVEN are word-blocked — all of them
--      by ONE class, the host program path (`Runtime.program`, refused by name
--      since perf word-arm-letdestr).  So the classifier's remaining classes are
--      GONE from the census: the frontier is no longer a construct list, it is
--      the host blob's val-arm stride, which is a runtime.mid layout job.
--      THE PER-DEFUN VIEW IS NOT THE WHOLE STORY, and the last two units
--      measured the difference twice: 26 let-destructuring groups were
--      "26 alone" and 19 moved, because 7 emitted cleanly and were WRONG at run
--      time; and the App-argument walk (which the classifier still does not do)
--      was measured in this unit to turn 5 groups out of BOTH into WORD-BLOCKED,
--      because `StreamRef` reaches it.  A census reads EMITS.
--      ARITHMETIC IS NOW PORTED (perf word-arm-arith; see item 4): `+ - *`,
--      `< <= > >=`, `=` and `/=` are ADMITTED, because the three inline
--      lowering functions skip their 40-byte tails under this arm and call the
--      runtime instead.  `/=` (`NotEqual`) was listed here as NOT PORTED and
--      the reason given was right — "porting it means porting that inline" —
--      and that is what happened.  A row pins the admitted set BY NAME, so a
--      prim losing its admission is RED rather than silently changing a count.
--      THE REFUSAL NOW NAMES EVERY BLOCKER (perf word-arm-frontier), and that
--      is an INSTRUMENT change, not a relaxation: `wordSurfaceUnported` and
--      `wordRtUnported` return LISTS.  The first-only form reported whichever
--      blocker came first in key order, so the 26 groups above looked
--      `MTagEq`-blocked when every one of them also applied `Ok`/`Err`/`Just` —
--      a ranking cannot be built from a first element.  A non-empty list still
--      refuses before any IL is produced.
wordLayout : ValLayout
wordLayout =
    { valSizeBytes = 8
    , valuePayloadWords = 0
    , payloadBase = 0
    , wordBytes = wordBytes
    , valueTagBytes = 0
    , valQbeFields = [ "l" ]
    , maxArity = maxArity
    , tagMask = 7
    , tagBits = 3
    , tagTrue = 3
    , tagFalse = 4
    , booleanSplit = True
    , heapTagIsKind = True
    , heapKindShift = heapKindShift
    , heapKindMask = heapKindMask
    , tagNumber = 0
    , tagString = 1
    , tagSymbol = 1
    , tagBoolean = 3
    , tagCons = 1
    , tagNil = 2
    , tagLambda = 1
    , tagMark = 1
    , tagPrim = 1
    , tagError = 5
    , tagVector = 1
    , tagStream = 1
    , tagFloat = 1
    , tagRecord = 1
    }



-- ==================== THE WORD ARM'S FIXNUM RANGE (VR3b2) ====================
-- A word-arm fixnum is an i61: the low 3 bits are the tag, so a value outside
-- [-2^60, 2^60-1] does not fit the tag-shifted word.  SINCE AREA 4 (perf
-- word-arm-area4) such a value is BOXED onto the heap — the overflow path
-- EXISTS, `storeWordCell`'s fixnum arm emits the `n * 8` round-trip test and
-- calls `boxWordInt` when it fails, and `mknum` boxes too — so this bound no
-- longer decides "refuse"; it decides WHICH PATH a value takes.  What it still
-- decides statically is the COMPILE-TIME literal: inside the range `n * 8` is an
-- exact i64 (no truncation, no overflow), so an in-band literal is emitted as
-- the fixnum shift, and a literal ABOVE 2^53 is rebuilt from its digits rather
-- than from a host double (the exact-parser work L3-U1 made legal).
--
-- The bound is EXCLUSIVE IN MAGNITUDE and stated once: a word-arm fixnum is an
-- `n` with `-wordFixnumLimit <= n < wordFixnumLimit`, i.e. 2^60.  It is not
-- written as the inclusive pair [-2^60, 2^60-1] because THIS COMPILER'S Int IS
-- A DOUBLE (the Elm runtime under node): 2^60-1 is not representable and rounds
-- UP to 2^60, so an inclusive upper bound compares equal to the first
-- out-of-range value and the check silently passes it — MEASURED at VR3b2, the
-- `2^60` literal was emitted as `n * 8` instead of being refused.  A bound whose
-- two spellings are the same number cannot express a range.
--
-- RE-SPELLED AT VR3d (the flip), which is the commit this note has been
-- deferring to: the product below was originally the only way to SPELL 2^60
-- (our own frontend rejected a 19-digit literal outright: "err parse failed"
-- from the self-host emit, every Elm-side gate green — MEASURED at VR3b2).  The
-- exact parser makes the plain literal legal, and it is now written as one
-- because a bound whose two spellings differ in kind invites the question this
-- note kept answering.  THE COST IS PAID IN THE SAME COMMIT: `gc:layout`
-- (`layout-census.sh --marker`) parses `name =` / `    <digits>` pairs, so the
-- re-spelling ADDS this constant to the census block and moves the ABI marker —
-- which is why `wordFixnumLimit` joined the census's MID_ONLY_NAMES and the
-- seed was re-frozen with it.  Nothing about the NUMBER moved (2^60 either way).
wordFixnumLimit : Int
wordFixnumLimit =
    1152921504606846976

{-| DOES A BIG LITERAL FIT THE WORD ARM'S i61 FIXNUM?  DECIDED ON THE DIGITS.

The bound is `Mid/RtLayout.wordFixnumLimit` (2^60) and it is EXCLUSIVE IN
MAGNITUDE: a fixnum is `-limit <= n < limit`.  It cannot be decided with host
arithmetic — this compiler's `Int` is a double, so 2^60-1 rounds UP to 2^60 and
the comparison would pass the first out-of-range value (the VR3b2 defect,
MEASURED).  So the decision is LEXICAL, on the same decimal digit string the
parser validated: strip leading zeros, compare lengths, then compare
lexicographically.  `String.fromInt wordFixnumLimit` is exact (2^60 IS
representable as a double), which is what makes the bound spellable as a digit
string at all.

`limit` itself fits when the literal is NEGATIVE (`-2^60 << 3` is INT64_MIN,
which sar-round-trips) and does not when it is positive (`2^60 << 3` overflows).
That asymmetry is the bound's whole content and it is stated once here.
-}
bigLiteralFitsFixnum : String -> Bool
bigLiteralFitsFixnum digits =
    let
        ( negative, magnitude ) =
            if String.startsWith "-" digits then
                ( True, String.dropLeft 1 digits )

            else
                ( False, digits )

        -- the decimal of `wordFixnumLimit`, exact on this host (a power of two)
        limitDigits =
            "1152921504606846976"

        leadingZeros str =
            if String.startsWith "0" str then
                1 + leadingZeros (String.dropLeft 1 str)

            else
                0

        normalised =
            String.dropLeft (leadingZeros magnitude) magnitude

        bound =
            if String.length normalised /= String.length limitDigits then
                String.length normalised < String.length limitDigits

            else
                normalised < limitDigits

        equalBound =
            normalised == limitDigits
    in
    if normalised == "" then
        True

    else if bound then
        True

    else if equalBound then
        negative

    else
        False




-- ============================ Desc ============================
-- `Mid.Qbe.Il.descType` is `align 8 { l, w, w }` — 16 bytes, which is
-- `descQbeFields` below and NOT restated here (a byte size this repo has no
-- reader for is a seat nobody sits in).  That QBE TYPE describes the Desc
-- PREFIX only (code pointer, static arity, capture count); the emitted
-- descriptor DATA carries one more word — `rt_global_closure`'s one-slot
-- value cache (`Mid.Qbe.Lower`: `{ DRef fn, w arity, w ncaps, z 8 }`) — so
-- the ABI OBJECT is 24 bytes and `tools/qbe/rt.zig`'s `Desc` extern struct
-- has four fields.  Both facts are recorded (the type's field list, the
-- object's size and field offsets) rather than one being rounded to the
-- other: the divergence is PRE-EXISTING, documented in rt.zig's own comment,
-- and inert — nothing allocates or indexes a `:desc`-typed value; the data
-- defs carry their own size and pointers to them are plain `l`.


descTotalBytes : Int
descTotalBytes =
    24


descCodeOffset : Int
descCodeOffset =
    0


descArityOffset : Int
descArityOffset =
    8


descNcapsOffset : Int
descNcapsOffset =
    12


descCacheOffset : Int
descCacheOffset =
    16



-- ============================ Meta (the entry table) ============================
-- `qbe_meta` is an array of rows emitted as
-- `{ l <name>, l <code>, w <arity>, z 4 }` — `tools/qbe/rt.zig`'s
-- `extern struct Meta { name, code, arity }` at align 8 is the same 24 bytes
-- (20 rounded to the stride).  The rows MUST live in one data symbol: their
-- 24-byte stride is then a property of the emitter, not of QBE's placement of
-- separate symbols (the bug the emitter's own comment records).


metaSizeBytes : Int
metaSizeBytes =
    24


metaNameOffset : Int
metaNameOffset =
    0


metaCodeOffset : Int
metaCodeOffset =
    8


metaArityOffset : Int
metaArityOffset =
    16



-- ============================ Ret (DELETED — AREA 6) ============================
-- `:ret` IS GONE.  U3b deleted the `.tail` protocol (the builder, both
-- chasers, `struct Ret`, the `Agg "ret"` result class, the 80-byte `@ret`
-- blit) and moved every closure body to `:val`; the one survivor was the WORD
-- arm's 48-byte `:ret`, and AREA 6 measured its stated justification FALSE.
--
-- THE MEASUREMENT (probe agg8.ssa against the vendored qbe): an 8-byte
-- aggregate return is REGISTER class, and `ret %s0` still means "the value AT
-- %s0" — qbe loads the word into rax and the caller's `%t =:val call` temp is
-- still the ADDRESS of a materialized 8-byte block, so the same IL text is
-- correct at both widths.  The exception's premise ("collapsing it would put a
-- slot address in a register") describes a NON-aggregate return; nobody was
-- proposing one.
--
-- So the word arm's body returns `:val` (8 B) like the value arm's (40 B), and
-- with the type went its last readers: `retQbeFields`, `retKindOffset` (whose
-- only reader was Lower's `leafTailZero`, materializing slot 1's kind word)
-- and the `:ret`-only result slot (`Lower.resultSlotBase` is now 1 on both
-- arms).  `closureRetClass` is one answer for the whole tree.


-- ============================ libc `struct dirent` ============================
-- `readdir`'s result.  glibc lays `struct dirent { d_ino u64; d_off i64;
-- d_reclen u16; d_type u8; d_name [256]u8 }` down with `d_name` at 19 — one
-- layout on every 64-bit Linux ABI (x86-64/aarch64/rv64), not per-arch.
-- The Mid `glob` body (zigretire stage 3 GROUP 3B) reads match names through
-- this offset; `vendor/osier-rt/src/rt/execplan.zig`'s own `Dirent`
-- declaration carries a comptime row against `gc/layout_gen.zig` (the same
-- leg as rt.zig's rows — no probe can import it), so a layout edit that
-- moves one side without the other fails `zig build gate` instead of reading
-- another struct's bytes at the wrong offset.


direntNameOffset : Int
direntNameOffset =
    19



-- ============================ the exec-plan DECODE blob ============================
-- (zigretire stage 3 GROUP 3B-2a.)  The Mid `exec-plan` body (Rt.exec-plan +
-- the RtPrims ep* helpers) decodes the TAGGED plan Value into a flat C-heap
-- word blob that the Mid RUN walks directly (Rt.execGo; the rt_exec_run
-- seat that used to rebuild the Zig RProg tree from it is DELETED, 3B-2c) —
-- so these offsets are MID-INTERNAL now (the census's MID_ONLY leg names
-- them; no Zig counterpart remains to assert against).  All
-- indexes are WORD offsets into a malloc'd record; every "pointer" slot is
-- a char* or a record pointer with 0 = absent.
--
--   prog   = [ nchains, chains* ]                    (chains* 0 iff nchains 0)
--   chain  = { op, pipe* }        op: epOpSeq/And/Or
--   pipe   = [ ncmds, cmds* ]                        (>= 1 by decode)
--   cmd    = { argv*, argc, redirs*, nredirs, sub* } argc doubles as the
--            running fill count (the partial-free discipline); argv*/sub*
--            0 = empty, redirs* 0 = none
--   redir  = { kind, fd, path*, dup_fd, body*, tmpfd }  kind: epKindIn..epKindHstr;
--            tmpfd is RUNTIME (the pre-opened heredoc body fd, -1 until wired)
--   argv   = char*[argc]  (NUL-terminated strings, Mid-malloc'd)
--
-- The op/kind CODES are part of the same contract: Mid writes the integer,
-- the seat maps it back to the Zig enum, so they are constants here too and
-- asserted against @intFromEnum on the Zig side.


epProgCountIdx : Int
epProgCountIdx =
    0


epProgChainsIdx : Int
epProgChainsIdx =
    1


epChainWords : Int
epChainWords =
    2


epChainOpIdx : Int
epChainOpIdx =
    0


epChainPipeIdx : Int
epChainPipeIdx =
    1


epPipeCmdCountIdx : Int
epPipeCmdCountIdx =
    0


epPipeCmdArrIdx : Int
epPipeCmdArrIdx =
    1


epCmdWords : Int
epCmdWords =
    5


epCmdArgvIdx : Int
epCmdArgvIdx =
    0


epCmdArgcIdx : Int
epCmdArgcIdx =
    1


epCmdRedirsIdx : Int
epCmdRedirsIdx =
    2


epCmdNredirsIdx : Int
epCmdNredirsIdx =
    3


epCmdSubIdx : Int
epCmdSubIdx =
    4


epRedirWords : Int
epRedirWords =
    6


epRedirKindIdx : Int
epRedirKindIdx =
    0


epRedirFdIdx : Int
epRedirFdIdx =
    1


epRedirPathIdx : Int
epRedirPathIdx =
    2


epRedirDupfdIdx : Int
epRedirDupfdIdx =
    3


epRedirBodyIdx : Int
epRedirBodyIdx =
    4


epRedirTmpfdIdx : Int
epRedirTmpfdIdx =
    5


epOpSeq : Int
epOpSeq =
    0


epOpAnd : Int
epOpAnd =
    1


epOpOr : Int
epOpOr =
    2


epKindIn : Int
epKindIn =
    0


epKindOut : Int
epKindOut =
    1


epKindAppend : Int
epKindAppend =
    2


epKindDup : Int
epKindDup =
    3


epKindHdoc : Int
epKindHdoc =
    4


epKindHstr : Int
epKindHstr =
    5



-- ============================ the arity ceiling ============================
-- The `rt_call0..rt_call16` dispatch-table bound.  NOT a QBE or C ABI limit:
-- QBE takes any fixed argument list; the table is how `rt_apply` bridges a
-- runtime code pointer to a fixed-arity call.  `tools/qbe/rt.zig`'s
-- `max_arity` is the same number and is asserted against this one.


maxArity : Int
maxArity =
    16



-- ============================ derived: payload offsets ============================


-- The byte offset of payload word `i` inside a Value cell — DERIVED FROM THE
-- INSTANCE IT IS GIVEN (not from the constants above), so a second instance
-- cannot disagree with its own payload base and word width.
payloadWordOffset : ValLayout -> Int -> Int
payloadWordOffset layout word =
    layout.payloadBase + layout.wordBytes * word



-- ============================ derived: the QBE type field lists ============================
-- The emitter's `:val`/`:desc` type definitions are BUILT from the
-- numbers above, so the .ssa cannot describe a different layout from the one
-- this module states.  The field spellings are QBE's (`w` = 32-bit, `l` =
-- 64-bit, `:val` = the nested aggregate).


valQbeFields : List String
valQbeFields =
    "w" :: List.repeat valuePayloadWords "l"


descQbeFields : List String
descQbeFields =
    "l" :: "w" :: "w" :: []
