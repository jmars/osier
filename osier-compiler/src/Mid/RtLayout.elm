module Mid.RtLayout exposing
    ( abiAlign
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
    , retArityOffset, retArgsOffset, retEOffset, retFOffset, retKindOffset, retQbeFields, retSizeBytes, retValOffset
    , tagBoolean, tagCons, tagError, tagFloat, tagLambda, tagMark, tagNil, tagNumber, tagPrim, tagRecord, tagStream, tagString, tagSymbol, tagVector
    , ValLayout, valLayout
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
-- DERIVED from them (`Mid.Qbe.Il.valType`/`retType`/`descType` are built out
-- of the field projections below, `Mid.Qbe.Lower` reads `valSizeBytes`,
-- `retSizeBytes`, `maxArity` and the tag numbers, `Mid.RtPrims` reads the tag
-- numbers), and the ZIG side is checked against them:
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
--   3. THE ret/desc/meta AGGREGATES ARE NOT VALUES AND DO NOT FLIP, so they
--      stay OUT of this record: a record mixing "flips with the
--      representation" and "never flips" is exactly the silent-mismatch shape
--      this module's header was written to prevent.  ONE COUPLING SURVIVES and
--      is named here so it cannot go silent: the `:ret` aggregate's first
--      field IS a Value, so `retKindOffset` is `valSizeBytes` and
--      `retSizeBytes` is `valSizeBytes + 40`.  VR3b1 DISCHARGED that finding
--      by turning all six tail offsets into functions OF THE INSTANCE
--      (see the Ret section below) — a `:ret` over a word Value is
--      `{ l, w, l, l, l, w }` = 48 B with kind at 8.  `desc*`/`meta*`/`ep*`/
--      `dirent*` carry no Value at all and stay put.


type alias ValLayout =
    { valSizeBytes : Int -- FLIPS 40 -> 8 (the cell IS a word)
    , valuePayloadWords : Int -- FLIPS 4 -> 0
    , payloadBase : Int -- FLIPS 8 -> 0 (no tag word before the payload)
    , wordBytes : Int -- UNCHANGED: the `l` width every offset is counted in
    , valueTagBytes : Int -- FLIPS 4 -> 0 (the tag moves into the low 3 bits)
    , valQbeFields : List String -- FLIPS { w, l, l, l, l } -> { l }
    , maxArity : Int -- UNCHANGED: the rt_callN dispatch bound, not a cell size
    , tagMask : Int -- FLIPS 0 -> 7 (VR3b2): the LOW-BIT MASK that extracts the tag (0 = the tag is a whole word)
    , tagTrue : Int -- FLIPS 12 -> 3 (VR3b2): see `booleanSplit`
    , tagFalse : Int -- FLIPS 12 -> 4 (VR3b2): see `booleanSplit`
    , booleanSplit : Bool -- FLIPS False -> True (VR3b2): two IMMEDIATES vs one tag + a payload bit
    , heapTagIsKind : Bool -- FLIPS False -> True (VR3b2): the tag names the kind vs the 2-word header does
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
    , tagTrue = tagBoolean
    , tagFalse = tagBoolean
    , booleanSplit = False
    , heapTagIsKind = False
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
-- BODY STRIDES: a cons cell is 24 B (2-word header + 2 words), a vector is
-- 8n+16, a values-table row is 16 B, a frame slot is 8 B.  The 2-word GC
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
--     arm every `tagCons`/`tagString`/... field reads 1 and a heap-object TAG
--     TEST is not a tag test at all: it is a header-KIND read
--     (`heapTagIsKind = True`).  The tag integers below stay the val arm's
--     numbers (VR3b does not renumber them); they are meaningful on the word
--     arm only as `w & 7` equals 1.
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
--      plus `storeNil`.  NOT PORTED: every HEAP-object tag — cons/string/
--      vector/record/float/lambda/stream/prim all collapse to `...001`, so a
--      heap-object test is a 2-word-HEADER KIND read (heapTagIsKind), which is
--      area 3/7's contract; and `storeValueCell`'s heap writes.  The .mid
--      surface lane's `RawTagIs`/`RawMkValue` are also un-ported
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
    , tagTrue = 3
    , tagFalse = 4
    , booleanSplit = True
    , heapTagIsKind = True
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



-- ============================ Ret (the bounce-loop result) ============================
-- `Mid.Qbe.Il.retType` is `align 8 { :val, w, l, l, l, w }` = 80 bytes on the
-- VAL arm:
--   :val  @0   the finished value when kind == `.done`;
--   kind  @40  the discriminator (0 = done, 1 = tail);
--   f     @48  the callee code pointer (`.tail`);
--   e     @56  the captures array, or null;
--   args  @64  a fresh GC array of `arity` Value structs (or the runtime's
--              static staging buffer for the known-tail path);
--   arity @72  the static arity == length of `args`.
--
-- VR3b1 — THE COUPLING IS NOW DERIVED, NOT CONSTANT.  VR3a's finding: the
-- `:ret` aggregate's FIRST FIELD IS A VALUE, so retKindOffset IS
-- `valSizeBytes` and every offset after it moves with it; the tail
-- `{ w kind, pad, l f, l e, l args, w arity, pad }` is 40 bytes on top.  These
-- are therefore FUNCTIONS OF THE INSTANCE, and `40`/`80` appear nowhere as a
-- ret number any more — that pair left as constants is exactly the stale-40
-- trap the moment the word arm is ported (`:ret` over a word Value is
-- `{ l, w, l, l, l, w }` = 48 B, kind at 8).  TestMain pins both values for
-- BOTH instances, so a derivation that stops agreeing with the emitted IL is
-- loud.
--
-- (The `:ret` TYPE is still a module constant — its FIELD LIST does not flip
-- with the representation, only the size of its first field does; see
-- `retQbeFields` below and Mid.RtLayout's TRAP-3 note.  The census's
-- MID_ONLY_NAMES list dropped these six names when they stopped being
-- constants, which is why they are pinned in TestMain instead.)


retSizeBytes : ValLayout -> Int
retSizeBytes layout =
    layout.valSizeBytes + 40


retValOffset : Int
retValOffset =
    0


retKindOffset : ValLayout -> Int
retKindOffset layout =
    layout.valSizeBytes


retFOffset : ValLayout -> Int
retFOffset layout =
    layout.valSizeBytes + 8


retEOffset : ValLayout -> Int
retEOffset layout =
    layout.valSizeBytes + 16


retArgsOffset : ValLayout -> Int
retArgsOffset layout =
    layout.valSizeBytes + 24


retArityOffset : ValLayout -> Int
retArityOffset layout =
    layout.valSizeBytes + 32



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
-- The emitter's `:val`/`:ret`/`:desc` type definitions are BUILT from the
-- numbers above, so the .ssa cannot describe a different layout from the one
-- this module states.  The field spellings are QBE's (`w` = 32-bit, `l` =
-- 64-bit, `:val` = the nested aggregate).


valQbeFields : List String
valQbeFields =
    "w" :: List.repeat valuePayloadWords "l"


retQbeFields : List String
retQbeFields =
    ":val" :: "w" :: "l" :: "l" :: "l" :: "w" :: []


descQbeFields : List String
descQbeFields =
    "l" :: "w" :: "w" :: []
