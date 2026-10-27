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
    , tagBoolean, tagCons, tagError, tagFloat, tagLambda, tagMark, tagNil, tagNumber, tagPrim, tagRecord, tagStream, tagString, tagSymbol, tagVector
    , untagMask
    , ValLayout, valLayout
    , WordTagShape(..), wordHeapCodes, wordTagShape
    , wordFixnumLimit, wordLayout
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
--                          packing — MEASURED: numClass < 2^20 at any mappable
--                          ceiling, so bits 22..23 are already spare)
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
    [ tagString, tagSymbol, tagCons, tagLambda, tagPrim, tagVector, tagStream, tagFloat, tagRecord ]


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
-- why the emitter's string construction (area A) writes `[bytes, len]` through
-- the shared cell writer and the runtime's `payload32(str, 1)`/`payload(str, 0)`
-- reads need NO twin at all: `payload`/`payload32` are layout-derived, so
-- porting THEM (area B) ports every string site in `runtime.mid` at once.
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
    , tagString : Int
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
--      the immediates in `lowerLitWord` (a fixnum `n * 8`, refused by name
--      outside i61 because boxing is area 4; `true`/`false` = tagTrue/tagFalse)
--      plus `storeNil`.  THE HEAP-OBJECT HALF IS PORTED (perf
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
--   4. ARITHMETIC.  Inline tag/untag (and + shift, no runtime call), the i61
--      overflow check and the boxing path, comparisons, div/mod, negate.
--   5. FLOATS.  The heap-boxed `[hdr | f64]` cell and Lower's `rawFloat` lane.
--   6. THE `:ret` AGGREGATE.  Its FIRST FIELD IS A VALUE, so its tail offsets
--      move with `valSizeBytes` (they are DERIVED below); plus the 80-byte sret
--      path, slot 1's `.tail` metadata and rt_bounce.
--   7. THE Rt SURFACE (`runtime.mid` — VR3c's, single-writer, NOT this unit):
--      gcAlloc's `2 + count + 4*count*kind` sizing, apply's `args + rem*40`,
--      gcScav/copyWordsGo, the values-table builder AND walk, argv install, and
--      the printer internals (mknum/payload/tagis).  REFUSED WHOLESALE under
--      the word arm by Lower's area-7 gate — a program whose emitted set
--      contains any Rt key stops there, which today is every real program.
--   8. THE C FFI GLUE.  The tag/untag at the boundary — a fixnum's payload IS
--      the C i64 after untag, and Values never cross raw (the extern
--      declarations already encode C widths, so nothing there moves).
--   9. THE MID.Ir CONSTRUCT LANE (perf word-arm-surface) — the SURFACE of the
--      Mid language, as opposed to item 7's runtime.  `Mid.Qbe.Lower`'s
--      `wordArmUnported` is the belt: a defun carrying an un-ported construct
--      refuses BEFORE its body walk, and the entry names the construct and the
--      area.  PORTED: literals, `Var`, `Let`, `If`/`&&`/`||`/`/=`, `Loop`,
--      `App`, and — via their desugars — `ListLit`, `Tup` and `Case` (the
--      aggregate prims `cons`/`@p`/`emptylist`/`assoc`/`snd` reach the
--      runtime's own twinned defuns through `rtPrimSlots`, which is
--      arm-independent by construction), plus the payload chases behind them
--      (`fieldBase`, one accessor: the val arm's payload word HOLDS a pointer,
--      the word arm's IS the element).  NOT PORTED, each refused by name:
--      `Con` (its vector is written through `storeValueCell` and its tag is an
--      `LSymbol`), the RECORD family (`RecordLit`/`RecordGet`/`RecordUpdate`,
--      and a `VField` pattern bind — its second parallel NAMES array has no
--      inline body layout, which is a design decision, not a stride), `Lam`,
--      `GRef`, `StreamRef`, float/symbol literals, let-destructuring, `MTagEq`
--      (a constructor-tag pattern, same `LSymbol` reason), and every
--      ARITHMETIC prim (area 4/5 — `isIntExp`/`isFloatExp` also deny there,
--      because S4/S4f's raw local is reboxed in the 40-byte shape).
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
-- [-2^60, 2^60-1] does not fit and must be BOXED onto the heap — worklist area
-- 4's overflow path, which does not exist yet.  These two bounds are what let a
-- COMPILE-TIME literal be decided statically: inside the range `n * 8` is an
-- exact i64 (no truncation, no overflow), outside it the emitter refuses the
-- literal by name instead of silently dropping its top three bits.
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
-- L3-U1 NOTE: the product below was originally the only way to SPELL 2^60 (our
-- own frontend rejected a 19-digit literal outright: "err parse failed" from
-- the self-host emit, every Elm-side gate green — MEASURED at VR3b2).  The
-- exact parser makes the plain literal legal now, but re-spelling it is
-- deliberately NOT done here: `abi-fingerprint.sh`'s `gc:layout` component
-- digests this declaration's TEXT, so the re-spelling moves the committed
-- seed's ABI marker and makes `tools/qbe-bootstrap.sh` REFUSE — measured, for a
-- change that moves no layout NUMBER (2^60 either way).  The re-spelling
-- belongs in the commit that re-freezes the seed, not in a parser unit.
wordFixnumLimit : Int
wordFixnumLimit =
    -- 2^60, spelled as a product (see the note above).
    1024 * 1024 * 1024 * 1024 * 1024 * 1024


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
