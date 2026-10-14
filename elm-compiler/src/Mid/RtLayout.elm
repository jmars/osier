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
    , epRedirBodyIdx, epRedirDupfdIdx, epRedirFdIdx, epRedirKindIdx, epRedirPathIdx, epRedirWords
    , lenFieldOffset, lenFieldWord
    , maxArity
    , metaArityOffset, metaCodeOffset, metaNameOffset, metaSizeBytes
    , payloadBase, payloadWordOffset
    , retArityOffset, retArgsOffset, retEOffset, retFOffset, retKindOffset, retQbeFields, retSizeBytes, retValOffset
    , tagBoolean, tagCons, tagError, tagFloat, tagLambda, tagMark, tagNil, tagNumber, tagPrim, tagRecord, tagStream, tagString, tagSymbol, tagVector
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
-- `Mid.Qbe.Il.retType` is `align 8 { :val, w, l, l, l, w }` = 80 bytes:
--   :val  @0   the finished value when kind == `.done`;
--   kind  @40  the discriminator (0 = done, 1 = tail);
--   f     @48  the callee code pointer (`.tail`);
--   e     @56  the captures array, or null;
--   args  @64  a fresh GC array of `arity` Value structs (or the runtime's
--              static staging buffer for the known-tail path);
--   arity @72  the static arity == length of `args`.
-- `tools/qbe/rt.zig`'s `Ret` extern struct is asserted to be these 80 bytes.


retSizeBytes : Int
retSizeBytes =
    80


retValOffset : Int
retValOffset =
    0


retKindOffset : Int
retKindOffset =
    40


retFOffset : Int
retFOffset =
    48


retEOffset : Int
retEOffset =
    56


retArgsOffset : Int
retArgsOffset =
    64


retArityOffset : Int
retArityOffset =
    72



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
-- word blob that the rt_exec_run seat (tools/qbe/rt.zig) reads back and
-- rebuilds the Zig RProg tree from — so these offsets are a cross-ABI
-- contract exactly like Desc/Meta/Ret, asserted by rt.zig's comptime rows
-- (the seat's file; the census's COMPTIME leg names them there).  All
-- indexes are WORD offsets into a malloc'd record; every "pointer" slot is
-- a char* or a record pointer with 0 = absent.
--
--   prog   = [ nchains, chains* ]                    (chains* 0 iff nchains 0)
--   chain  = { op, pipe* }        op: epOpSeq/And/Or
--   pipe   = [ ncmds, cmds* ]                        (>= 1 by decode)
--   cmd    = { argv*, argc, redirs*, nredirs, sub* } argc doubles as the
--            running fill count (the partial-free discipline); argv*/sub*
--            0 = empty, redirs* 0 = none
--   redir  = { kind, fd, path*, dup_fd, body* }      kind: epKindIn..epKindHstr
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
    5


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


-- The byte offset of payload word `i` inside a Value cell.
payloadWordOffset : Int -> Int
payloadWordOffset word =
    payloadBase + wordBytes * word



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
