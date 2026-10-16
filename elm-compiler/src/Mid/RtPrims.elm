module Mid.RtPrims exposing
    ( primDefuns
    , helperDefuns
    , seat
    )

{-| Mid.RtPrims — the PRIM BODIES of the Mid-written runtime (handoff
osier-midprims, TRACK 2 step 5: the mechanical remainder after the cons
spike).


## WHAT IS HERE (post-T24 — the DSL is GONE)

162 MIGRATION SEATS and nothing else — the defun-list positions
`Mid.Rt.spliceSurface` replaces by key (MEASURED: 56 in `primDefuns`, 94
in `helperDefuns`, 12 in Mid.RtGc's `gcProgram` — 150 prim/helper seats =
the built program's 150 defuns, plus the 12 gc ones; the pre-T24 header's
"51 prim / 87 helper" split was a miscount, the lists never had 138).
The 6 MORE surface defun LINES than
seats are the `@flag`-guarded second variants — Rt.= x4 lines (3 extra),
Rt.cons / Rt.@p / Rt.deepEq x2 each (1 extra) — so 168 lines = 162 unique
keys.  Every seat is a `seat` tripwire: the real bodies of ALL the keys
live in Mid.RtSource's surface text (162 keys under the default flags).  Mid.Rt maps the surface prim
names onto the prim keys (`primImpl`); Mid.Rt.rtDeps closes the RawCall
edges for reachability.  Mid.RtGc's own copy of the builder DSL is dead
in the same way (all 12 of its positions are seats) — it dies in that
module's own cleanup, not here.

THIS MODULE NOW CONTAINS: `seat` / `seatParams` and the two list
functions.  The BUILDER DSL (n/v/b/p1..p3/lets/iff/and2/or2/wOf/iadd/
isub/imul/cmpW/tagIs/mkNum/mkBool/mkNil/mkStr/callR/callW/carV/cdrV/lam/
haltV/letL) is DELETED (T24) — with the last three bodies migrated every
one of its helpers had zero readers left (verified by reference search;
the compiler build is the second check).  Nothing outside this module ever
referenced them: the only exports are `primDefuns`, `helperDefuns` and
`seat`.


## THE HOLDOUT INVENTORY (FINAL, post-T24 — ZERO DSL-bodied defuns)

T8-T21 migrated 150 keys; T22 moved the LAST nine never-scheduled ones —
the constructor layer Rt.con / conFill / closure / closureFill, the walk
helpers Rt.subGo / repGo / bytesBuild / symLess, and
Rt.read-file-as-string.  T23 landed the grammar feature the last three
needed — the BLOCK-BRANCH `if` EXPRESSION `if (c) { block } else
{ block }` in expression position (EIfBlock, lowering through the
term-if's own machinery) — and T24 migrated them with it:

  - `Rt.readFileGo` (growB — the wall T9 found): the T23 acceptance row's
    spelling, verbatim.  Canon-EQUAL to its deleted builder (MEASURED with
    the T6 canon normalizer before the builder was deleted).
  - `Rt.epCmd` (ago/rgo): EIfBlock binds for the two read-value walls; the
    chain-tail Ifs are TERM-ifs (a both-diverging TERM-if lowers to a BARE
    If — the DSL's value-position shape — where the STATEMENT-if
    dead-binds); tagCountState is written OUT at the subState binder (the
    T16 epUnwrap precedent — the same tree was already corpus-green as
    epCount's T9b ?: join, copied verbatim).  Canon-EQUAL to its builder
    (MEASURED).
  - `Rt.childCd` (dirN binder #2): the T23 acceptance row's spelling;
    dirN #1/#3 are pure-expression branches (the T9b ?: join).  Its canon
    differs from the builder's in ONE respect that is byte-inert and
    MEASURED as such: the DSL reuses ONE Binder id for all three dirN
    binds, so the in-initializer read canon-maps to the CURRENT bind's
    number, while the surface resolves it to the previous binder's id —
    the same binding, and binder ids are Dict keys, never emitted (plan
    fact F1).  The corpus (byte-identity, 159/159) is the proof; the T23
    dirN#2 row pins the surface spelling.

THE WALL CLASS, resolved: an If BOUND IN A LET-VALUE whose branch carries
a Let-chain and whose VALUE the continuation reads spells as the
block-branch if bound at a binder (`val x = if (c) { .. } else { .. };` →
`Let { x = If { .. } }`, the DSL shape).  The `?:` join still takes
EXPRESSION branches, and a both-diverge statement-if still dead-binds —
the T23 form is what closed the class.

Their ELM-SIDE CO-HELPERS died with them (T24): `tagCountState` (its
single caller epCmd — the surface has no intra-defun abstraction, so its
tree was written out), and `runLits` / `runLitsPacked` / `runOff` /
`rLoad` / `rCbuf` (childCd's — `runOff`'s byte offsets into the packed
cbuf literal list are FROZEN as literals in the surface text, re-derived
from HEAD and matched to T17's numbers: "/" = 139, "\n" = 173, "cd: " =
240; cbuf size 336; cross-checked against the already-migrated sites —
childBuiltin's cbufW + 104..125, the cbufW + 173 "\n", exec-plan's
malloc(336)).

That is the WHOLE remainder: 162 keys on the surface under the default
flags (MEASURED: 168 surface defun lines - 6 guarded duplicate variants),
and NO key whose body is a DSL tree.  Any future runtime body is surface text
in Mid.RtSource.


## THE STEP-5 CLASSIFICATION, SUPERSEDED IN PART

The step-5 enumeration below divided the prims into PORTED (DSL bodies
here), HOST-ONLY (still Zig) and UNREACHABLE/UNPORTED.  The PORTED/HOST-ONLY
split is historical since the tier-2 waves: what it called PORTED has
largely MIGRATED to the surface (T8-T18), and what it called HOST-ONLY
(fd/process/VM-state/str) migrated too.  The enumeration's UNREACHABLE set
(hd, tl, fst, reverse, append, absvector? — in no wrapper/alias table, so
no compiled fixture can name them) remains accurately described.


The classification this step encoded (historical): the desugar set (cons,
@p, emptylist, assoc, snd), the operators (=, +, -, *, /, f/, <, <=, >,
>=), the alias set (cn, c-strlen, repeat, substring, char-code,
shen.str->bytes, shen.bytes->string, number?, string?, cons?, empty?,
absvector, <-address, address->) and the Bitwise family were ported here;
the fd layer (write-byte, read-byte, read-file-as-string, open, close), the
process layer (exec-plan, cd, getcwd, getpid, getenv, setenv, glob), VM
state (intern — the symbol table; value — the registry; simple-error —
error unwinding) and `str` (floatText's shortest-round-trip float render +
strValue's composite printer) were HOST-ONLY.


## THE NODE-SET FINDINGS THIS STEP LANDED

The spike's set could build and walk Values but could not COMPUTE — the
step extended it (Mid.Ir's STEP 5 block) with the scalar/word family
(RawBin/RawUn/RawCmp, the float words, RawTagIs, RawPayload32,
RawAllocRaw/RawByteLoad/RawByteStore) and lowered RawCall for Rt->Rt
recursion.  Two of those deserve their `why` repeated here:


### Tag dispatch never goes through `Case MLitEq`/`MTagEq`

Those matches lower through `rtPrimSlots "="` — which ROUTES to Rt.eq when
the route hatch is on, an infinite regress inside Rt.eq's own body.  Every
tag test here is `RawTagIs` boxed by `RawMkValue` tag 3 and branched with
`If`/`ShortAnd`/`ShortOr` (lowerIf/lowerShortAnd test the boolean payload
inline; no prim call).


### 32-bit payload fields are read with RawPayload32

str.len / vector.len / boolean are i32 FIELDS (gc/types.zig extern
structs).  A 64-bit RawPayload read of a ZIG-built Value's word 1 reads
GARBAGE in the high half (the extern-struct store writes only 12 payload
bytes; heap memory is recycled).  Number payloads are i64 and keep
RawPayload.  Every length/boolean compare below uses the 32-bit read.


## THE DISCIPLINE

Unchanged from the spike, plus what step 5 added: word-producing raw nodes
bind to raw TEMPS (Lower's rawWord table); float words are a second class
and are only ever NESTED inside raw-argument positions (RawFltBin operands,
RawMkValue float words) — never let-bound; a raw buffer address never
crosses a safepoint (the only safepoints a body introduces are its
RawAllocVector/RawAllocRaw nodes, and every helper those feed writes its
bytes before returning); recursive helpers take and return VALUES only —
word arguments are boxed (a pointer rides as a NUMBER Value, which the
collector never chases) and unpacked at the raw use.

GAPS, stated rather than papered over: `assoc`/`bytes->string` non-list
inputs and `emptylist`'s non-0 arm throw in Zig (catchable Shen errors /
error.Halt); Mid has no error mechanism this step, so those arms route to
the `rt_halt` seat — process death on QBE either way, but not a catchable
error.  The float arms of the Bitwise ToInt32 conversion are unreachable
from typed Elm fixtures (Bitwise is Int-typed at the surface), so the
differential covers the Int arms; the float arm is proven only by the
shared `asF`/`toI32` machinery the arithmetic differential does cover.

-}

import Mid.Ir exposing (Binder, Defun, Exp(..), UnsafeNode(..))


{-| A migration SEAT (T8, handoff-osier-tier2-t8): the defun-list POSITION
a surface-migrated key still occupies.  `Mid.Rt.spliceSurface` replaces
entries BY KEY at their list position — list ORDER is .ssa bytes — so a
migrated defun hands its body to the surface text but KEEPS this position.
The body is a TRIPWIRE, never emitted while the splice is wired: its one
RawCall names `key ++ ".surface-seat"`, a key in no rtDeps row and no
program, so if the splice ever failed to replace a seat, Mid.Qbe.Lower's
rawCall arm fails LOUDLY instead of emitting a wrong runtime.  The param
count MIRRORS the migrated defun's arity, and the reader that makes the
mirror load-bearing is TestMain's T19 seat-arity row (every seat's param
count == the surface defun's arity at its key — a drift is a loud FAIL,
never a silent no-op).  Note the T7 safety-net row is a DIFFERENT check:
it compares the SURFACE defun's arity to externArities and reads no seat.
-}
seat : String -> Int -> Defun
seat key arity =
    { key = key
    , value = Lam
        { params = seatParams arity
        , body = Unsafe (RawCall { sym = key ++ ".surface-seat", args = [] })
        }
    }


seatParams : Int -> List Binder
seatParams count =
    if count <= 0 then
        []

    else
        { id = count, name = "p" ++ String.fromInt count } :: seatParams (count - 1)


-- ============================ HELPERS ============================
-- Rt->Rt value-level helpers.  Recursive helpers call their OWN key via
-- RawCall (lowered since this step); Mid.Rt.rtDeps declares every edge here
-- so the used-prim census seeds the whole closure.


-- Rt.deepEq / Rt.bytesEqGo / Rt.symEq / Rt.vecEq MOVED TO THE SURFACE
-- (T10 wave 3, handoff-osier-tier2-t10): the equality helpers lower from
-- Mid.RtSource -- deepEq as TWO @rec-guarded variants of one key (the
-- tag-14 arm exists only under rec), the other three unguarded; every
-- self-reference is `call Rt.<own-key>` (RawCall), exactly the builders'
-- callR.  Their list positions below are seats.


-- Rt.asF / Rt.toI32 / Rt.dgs / Rt.revGo / Rt.bytesOf / Rt.numText /
-- Rt.bytesToStr / Rt.countL / Rt.fillGo MOVED TO THE SURFACE (T11 wave 4,
-- handoff-osier-tier2-t11): the number/string builders lower from
-- Mid.RtSource -- asF/toI32 the two class-conversion prims, dgs/revGo/
-- numText the decimal-text chain, bytesOf/countL/bytesToStr/fillGo the
-- bytes->string machinery; every self-reference is `call Rt.<own-key>`
-- (RawCall), exactly the builders' callR (NOT recur).  numText's signed
-- and dgs's rAbs — Ifs in LET VALUE positions — spelled with the T9b
-- `?:` join.  Their list positions below are seats.
--
-- T12 (handoff-osier-tier2-t12) moved the REST of the number/string
-- builders to Mid/RtSource.elm: cn2, appendL, symToStr, nameBytes,
-- strOf (the primCn coercion chain) and floatCopy (the countdown fill)
-- — their `defun` text now lives there, 1:1 tree transcriptions, and
-- their list positions below are seats.  T12 also moved cons/atp (the
-- @consArr guard pair) — see the primDefuns seat comment.


-- Rt.assocGo moved to Mid/RtSource.elm in T13 (handoff-osier-tier2-t13)
-- — primAssoc's chain walk (the first pair whose car is a cons and whose
-- key deep-equals k; non-list = the halt arm), its `defun` text now
-- there; its list position below (helperDefuns) is a seat.


-- Rt.subGo / Rt.repGo / Rt.bytesBuild MOVED TO THE SURFACE (T22, the
-- never-scheduled family part 3): substring's / repeat's / str->bytes'
-- value walks — plain `call` recursion over RawCall self-edges, NOT
-- recur (the builders' callR, MEASURED) — transcribed in Mid/RtSource's
-- T22 block; their list positions below (helperDefuns) are seats.  Their
-- deletion killed the last readers of consV and byteOf (both deleted).


-- Rt.symLess a b i — byte-lexicographic LESS-THAN of two symbol Values'
-- names (symEq tests equality only; the sorted-insert path needs `<`).
-- Mirrors symEq's walk: byte at i, null-termination decides prefix order.
--
-- MOVED TO THE SURFACE (T22): the two boxed byte reads then the nested
-- term-if chain (ca==0 -> cb!=0; cb==0 -> false; ca<cb -> true; ca>cb ->
-- false; else the self-call at i+1) transcribed in Mid/RtSource's T22
-- block; its list position below (helperDefuns) is a seat.  Its deletion
-- killed the last readers of trueV/falseV (both deleted).


-- Rt.recGet / Rt.recGetGo moved to Mid/RtSource.elm in T13
-- (handoff-osier-tier2-t13) — the tag-14 record read's walk form (names
-- array at word 2, symEq against the boxed name pointer, data at word 0;
-- absent = the halt arm), their `defun` text now there; their list
-- positions below (helperDefuns) are seats.


-- Rt.recUpd / Rt.recUpdFind / Rt.recUpdCopy moved to Mid/RtSource.elm in
-- T13 (handoff-osier-tier2-t13) — the tag-14 record UPDATE walk (find,
-- copy, overwrite, wrap reusing the base's names pointer; every defun
-- <= 3 params for the lean ABI), their `defun` text now there; their
-- list positions below (helperDefuns) are seats.


-- Rt.recAppendFind / Rt.recAppendDataGo / Rt.recAppendNamesGo moved to
-- Mid/RtSource.elm in T13 (handoff-osier-tier2-t13) — the sorted-insert
-- walk (the first index whose name sorts after the field via symLess; the
-- packed pos*65536 + j hole-leaving copies), their `defun` text now
-- there; their list positions below (helperDefuns) are seats.


-- Rt.recAppend / Rt.recInsert / Rt.recToChain / Rt.recToChainGo moved to
-- Mid/RtSource.elm in T13 (handoff-osier-tier2-t13) — the insertion's
-- absent case (two one-longer arrays, shift walks, the wrap carrying both
-- vecaddrs), the insert-or-update dispatch, and the positional->assoc
-- walk, their `defun` text now there; their list positions below
-- (helperDefuns) are seats.


-- ============================ FD PRIMS (zigretire stage 3 GROUP 1) ============================
-- The fd layer's read-byte/open (and T8/T9's write-byte/close) moved to
-- Mid/RtSource.elm in T14/T9/T8; their list positions in primDefuns are
-- seats.  read-file-as-string is still a DSL body here (its copy-on-grow
-- page-allocator accumulator is a distinct mechanism).
--
-- The stream Value layout (gc/types.zig stream extern struct): payload word 0
-- = file (?*anyopaque, an fd-int-in-pointer; null = fd 0), payload word 1 =
-- is_input (LOW half) | is_string (HIGH half).  is_string is read by shifting
-- the packed word right 32 (is_input is the RawPayload32 half).


-- The cStrOf four-binder EXPANSION (len = payload32(path, 1); buf =
-- allocraw(len + 1); bufN = mknum(buf); call Rt.cStrFill(bufN, path,
-- mknum(0))) is spelled out in the surface defuns that NUL-copy a path
-- (T14's open/getcwd/cd/getenv/setenv, T15's glob, T22's read-file-
-- as-string).  The ELM HELPER is DELETED (T22): read-file-as-string —
-- its last DSL reader — moved to the surface.


-- read-byte (1 arg: stream) and open (2 args: path, dir) moved to
-- Mid/RtSource.elm in T14 (handoff-osier-tier2-t14) — their `defun` text is
-- there; their list positions in primDefuns are seats.  read-byte's string
-- arm rode the registry seats (rt_ss_readbyte), its file arm Rt.readFull;
-- open's two arms each inlined cStrOf twice (bases 10 and 20) and packed
-- the stream Value via mkStream (tag 11, the is_input/is_string word a
-- 64-bit multiply).


-- ====================== VALUE / INTERN / STR (zigretire stage 3 GROUP 2) ======================
-- intern/value/str moved to Mid/RtSource.elm in T14
-- (handoff-osier-tier2-t14) — their `defun` text is there; their list
-- positions in primDefuns are seats.  All three were frame-free reads
-- over alloc-free Zig seats (rt_sym_intern / rt_value_slot /
-- rt_float_text) EXCEPT Rt.str, which RawAllocRaw's a GC string (the
-- rt_float_text render is COPIED into it) and is therefore framed.


-- ============================ PROCESS LAYER (GROUP 3A) ============================
-- The simple libc-backed process prims moved to Mid/RtSource.elm — getpid
-- in T8, getcwd/cd/getenv/setenv in T14 (handoff-osier-tier2-t14); their
-- list positions in primDefuns are seats.  The Zig originals are
-- vendor/osier-rt/src/rt/execplan.zig
-- primGetpid/primGetcwd/primCd/primGetenv/primSetenv.  No new Zig seat: the
-- name buffers are GC-allocated + cStrFill'd (used before any further alloc),
-- and the getcwd result reuses its own PATH_MAX buffer as the string (a
-- second alloc would move it — see cStrLenGo's contract).
--
-- THE NON-STRING ARMS: primCd/primGetenv/primSetenv throw Shen errors on a
-- non-string arg (the host effect loop's defensive dispatch).  Those arms are
-- UNREACHABLE from compiled Elm (`cd`/`getenv`/`setenv` are String-typed at
-- the surface), so the Mid bodies assume the tag, exactly as Rt.open/
-- Rt.write-byte/Rt.intern do.  The HOST dispatch path stays Zig until stage 7.
--
-- The empty-result strings use the static `Lit (LString "")` where the Zig
-- used `valString(g, "")` — behaviourally identical (a String Value, len 0),
-- and the static literal is never GC-reclaimed, so it is no soundness concern
-- under the hatch gate.


-- ================== read-file-as-string (GROUP 3B-3) ==================
-- streams.primReadFileAsString (streams.zig:191) as a Mid body — the LAST
-- prim that still routed through rt_prim, so this closes stage 3's zero-
-- rt_prim exit condition.  No new Zig seat: openat/read/close/write AND
-- malloc/free are plain libc symbols under RawCallRaw (the glob precedent).
--
-- THE ALLOCATOR SPLIT (why this was deferred until malloc/free were proven
-- seats): Zig accumulates into a page_allocator ArrayList — NON-MOVING — and
-- valString's alloc is the ONE GC operation.  A GC-allocRaw copy-on-grow
-- accumulator is UNSOUND under the moving Zig GC (the boxed pointer goes
-- stale at the grow safepoint), so the Mid accumulator lives on the C HEAP:
-- malloc-new + memGo copy + free-old (realloc never needed, and its classic
-- failure leak — the old pointer lost when realloc returns NULL — is
-- structurally impossible: the OOM arm keeps the OLD buffer as the result).
-- The GC heap holds only the path's NUL copy (cStrOf) and the final string.
--
-- ZIG PARITY, arm by arm (streams.zig:191-216): ANY openat failure prints
-- "runtime: cannot open file for read-file-as-string\n" to stderr (fd 2,
-- write(2) on the interned literal's data+len) and returns "" — the note is
-- part of the observable contract (the gate's 2>&1 capture pins it); the
-- read loop is Zig's 65536-byte tmp + appendSlice chunking EXACTLY (there is
-- NO length cap — the 65536 is the CHUNK size; growth is geometric:
-- max(2*cap, needed)); read goes through Rt.readFull because Zig's
-- std.posix.read RETRIES EINTR internally (a bare read would return -1 where
-- Zig retried); a read error BREAKS with the partial buffer (the rfa-dir
-- probe: EISDIR on the first read -> ""); append OOM breaks with the old
-- buffer INTACT (Zig's `catch break` — ArrayList keeps the old allocation on
-- a failed append, then deinit frees it); the result is valString's exact
-- shape — alloc len+1, copy len bytes, NUL at [len], tag string with
-- [data, len] (binary-safe: file bytes may include NULs; nothing reads a
-- terminator on this path); fd closed and every C allocation freed on the
-- SINGLE success exit (free(NULL) is a no-op for the empty-file case).


-- `Rt.read-file-as-string path` — primReadFileAsString.  Arity 1, FRAMED
-- (allocates: the path NUL copy, the result RawAllocRaw, and the "" literals).
-- The loop state (fd/tmp/acc/len/cap at words 0..4) and the memcpy block
-- (words 6..8) share ONE 72-byte C-heap block; mblk = block+48 is passed to
-- memGo.  All state crossing the loop is C-heap or int — the two GC
-- allocations (path copy, result) sit OUTSIDE the loop's raw-pointer window,
-- and the result buffer is consumed by mkStr before any further allocation
-- (the moving-GC discipline: the raw temp is valid only to the next safepoint,
-- and there is none between the RawAllocRaw and the mkStr).
-- 
-- MOVED TO THE SURFACE (T22): the tree above is transcribed in Mid/RtSource's
-- T22 block — the cStrOf four binders written out (its Elm helper is deleted
-- with this, its last reader), the OOM checks as the T15 both-diverge
-- mid-block if, the tail exactly as read here.  Rt.readFileGo moved in
-- T24 — the growB wall fell with the T23 block-branch if (its builder is
-- deleted and its list position in helperDefuns is a seat).


-- Rt.floatCopy moved to Mid/RtSource.elm in T12 (handoff-osier-tier2-t12)
-- — the countdown fill from the static float-text buffer, its `defun`
-- text now there; its list position below (helperDefuns) is a seat.


-- ===================== glob (zigretire stage 3 GROUP 3B) =====================
-- All NINE glob keys moved to Mid/RtSource.elm in T15
-- (handoff-osier-tier2-t15) — the eight helpers (globLastSlash, globIsDot,
-- globIsDotDot, globScanGo, globStrLess, globSortShift, globSortGo,
-- globBuildGo) plus glob itself; their `defun` text is there, with the
-- allocator split (the match table and every matched name on the C HEAP —
-- non-moving, so raw pointers survive every safepoint — the GC heap holding
-- only the pattern's NUL-copy and the results), the dotfile-guard parity
-- note (REAL fnmatch calls against the cbuf "." / ".." literals, the base
-- AS the pattern — byte equality would invert the argument roles) and the
-- loud-OOM rule (both malloc failure points branch to the rt_halt seat).
-- The rawcall symbols (opendir/readdir/closedir/fnmatch/malloc/free) are
-- plain libc under RawCallRaw — no whitelist — and are rows in
-- Mid.RtLang.Ast's rawcallArity for the surface checker.  Their list
-- positions are seats: the eight helpers here in helperDefuns, glob in
-- primDefuns.  direntNameOffset (RtLayout) reads as the literal 19 in the
-- surface text.

{- exec-plan DECODE (zigretire stage 3 GROUP 3B-2a) — planDecode as Mid.

execplan.zig's planDecode walks the TAGGED plan Value (the Shen demarshal
shape the Plan.* builders produce: EMPTY = [cons] = cons(sym"cons", nil),
NODE = [cons H T] = cons(sym"cons", cons(H, cons(T, nil))) with T the tagged
tail — a plain Elm list decodes as EMPTY-or-MALFORMED, never as a plan) and
builds a C-heap RProg blob per Mid.RtLayout's ep* constants.  The blob is
decoded by Rt.exec-plan itself; the RUN half (GROUP 3B-2b) walks the blob
directly via Rt.execGo, and the SLURP+RESULT half (GROUP 3B-2c) is
Rt.exec-run — no Zig seat remains.

THE WHOLE DECODE IS SAFEPOINT-FREE (Zig INVARIANT 1's Mid form: decode
performs zero GC allocation): no Lit LString (an interning safepoint — the
tag names ride as BYTES in a malloc'd cbuf instead), no RawAllocRaw, no
Rt.cons/intern.  That is what makes every raw temp below — the blob
pointers, the cbuf, and the string DATA pointers read while dupeZ'ing —
valid for the entire decode; malloc/free via RawCallRaw allocate nothing on
the GC heap.  Never allocate in any ep* helper.

MALLOC/FREE PAIRING (the brief's named rule): every level owns its own
allocations, keeps its running COUNT in the blob (prog[0]/pipe[0]/argc/
nredirs are updated after each successfully decoded element — Zig's
`n = i + 1` discipline), and frees EXACTLY the decoded prefix on failure
(epFreeChains/epFreeCmds/epFreeCmd/epFreeArgv/epFreeRedirs).  Decode failure
therefore leaks nothing before the loud halt.  The two OOM arms (cbuf/st/
arrays) halt immediately — process death, the glob precedent.

THE MID/ERROR-MODEL GAP, stated: Zig's decode failures throw ShenError,
which the old rt_prim route turned into "qbe-rt: prim exec-plan failed:
ShenError" + exit 1; Mid's arm is rt_halt ("qbe-rt: halt (a Mid prim
reached its halt arm)" + exit 1) — equally loud, different text, the same
documented class as every other halt arm.
-}


-- Rt.epSymIs / Rt.epCount / Rt.epElem / Rt.epNum / Rt.epStr / Rt.epSymOf /
-- Rt.epProg / Rt.epProgGo / Rt.epChain / Rt.epPipeline / Rt.epPipeGo /
-- Rt.epArgvGo / Rt.epRedirsGo / Rt.epRedir / Rt.epCountStdin /
-- Rt.epFreeChains / Rt.epFreeCmds / Rt.epFreeCmd / Rt.epFreeArgv /
-- Rt.epFreeRedirs MOVED TO THE SURFACE (T16 wave 8,
-- handoff-osier-tier2-t16): the exec-plan DECODE family lowers from
-- Mid/RtSource.elm — the epUnwrap TEMPLATE written out as three explicit
-- defuns (epNum +16/tag 0, epStr +8/tag 1, epSymOf +24/tag 2), the
-- Mid.RtLayout blob offsets transcribed as literals — every self-reference
-- is recur (App on the own key), MEASURED per defun.  Their list positions
-- below are seats.  Rt.epCmd moved in T24 (the ago/rgo binders fell with
-- the T23 block-branch if — its builder and tagCountState are deleted, its
-- list position below a seat).


-- ============================ exec-plan RUN (zigretire stage 3 GROUP 3B-2b) ============================
-- The RUN half of execRunDecoded (runProgram/runPipeline/applyRedirects/
-- childBuiltin + the tmpfile wiring) as Mid defuns over RawCallRaw libc seats
-- (fork/execvp/waitpid/_exit/pipe/dup2/close/openat/mkstemp/unlink/write/
-- lseek/chdir/getcwd/getpid/kill/getenv/malloc/free), operating DIRECTLY on
-- the decode blob (no Zig rebuild).  The SLURP+RESULT half is Rt.exec-run
-- (3B-2c); the rt_exec_run seat is deleted.
--
-- THE 3-ARG LEAN-ABI BOUND (Lower.elm rtArityErr): EVERY Rt defun has 1..3
-- params, and a saturated self-tail `App` (GRef own-key) is the ONLY loop.
-- All loop state therefore lives in a malloc'd STATE BLOCK threaded by its
-- one pointer param (the stage-4 collector-state pattern).  The state block
-- and every scratch the run mallocs are C-heap (RawCallRaw malloc), so they
-- are non-moving across every safepoint and fork.
--
-- THE CHILD-AFTER-FORK DISCIPLINE (execplan.zig INVARIANT 2, preserved): the
-- fork'd child's only work is RawCallRaw (libc) + reads of the C-heap
-- blob/cbuf/state block + _exit — NEVER a GC safepoint.  Every defun below
-- is therefore frame-free and allocation-free except where it mallocs a
-- C-heap scratch (a RawCallRaw, not a GC safepoint).
--
-- MALLOC/FREE PAIRING: pfds/pids and every scratch buffer are freed on EVERY
-- exit path including the fork-fail and pipe-fail unwinds; a leak is
-- invisible to every oracle.

-- cStrEqLit/wStr/wRaw/waitStatusCode MOVED TO THE SURFACE (T8 wave 1):
-- their surface text is in Mid.RtSource and lowers to the same trees
-- (cStrEqLit's self-tail recur included).  Rt.close, the next defun in
-- the old run here, stayed DSL-side — see its note above.


helperDefuns : Bool -> List Defun
helperDefuns rec =
    [ seat "Rt.deepEq" 2
    , seat "Rt.bytesEqGo" 3
    , seat "Rt.symEq" 3
    , seat "Rt.vecEq" 3
    , seat "Rt.asF" 1
    , seat "Rt.toI32" 1
    , seat "Rt.dgs" 1
    , seat "Rt.revGo" 2
    , seat "Rt.bytesOf" 2
    , seat "Rt.numText" 1
    , seat "Rt.bytesToStr" 1
    , seat "Rt.countL" 1
    , seat "Rt.fillGo" 3
      -- T12: cn2/appendL/symToStr/nameBytes/strOf moved to Mid/RtSource
      -- (the primCn coercion chain); their seats keep the list order.
    , seat "Rt.cn2" 2
    , seat "Rt.appendL" 2
    , seat "Rt.symToStr" 2
    , seat "Rt.nameBytes" 2
    , seat "Rt.strOf" 1
      -- T13: assocGo + the rec walk family moved to Mid/RtSource
      -- (handoff-osier-tier2-t13); their seats keep the list order.
    , seat "Rt.assocGo" 2
      -- T22: subGo/repGo/bytesBuild moved to Mid/RtSource (the walk
      -- helpers, the never-scheduled family part 3); their seats keep
      -- the list order.
    , seat "Rt.subGo" 3
    , seat "Rt.repGo" 2
    , seat "Rt.bytesBuild" 3
    , seat "Rt.recGet" 2
    , seat "Rt.recGetGo" 3
    , seat "Rt.recUpd" 3
    , seat "Rt.recUpdFind" 3
    , seat "Rt.recUpdCopy" 3
    , seat "Rt.symLess" 3
    , seat "Rt.recAppendFind" 3
    , seat "Rt.recAppendDataGo" 3
    , seat "Rt.recAppendNamesGo" 3
    , seat "Rt.recAppend" 3
    , seat "Rt.recInsert" 3
    , seat "Rt.recToChain" 1
    , seat "Rt.recToChainGo" 3
    , seat "Rt.readFull" 3
    , seat "Rt.readFileGo" 1
    , seat "Rt.memGo" 2
    , seat "Rt.cStrFill" 3
      -- T12: floatCopy moved to Mid/RtSource; its seat keeps the position.
    , seat "Rt.floatCopy" 3
    , seat "Rt.cStrLenGo" 2
      -- T15: the eight glob helpers moved to Mid/RtSource (the readdir/
      -- fnmatch loop and its sort/build walkers); their seats keep the
      -- list order.
    , seat "Rt.globLastSlash" 2
    , seat "Rt.globIsDot" 1
    , seat "Rt.globIsDotDot" 1
    , seat "Rt.globScanGo" 1
    , seat "Rt.globStrLess" 3
    , seat "Rt.globSortShift" 3
    , seat "Rt.globSortGo" 3
    , seat "Rt.globBuildGo" 3
    , seat "Rt.cStrCopyGo" 3
    -- T16 (handoff-osier-tier2-t16) moved the exec-plan DECODE family to
    -- Mid/RtSource.elm — the twenty keys below are seats; Rt.epCmd is NOT
    -- migrated (its ago/rgo binders are unspellable Ifs-in-let-value — see
    -- the move-note above) and keeps its builder at its list position.
    , seat "Rt.epNum" 2
    , seat "Rt.epStr" 2
    , seat "Rt.epSymOf" 2
    , seat "Rt.epSymIs" 3
    , seat "Rt.epCount" 3
    , seat "Rt.epElem" 3
    , seat "Rt.epProg" 2
    , seat "Rt.epProgGo" 3
    , seat "Rt.epChain" 3
    , seat "Rt.epPipeline" 2
    , seat "Rt.epPipeGo" 3
    , seat "Rt.epCmd" 3
    , seat "Rt.epArgvGo" 3
    , seat "Rt.epRedirsGo" 3
    , seat "Rt.epRedir" 3
    , seat "Rt.epCountStdin" 3
    , seat "Rt.epFreeChains" 3
    , seat "Rt.epFreeCmds" 3
    , seat "Rt.epFreeCmd" 1
    , seat "Rt.epFreeArgv" 3
    , seat "Rt.epFreeRedirs" 3
    , seat "Rt.cStrEqLit" 3
    , seat "Rt.wStr" 2
    , seat "Rt.wRaw" 3
    , seat "Rt.waitStatusCode" 1
    -- T17 (handoff-osier-tier2-t17) moved the exec-plan RUN machinery to
    -- Mid/RtSource.elm — the twenty keys below are seats.  Rt.childCd moved
    -- in T24 (its second dirN binder fell with the T23 block-branch if; its
    -- builder is deleted, its position a seat, and runLits/runLitsPacked/
    -- runOff/rLoad/rCbuf were its only readers — deleted with it, the cbuf
    -- literal offsets frozen as literals in the surface text: "/" 139,
    -- "\n" 173, "cd: " 240, cbuf 336).
    , seat "Rt.envHome" 1
    , seat "Rt.isChildBuiltin" 2
    , seat "Rt.echoGo" 3
    , seat "Rt.childCd" 3
    , seat "Rt.childPwd" 1
    , seat "Rt.childBuiltin" 3
    , seat "Rt.applyOneRedir" 2
    , seat "Rt.applyRedirects" 3
    , seat "Rt.bodyWriteGo" 3
    , seat "Rt.openBodyTmpfile" 2
    , seat "Rt.wireCmdGo" 3
    , seat "Rt.wirePipeGo" 3
    , seat "Rt.closeCmdTmpfds" 2
    , seat "Rt.closePipeTmpfds" 2
    , seat "Rt.closePipesGo" 3
    , seat "Rt.closeOthersGo" 3
    , seat "Rt.runBuiltinInprocess" 2
    , seat "Rt.execGo" 2
    , seat "Rt.mkTmpAt" 1
    ]


-- ============================ PRIM DEFUNS ============================


-- Rt.cons / Rt.@p moved to Mid/RtSource.elm in T12
-- (handoff-osier-tier2-t12) as the @consArr-guarded family: TWO variants
-- per key, @consArr = the (A) ONE-pointer fused pair (the RawMkValue
-- carries only the pair head; the cdr word stays ZERO — storeValueWords
-- zeroes unwritten words — and every cdr reader derives it as pair[1]),
-- @!consArr = the pre-(A) two-word pair (the QBE_NOCONSARR=1 hatch,
-- which reproduces the 00cc7da corpus byte-for-byte).  The WithRoots
-- rooting discipline and the alloc-first evaluation order are spelled
-- in the surface text; the DSL's single three-binder Let and the
-- statement layer's nested 1-binder Lets emit identical .ssa
-- (Qbe/Lower.lowerLetBinders folds a Let's binder list in order).
-- Their list positions in primDefuns below are seats.

-- Rt.con / Rt.conFill / Rt.closure / Rt.closureFill MOVED TO THE SURFACE
-- (T22, the never-scheduled family part 3 — FINAL): the constructor layer
-- (RawAllocVector + the staged-block copy walks + the tag-10/tag-6 wraps)
-- transcribed in Mid/RtSource's T22 block; their seats keep the order in
-- primDefuns below.


-- Rt.closure desc capBase K — the Mid closure (zigretire stage 5 PART 2):
-- allocate a K-Value env array through `RawAllocVector` (under QBE_MIDGC=1
-- the Mid collector's seat `Rt.allocVector`), copy the K captures from the
-- caller's STAGED contiguous block (capBase), and wrap as a tag-6 lambda
-- Value whose `code` is the static Desc pointer and whose `code_len` is
-- the Desc's arity.  Mirrors values.valLambda (the Zig seat
-- rt_make_closure calls) word for word.  The captures survive the
-- allocation because they live in the caller's ROOTED frame — the Zig
-- contract, unchanged; desc/capBase/K live in Rt.closure's OWN rooted
-- frame (Rt.closure is `allocating`).  The copy is Rt.closureFill —
-- conFill's 0-BASED twin (the env array has NO tag slot, so env[i] =
-- cap[i], whereas Con's vector stores args at [1..n] past the tag at
-- [0]); alloc-free, so the copy is not itself a safepoint.
--
-- code_len comes from the Desc's arity WORD (offset 8 = `{ w arity,
-- w ncaps }`: arity in the low 32 bits, ncaps in the high 32).  Storing
-- the full word as lambda payload word 1 puts arity in the low half —
-- read as the i32 `code_len` field — and ncaps in the high half, which
-- is the Value's padding that Zig's struct store leaves UNWRITTEN and no
-- reader (applyGo, the collectors, the nursery predicate) ever reads.
--
-- MOVED TO THE SURFACE (T22): the tree above (the allocvec, the arity
-- wload, the closureFill copy call, the mkval(6, ..) wrap) is
-- transcribed in Mid/RtSource's T22 block; the DSL defuns are deleted
-- and the list positions in primDefuns below are seats.  The code_len
-- note stays — it is the reason the surface spells `wload(descW, 1)`.


-- Rt.emptylist MOVED TO THE SURFACE (T8 wave 1): the surface text in
-- Mid.RtSource lowers to the same tree (tagis/and2 cond, mknil arm, the
-- rt_halt dead binder); TestMain's T6 compile-back row pins the shape.


-- Rt.= MOVED TO THE SURFACE (T10 wave 3): FOUR @guard-conjunction variants
-- of one key -- @rec@eqPtrFast / @rec@!eqPtrFast / @!rec@eqPtrFast /
-- @!rec@!eqPtrFast -- the 2x2 product of the two switches eqDefun took
-- (the symFast or2 at three sites, the rec tag-14 tail).  Its primDefuns
-- position below is a seat.


-- Rt.+ / Rt.- / Rt.* MOVED TO THE SURFACE (T20 wave: the never-scheduled
-- arithmetic family): the float-promote guard then either the f64 op over
-- `fload(call Rt.asF(..))` or the BARE i64 op; TestMain's T20 splice rows
-- pin the shapes.  Rt.< <= > >= moved in the SAME wave — the nested
-- term-if spells the DSL's iff-in-iff (both operands numeric or `false`;
-- either float promotes to the f64 compare, else the signed i64 compare).


-- The Bitwise family (bit2Defun/bitNotDefun/shlDefun/sarDefun/shrDefun —
-- the seven Rt.bitwise-* keys) MOVED TO THE SURFACE (T21, the
-- never-scheduled family part 2): JS int32 semantics — operands through
-- toI32, ops at word width, shift counts masked mod 32 — transcribed in
-- Mid/RtSource's T21 block; their seats keep the order in primDefuns
-- below.


-- Rt.number? / string? / cons? / empty? MOVED TO THE SURFACE (T20):
-- predDefun's List.foldr OR-chain spelled out per defun — number? keeps
-- the fold's RIGHT-nested shape (`tag 0 || (tag 12 || false)`), the
-- single-tag preds are `tag N || false`.


-- The string prims (cstrlenDefun/charCodeAtDefun/substringDefun/cnDefun/
-- repeatDefun/strToBytesDefun/bytesToStringDefun — Rt.c-strlen, char-code,
-- substring, cn, repeat, shen.str->bytes, shen.bytes->string) MOVED TO
-- THE SURFACE (T21, the never-scheduled family part 2): the bounds test
-- as a boxed `&&`, substring's clamps as the T9b `?:` value joins, the
-- halt arms as the rt_halt dead binder — transcribed in Mid/RtSource's
-- T21 block; their seats keep the order in primDefuns below.


-- Rt.absvector / Rt.address-> / Rt.<-address / Rt.assoc / Rt.snd moved to
-- Mid/RtSource.elm in T13 (handoff-osier-tier2-t13) — the desugar set's
-- value prims (primAbsvector/primAddressSet/primAddressGet/primAssoc/
-- primSnd), their `defun` text now there; their list positions below
-- (primDefuns) are seats.


{-| `primDefuns consArr rec eqPtrFast` — the flag params are KEPT for
signature stability but DEAD since T10/T12: eqDefun (T10) and
consDefun/atpDefun (T12) moved to Mid/RtSource as `@flag`-guarded
surface variants; their list-head positions are seats.  Selecting the
ACTIVE variant happens in `Mid.Rt.activeSurf` under
`Mid.Rt.activeFlags`.
-}
primDefuns : Bool -> Bool -> Bool -> List Defun
primDefuns consArr rec eqPtrFast =
    [ -- T12: cons/atp moved to Mid/RtSource as the @consArr guard family;
      -- these seats keep their list positions (primDefuns' head).
    seat "Rt.cons" 2
    , seat "Rt.@p" 2
      -- T22: con/conFill/closure/closureFill moved to Mid/RtSource (the
      -- constructor layer, the never-scheduled family part 3); these
      -- seats keep their list positions.
    , seat "Rt.con" 3
    , seat "Rt.conFill" 3
    , seat "Rt.closure" 3
    , seat "Rt.closureFill" 3
    , seat "Rt.emptylist" 1
    , seat "Rt.=" 2
      -- T20: the arithmetic + comparison + tag-predicate families moved to
      -- Mid/RtSource (handoff-osier-tier2-t20); their seats keep the order.
    , seat "Rt.+" 2
    , seat "Rt.-" 2
    , seat "Rt.*" 2
    , seat "Rt./" 2
    , seat "Rt.f/" 2
    , seat "Rt.<" 2
    , seat "Rt.<=" 2
    , seat "Rt.>" 2
    , seat "Rt.>=" 2
    , seat "Rt.bitwise-and" 2
    , seat "Rt.bitwise-not" 1
    , seat "Rt.bitwise-or" 2
    , seat "Rt.bitwise-shift-left" 2
    , seat "Rt.bitwise-shift-right" 2
    , seat "Rt.bitwise-shift-right-zf" 2
    , seat "Rt.bitwise-xor" 2
      -- T20: the tag predicates moved to Mid/RtSource; their seats keep
      -- the order.  The Bitwise family joined them in T21 (the
      -- never-scheduled family part 2) — seats too.
    , seat "Rt.number?" 1
    , seat "Rt.string?" 1
    , seat "Rt.cons?" 1
    , seat "Rt.empty?" 1
    , seat "Rt.c-strlen" 1
    , seat "Rt.char-code" 2
    , seat "Rt.substring" 3
    , seat "Rt.cn" 2
    , seat "Rt.repeat" 2
    , seat "Rt.shen.str->bytes" 1
    , seat "Rt.shen.bytes->string" 1
      -- T21: the seven string prims above moved to Mid/RtSource too
      -- (the never-scheduled family part 2) — seats keep the order.
      -- T13: absvector/address->/<-address/assoc/snd moved to Mid/RtSource
      -- (handoff-osier-tier2-t13); their seats keep the list order.
    , seat "Rt.absvector" 1
    , seat "Rt.address->" 3
    , seat "Rt.<-address" 2
    , seat "Rt.assoc" 2
    , seat "Rt.snd" 1
    , seat "Rt.write-byte" 2
    , -- T14: read-byte/open/intern/value/str/getcwd/cd/getenv/setenv
      -- moved to Mid/RtSource (handoff-osier-tier2-t14); their seats keep
      -- the list order.
    seat "Rt.read-byte" 1
    , seat "Rt.open" 2
    , seat "Rt.close" 1
    , seat "Rt.intern" 1
    , seat "Rt.value" 1
    , seat "Rt.str" 1
    , seat "Rt.getpid" 1
    , seat "Rt.getcwd" 1
    , seat "Rt.cd" 1
    , seat "Rt.getenv" 1
    , seat "Rt.setenv" 2
      -- T15: glob moved to Mid/RtSource (the sorted tagged match list; its
      -- eight helpers seat in helperDefuns above).
    , seat "Rt.glob" 1
    -- T17: exec-plan + exec-run moved to Mid/RtSource (the RUN machinery
    -- wave); their seats keep the list order.
    , seat "Rt.exec-plan" 1
    , seat "Rt.exec-run" 3
      -- T22: read-file-as-string moved to Mid/RtSource (the never-scheduled
      -- family part 3); its seat keeps the list position.
    , seat "Rt.read-file-as-string" 1
    ]
