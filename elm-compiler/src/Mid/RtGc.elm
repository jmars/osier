module Mid.RtGc exposing (gcProgram)

{-| Mid.RtGc — the FRESH non-moving, non-generational MARK-SWEEP collector
(zigretire stage 4, plan.md §2.2).  NOT a port of the moving generational
Zig collector (vendor/osier-rt/src/gc/*): that collector's hard parts serve
movement + generations (forwarding bits, nursery, promotion, remembered
sets), none of which mark-sweep needs.  This module is the whole collector,
expressed as Mid defuns under the reserved `Rt.*` namespace and lowered by
this compiler's own backend.

HEAP MODEL.  One mmap'd region, lazily created by `Rt.gcInit` (RawCallRaw
`mmap` — the plan's "OS memory via libc").  The region is laid out as:

    word 0        magic (fail loudly if collect/alloc runs before init)
    word 1        free-list head (a body pointer, 0 = empty)
    word 2        heap_start (first object byte)
    word 3        heap_cursor (next bump address)
    word 4        heap_end
    word 5        mark-stack top (word INDEX into the region)
    word 6        mark-stack end (word INDEX)
    word 7..9     allocator scratch (total/kind/count of the in-flight request)
    word 10..63   reserved
    [64, mark_end) the mark stack
    [heap_start, heap_end) the object area

OBJECTS.  Two kinds (the plan's "two object kinds" claim, RE-DERIVED rather
than inherited: the only producers are Rt.allocVector and Rt.allocRaw, so
value_array and raw are the whole of it):

    value_array  n Value elements (5 words each)
    raw          n body words (raw bytes)

Header is TWO words immediately before the body (body = the address this
collector hands out, exactly the Zig convention where the returned pointer
is the body and the header is at body-8/body-16):

    word -2  flags = kind*2 + mark   (kind: 0 = raw, 1 = value_array;
                                      mark: 0 = unmarked, 1 = marked)
    word -1  count = the element count (value_array) or the body words (raw)

Total object words = 2 + count + 4*count*kind (arithmetic only — the Mid
word ops have no 64-bit bitwise family, so every header access is expressed
with i64 add/sub/mul/div and the sign-safe low-32 extraction below).

ROOTS.  Precise, unchanged: the Zig shadow stack (roots.zig) survives this
stage, and Rt.collect reads it through the alloc-free RawCallRaw seats
rt_gc_roots_len / rt_gc_root_kind / rt_gc_root_slot / rt_gc_root_np.
FRAME-FREE BY CONSTRUCTION: no collector defun contains an allocating node
(no RawAllocVector/RawAllocRaw, no LString, no WithRoots), so
Mid.Rt.allocating leaves every one of them out of the framed set — pinned by
a TestMain row.

TRIGGER.  Inside the allocating seats: Rt.allocVector/Rt.allocRaw
RawCall Rt.gcAlloc, which bumps from the free region and — only when the
free list and the bump cursor can both no longer serve the request —
RawCall Rt.collect (the mark-sweep analogue of heap.zig's gc_alloc
threshold: "the heap cannot serve the next allocation without collecting").
On exhaustion after a collect, it dies loudly.

FAILURE IS LOUD.  Every path this collector cannot handle (an unknown
ValTag, an unknown root kind, mark-stack overflow, out of memory, mmap
failure, collect-before-init) exits through the rt_midgc_die seat — never a
silent leak or a stale read.

-}

import Mid.Ir exposing (Binder, Defun, Exp(..), LetBinder(..), Lit(..), RawBinOp(..), RawCmpOp(..), UnsafeNode(..))
import Mid.RtLayout as RtLayout


-- ============================ BUILDERS ============================
-- A self-contained copy of RtPrims' tiny DSL (RtPrims does not export it;
-- the collector needs the same shapes, so they live here too rather than
-- widening RtPrims' surface for a module that is not a prim).


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


-- ---- words ----

wOf : Exp -> Exp
wOf x =
    Unsafe (RawPayload { value = x, word = 0 })


callR : String -> List Exp -> Exp
callR key args =
    Unsafe (RawCall { sym = key, args = args })


callW : String -> List Exp -> Exp
callW sym args =
    Unsafe (RawCallRaw { sym = sym, args = args })


wload : Exp -> Exp -> Exp
wload ptr index =
    Unsafe (RawWordLoad { ptr = ptr, index = index })


wstore : Exp -> Exp -> Exp -> Exp
wstore ptr index value =
    Unsafe (RawWordStore { ptr = ptr, index = index, value = value })


iadd : Exp -> Exp -> Exp
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


icmp : RawCmpOp -> Exp -> Exp -> Exp
icmp op x y =
    Unsafe (RawCmp { op = op, a = x, b = y })


mkBool : Exp -> Exp
mkBool we =
    Unsafe (RawMkValue { tag = RtLayout.tagBoolean, words = [ we ] })


mkNil : Exp
mkNil =
    Unsafe (RawMkValue { tag = RtLayout.tagNil, words = [] })


mkNum : Exp -> Exp
mkNum we =
    Unsafe (RawMkValue { tag = RtLayout.tagNumber, words = [ we ] })


eqW : Exp -> Exp -> Exp
eqW a bb =
    mkBool (icmp RCeq a bb)


neW : Exp -> Exp -> Exp
neW a bb =
    mkBool (icmp RCne a bb)


ltW : Exp -> Exp -> Exp
ltW a bb =
    mkBool (icmp RClts a bb)


geW : Exp -> Exp -> Exp
geW a bb =
    mkBool (icmp RCges a bb)


lam : String -> List Binder -> Exp -> Defun
lam key params body =
    { key = key
    , value = Lam { params = params, body = body }
    }


-- The low 32 bits of a Value's tag / a root count, read SIGN-SAFELY.  The
-- 64-bit word op family has no bitwise AND, and a truncated-division
-- low-32 extraction breaks on the padding's high bit (w in
-- [tag + 2^31*2^32, 2^64) is a NEGATIVE i64, and `w div 2^32` truncates
-- toward zero to 0 instead of the padding word).  Four zero-extended byte
-- loads are the sign-free form: the tag is bytes 0..3 of the 40-byte Value
-- (little-endian — the host and the cross-target smoke targets are all
-- little-endian; the Zig extern struct writes the u32 tag at offset 0 and
-- leaves bytes 4..7 UNWRITTEN, so a full 64-bit read carries garbage there).
byteOf : Exp -> Exp -> Exp
byteOf ptr index =
    Unsafe (RawByteLoad { ptr = ptr, index = index })


tag32 : Exp -> Exp
tag32 addr =
    iadd (byteOf addr (n 0))
        (iadd (imul (byteOf addr (n 1)) (n 256))
            (iadd (imul (byteOf addr (n 2)) (n 65536))
                (imul (byteOf addr (n 3)) (n 16777216))
            )
        )


-- Total object words from a kind (0/1) and a header count.
totalWords : Exp -> Exp -> Exp
totalWords kindW countW =
    iadd (n 2) (iadd countW (imul (imul (n 4) countW) kindW))


-- ============================ CONSTANTS ============================

-- Region word offsets.
offFreeHead : Int
offFreeHead =
    1


offHeapStart : Int
offHeapStart =
    2


offHeapCursor : Int
offHeapCursor =
    3


offHeapEnd : Int
offHeapEnd =
    4


offMarkTop : Int
offMarkTop =
    5


offMarkEnd : Int
offMarkEnd =
    6


offAllocTotal : Int
offAllocTotal =
    7


offAllocKind : Int
offAllocKind =
    8


offAllocCount : Int
offAllocCount =
    9


offHeapBytes : Int
offHeapBytes =
    10


offAllocated : Int
offAllocated =
    11


metaWords : Int
metaWords =
    64


-- "MIDGC" as ASCII hex, decimal.  Any non-zero value works; this one is
-- self-describing in a core dump.
magic : Int
magic =
    331941693251


-- rt_midgc_die codes (kept in step with tools/qbe/rt.zig's message table).
dieUnknownTag : Int
dieUnknownTag =
    0


dieUnknownRoot : Int
dieUnknownRoot =
    1


dieMarkOverflow : Int
dieMarkOverflow =
    2


dieOom : Int
dieOom =
    3


dieMmap : Int
dieMmap =
    4


dieNotInit : Int
dieNotInit =
    5


-- A value-position failure: run rt_midgc_die(code) for its effect and yield
-- nil (the result is never read — the seat exits the process).
die : Int -> Exp
die code =
    lets [ ( b 100, callW "rt_midgc_die" [ n code ] ) ] mkNil


-- ============================ DEFUNS ============================


{-| `Rt.gcInit _` — lazily mmap the heap region and lay down its header
words, once per process.  Idempotent: a second call returns the existing
region unchanged (the `rt_midgc_region` seat keeps the base across calls).
-}
gcInitDefun : Defun
gcInitDefun =
    let
        dummy =
            p1

        region =
            b 2

        heapBytes =
            b 3

        regionSize =
            b 4

        base =
            b 5

        heapStart =
            b 6

        markEnd =
            b 7
    in
    lam "Rt.gcInit" [ dummy ]
        (lets
            [ ( region, callW "rt_midgc_region" [] ) ]
            (iff (neW (v region) (n 0))
                (mkNum (v region))
                (lets
                    [ ( heapBytes, callW "rt_gc_heap_bytes" [] )
                    , ( regionSize, iadd (v heapBytes) (idiv (v heapBytes) (n 8)) )
                    , ( base, callW "mmap" [ n 0, v regionSize, n 3, n 34, n -1, n 0 ] )
                    ]
                    (iff (ltW (v base) (n 0))
                        (die dieMmap)
                        (lets
                            [ ( heapStart, iadd (v base) (iadd (n 528) (idiv (v heapBytes) (n 8))) )
                            , ( markEnd, iadd (n metaWords) (idiv (idiv (v heapBytes) (n 8)) (n 8)) )
                            ]
                            (lets [ ( b 8, callW "rt_midgc_set_region" [ v base ] ) ]
                                (lets
                                    [ ( b 9, wstore (v base) (n 0) (n magic) )
                                    , ( b 10, wstore (v base) (n offFreeHead) (n 0) )
                                    , ( b 11, wstore (v base) (n offHeapStart) (v heapStart) )
                                    , ( b 12, wstore (v base) (n offHeapCursor) (v heapStart) )
                                    , ( b 13, wstore (v base) (n offHeapEnd) (iadd (v base) (v regionSize)) )
                                    , ( b 14, wstore (v base) (n offMarkTop) (n metaWords) )
                                    , ( b 15, wstore (v base) (n offMarkEnd) (v markEnd) )
                                    , ( b 16, wstore (v base) (n offHeapBytes) (v heapBytes) )
                                    , ( b 17, wstore (v base) (n offAllocated) (n 0) )
                                    ]
                                    (mkNum (v base))
                                )
                            )
                        )
                    )
                )
            )
        )


{-| `Rt.allocVector count` — the Mid allocating seat under the
`RawAllocVector` node (QBE_MIDGC=1).  Returns the array BODY address boxed
as a number Value.  The trigger lives here: when the free list and the bump
cursor can no longer serve the request, Rt.gcAlloc RawCalls Rt.collect.
-}
allocVectorDefun : Defun
allocVectorDefun =
    let
        count =
            p1

        region =
            b 2

        countW =
            b 3
    in
    lam "Rt.allocVector" [ count ]
        (lets
            [ ( region, callR "Rt.gcInit" [ mkNum (n 0) ] )
            , ( countW, wOf (v count) )
            ]
            (callR "Rt.gcAlloc" [ v region, mkNum (n 1), mkNum (v countW) ])
        )


{-| `Rt.allocRaw nbytes` — the Mid allocating seat under `RawAllocRaw`.
Body words are ceil(nbytes/8); the result is the body address boxed as a
number Value.
-}
allocRawDefun : Defun
allocRawDefun =
    let
        nbytes =
            p1

        region =
            b 2

        nbytesW =
            b 3

        bodyWords =
            b 4
    in
    lam "Rt.allocRaw" [ nbytes ]
        (lets
            [ ( region, callR "Rt.gcInit" [ mkNum (n 0) ] )
            , ( nbytesW, wOf (v nbytes) )
            , ( bodyWords, idiv (iadd (v nbytesW) (n 7)) (n 8) )
            ]
            (callR "Rt.gcAlloc" [ v region, mkNum (n 0), mkNum (v bodyWords) ])
        )


{-| `Rt.gcAlloc region kind count` — the collector's allocation core.  First a
PROACTIVE threshold collect (the mark-sweep analogue of heap.zig's gc_alloc
`allocatedpages > heappages/4` trigger: bytes-since-last-collect exceeding a
quarter of the heap), then first-fit (exact total) over the free list, then
bump, then an exhaustion collect-and-retry.  `count` is the header count (the
element count for kind=1, the body words for kind=0).  The request is parked
in the region's scratch words so the walker (`Rt.gcAllocGo`) stays under the
3-arg lean-ABI ceiling.
-}
gcAllocDefun : Defun
gcAllocDefun =
    let
        region =
            p1

        kind =
            p2

        count =
            p3

        kindW =
            b 4

        countW =
            b 5

        regionW =
            b 6

        total =
            b 7

        heapBytes =
            b 8

        allocated =
            b 9

        first =
            b 10

        firstW =
            b 11

        cursor =
            b 12

        heapEnd =
            b 13

        retry =
            b 14

        retryW =
            b 15

        -- Increment the bytes-since-collect counter and return `addrW` boxed.
        returnAddr : Exp -> Exp
        returnAddr addrW =
            lets [ ( b 16, wstore (v regionW) (n offAllocated) (iadd (wload (v regionW) (n offAllocated)) (imul (v total) (n 8))) ) ]
                (mkNum addrW)

        -- Free list came up empty: bump, or collect-and-retry.
        bumpPath : Exp
        bumpPath =
            lets
                [ ( cursor, wload (v regionW) (n offHeapCursor) )
                , ( heapEnd, wload (v regionW) (n offHeapEnd) )
                ]
                (iff (ltW (iadd (v cursor) (imul (v total) (n 8))) (v heapEnd))
                    (lets
                        [ ( b 17, wstore (v cursor) (n -2) (imul (v kindW) (n 2)) )
                        , ( b 18, wstore (v cursor) (n -1) (v countW) )
                        , ( b 19, wstore (v regionW) (n offHeapCursor) (iadd (v cursor) (imul (v total) (n 8))) )
                        ]
                        (returnAddr (v cursor))
                    )
                    (lets [ ( b 20, callR "Rt.collect" [ mkNum (n 0) ] ) ]
                        (lets
                            [ ( b 21, wstore (v regionW) (n offAllocated) (n 0) )
                            , ( retry, callR "Rt.gcAllocGo" [ v region, mkNum (iadd (v regionW) (n 8)) ] )
                            , ( retryW, wOf (v retry) )
                            ]
                            (iff (eqW (v retryW) (n 0))
                                (die dieOom)
                                (returnAddr (v retryW))
                            )
                        )
                    )
                )
    in
    lam "Rt.gcAlloc" [ region, kind, count ]
        (lets
            [ ( kindW, wOf (v kind) )
            , ( countW, wOf (v count) )
            , ( regionW, wOf (v region) )
            , ( total, totalWords (v kindW) (v countW) )
            , ( heapBytes, wload (v regionW) (n offHeapBytes) )
            , ( allocated, wload (v regionW) (n offAllocated) )
            , ( b 22, wstore (v regionW) (n offAllocTotal) (v total) )
            , ( b 23, wstore (v regionW) (n offAllocKind) (v kindW) )
            , ( b 24, wstore (v regionW) (n offAllocCount) (v countW) )
            ]
            (lets
                [ ( b 25
                  , iff (gtW (v allocated) (idiv (v heapBytes) (n 4)))
                        (lets
                            [ ( b 26, callR "Rt.collect" [ mkNum (n 0) ] )
                            , ( b 27, wstore (v regionW) (n offAllocated) (n 0) )
                            ]
                            mkNil
                        )
                        mkNil
                  )
                , ( first, callR "Rt.gcAllocGo" [ v region, mkNum (iadd (v regionW) (n 8)) ] )
                , ( firstW, wOf (v first) )
                ]
                (iff (eqW (v firstW) (n 0))
                    bumpPath
                    (returnAddr (v firstW))
                )
            )
        )


{-| `Rt.gcAllocGo region linkAddr` — one step of the free-list walk.  The
request lives in the region's scratch words (total/kind/count).  `linkAddr`
is the address of the word holding the next candidate (region word 1 for the
head, or a free object's body word 0).  Returns 0 when the list is exhausted.
-}
gcAllocGoDefun : Defun
gcAllocGoDefun =
    let
        region =
            p1

        linkAddr =
            p2

        p =
            b 3

        flags =
            b 4

        fkind =
            b 5

        fcount =
            b 6

        ftotal =
            b 7

        total =
            b 8

        kind =
            b 9

        count =
            b 10
    in
    lam "Rt.gcAllocGo" [ region, linkAddr ]
        (lets
            [ ( p, wload (wOf (v linkAddr)) (n 0) )
            , ( total, wload (wOf (v region)) (n offAllocTotal) )
            , ( kind, wload (wOf (v region)) (n offAllocKind) )
            , ( count, wload (wOf (v region)) (n offAllocCount) )
            ]
            (iff (eqW (v p) (n 0))
                (mkNum (n 0))
                (lets
                    [ ( flags, wload (v p) (n -2) )
                    , ( fkind, idiv (v flags) (n 2) )
                    , ( fcount, wload (v p) (n -1) )
                    , ( ftotal, totalWords (v fkind) (v fcount) )
                    ]
                    (iff (eqW (v ftotal) (v total))
                        (lets
                            [ ( b 11, wstore (wOf (v linkAddr)) (n 0) (wload (v p) (n 0)) )
                            , ( b 12, wstore (v p) (n -2) (imul (v kind) (n 2)) )
                            , ( b 13, wstore (v p) (n -1) (v count) )
                            ]
                            (mkNum (v p))
                        )
                        (callR "Rt.gcAllocGo" [ v region, mkNum (v p) ])
                    )
                )
            )
        )


{-| `Rt.collect _` — one full mark-sweep: mark the precise roots (the Zig
shadow stack), drain the mark stack (marking transitively), then sweep the
allocated region into the free list.  Frame-free by construction.
-}
collectDefun : Defun
collectDefun =
    let
        dummy =
            p1

        region =
            b 2
    in
    lam "Rt.collect" [ dummy ]
        (lets
            [ ( region, callW "rt_midgc_region" [] ) ]
            (iff (eqW (wload (v region) (n 0)) (n magic))
                (lets
                    [ ( b 3, wstore (v region) (n offMarkTop) (n metaWords) )
                    , ( b 4, callR "Rt.gcMarkRoots" [ mkNum (n 0) ] )
                    , ( b 5, callR "Rt.gcDrain" [ mkNum (n 0) ] )
                    , ( b 6, wstore (v region) (n offFreeHead) (n 0) )
                    , ( b 7, callR "Rt.gcSweep" [ mkNum (wload (v region) (n offHeapStart)) ] )
                    ]
                    mkNil
                )
                (die dieNotInit)
            )
        )


{-| `Rt.gcMarkRoots i` — mark root entry i, then recurse.  RootKind dispatch
mirrors the Zig collector's scanRoots (roots.zig): ROOT_PTR reads one word,
ROOT_VALUE/ROOT_VALUE_VOLATILE scan a Value in place, ROOT_VALUE_ARRAY scans
a live count of Values; anything else dies loudly.
-}
gcMarkRootsDefun : Defun
gcMarkRootsDefun =
    let
        i =
            p1

        iW =
            b 2

        nRoots =
            b 3

        kind =
            b 4

        slot =
            b 5

        np =
            b 6

        count =
            b 7
    in
    lam "Rt.gcMarkRoots" [ i ]
        (lets
            [ ( iW, wOf (v i) )
            , ( nRoots, callW "rt_gc_roots_len" [] )
            ]
            (iff (geW (v iW) (v nRoots))
                mkNil
                (lets
                    [ ( kind, callW "rt_gc_root_kind" [ v iW ] )
                    , ( slot, callW "rt_gc_root_slot" [ v iW ] )
                    , ( np, callW "rt_gc_root_np" [ v iW ] )
                    ]
                    (lets
                        [ ( b 8
                          , iff (eqW (v kind) (n 0))
                                (callR "Rt.gcMarkPtr" [ mkNum (wload (v slot) (n 0)) ])
                                (iff (eqW (v kind) (n 1))
                                    (callR "Rt.gcMarkValue" [ mkNum (v slot) ])
                                    (iff (eqW (v kind) (n 3))
                                        (callR "Rt.gcMarkValue" [ mkNum (v slot) ])
                                        (iff (eqW (v kind) (n 2))
                                            (lets [ ( count, tag32 (v np) ) ]
                                                (callR "Rt.gcScanValueArray" [ mkNum (v slot), mkNum (v count) ])
                                            )
                                            (die dieUnknownRoot)
                                        )
                                    )
                                )
                          )
                        ]
                        (callR "Rt.gcMarkRoots" [ mkNum (iadd (v iW) (n 1)) ])
                    )
                )
            )
        )


{-| `Rt.gcScanValueArray base n` — mark n Value elements from `base`
(40-byte stride), then stop.
-}
gcScanValueArrayDefun : Defun
gcScanValueArrayDefun =
    let
        base =
            p1

        cnt =
            p2

        baseW =
            b 3

        cntW =
            b 4
    in
    lam "Rt.gcScanValueArray" [ base, cnt ]
        (lets
            [ ( baseW, wOf (v base) )
            , ( cntW, wOf (v cnt) )
            ]
            (iff (eqW (v cntW) (n 0))
                mkNil
                (lets [ ( b 5, callR "Rt.gcMarkValue" [ mkNum (v baseW) ] ) ]
                    (callR "Rt.gcScanValueArray" [ mkNum (iadd (v baseW) (n 40)), mkNum (isub (v cntW) (n 1)) ])
                )
            )
        )


{-| `Rt.gcDrain _` — pop one object off the mark stack, scan its body by
kind (value_array -> its n elements; raw -> nothing), recurse until empty.
-}
gcDrainDefun : Defun
gcDrainDefun =
    let
        dummy =
            p1

        region =
            b 2

        top =
            b 3

        newTop =
            b 4

        p =
            b 5

        flags =
            b 6

        kind =
            b 7

        count =
            b 8
    in
    lam "Rt.gcDrain" [ dummy ]
        (lets
            [ ( region, callW "rt_midgc_region" [] )
            , ( top, wload (v region) (n offMarkTop) )
            ]
            (iff (gtW (v top) (n metaWords))
                (lets
                    [ ( newTop, isub (v top) (n 1) )
                    , ( p, wload (v region) (v newTop) )
                    , ( flags, wload (v p) (n -2) )
                    , ( kind, idiv (v flags) (n 2) )
                    , ( count, wload (v p) (n -1) )
                    ]
                    (lets
                        [ ( b 9, wstore (v region) (n offMarkTop) (v newTop) )
                        , ( b 10
                          , iff (eqW (v kind) (n 1))
                                (callR "Rt.gcScanValueArray" [ mkNum (v p), mkNum (v count) ])
                                mkNil
                          )
                        ]
                        (callR "Rt.gcDrain" [ mkNum (n 0) ])
                    )
                )
                mkNil
            )
        )


{-| `Rt.gcSweep cursor` — walk the allocated region one object at a time:
clear the mark bit on live objects, link dead objects into the free list
(body word 0 holds the next pointer, the header stays for the allocator).
-}
gcSweepDefun : Defun
gcSweepDefun =
    let
        cursor =
            p1

        cursorW =
            b 2

        region =
            b 3

        heapCursor =
            b 4

        flags =
            b 5

        kind =
            b 6

        count =
            b 7

        total =
            b 8

        marked =
            b 9
    in
    lam "Rt.gcSweep" [ cursor ]
        (lets
            [ ( cursorW, wOf (v cursor) )
            , ( region, callW "rt_midgc_region" [] )
            , ( heapCursor, wload (v region) (n offHeapCursor) )
            ]
            (iff (geW (v cursorW) (v heapCursor))
                mkNil
                (lets
                    [ ( flags, wload (v cursorW) (n -2) )
                    , ( kind, idiv (v flags) (n 2) )
                    , ( count, wload (v cursorW) (n -1) )
                    , ( total, totalWords (v kind) (v count) )
                    , ( marked, isub (v flags) (imul (idiv (v flags) (n 2)) (n 2)) )
                    ]
                    (iff (eqW (v marked) (n 1))
                        (lets [ ( b 10, wstore (v cursorW) (n -2) (isub (v flags) (n 1)) ) ]
                            (callR "Rt.gcSweep" [ mkNum (iadd (v cursorW) (imul (v total) (n 8))) ])
                        )
                        (lets
                            [ ( b 11, wstore (v cursorW) (n 0) (wload (v region) (n offFreeHead)) )
                            , ( b 12, wstore (v region) (n offFreeHead) (v cursorW) )
                            ]
                            (callR "Rt.gcSweep" [ mkNum (iadd (v cursorW) (imul (v total) (n 8))) ])
                        )
                    )
                )
            )
        )


{-| `Rt.gcMarkPtr p` — mark one object head (p is the body address, boxed).
Bounds-checked against the object area (a static data address or a Zig-heap
pointer is outside it and is deliberately not ours to mark); push the newly
marked object onto the mark stack.
-}
gcMarkPtrDefun : Defun
gcMarkPtrDefun =
    let
        p =
            p1

        ptr =
            b 2

        region =
            b 3

        heapStart =
            b 4

        heapEnd =
            b 5

        flags =
            b 6

        marked =
            b 7

        top =
            b 8

        markEnd =
            b 9
    in
    lam "Rt.gcMarkPtr" [ p ]
        (lets
            [ ( ptr, wOf (v p) )
            , ( region, callW "rt_midgc_region" [] )
            , ( heapStart, wload (v region) (n offHeapStart) )
            , ( heapEnd, wload (v region) (n offHeapEnd) )
            ]
            (iff (and2 (neW (v ptr) (n 0)) (and2 (geW (v ptr) (v heapStart)) (ltW (v ptr) (v heapEnd))))
                (lets
                    [ ( flags, wload (v ptr) (n -2) )
                    , ( marked, isub (v flags) (imul (idiv (v flags) (n 2)) (n 2)) )
                    , ( top, wload (v region) (n offMarkTop) )
                    , ( markEnd, wload (v region) (n offMarkEnd) )
                    ]
                    (iff (eqW (v marked) (n 0))
                        (iff (ltW (v top) (v markEnd))
                            (lets
                                [ ( b 10, wstore (v ptr) (n -2) (iadd (v flags) (n 1)) )
                                , ( b 11, wstore (v region) (v top) (v ptr) )
                                , ( b 12, wstore (v region) (n offMarkTop) (iadd (v top) (n 1)) )
                                ]
                                mkNil
                            )
                            (die dieMarkOverflow)
                        )
                        mkNil
                    )
                )
                mkNil
            )
        )


{-| `Rt.gcMarkValue vaddr` — scan ONE Value in place: read its tag and mark
every pointer-bearing payload word.  The pointer tags mirror the Zig
collector's scan.zig scanValue exactly (string/cons/lambda/error/vector/
record); the unboxed tags (number/symbol/boolean/nil/mark/prim/stream/float)
hold no pointers; the unused gap 13 and anything above 14 fail loudly.
-}
gcMarkValueDefun : Defun
gcMarkValueDefun =
    let
        vaddr =
            p1

        tag =
            b 2

        vaddrW =
            b 3

        markAt : Int -> Exp
        markAt wordIndex =
            callR "Rt.gcMarkPtr" [ mkNum (wload (v vaddrW) (n wordIndex)) ]

        seqMark : Int -> Int -> Exp
        seqMark w1 w2 =
            lets [ ( b 60, markAt w1 ) ] (markAt w2)

        dispatch : Exp -> Exp
        dispatch tagW =
            iff (eqW tagW (n 1)) (markAt 1)
                (iff (eqW tagW (n 4)) (markAt 1)
                    (iff (eqW tagW (n 6)) (seqMark 1 3)
                        (iff (eqW tagW (n 9)) (markAt 1)
                            (iff (eqW tagW (n 10)) (markAt 1)
                                (iff (eqW tagW (n 14)) (seqMark 1 3)
                                    (iff (eqW tagW (n 13)) (die dieUnknownTag)
                                        (iff (gtW tagW (n 14)) (die dieUnknownTag)
                                            mkNil
                                        )
                                    )
                                )
                            )
                        )
                    )
                )
    in
    lam "Rt.gcMarkValue" [ vaddr ]
        (lets
            [ ( tag, tag32 (wOf (v vaddr)) )
            , ( vaddrW, wOf (v vaddr) )
            ]
            (dispatch (v tag))
        )


-- A value-position `tag > 14` test (the unboxed tags stop at 14).
gtW : Exp -> Exp -> Exp
gtW a bb =
    mkBool (icmp RCgts a bb)


-- ============================ PROGRAM ============================


{-| The whole collector program: every defun above.  Injected by
Mid.QbeModule when QBE_MIDGC=1 and seeded by Mid.Rt.gcSeeds.
-}
gcProgram : List Defun
gcProgram =
    [ gcInitDefun
    , allocVectorDefun
    , allocRawDefun
    , gcAllocDefun
    , gcAllocGoDefun
    , collectDefun
    , gcMarkRootsDefun
    , gcScanValueArrayDefun
    , gcDrainDefun
    , gcSweepDefun
    , gcMarkPtrDefun
    , gcMarkValueDefun
    ]
