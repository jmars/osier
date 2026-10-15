module Mid.RtPrims exposing
    ( primDefuns
    , helperDefuns
    , seat
    )

{-| Mid.RtPrims — the PRIM BODIES of the Mid-written runtime (handoff
osier-midprims, TRACK 2 step 5: the mechanical remainder after the cons
spike).


## WHAT IS HERE (post-T19)

123 MIGRATION SEATS — the defun-list positions `Mid.Rt.spliceSurface`
replaces by key (24 in `primDefuns`, 87 in `helperDefuns`, 12 in
Mid.RtGc's `gcProgram`) — and the 39 DSL-bodied HOLDOUTS at the keys the
surface does not yet carry, each a Mid.Ir tree transcribed NODE FOR NODE
from the Zig original in vendor/osier-rt/src/rt/prims.zig / values.zig /
streams.zig / execplan.zig.  The seats are `seat` tripwires: the real
bodies of the migrated keys live in Mid.RtSource's surface text.  Mid.Rt
maps the surface prim names onto the prim keys (`primImpl`); Mid.Rt.rtDeps
closes the RawCall edges for reachability.


## THE HOLDOUT INVENTORY (T19 — what the tier-2 surface cannot express
## today, and what it was never asked to)

WALL-CLASS — UNSPELLABLE in the surface TODAY (the grammar-gap record; any
future grammar work starts here).  The common shape: an If BOUND IN A
LET-VALUE whose branch carries a Let-chain and whose VALUE the continuation
subsequently READS.  All three spellings the grammar offers fail: the `?:`
value-join takes EXPRESSION branches (no lets); the both-diverge
statement-if needs the bound value DEAD (these are read); else-nesting
needs a diverging then (the then IS the value).  T9 found the class
(readFileGo's growB), T16 and T17 confirmed it twice more:

  - Rt.readFileGo (`readFileGoDefun`): `growB` — the grow/no-grow decision;
    its then-branch chains the malloc + state-block stores, and the
    continuation tests `growB == 1` for the OOM stop.
  - Rt.epCmd (`epCmdDefun`): `ago` and `rgo` — each dispatches a Go helper
    in a let-value If whose branches carry malloc/store/clear chains, and
    the continuation tests `ago < 0` / `rgo < 0` to unwind.
  - Rt.childCd (`childCdDefun`): `dirN` binder #2 — the argv[1]-or-HOME
    resolution; its else chains `ln = cStrLenGo dirN`, and binder #3 plus
    `ln` read `dirN` after.

Their ELM-SIDE CO-HELPERS are spellable in isolation and migrate only with
their callers:

  - `tagCountState` (an Elm Exp-of-Exp function; single caller epCmd): its
    tree is the `?:` join class, but migrating epCmd means WRITING IT OUT
    at the `subState` binder — the surface has no intra-defun abstraction
    (T16's epUnwrap precedent, written out as three defuns).
  - `runLits` / `runLitsPacked` / `runOff` / `rLoad` / `rCbuf` (childCd's):
    `runOff` computes byte offsets into the packed cbuf literal list at
    ELM-compile time; the surface has no constant evaluator, so migrating
    childCd means freezing those offsets as literals (T17 computed them:
    "/" = 139, "\n" = 173, "cd: " = 240; cbuf size 336).

NEVER-SCHEDULED — SPELLABLE TODAY; no wave covered them.  T8-T18 migrated
123 keys; these 36 were left out of every wave's list, not blocked by any
wall.  A future wave can transcribe them with the existing grammar:

  - the arithmetic family Rt.+ - * / f/ (float-promote or bare i64 wrap);
  - the comparisons Rt.< <= > >= (`cmpDefun`: numeric-guard + promote);
  - the Bitwise family Rt.bitwise-and/or/xor/not/-shift-left/right/
    right-zf (`bit2Defun`/shl/sar/shr: toI32, ops at i32, mod-32 counts);
  - the tag predicates Rt.number?/string?/cons?/empty? (`predDefun`'s
    tag-or-fold, spelled explicitly per defun);
  - the string prims Rt.c-strlen / char-code / substring / cn / repeat /
    shen.str->bytes / shen.bytes->string — substring's clamped binders are
    the T9b `?:` join class (numText precedent), the rest are plain;
  - the constructor layer Rt.con / conFill / closure / closureFill
    (RawAllocVector + the staged-block copies; the allocvec/vecstore/
    vecload builtins all exist);
  - the walk helpers Rt.subGo / repGo / bytesBuild / symLess (plain value
    recursion over RawCall self-edges);
  - Rt.read-file-as-string — its OOM binders (blkOOM/tmpOOM) LOOK like the
    wall class but are DEAD-VALUE binders (never read), so the T15/T16
    both-diverge statement-if spelling applies; the rest of the body is
    plain lets and a tail if.


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

import Mid.Ir exposing (Binder, Defun, Exp(..), LetBinder(..), Lit(..), RawBinOp(..), RawCmpOp(..), RawFltBinOp(..), RawFltCmpOp(..), RawUnOp(..), UnsafeNode(..))
import Mid.RtLayout as RtLayout


-- ============================ BUILDER DSL ============================
-- The trees below are read as PORTS: each `let` binder is one line of the
-- Zig body, in the Zig body's order.  Tag constants mirror Lower's
-- (gc/types.zig ValTag): number 0, string 1, symbol 2, boolean 3, cons 4,
-- nil 5, prim 8, vector 10, float 12.


n : Int -> Exp
n i =
    Lit (LNumber i)


v : Binder -> Exp
v binder =
    Var binder.id


b : Int -> Binder
b i =
    { id = i, name = "t" ++ String.fromInt i }


p1 : Binder
p1 =
    { id = 1, name = "a1" }


p2 : Binder
p2 =
    { id = 2, name = "a2" }


p3 : Binder
p3 =
    { id = 3, name = "a3" }


{-| Sequential `let`s, threaded left to right like the Zig body's lines.
-}
lets : List ( Binder, Exp ) -> Exp -> Exp
lets binds body =
    case binds of
        [] ->
            body

        ( binder, value ) :: rest ->
            Let
                { binders = [ LetBind { binder = binder, value = value } ]
                , body = lets rest body
                }


iff : Exp -> Exp -> Exp -> Exp
iff cond thenBranch elseBranch =
    If
        { cond = cond
        , thenBranch = thenBranch
        , elseBranch = elseBranch
        , falseLabel = "F"
        , endLabel = "E"
        }


and2 : Exp -> Exp -> Exp
and2 left right =
    ShortAnd
        { left = left
        , right = right
        , falseLabel = "F"
        , endLabel = "E"
        }


or2 : Exp -> Exp -> Exp
or2 left right =
    ShortOr
        { left = left
        , right = right
        , falseLabel = "F"
        , endLabel = "E"
        }


-- ---- words ----

wOf : Exp -> Exp
wOf x =
    Unsafe (RawPayload { value = x, word = 0 })


{-| The i32 LENGTH field (word 1) of a string or vector Value.  (The i32
word-0 read the deleted boolean-payload builders used — the DSL `w32Of` —
died with its readers in T19; the surface spells `payload32(x, 0)` where a
body needs it.)
-}
lenOf : Exp -> Exp
lenOf x =
    Unsafe (RawPayload32 { value = x, word = 1 })


-- ---- values ----
iadd x y =
    Unsafe (RawBin { op = RAdd, a = x, b = y })


isub : Exp -> Exp -> Exp
isub x y =
    Unsafe (RawBin { op = RSub, a = x, b = y })


imul : Exp -> Exp -> Exp
imul x y =
    Unsafe (RawBin { op = RMul, a = x, b = y })


idiv : Exp -> Exp -> Exp
idiv x y =
    Unsafe (RawBin { op = RDiv, a = x, b = y })


iand : Exp -> Exp -> Exp
iand x y =
    Unsafe (RawBin { op = RBitAnd, a = x, b = y })


ior : Exp -> Exp -> Exp
ior x y =
    Unsafe (RawBin { op = RBitOr, a = x, b = y })


ixor : Exp -> Exp -> Exp
ixor x y =
    Unsafe (RawBin { op = RBitXor, a = x, b = y })


shlW : Exp -> Exp -> Exp
shlW x count =
    Unsafe (RawBin { op = RShl, a = x, b = count })


sarW : Exp -> Exp -> Exp
sarW x count =
    Unsafe (RawBin { op = RShAr, a = x, b = count })


shrW : Exp -> Exp -> Exp
shrW x count =
    Unsafe (RawBin { op = RShR, a = x, b = count })


cmpW : RawCmpOp -> Exp -> Exp -> Exp
cmpW op x y =
    Unsafe (RawCmp { op = op, a = x, b = y })


tagIs : Exp -> Int -> Exp
tagIs x tag =
    Unsafe (RawTagIs { value = x, tag = tag })


flOf : Exp -> Exp
flOf x =
    Unsafe (RawLoadFlt x)


fbin : RawFltBinOp -> Exp -> Exp -> Exp
fbin op x y =
    Unsafe (RawFltBin { op = op, a = x, b = y })


fcmp : RawFltCmpOp -> Exp -> Exp -> Exp
fcmp op x y =
    Unsafe (RawFltCmp { op = op, a = x, b = y })


-- ---- values ----

mkNum : Exp -> Exp
mkNum we =
    Unsafe (RawMkValue { tag = RtLayout.tagNumber, words = [ we ] })


mkBool : Exp -> Exp
mkBool we =
    Unsafe (RawMkValue { tag = RtLayout.tagBoolean, words = [ we ] })


mkNil : Exp
mkNil =
    Unsafe (RawMkValue { tag = RtLayout.tagNil, words = [] })


mkStr : Exp -> Exp -> Exp
mkStr dataW lenW =
    Unsafe (RawMkValue { tag = RtLayout.tagString, words = [ dataW, lenW ] })


mkFlt : Exp -> Exp
mkFlt fwe =
    Unsafe (RawMkValue { tag = RtLayout.tagFloat, words = [ fwe ] })


mkVec : Exp -> Exp -> Exp
mkVec dataW lenW =
    Unsafe (RawMkValue { tag = RtLayout.tagVector, words = [ dataW, lenW ] })


trueV : Exp
trueV =
    mkBool (n 1)


falseV : Exp
falseV =
    mkBool (n 0)


callR : String -> List Exp -> Exp
callR key args =
    Unsafe (RawCall { sym = key, args = args })


callW : String -> List Exp -> Exp
callW sym args =
    Unsafe (RawCallRaw { sym = sym, args = args })


consV : Exp -> Exp -> Exp
consV car cdr =
    callR "Rt.cons" [ car, cdr ]


carV : Exp -> Exp
carV l =
    Unsafe (RawVecLoad { vec = wOf l, index = n 0 })


cdrV : Exp -> Exp
cdrV l =
    Unsafe (RawVecLoad { vec = wOf l, index = n 1 })


byteOf : Exp -> Exp -> Exp
byteOf s indexW =
    Unsafe (RawStrByte { str = s, index = indexW })


lam : String -> List Binder -> Exp -> Defun
lam key params body =
    { key = key
    , value = Lam { params = params, body = body }
    }


{-| A migration SEAT (T8, handoff-osier-tier2-t8): the defun-list POSITION
a surface-migrated key still occupies.  `Mid.Rt.spliceSurface` replaces
entries BY KEY at their list position — list ORDER is .ssa bytes — so a
migrated defun leaves its builder to the surface but KEEPS this position.
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


haltV : Exp
haltV =
    -- the halt arm: process death through the rt_halt seat (see the module
    -- header's GAPS — Zig's arm is a catchable throw / error.Halt; Mid has
    -- no error mechanism this step, and on QBE error.Halt dies loudly too).
    letL [ ( b 30, callW "rt_halt" [] ) ] mkNil


letL : List ( Binder, Exp ) -> Exp -> Exp
letL =
    lets


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


{-| subGo s i end — s's bytes in [i, end) as a list (substring's copy).
-}
subGoDefun : Defun
subGoDefun =
    let
        s =
            p1

        i =
            p2

        e =
            p3
    in
    lam "Rt.subGo" [ s, i, e ]
        (iff (mkBool (cmpW RCges (wOf (v i)) (wOf (v e))))
            mkNil
            (consV (mkNum (byteOf (v s) (wOf (v i))))
                (callR "Rt.subGo" [ v s, mkNum (iadd (wOf (v i)) (n 1)), v e ])
            )
        )


{-| repGo s i — i copies of s's bytes appended (repeat's doubling in Zig is
an optimization; the byte RESULT is s^n either way).
-}
repGoDefun : Defun
repGoDefun =
    let
        s =
            p1

        i =
            p2
    in
    lam "Rt.repGo" [ s, i ]
        (iff (mkBool (cmpW RCles (wOf (v i)) (n 0)))
            mkNil
            (callR "Rt.appendL"
                [ callR "Rt.bytesOf" [ v s, mkNum (n 0) ]
                , callR "Rt.repGo" [ v s, mkNum (isub (wOf (v i)) (n 1)) ]
                ]
            )
        )


{-| bytesBuild s i acc — str->bytes' back-to-front walk: cons byte[i-1]
onto acc and recurse at i-1; entered at i = len.
-}
bytesBuildDefun : Defun
bytesBuildDefun =
    let
        s =
            p1

        i =
            p2

        acc =
            p3
    in
    lam "Rt.bytesBuild" [ s, i, acc ]
        (iff (mkBool (cmpW RCles (wOf (v i)) (n 0)))
            (v acc)
            (callR "Rt.bytesBuild"
                [ v s
                , mkNum (isub (wOf (v i)) (n 1))
                , consV (mkNum (byteOf (v s) (isub (wOf (v i)) (n 1)))) (v acc)
                ]
            )
        )


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


{-| `Rt.symLess a b i` — byte-lexicographic LESS-THAN of two symbol Values'
names (symEq tests equality only; the sorted-insert path needs `<`).  Mirrors
symEq's walk: byte at i, null-termination decides prefix order.
-}
symLessDefun : Defun
symLessDefun =
    let
        a =
            p1

        bb =
            p2

        i =
            p3

        ca =
            b 4

        cb =
            b 5
    in
    lam "Rt.symLess" [ a, bb, i ]
        (lets
            [ ( ca, mkNum (byteOf (v a) (wOf (v i))) )
            , ( cb, mkNum (byteOf (v bb) (wOf (v i))) )
            ]
            (iff (mkBool (cmpW RCeq (wOf (v ca)) (n 0)))
                (mkBool (cmpW RCne (wOf (v cb)) (n 0)))
                (iff (mkBool (cmpW RCeq (wOf (v cb)) (n 0)))
                    falseV
                    (iff (mkBool (cmpW RClts (wOf (v ca)) (wOf (v cb))))
                        trueV
                        (iff (mkBool (cmpW RCgts (wOf (v ca)) (wOf (v cb))))
                            falseV
                            (callR "Rt.symLess" [ v a, v bb, mkNum (iadd (wOf (v i)) (n 1)) ])
                        )
                    )
                )
            )
        )


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


{-| The null-terminated copy of a string: the binders to prepend plus the
buffer WORD (a raw `Var`, usable directly in a raw argument position).  Alloc
len+1, re-read the data pointer AFTER the alloc (the Zig GC is moving), fill
+ NUL.  `base` supplies four fresh binder ids so a defun can inline this
twice (the open arms) without an id collision.
-}
cStrOf : Int -> Exp -> ( List ( Binder, Exp ), Exp )
cStrOf base path =
    let
        lenW =
            { id = base, name = "t" ++ String.fromInt base }

        bufW =
            { id = base + 1, name = "t" ++ String.fromInt (base + 1) }

        bufN =
            { id = base + 2, name = "t" ++ String.fromInt (base + 2) }

        fill =
            { id = base + 3, name = "t" ++ String.fromInt (base + 3) }
    in
    ( [ ( lenW, lenOf path )
      , ( bufW, Unsafe (RawAllocRaw (iadd (v lenW) (n 1))) )
      , ( bufN, mkNum (v bufW) )
      , ( fill, callR "Rt.cStrFill" [ v bufN, path, mkNum (n 0) ] )
      ]
    , v bufW
    )


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


{-| `Rt.read-file-as-string path` — primReadFileAsString.  Arity 1, FRAMED
(allocates: cStrOf, the result RawAllocRaw, and the "" literals).  The loop
state (fd/tmp/acc/len/cap at words 0..4) and the memcpy block (words 6..8)
share ONE 72-byte C-heap block; mblk = block+48 is passed to memGo.  All
state crossing the loop is C-heap or int — the two GC allocations (path copy,
result) sit OUTSIDE the loop's raw-pointer window, and the result buffer is
consumed by mkStr before any further allocation (the moving-GC discipline:
the raw temp is valid only to the next safepoint, and there is none between
the RawAllocRaw and the mkStr).
-}
readFileAsStringDefun : Defun
readFileAsStringDefun =
    let
        path =
            p1

        -- cStrOf 3: binders 3..6
        ( cstrBinds, cstr ) =
            cStrOf 3 (v path)

        fdW =
            b 7

        blkW =
            b 8

        blkN =
            b 9

        tmpW =
            b 10

        msg =
            b 11

        blkOOM =
            b 13

        tmpOOM =
            b 14

        stStores =
            [ ( b 16, Unsafe (RawWordStore { ptr = v blkW, index = n 0, value = v fdW }) )
            , ( b 17, Unsafe (RawWordStore { ptr = v blkW, index = n 1, value = v tmpW }) )
            , ( b 18, Unsafe (RawWordStore { ptr = v blkW, index = n 2, value = n 0 }) )
            , ( b 19, Unsafe (RawWordStore { ptr = v blkW, index = n 3, value = n 0 }) )
            , ( b 20, Unsafe (RawWordStore { ptr = v blkW, index = n 4, value = n 0 }) )
            ]

        lenW =
            b 22

        accW =
            b 23

        dstW =
            b 24
    in
    lam "Rt.read-file-as-string" [ path ]
        (lets
            (cstrBinds ++ [ ( fdW, callW "openat" [ n (-100), cstr, n 0, n 0 ] ) ])
            (iff (mkBool (cmpW RClts (v fdW) (n 0)))
                -- open failure: the stderr note + "" (Zig's catch arm — ANY
                -- open error, not just ENOENT)
                (lets
                    [ ( msg, Lit (LString "runtime: cannot open file for read-file-as-string\n") )
                    , ( b 12, callW "write" [ n 2, wOf (v msg), lenOf (v msg) ] )
                    ]
                    (Lit (LString ""))
                )
                -- success: state block, the read loop, then the ONE exit
                -- (build the result, free everything, close)
                (lets
                    ([ ( blkW, callW "malloc" [ n 72 ] )
                     , -- OOM is LOUD (glob's precedent: halt, never a NULL
                       -- write) — nothing else is allocated yet at this point.
                       ( blkOOM, iff (mkBool (cmpW RCeq (v blkW) (n 0))) haltV (mkNum (n 0)) )
                     , ( blkN, mkNum (v blkW) )
                     , ( tmpW, callW "malloc" [ n 65536 ] )
                     , -- tmp OOM: free the block FIRST (the pairing), then halt.
                       ( tmpOOM, iff (mkBool (cmpW RCeq (v tmpW) (n 0))) (lets [ ( b 15, callW "free" [ v blkW ] ) ] haltV) (mkNum (n 0)) )
                     ]
                        ++ stStores
                        ++ [ ( b 21, callR "Rt.readFileGo" [ v blkN ] ) ]
                    )
                    (lets
                        [ ( lenW, Unsafe (RawWordLoad { ptr = v blkW, index = n 3 }) )
                        , ( accW, Unsafe (RawWordLoad { ptr = v blkW, index = n 2 }) )
                        , ( dstW, Unsafe (RawAllocRaw (iadd (v lenW) (n 1))) )
                        , ( b 25, Unsafe (RawWordStore { ptr = v blkW, index = n 6, value = v accW }) )
                        , ( b 26, Unsafe (RawWordStore { ptr = v blkW, index = n 7, value = v dstW }) )
                        , ( b 27, Unsafe (RawWordStore { ptr = v blkW, index = n 8, value = v lenW }) )
                        , ( b 28, callR "Rt.memGo" [ mkNum (iadd (v blkW) (n 48)), mkNum (n 0) ] )
                        , -- valString parity: dst[len] = 0 (the length stays
                          -- the observable bound; nothing reads past it)
                          ( b 29, Unsafe (RawByteStore { ptr = v dstW, index = v lenW, value = n 0 }) )
                        , -- frees BEFORE the mkStr consume: they are raw
                          -- calls, no safepoint, so dstW stays valid.
                          ( b 30, callW "free" [ v accW ] )
                        , ( b 31, callW "free" [ v tmpW ] )
                        , ( b 32, callW "free" [ v blkW ] )
                        , ( b 33, callW "close" [ v fdW ] )
                        ]
                        (mkStr (v dstW) (v lenW))
                    )
                )
            )
        )


{-| `Rt.readFileGo blkN` — Zig's `while (true)` read loop, one self-tail
in-frame loop over the 72-byte C block (blkN boxes the block pointer):
word 0 = fd, 1 = tmp, 2 = acc, 3 = len, 4 = cap.  Each iteration:
readFull(fd, tmp, 65536) -> nV; nV < 0 -> STOP (read error: Zig's
`catch break`, partial buffer kept); nV == 0 -> STOP (EOF); else append
tmp[0..n) to acc (grow first when len+n > cap: newcap = max(2*cap, needed),
malloc, memGo the old content, free the OLD buffer — on malloc OOM STOP with
the old buffer INTACT, Zig's `appendSlice catch break`), then the loop.
FRAME-FREE and non-allocating: no safepoint anywhere (readFull/memGo/
malloc/free are raw; the state is C-heap), which is what makes the acc/tmp
raw pointers sound across iterations — the TestMain partition row pins it.
-}
readFileGoDefun : Defun
readFileGoDefun =
    let
        blkN =
            p1

        fdW =
            b 3

        tmpW =
            b 4

        nV =
            b 5

        lenW =
            b 6

        capW =
            b 7

        neededW =
            b 8

        growB =
            b 9
    in
    lam "Rt.readFileGo" [ blkN ]
        (lets
            [ ( fdW, Unsafe (RawWordLoad { ptr = wOf (v blkN), index = n 0 }) )
            , ( tmpW, Unsafe (RawWordLoad { ptr = wOf (v blkN), index = n 1 }) )
            , ( nV, callR "Rt.readFull" [ mkNum (v fdW), mkNum (v tmpW), mkNum (n 65536) ] )
            ]
            (iff (mkBool (cmpW RClts (wOf (v nV)) (n 0)))
                -- read error: break (partial content is the answer)
                mkNil
                (iff (mkBool (cmpW RCeq (wOf (v nV)) (n 0)))
                    -- EOF: break
                    mkNil
                    (lets
                        [ ( lenW, Unsafe (RawWordLoad { ptr = wOf (v blkN), index = n 3 }) )
                        , ( capW, Unsafe (RawWordLoad { ptr = wOf (v blkN), index = n 4 }) )
                        , ( neededW, iadd (v lenW) (wOf (v nV)) )
                        , ( growB, iff (mkBool (cmpW RCgts (v neededW) (v capW)))
                            -- grow arm: newcap = max(2*cap, needed)
                            (lets
                                -- newcap = max(2*cap, needed), as ARITHMETIC
                                -- (an iff's branches are VALUE positions and
                                -- a raw word binder cannot appear there):
                                -- needed + (2*cap - needed) * [2*cap > needed]
                                [ ( b 10, iadd (v neededW) (imul (isub (imul (v capW) (n 2)) (v neededW)) (cmpW RCgts (imul (v capW) (n 2)) (v neededW))) )
                                , ( b 11, callW "malloc" [ v (b 10) ] )
                                ]
                                (iff (mkBool (cmpW RCeq (v (b 11)) (n 0)))
                                    -- OOM: flag 1 = stop WITHOUT freeing the
                                    -- old buffer (it IS the partial answer;
                                    -- the exit path frees it)
                                    (mkNum (n 1))
                                    (lets
                                        [ ( b 12, Unsafe (RawWordLoad { ptr = wOf (v blkN), index = n 2 }) )
                                        , ( b 13, Unsafe (RawWordStore { ptr = wOf (v blkN), index = n 6, value = v (b 12) }) )
                                        , ( b 14, Unsafe (RawWordStore { ptr = wOf (v blkN), index = n 7, value = v (b 11) }) )
                                        , ( b 15, Unsafe (RawWordStore { ptr = wOf (v blkN), index = n 8, value = v lenW }) )
                                        , ( b 16, callR "Rt.memGo" [ mkNum (iadd (wOf (v blkN)) (n 48)), mkNum (n 0) ] )
                                        , ( b 17, callW "free" [ v (b 12) ] )
                                        , ( b 18, Unsafe (RawWordStore { ptr = wOf (v blkN), index = n 2, value = v (b 11) }) )
                                        , ( b 19, Unsafe (RawWordStore { ptr = wOf (v blkN), index = n 4, value = v (b 10) }) )
                                        ]
                                        (mkNum (n 0))
                                    )
                                )
                            )
                            -- needed <= cap: nothing to do
                            (mkNum (n 0))
                        )
                        ]
                        (iff (mkBool (cmpW RCeq (wOf (v growB)) (n 1)))
                            -- the OOM stop
                            mkNil
                            (lets
                                [ ( b 20, Unsafe (RawWordLoad { ptr = wOf (v blkN), index = n 2 }) )
                                , ( b 21, Unsafe (RawWordStore { ptr = wOf (v blkN), index = n 6, value = v tmpW }) )
                                , -- the append lands at acc + len (the
                                  -- memGo block's dst BASE — offset 0 here
                                  -- would overwrite the first chunk, the
                                  -- exact bug the tail-BAD differential
                                  -- caught).
                                  ( b 22, Unsafe (RawWordStore { ptr = wOf (v blkN), index = n 7, value = iadd (v (b 20)) (v lenW) }) )
                                , ( b 23, Unsafe (RawWordStore { ptr = wOf (v blkN), index = n 8, value = wOf (v nV) }) )
                                , ( b 24, callR "Rt.memGo" [ mkNum (iadd (wOf (v blkN)) (n 48)), mkNum (n 0) ] )
                                , ( b 25, Unsafe (RawWordStore { ptr = wOf (v blkN), index = n 3, value = v neededW }) )
                                ]
                                (App { fn = GRef { key = "Rt.readFileGo", force = False }, args = [ v blkN ] })
                            )
                        )
                    )
                )
            )
        )


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
-- below are seats.  Rt.epCmd STAYS HERE: its ago/rgo binders are Ifs in
-- LET-VALUE positions whose branches carry Lets and whose values the
-- continuation reads (iff (ago < 0) ..) — the surface grammar cannot spell
-- them (?: needs expression branches, both-diverge needs both branches
-- returning, else-nesting needs a diverging then); tagCountState stays
-- for it.


{-| The tdlIsEmpty state as a WORD: 0 empty, 1 node, 2 malformed.  Shared by
epCmd (the T16 wave's one ep* holdout — epCount and the fill loops migrated
to the surface and spell their own checks).
-}
tagCountState : Exp -> Exp -> Exp
tagCountState vv cbufW =
    iff (mkBool (cmpW RCeq (tagIs vv RtLayout.tagCons) (n 0)))
        (mkNum (n 2))
        (iff (mkBool (cmpW RCeq (tagIs (carV vv) RtLayout.tagSymbol) (n 0)))
            (mkNum (n 2))
            (iff (callR "Rt.epSymIs" [ carV vv, mkNum cbufW, mkNum (n 0) ])
                (iff (mkBool (cmpW RCne (tagIs (cdrV vv) RtLayout.tagNil) (n 0)))
                    (mkNum (n 0))
                    (iff (mkBool (cmpW RCne (tagIs (cdrV vv) RtLayout.tagCons) (n 0)))
                        (mkNum (n 1))
                        (mkNum (n 2))
                    )
                )
                (mkNum (n 2))
            )
        )


{-| epCmd e stN cAddrN — decodeCmd: [Argv Redirs Sub], len 3.  Argv strings
are dupeZ'd onto the C heap into a char*[argc] (argc doubles as the running
fill count); redirs into word records; sub recurses into epProg with depth+1
(st[1] is bumped and restored in place — the block is decode-private).
Every failure arm frees exactly what this level built, in reverse order
(Zig's cmdFree discipline).
-}
epCmdDefun : Defun
epCmdDefun =
    let
        e =
            p1

        stN =
            p2

        cAddrN =
            p3

        lim8 =
            b 4

        cnt =
            b 5

        argvv =
            b 6

        redirsv =
            b 7

        subv =
            b 8

        cbufW =
            b 9

        limArgv =
            b 10

        acnt =
            b 11

        argvW =
            b 12

        ago =
            b 13

        limRedir =
            b 14

        rcnt =
            b 15

        redirsW =
            b 16

        rgo =
            b 17

        subState =
            b 18

        depthW =
            b 19

        subN =
            b 21

        nstdin =
            b 23

        agoGo =
            b 20

        rgoGo =
            b 49

        -- free this level's argv (strings + array), then clear the slots.
        freeArgv =
            callR "Rt.epFreeArgv"
                [ mkNum (Unsafe (RawWordLoad { ptr = wOf (v cAddrN), index = n RtLayout.epCmdArgvIdx }))
                , mkNum (n 0)
                , mkNum (Unsafe (RawWordLoad { ptr = wOf (v cAddrN), index = n RtLayout.epCmdArgcIdx }))
                ]

        freeRedirs =
            callR "Rt.epFreeRedirs"
                [ mkNum (Unsafe (RawWordLoad { ptr = wOf (v cAddrN), index = n RtLayout.epCmdRedirsIdx }))
                , mkNum (n 0)
                , mkNum (Unsafe (RawWordLoad { ptr = wOf (v cAddrN), index = n RtLayout.epCmdNredirsIdx }))
                ]

        clearArgv =
            Unsafe (RawWordStore { ptr = wOf (v cAddrN), index = n RtLayout.epCmdArgvIdx, value = n 0 })

        clearRedirs =
            Unsafe (RawWordStore { ptr = wOf (v cAddrN), index = n RtLayout.epCmdRedirsIdx, value = n 0 })

        freeSub =
            -- epFreeChains frees BOTH the sub's chains array AND the sub prog
            -- record (its `free progN` leg) — no separate free of the record.
            callR "Rt.epFreeChains"
                [ mkNum (Unsafe (RawWordLoad { ptr = wOf (v cAddrN), index = n RtLayout.epCmdSubIdx }))
                , mkNum (Unsafe (RawWordLoad { ptr = Unsafe (RawWordLoad { ptr = wOf (v cAddrN), index = n RtLayout.epCmdSubIdx }), index = n RtLayout.epProgChainsIdx }))
                , mkNum (n 0)
                ]

        unwindAll =
            -- reverse build order: sub, redirs, argv
            lets
                [ ( b 26, iff (mkBool (cmpW RCne (Unsafe (RawWordLoad { ptr = wOf (v cAddrN), index = n RtLayout.epCmdSubIdx })) (n 0))) (freeSub) mkNil)
                , ( b 27, iff (mkBool (cmpW RCne (Unsafe (RawWordLoad { ptr = wOf (v cAddrN), index = n RtLayout.epCmdRedirsIdx })) (n 0))) (freeRedirs) mkNil)
                , ( b 28, Unsafe (RawWordStore { ptr = wOf (v cAddrN), index = n RtLayout.epCmdRedirsIdx, value = n 0 }) )
                , ( b 29, iff (mkBool (cmpW RCne (Unsafe (RawWordLoad { ptr = wOf (v cAddrN), index = n RtLayout.epCmdArgvIdx })) (n 0))) (freeArgv) mkNil)
                , ( b 30, Unsafe (RawWordStore { ptr = wOf (v cAddrN), index = n RtLayout.epCmdArgvIdx, value = n 0 }) )
                ]
                (mkNum (n (-1)))

        stdinGuard =
            -- the stdin-exclusivity check (Zig decodeCmd's tail, C:1358-1366):
            -- applies to BOTH plain commands and subshells, after the sub
            -- dispatch (the first cut nested it in the subshell arm only,
            -- so a plain `cat <a <b` was accepted — wrong, not loud).
            lets
                [ ( nstdin
                  , callR "Rt.epCountStdin"
                        [ mkNum (Unsafe (RawWordLoad { ptr = wOf (v cAddrN), index = n RtLayout.epCmdRedirsIdx }))
                        , mkNum (Unsafe (RawWordLoad { ptr = wOf (v cAddrN), index = n RtLayout.epCmdNredirsIdx }))
                        , mkNum (n 0)
                        ]
                  )
                ]
                (iff (mkBool (cmpW RCgts (wOf (v nstdin)) (n 1)))
                    (unwindAll)
                    (mkNum (n 0))
                )
    in
    lam "Rt.epCmd" [ e, stN, cAddrN ]
        (lets
            [ ( lim8, Unsafe (RawWordStore { ptr = wOf (v stN), index = n 2, value = n 8 }) )
            , ( cnt, callR "Rt.epCount" [ v e, v stN, mkNum (n 0) ] )
            , ( cbufW, Unsafe (RawWordLoad { ptr = wOf (v stN), index = n 0 }) )
            ]
            (iff (mkBool (cmpW RCne (wOf (v cnt)) (n 3)))
                (mkNum (n (-1)))
                (lets
                    [ ( argvv, callR "Rt.epElem" [ v e, mkNum (n 0), mkNum (n 0) ] )
                    , ( redirsv, callR "Rt.epElem" [ v e, mkNum (n 0), mkNum (n 1) ] )
                    , ( subv, callR "Rt.epElem" [ v e, mkNum (n 0), mkNum (n 2) ] )
                    , ( b 31, Unsafe (RawWordStore { ptr = wOf (v cAddrN), index = n RtLayout.epCmdArgvIdx, value = n 0 }) )
                    , ( b 32, Unsafe (RawWordStore { ptr = wOf (v cAddrN), index = n RtLayout.epCmdArgcIdx, value = n 0 }) )
                    , ( b 33, Unsafe (RawWordStore { ptr = wOf (v cAddrN), index = n RtLayout.epCmdRedirsIdx, value = n 0 }) )
                    , ( b 34, Unsafe (RawWordStore { ptr = wOf (v cAddrN), index = n RtLayout.epCmdNredirsIdx, value = n 0 }) )
                    , ( b 35, Unsafe (RawWordStore { ptr = wOf (v cAddrN), index = n RtLayout.epCmdSubIdx, value = n 0 }) )
                    , ( limArgv, Unsafe (RawWordStore { ptr = wOf (v stN), index = n 2, value = n 256 }) )
                    , ( acnt, callR "Rt.epCount" [ v argvv, v stN, mkNum (n 0) ] )
                    ]
                    (iff (or2 (mkBool (cmpW RClts (wOf (v acnt)) (n 0))) (mkBool (cmpW RCgts (wOf (v acnt)) (n 256))))
                        (mkNum (n (-1)))
                        (lets
                            [ ( ago
                              , iff (mkBool (cmpW RCeq (wOf (v acnt)) (n 0)))
                                    (mkNum (n 0))
                                    (lets
                                        [ ( argvW, callW "malloc" [ iadd (imul (wOf (v acnt)) (n 8)) (n 8) ] )
                                        , ( b 36, iff (mkBool (cmpW RCeq (v argvW) (n 0))) haltV (mkNum (n 0)) )
                                        , ( b 37, Unsafe (RawWordStore { ptr = wOf (v cAddrN), index = n RtLayout.epCmdArgvIdx, value = v argvW }) )
                                        , ( agoGo, callR "Rt.epArgvGo" [ v argvv, v stN, v cAddrN ] )
                                        ]
                                        (iff (mkBool (cmpW RClts (wOf (v agoGo)) (n 0)))
                                            -- epArgvGo already freed the strings and
                                            -- the array; clear the slot and stop.
                                            (lets [ ( b 38, clearArgv ) ] (mkNum (n (-1))))
                                            -- (3B-2b) the argv array carries the NULL
                                            -- terminator Zig's [:null] slice gave the
                                            -- rebuilt RCmd: execvp reads argv[argc].
                                            (lets [ ( b 39, Unsafe (RawWordStore { ptr = v argvW, index = wOf (v acnt), value = n 0 }) ) ]
                                                (mkNum (n 0))
                                            )
                                        )
                                    )
                              )
                            ]
                            (iff (mkBool (cmpW RClts (wOf (v ago)) (n 0)))
                                (mkNum (n (-1)))
                                (lets
                                    [ ( limRedir, Unsafe (RawWordStore { ptr = wOf (v stN), index = n 2, value = n 64 }) )
                                    , ( rcnt, callR "Rt.epCount" [ v redirsv, v stN, mkNum (n 0) ] )
                                    ]
                                    (iff (or2 (mkBool (cmpW RClts (wOf (v rcnt)) (n 0))) (mkBool (cmpW RCgts (wOf (v rcnt)) (n 64))))
                                        (lets
                                            [ ( b 39, iff (mkBool (cmpW RCne (Unsafe (RawWordLoad { ptr = wOf (v cAddrN), index = n RtLayout.epCmdArgvIdx })) (n 0))) (freeArgv) mkNil)
                                            , ( b 40, Unsafe (RawWordStore { ptr = wOf (v cAddrN), index = n RtLayout.epCmdArgvIdx, value = n 0 }) )
                                            ]
                                            (mkNum (n (-1)))
                                        )
                                        (lets
                                            [ ( rgo
                                              , iff (mkBool (cmpW RCeq (wOf (v rcnt)) (n 0)))
                                                    (mkNum (n 0))
                                                    (lets
                                                        [ ( redirsW, callW "malloc" [ imul (wOf (v rcnt)) (n (8 * RtLayout.epRedirWords)) ] )
                                                        , ( b 41, iff (mkBool (cmpW RCeq (v redirsW) (n 0))) haltV (mkNum (n 0)) )
                                                        , ( b 42, Unsafe (RawWordStore { ptr = wOf (v cAddrN), index = n RtLayout.epCmdRedirsIdx, value = v redirsW }) )
                                                        , ( rgoGo, callR "Rt.epRedirsGo" [ v redirsv, v stN, v cAddrN ] )
                                                        ]
                                                        (iff (mkBool (cmpW RClts (wOf (v rgoGo)) (n 0)))
                                                            -- epRedirsGo freed the
                                                            -- redir prefix + array;
                                                            -- then argv too.
                                                            (lets
                                                                [ ( b 43, Unsafe (RawWordStore { ptr = wOf (v cAddrN), index = n RtLayout.epCmdRedirsIdx, value = n 0 }) )
                                                                , ( b 44, iff (mkBool (cmpW RCne (Unsafe (RawWordLoad { ptr = wOf (v cAddrN), index = n RtLayout.epCmdArgvIdx })) (n 0))) (freeArgv) mkNil)
                                                                , ( b 45, Unsafe (RawWordStore { ptr = wOf (v cAddrN), index = n RtLayout.epCmdArgvIdx, value = n 0 }) )
                                                                ]
                                                                (mkNum (n (-1)))
                                                            )
                                                            (mkNum (n 0))
                                                        )
                                                    )
                                              )
                                            ]
                                            (iff (mkBool (cmpW RClts (wOf (v rgo)) (n 0)))
                                                (mkNum (n (-1)))
                                                (lets
                                                    [ ( subState, tagCountState (v subv) (v cbufW) ) ]
                                                    (iff (mkBool (cmpW RCeq (wOf (v subState)) (n 2)))
                                                        (unwindAll)
                                                        (iff (mkBool (cmpW RCeq (wOf (v subState)) (n 0)))
                                                            -- plain command: empty argv is illegal (C:1343)
                                                            (iff (mkBool (cmpW RCeq (Unsafe (RawWordLoad { ptr = wOf (v cAddrN), index = n RtLayout.epCmdArgvIdx })) (n 0)))
                                                                (unwindAll)
                                                                stdinGuard
                                                            )
                                                            -- subshell: no argv allowed, depth < 32
                                                            (iff (mkBool (cmpW RCne (Unsafe (RawWordLoad { ptr = wOf (v cAddrN), index = n RtLayout.epCmdArgvIdx })) (n 0)))
                                                                (unwindAll)
                                                                (lets
                                                                    [ ( depthW, Unsafe (RawWordLoad { ptr = wOf (v stN), index = n 1 }) )
                                                                    ]
                                                                    (iff (mkBool (cmpW RCges (v depthW) (n 32)))
                                                                        (unwindAll)
                                                                        (lets
                                                                            [ ( b 46, Unsafe (RawWordStore { ptr = wOf (v stN), index = n 1, value = iadd (v depthW) (n 1) }) )
                                                                            , ( subN, callR "Rt.epProg" [ v subv, v stN ] )
                                                                            , ( b 47, Unsafe (RawWordStore { ptr = wOf (v stN), index = n 1, value = v depthW }) )
                                                                            ]
                                                                            (iff (mkBool (cmpW RClts (wOf (v subN)) (n 0)))
                                                                                (unwindAll)
                                                                                (lets
                                                                                    [ ( b 48, Unsafe (RawWordStore { ptr = wOf (v cAddrN), index = n RtLayout.epCmdSubIdx, value = wOf (v subN) }) ) ]
                                                                                    stdinGuard
                                                                                )
                                                                            )
                                                                        )
                                                                    )
                                                                )
                                                            )
                                                        )
                                                    )
                                                )
                                            )
                                        )
                                    )
                                )
                            )
                        )
                    )
                )
            )
        )


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

-- run-path literals, packed NUL-terminated after the decode's 13 word-aligned
-- tag names (byte 104).  ASCII only, so String.length == byte length.
runLits : List String
runLits =
    [ "echo", "true", "false", ":", "cd", "pwd", "-n", "HOME", " ", "/"
    , "Input redirect file not found: ", "\n", "Output redirect failed: "
    , "shensh: ", ": not found\n", ": cannot execute\n", "cd: "
    , "pwd: cannot get cwd\n"
    , "/tmp/shensh-out.XXXXXX", "/tmp/shensh-err.XXXXXX", "/tmp/shensh-hdoc.XXXXXX"
    ]


runLitsPacked : List ( String, Int, Int )
runLitsPacked =
    let
        step s ( off, acc ) =
            ( off + String.length s + 1, ( s, off, String.length s ) :: acc )
    in
    List.foldl step ( 104, [] ) runLits |> Tuple.second |> List.reverse


runOff : String -> Int
runOff name =
    case List.filter (\( nm, _, _ ) -> nm == name) runLitsPacked of
        ( _, off, _ ) :: _ ->
            off

        [] ->
            0


-- runCbufSize was DELETED in T19: its one reader, the DSL Rt.exec-plan
-- builder (malloc'd the cbuf at this size), moved to the surface in T17,
-- which spells the size as the literal 336.


-- run-state block word slots (malloc'd in Rt.exec-plan).  T19: only rCbuf
-- survives — Rt.childCd's cbuf read is its last reader; the other 21 slot
-- names died with the DSL run builders in T17 (the surface spells the
-- offsets as literals).
rCbuf = 0


rLoad : Binder -> Int -> Exp
rLoad stN idx =
    Unsafe (RawWordLoad { ptr = wOf (v stN), index = n idx })


-- rStore was DELETED in T19: rStoreW (its dedicated wide variant) died with
-- Rt.exec-plan in T17 as "its only reader", and T17's childCd holdout in
-- fact reads state only through rLoad — rStore had no reader left.


-- cStrEqLit/wStr/wRaw/waitStatusCode MOVED TO THE SURFACE (T8 wave 1):
-- their surface text is in Mid.RtSource and lowers to the same trees
-- (cStrEqLit's self-tail recur included).  Rt.close, the next defun in
-- the old run here, stayed DSL-side — see its note above.


{-| childCd argvN argcN stN — the cd builtin arm (Zig's two-pass dir
resolution: argv[1] or HOME, then "/"; PATH_MAX guard; chdir).
-}
childCdDefun : Defun
childCdDefun =
    let
        argvN = p1

        argcN = p2

        stN = p3

        cbufW = b 4

        dirN = b 5

        ln = b 6

        bufW = b 7

        rc = b 8
    in
    lam "Rt.childCd" [ argvN, argcN, stN ]
        (lets
            [ ( cbufW, rLoad stN rCbuf )
            , ( dirN, iff (mkBool (cmpW RCgts (wOf (v argcN)) (n 1)))
                        (mkNum (Unsafe (RawWordLoad { ptr = wOf (v argvN), index = n 1 })))
                        (mkNum (n 0))
              )
            , ( dirN, iff (mkBool (cmpW RCeq (wOf (v dirN)) (n 0)))
                        (callR "Rt.envHome" [ v stN ])
                        (lets
                            [ ( ln, callR "Rt.cStrLenGo" [ v dirN, mkNum (n 0) ] ) ]
                            (iff (mkBool (cmpW RCeq (wOf (v ln)) (n 0)))
                                (callR "Rt.envHome" [ v stN ])
                                (v dirN)
                            )
                        )
              )
            , ( dirN, iff (mkBool (cmpW RCeq (wOf (v dirN)) (n 0)))
                        (mkNum (iadd (v cbufW) (n (runOff "/"))))
                        (v dirN)
              )
            , ( ln, callR "Rt.cStrLenGo" [ v dirN, mkNum (n 0) ] )
            ]
            (iff (mkBool (cmpW RCges (wOf (v ln)) (n 4096)))
                (mkNum (n 1))
                (lets
                    [ ( bufW, callW "malloc" [ n 4096 ] )
                    , ( b 9, iff (mkBool (cmpW RCeq (v bufW) (n 0))) haltV (mkNum (n 0)) )
                    , ( b 10, callR "Rt.cStrCopyGo" [ v dirN, mkNum (v bufW), mkNum (n 0) ] )
                    , ( rc, callW "chdir" [ v bufW ] )
                    , ( b 11, callW "free" [ v bufW ] )
                    ]
                    (iff (mkBool (cmpW RCeq (v rc) (n 0)))
                        (mkNum (n 0))
                        (lets
                            [ ( b 12, callR "Rt.wStr" [ mkNum (n 2), mkNum (iadd (v cbufW) (n (runOff "cd: "))) ] )
                            , ( b 13, callR "Rt.wStr" [ mkNum (n 2), v dirN ] )
                            , ( b 14, callR "Rt.wRaw" [ mkNum (n 2), mkNum (iadd (v cbufW) (n (runOff "\n"))) , mkNum (n 1) ] )
                            ]
                            (mkNum (n 1))
                        )
                    )
                )
            )
        )


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
    , subGoDefun
    , repGoDefun
    , bytesBuildDefun
    , seat "Rt.recGet" 2
    , seat "Rt.recGetGo" 3
    , seat "Rt.recUpd" 3
    , seat "Rt.recUpdFind" 3
    , seat "Rt.recUpdCopy" 3
    , symLessDefun
    , seat "Rt.recAppendFind" 3
    , seat "Rt.recAppendDataGo" 3
    , seat "Rt.recAppendNamesGo" 3
    , seat "Rt.recAppend" 3
    , seat "Rt.recInsert" 3
    , seat "Rt.recToChain" 1
    , seat "Rt.recToChainGo" 3
    , seat "Rt.readFull" 3
    , readFileGoDefun
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
    , epCmdDefun
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
    -- Mid/RtSource.elm — the nineteen keys below are seats.  Rt.childCd is
    -- NOT migrated (its second dirN binder is an If in a let-value position
    -- whose else chains ln = cStrLenGo dirN and whose value the continuation
    -- reads — the epCmd wall class, see the T16 note and the RtSource T17
    -- header) and keeps its builder at its list position; runLits/runOff/
    -- rLoad/rCbuf stay for it (rStore died in T19 — no reader left; the
    -- surface spells the other state-block offsets as literals).
    , seat "Rt.envHome" 1
    , seat "Rt.isChildBuiltin" 2
    , seat "Rt.echoGo" 3
    , childCdDefun
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

{-| `Rt.con tag argsPtr n` — the Mid ADT constructor (zigretire stage 5):
allocate a vector of n+1 Values through `RawAllocVector` (which QBE_MIDGC=1
routes to the Mid collector's seat `Rt.allocVector`), store the tag at index
0, copy the n args from the caller's STAGED block (argsPtr, a contiguous
[*]Value array in the caller's ROOTED frame), and wrap as a tag-10 vector
Value.  The args survive the allocation because they live in the caller's
rooted frame — the Zig `rt_con` contract, unchanged; tag and the two boxed
words live in Rt.con's OWN rooted frame (Rt.con is `allocating`).  Rt.conFill
does the copy alloc-free, so it is frame-free.
-}
conDefun : Defun
conDefun =
    let
        tag =
            p1

        argsPtr =
            p2

        cnt =
            p3

        dataW =
            b 4

        cntW =
            b 5
    in
    lam "Rt.con" [ tag, argsPtr, cnt ]
        (lets
            [ ( dataW, Unsafe (RawAllocVector (iadd (wOf (v cnt)) (n 1))) )
            , ( cntW, wOf (v cnt) )
            , ( b 6, Unsafe (RawVecStore { vec = Var dataW.id, index = n 0, value = v tag }) )
            , ( b 7, callR "Rt.conFill" [ mkNum (Var dataW.id), v argsPtr, mkNum (v cntW) ] )
            ]
            (mkVec (Var dataW.id) (iadd (v cntW) (n 1)))
        )


{-| `Rt.conFill data argsPtr i` — fill vector element i from staged arg i-1,
then recurse.  Frame-free: RawVecLoad/RawVecStore allocate nothing (the
plain store, no barrier — the collector is non-moving).
-}
conFillDefun : Defun
conFillDefun =
    let
        data =
            p1

        argsPtr =
            p2

        idx =
            p3

        dataW =
            b 4

        argsW =
            b 5

        idxW =
            b 6
    in
    lam "Rt.conFill" [ data, argsPtr, idx ]
        (lets
            [ ( dataW, wOf (v data) )
            , ( argsW, wOf (v argsPtr) )
            , ( idxW, wOf (v idx) )
            ]
            (iff (mkBool (cmpW RCeq (v idxW) (n 0)))
                mkNil
                (lets
                    [ ( b 7
                      , Unsafe
                            (RawVecStore
                                { vec = Var dataW.id
                                , index = Var idxW.id
                                , value = Unsafe (RawVecLoad { vec = Var argsW.id, index = isub (v idxW) (n 1) })
                                }
                            )
                      )
                    ]
                    (callR "Rt.conFill" [ mkNum (Var dataW.id), mkNum (Var argsW.id), mkNum (isub (v idxW) (n 1)) ])
                )
            )
        )


{-| `Rt.closure desc capBase K` — the Mid closure (zigretire stage 5 PART 2):
allocate a K-Value env array through `RawAllocVector` (under QBE_MIDGC=1 the
Mid collector's seat `Rt.allocVector`), copy the K captures from the caller's
STAGED contiguous block (capBase), and wrap as a tag-6 lambda Value whose
`code` is the static Desc pointer and whose `code_len` is the Desc's arity.
Mirrors values.valLambda (the Zig seat rt_make_closure calls) word for word.
The captures survive the allocation because they live in the caller's ROOTED
frame — the Zig contract, unchanged; desc/capBase/K live in Rt.closure's OWN
rooted frame (Rt.closure is `allocating`).  The copy is Rt.closureFill —
conFill's 0-BASED twin (the env array has NO tag slot, so env[i] = cap[i],
whereas Con's vector stores args at [1..n] past the tag at [0]); alloc-free,
so the copy is not itself a safepoint.

code_len comes from the Desc's arity WORD (offset 8 = `{ w arity, w ncaps }`:
arity in the low 32 bits, ncaps in the high 32).  Storing the full word as
lambda payload word 1 puts arity in the low half — read as the i32 `code_len`
field — and ncaps in the high half, which is the Value's padding that Zig's
struct store leaves UNWRITTEN and no reader (applyGo, the collectors, the
nursery predicate) ever reads.
-}
closureDefun : Defun
closureDefun =
    let
        desc =
            p1

        capBase =
            p2

        cnt =
            p3

        dataW =
            b 4

        cntW =
            b 5

        descW =
            b 6

        arityW =
            b 7
    in
    lam "Rt.closure" [ desc, capBase, cnt ]
        (lets
            [ ( dataW, Unsafe (RawAllocVector (wOf (v cnt))) )
            , ( cntW, wOf (v cnt) )
            , ( descW, wOf (v desc) )
            , ( arityW, Unsafe (RawWordLoad { ptr = Var descW.id, index = n 1 }) )
            , ( b 8, callR "Rt.closureFill" [ mkNum (Var dataW.id), v capBase, mkNum (v cntW) ] )
            ]
            (Unsafe
                (RawMkValue
                    { tag = RtLayout.tagLambda
                    , words = [ Var descW.id, Var arityW.id, Var dataW.id, Var cntW.id ]
                    }
                )
            )
        )


{-| `Rt.closureFill data capBase idx` — fill env element idx-1 from staged
capture idx-1, then recurse.  Frame-free: RawVecLoad/RawVecStore allocate
nothing (the plain store, no barrier — the collector is non-moving).  This is
Rt.conFill's 0-BASED twin: the closure env array has NO tag slot, so
env[i] = cap[i], where Con stores args at [1..n] past the tag at [0].

THE BOUND (named, per the stage-5 review's ask): the recursion depth is the
closure's CAPTURE COUNT K, a finite number of free binders — not the arity
ceiling, and doubly moot because the self-tail lowers to an IN-FRAME LOOP
(the same gate that makes conFill's "recursion" loop-shaped).  The arity
itself (read into code_len) is bounded by `maxArity` = 16, enforced where
the closure's defun is rejected (`Lower.elm` lowerClosure: "closure has arity
> 16 (rt_callN table limit)").
-}
closureFillDefun : Defun
closureFillDefun =
    let
        data =
            p1

        capBase =
            p2

        idx =
            p3

        dataW =
            b 4

        capW =
            b 5

        idxW =
            b 6
    in
    lam "Rt.closureFill" [ data, capBase, idx ]
        (lets
            [ ( dataW, wOf (v data) )
            , ( capW, wOf (v capBase) )
            , ( idxW, wOf (v idx) )
            ]
            (iff (mkBool (cmpW RCeq (v idxW) (n 0)))
                mkNil
                (lets
                    [ ( b 7
                      , Unsafe
                            (RawVecStore
                                { vec = Var dataW.id
                                , index = isub (v idxW) (n 1)
                                , value = Unsafe (RawVecLoad { vec = Var capW.id, index = isub (v idxW) (n 1) })
                                }
                            )
                      )
                    ]
                    (callR "Rt.closureFill" [ mkNum (Var dataW.id), mkNum (Var capW.id), mkNum (isub (v idxW) (n 1)) ])
                )
            )
        )


-- Rt.emptylist MOVED TO THE SURFACE (T8 wave 1): the surface text in
-- Mid.RtSource lowers to the same tree (tagis/and2 cond, mknil arm, the
-- rt_halt dead binder); TestMain's T6 compile-back row pins the shape.


-- Rt.= MOVED TO THE SURFACE (T10 wave 3): FOUR @guard-conjunction variants
-- of one key -- @rec@eqPtrFast / @rec@!eqPtrFast / @!rec@eqPtrFast /
-- @!rec@!eqPtrFast -- the 2x2 product of the two switches eqDefun took
-- (the symFast or2 at three sites, the rec tag-14 tail).  Its primDefuns
-- position below is a seat.


{-| `Rt.+ a b` — primAdd: EITHER float promotes and computes in f64;
otherwise the BARE i64 wrap (no numeric guard — shen semantics, AGENTS.md;
the metacircular interpreter relies on it).  `-`/`*` identical modulo the
op.
-}
addDefun : Defun
addDefun =
    let
        a =
            p1

        bb =
            p2
    in
    lam "Rt.+" [ a, bb ]
        (iff (or2 (mkBool (tagIs (v a) 12)) (mkBool (tagIs (v bb) 12)))
            (mkFlt (fbin RFAdd (flOf (callR "Rt.asF" [ v a ])) (flOf (callR "Rt.asF" [ v bb ]))))
            (mkNum (iadd (wOf (v a)) (wOf (v bb))))
        )


subDefun : Defun
subDefun =
    let
        a =
            p1

        bb =
            p2
    in
    lam "Rt.-" [ a, bb ]
        (iff (or2 (mkBool (tagIs (v a) 12)) (mkBool (tagIs (v bb) 12)))
            (mkFlt (fbin RFSub (flOf (callR "Rt.asF" [ v a ])) (flOf (callR "Rt.asF" [ v bb ]))))
            (mkNum (isub (wOf (v a)) (wOf (v bb))))
        )


mulDefun : Defun
mulDefun =
    let
        a =
            p1

        bb =
            p2
    in
    lam "Rt.*" [ a, bb ]
        (iff (or2 (mkBool (tagIs (v a) 12)) (mkBool (tagIs (v bb) 12)))
            (mkFlt (fbin RFMul (flOf (callR "Rt.asF" [ v a ])) (flOf (callR "Rt.asF" [ v bb ]))))
            (mkNum (imul (wOf (v a)) (wOf (v bb))))
        )


{-| `Rt./ a b` — primDiv: bare integer @divTrunc (Elm `//`).  A zero
divisor SIGFPEs both arms (Zig panics, QBE idivs) — parity by crash.
-}
divDefun : Defun
divDefun =
    let
        a =
            p1

        bb =
            p2
    in
    lam "Rt./" [ a, bb ]
        (mkNum (idiv (wOf (v a)) (wOf (v bb))))


{-| `Rt.f/ a b` — primFdiv: ALWAYS f64 division (Elm `/`), promoting.
x/0.0 = Infinity (IEEE), matching Elm.
-}
fdivDefun : Defun
fdivDefun =
    let
        a =
            p1

        bb =
            p2
    in
    lam "Rt.f/" [ a, bb ]
        (mkFlt (fbin RFDiv (flOf (callR "Rt.asF" [ v a ])) (flOf (callR "Rt.asF" [ v bb ]))))


{-| The comparison family — primLt/Le/Gt/Ge: BOTH operands numeric or the
answer is false; either float promotes to the f64 compare, else the signed
i64 compare.
-}
cmpDefun : String -> RawCmpOp -> RawFltCmpOp -> Defun
cmpDefun key icmp fcmpOp =
    let
        a =
            p1

        bb =
            p2
    in
    lam key [ a, bb ]
        (iff (and2
                (or2 (mkBool (tagIs (v a) 0)) (mkBool (tagIs (v a) 12)))
                (or2 (mkBool (tagIs (v bb) 0)) (mkBool (tagIs (v bb) 12)))
             )
            (iff (or2 (mkBool (tagIs (v a) 12)) (mkBool (tagIs (v bb) 12)))
                (mkBool (fcmp fcmpOp (flOf (callR "Rt.asF" [ v a ])) (flOf (callR "Rt.asF" [ v bb ]))))
                (mkBool (cmpW icmp (wOf (v a)) (wOf (v bb))))
            )
            falseV
        )


{-| The Bitwise family — JS int32 semantics (prims.zig bitOperand/
shiftAmount): operands through toI32, ops at i32, results re-entering i64
sign-extended (zero for shift-right-zf), shift counts masked mod 32.
-}
bit2Defun : String -> (Exp -> Exp -> Exp) -> Defun
bit2Defun key op =
    let
        a =
            p1

        bb =
            p2
    in
    lam key [ a, bb ]
        (mkNum (op (wOf (callR "Rt.toI32" [ v a ])) (wOf (callR "Rt.toI32" [ v bb ]))))


bitNotDefun : Defun
bitNotDefun =
    let
        a =
            p1
    in
    lam "Rt.bitwise-not" [ a ]
        (mkNum (Unsafe (RawUn { op = RBitNot, v = wOf (callR "Rt.toI32" [ v a ]) })))


shlDefun : Defun
shlDefun =
    -- ZINC RTL: a1 = count (leftmost), a2 = value.
    let
        count =
            p1

        value =
            p2
    in
    lam "Rt.bitwise-shift-left" [ count, value ]
        (mkNum
            (shlW (wOf (callR "Rt.toI32" [ v value ]))
                (iand (wOf (callR "Rt.toI32" [ v count ])) (n 31))
            )
        )


sarDefun : Defun
sarDefun =
    let
        count =
            p1

        value =
            p2
    in
    lam "Rt.bitwise-shift-right" [ count, value ]
        (mkNum
            (sarW (wOf (callR "Rt.toI32" [ v value ]))
                (iand (wOf (callR "Rt.toI32" [ v count ])) (n 31))
            )
        )


shrDefun : Defun
shrDefun =
    let
        count =
            p1

        value =
            p2
    in
    lam "Rt.bitwise-shift-right-zf" [ count, value ]
        (mkNum
            (shrW (wOf (callR "Rt.toI32" [ v value ]))
                (iand (wOf (callR "Rt.toI32" [ v count ])) (n 31))
            )
        )


{-| The tag predicates — number? covers Int AND Float (primNumberP).
-}
predDefun : String -> List Int -> Defun
predDefun key tags =
    let
        a =
            p1
    in
    lam key [ a ]
        (List.foldr (\t acc -> or2 (mkBool (tagIs (v a) t)) acc) falseV tags)


{-| `Rt.c-strlen s` — the i32 len field (lenOf — the word-1 i32 length).
-}
cstrlenDefun : Defun
cstrlenDefun =
    let
        s =
            p1
    in
    lam "Rt.c-strlen" [ s ] (mkNum (lenOf (v s)))


{-| `Rt.char-code s i` — byte at index, -1 out of bounds (primCharCode).
-}
charCodeAtDefun : Defun
charCodeAtDefun =
    let
        s =
            p1

        i =
            p2
    in
    lam "Rt.char-code" [ s, i ]
        (iff (and2
                (mkBool (cmpW RCles (n 0) (wOf (v i))))
                (mkBool (cmpW RClts (wOf (v i)) (lenOf (v s))))
             )
            (mkNum (byteOf (v s) (wOf (v i))))
            (mkNum (n -1))
        )


{-| `Rt.substring s start len` — primSubstring's clamps, then the slice:
start = clamp [0, slen]; len = clamp [0, slen - start].
-}
substringDefun : Defun
substringDefun =
    let
        s =
            p1

        st =
            p2

        ln =
            p3

        st0 =
            b 4

        ln0 =
            b 5

        end =
            b 6

        stW =
            wOf (v st)

        lnW =
            wOf (v ln)

        lenW =
            lenOf (v s)

        stClamped =
            iff (mkBool (cmpW RClts stW (n 0)))
                (mkNum (n 0))
                (iff (mkBool (cmpW RCgts stW lenW))
                    (mkNum lenW)
                    (v st)
                )

        lnClamped =
            iff (mkBool (cmpW RClts lnW (n 0)))
                (mkNum (n 0))
                (iff (mkBool (cmpW RCgts (iadd (wOf (v st0)) lnW) lenW))
                    (mkNum (isub lenW (wOf (v st0))))
                    (v ln)
                )
    in
    lam "Rt.substring" [ s, st, ln ]
        (lets
            [ ( st0, stClamped )
            , ( ln0, lnClamped )
            , ( end, mkNum (iadd (wOf (v st0)) (wOf (v ln0))) )
            ]
            (callR "Rt.bytesToStr" [ callR "Rt.subGo" [ v s, v st0, v end ] ])
        )


{-| `Rt.cn a b` — primCn: coerce each operand to its text (strOf), then
concatenate (cn2).
-}
cnDefun : Defun
cnDefun =
    let
        a =
            p1

        bb =
            p2
    in
    lam "Rt.cn" [ a, bb ]
        (callR "Rt.cn2" [ callR "Rt.strOf" [ v a ], callR "Rt.strOf" [ v bb ] ])


{-| `Rt.repeat n s` — primRepeat: n <= 0 or empty s -> ""; else s, n times
(byte-exact with the doubling schedule's result).
-}
repeatDefun : Defun
repeatDefun =
    let
        cnt =
            p1

        s =
            p2
    in
    lam "Rt.repeat" [ cnt, s ]
        (iff (or2
                (mkBool (cmpW RCles (wOf (v cnt)) (n 0)))
                (mkBool (cmpW RCles (lenOf (v s)) (n 0)))
             )
            (Lit (LString ""))
            (callR "Rt.bytesToStr" [ callR "Rt.repGo" [ v s, v cnt ] ])
        )


{-| `Rt.shen.str->bytes s` — primStrToBytes: byte[0] lands at the head
(back-to-front build, entered at i = len).  A non-string throws in Zig —
the halt arm here (module header GAPS).
-}
strToBytesDefun : Defun
strToBytesDefun =
    let
        s =
            p1
    in
    lam "Rt.shen.str->bytes" [ s ]
        (iff (mkBool (tagIs (v s) 1))
            (callR "Rt.bytesBuild" [ v s, mkNum (lenOf (v s)), mkNil ])
            haltV
        )


{-| `Rt.shen.bytes->string bs` — primBytesToStr's shape (count, ONE alloc,
fill, wrap).  A non-list throws in Zig — the halt arm here.
-}
bytesToStringDefun : Defun
bytesToStringDefun =
    let
        bs =
            p1
    in
    lam "Rt.shen.bytes->string" [ bs ]
        (iff (or2 (mkBool (tagIs (v bs) 5)) (mkBool (tagIs (v bs) 4)))
            (callR "Rt.bytesToStr" [ v bs ])
            haltV
        )


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
    , conDefun
    , conFillDefun
    , closureDefun
    , closureFillDefun
    , seat "Rt.emptylist" 1
    , seat "Rt.=" 2
    , addDefun
    , subDefun
    , mulDefun
    , divDefun
    , fdivDefun
    , cmpDefun "Rt.<" RClts RFLt
    , cmpDefun "Rt.<=" RCles RFLe
    , cmpDefun "Rt.>" RCgts RFGt
    , cmpDefun "Rt.>=" RCges RFGe
    , bit2Defun "Rt.bitwise-and" iand
    , bit2Defun "Rt.bitwise-or" ior
    , bit2Defun "Rt.bitwise-xor" ixor
    , bitNotDefun
    , shlDefun
    , sarDefun
    , shrDefun
    , predDefun "Rt.number?" [ 0, 12 ]
    , predDefun "Rt.string?" [ 1 ]
    , predDefun "Rt.cons?" [ 4 ]
    , predDefun "Rt.empty?" [ 5 ]
    , cstrlenDefun
    , charCodeAtDefun
    , substringDefun
    , cnDefun
    , repeatDefun
    , strToBytesDefun
    , bytesToStringDefun
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
    , readFileAsStringDefun
    ]
