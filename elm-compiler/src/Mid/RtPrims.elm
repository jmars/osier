module Mid.RtPrims exposing
    ( consDefun
    , primDefuns
    , helperDefuns
    )

{-| Mid.RtPrims — the PRIM BODIES of the Mid-written runtime (handoff
osier-midprims, TRACK 2 step 5: the mechanical remainder after the cons
spike).


## WHAT IS HERE

36 prim defuns (cons from the spike + 35 new) and 20 helper defuns, each a
Mid.Ir tree transcribed NODE FOR NODE from the Zig original in
vendor/osier-rt/src/rt/prims.zig / values.zig — ports, not re-designs, so
the fuzz differential (tools/qbe/consdiff) only has to prove the LOWERING
faithful.  Mid.Rt.impls maps the surface prim names onto the prim defuns;
Mid.Rt.rtDeps closes the RawCall edges for reachability.


## THE CLASSIFICATION THIS ENCODES (the step's enumeration)

PORTED here: the prims reachable from the Elm front end whose bodies are
pure value functions — the desugar set (cons, @p, emptylist, assoc, snd),
the operators (=, +, -, *, /, f/, <, <=, >, >=), the alias set (cn,
c-strlen, repeat, substring, char-code, shen.str->bytes,
shen.bytes->string, number?, string?, cons?, empty?, absvector, <-address,
address->) and the Bitwise family.  HOST-ONLY (still Zig at the flip): the
fd layer (write-byte, read-byte, read-file-as-string, open, close), the
process layer (exec-plan, cd, getcwd, getpid, getenv, setenv, glob), VM
state (intern — the symbol table; value — the registry; simple-error —
error unwinding) and `str` (floatText's shortest-round-trip float render +
strValue's composite printer: an algorithmic library, not a value
constructor).  UNREACHABLE, therefore UNPORTED (no compiled fixture can
name them, so no differential can drive them): hd, tl, fst, reverse,
append, absvector? — none is in any wrapper/alias table; the Prelude
implements reverse/append in Elm and case-destructuring reads pairs without
the prims.


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


p4 : Binder
p4 =
    { id = 4, name = "a4" }


p5 : Binder
p5 =
    { id = 5, name = "a5" }


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


w32Of : Exp -> Exp
w32Of x =
    Unsafe (RawPayload32 { value = x, word = 0 })


{-| The i32 LENGTH field (word 1) of a string or vector Value.  Booleans
keep `w32Of` (their payload is word 0).
-}
lenOf : Exp -> Exp
lenOf x =
    Unsafe (RawPayload32 { value = x, word = 1 })


{-| The record-helpers' length: a NIL base (the `{}` literal, which E keeps on
the emptylist route) has UNZEROED payload words 1/2 in a frame-free defun's
scratch slot, so a plain `lenOf` reads garbage and a huge `rt_vec_alloc`
follows.  Only the record walk/rebuild defuns use this — they are emitted
ONLY under rec=True, so the QBE_NOREC=1 hatch (which never emits them) keeps
mkNil's 0-word shape byte-identical to pre-E.
-}
recLenOf : Exp -> Exp
recLenOf x =
    -- WORD-level nil-aware length: len * (1 - isNil).  A nil base (the `{}`
    -- literal) has UNZEROED payload words 1/2 in a frame-free defun's scratch
    -- slot, so a plain lenOf reads garbage; this forces 0 for tag 5.  Stays a
    -- WORD producer (usable in RawAllocVector/cmpW), unlike an If branch.
    Unsafe
        (RawBin
            { op = RMul
            , a = Unsafe (RawPayload32 { value = x, word = 1 })
            , b = Unsafe (RawBin { op = RSub, a = n 1, b = Unsafe (RawTagIs { value = x, tag = RtLayout.tagNil }) })
            }
        )


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


itof : Exp -> Exp
itof we =
    Unsafe (RawIToF we)


fbin : RawFltBinOp -> Exp -> Exp -> Exp
fbin op x y =
    Unsafe (RawFltBin { op = op, a = x, b = y })


fcmp : RawFltCmpOp -> Exp -> Exp -> Exp
fcmp op x y =
    Unsafe (RawFltCmp { op = op, a = x, b = y })


toI32F : Exp -> Exp
toI32F x =
    Unsafe (RawUn { op = RFToI32, v = flOf x })


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


{-| values.zig deepEqual — the cons/vector kernel behind `=` and assoc's
key test.  depth is structurally bounded by the heap, as in Zig (its depth
counter guards only against malformed cycles, which the fused-pair
representation cannot produce).
-}
deepEqDefun : Bool -> Defun
deepEqDefun rec =
    let
        a =
            p1

        bb =
            p2
    in
    lam "Rt.deepEq" [ a, bb ] (deepEqArms rec a bb)


deepEqArms : Bool -> Binder -> Binder -> Exp
deepEqArms rec a bb =
    let
        -- E's tag-14 arm exists ONLY when records are positional (QBE_NOREC=1
        -- restores the pre-E chain where tag 14 is never produced).
        -- BOUNDARY (documented, plan risk 6): a compiled record (tag 14) == a
        -- host-built chain (tag 4) of the SAME content is FALSE — the tags
        -- differ and this switch short-circuits on `a.tag != b.tag` before any
        -- arm runs.  Reachable for host-only record types (Io.stat) and via
        -- Record.remove (recToChain returns a CHAIN), so e.g.
        --   Record.remove "x" { x = 1, y = 2 } == { y = 2 }
        -- is false under E where Elm's assoc-list semantics said true.
        aggTail =
            if rec then
                (iff (and2 (mkBool (tagIs (v a) 14)) (mkBool (tagIs (v bb) 14)))
                    (and2 (mkBool (cmpW RCeq (lenOf (v a)) (lenOf (v bb))))
                        (callR "Rt.vecEq" [ v a, v bb, mkNum (n 0) ])
                    )
                    (iff (and2 (mkBool (tagIs (v a) 10)) (mkBool (tagIs (v bb) 10)))
                        (and2 (mkBool (cmpW RCeq (lenOf (v a)) (lenOf (v bb))))
                            (callR "Rt.vecEq" [ v a, v bb, mkNum (n 0) ])
                        )
                        falseV
                    )
                )

            else
                (iff (and2 (mkBool (tagIs (v a) 10)) (mkBool (tagIs (v bb) 10)))
                    (and2 (mkBool (cmpW RCeq (lenOf (v a)) (lenOf (v bb))))
                        (callR "Rt.vecEq" [ v a, v bb, mkNum (n 0) ])
                    )
                    falseV
                )
    in
    iff (and2 (mkBool (tagIs (v a) 0)) (mkBool (tagIs (v bb) 0)))
        (mkBool (cmpW RCeq (wOf (v a)) (wOf (v bb))))
        (iff (and2 (mkBool (tagIs (v a) 1)) (mkBool (tagIs (v bb) 1)))
            (and2 (mkBool (cmpW RCeq (lenOf (v a)) (lenOf (v bb))))
                (callR "Rt.bytesEqGo" [ v a, v bb, mkNum (n 0) ])
            )
            (iff (and2 (mkBool (tagIs (v a) 2)) (mkBool (tagIs (v bb) 2)))
                (callR "Rt.symEq" [ v a, v bb, mkNum (n 0) ])
                (iff (and2 (mkBool (tagIs (v a) 3)) (mkBool (tagIs (v bb) 3)))
                    (mkBool (cmpW RCeq (w32Of (v a)) (w32Of (v bb))))
                    (iff (and2 (mkBool (tagIs (v a) 12)) (mkBool (tagIs (v bb) 12)))
                        (mkBool (fcmp RFEq (flOf (v a)) (flOf (v bb))))
                        (iff (mkBool (tagIs (v a) 5))
                            (mkBool (tagIs (v bb) 5))
                            (iff (and2 (mkBool (tagIs (v a) 4)) (mkBool (tagIs (v bb) 4)))
                                (and2 (callR "Rt.deepEq" [ carV (v a), carV (v bb) ])
                                    (callR "Rt.deepEq" [ cdrV (v a), cdrV (v bb) ])
                                )
                                aggTail
                            )
                        )
                    )
                )
            )
        )


{-| bytesEqGo a b i — a's bytes vs b's bytes from i (lengths already
checked equal by the caller): byte compare + recurse.
-}
bytesEqGoDefun : Defun
bytesEqGoDefun =
    let
        a =
            p1

        bb =
            p2

        i =
            p3

        body =
            iff (mkBool (cmpW RCges (wOf (v i)) (lenOf (v a))))
                trueV
                (and2
                    (mkBool (cmpW RCeq (byteOf (v a) (wOf (v i))) (byteOf (v bb) (wOf (v i)))))
                    (callR "Rt.bytesEqGo" [ v a, v bb, mkNum (iadd (wOf (v i)) (n 1)) ])
                )
    in
    lam "Rt.bytesEqGo" [ a, bb, i ] body


{-| symEq a b i — the null-terminated name walk shared by symbol/symbol and
symbol/prim equality (a prim Value's word 0 is its name pointer, exactly
like a symbol's).
-}
symEqDefun : Defun
symEqDefun =
    let
        a =
            p1

        bb =
            p2

        i =
            p3

        body =
            iff (mkBool (cmpW RCeq (byteOf (v a) (wOf (v i))) (n 0)))
                (mkBool (cmpW RCeq (byteOf (v bb) (wOf (v i))) (n 0)))
                (and2
                    (mkBool (cmpW RCeq (byteOf (v a) (wOf (v i))) (byteOf (v bb) (wOf (v i)))))
                    (callR "Rt.symEq" [ v a, v bb, mkNum (iadd (wOf (v i)) (n 1)) ])
                )
    in
    lam "Rt.symEq" [ a, bb, i ] body


{-| vecEq va vb i — elementwise deepEqual from i (lengths already equal).
-}
vecEqDefun : Defun
vecEqDefun =
    let
        a =
            p1

        bb =
            p2

        i =
            p3

        body =
            iff (mkBool (cmpW RCges (wOf (v i)) (lenOf (v a))))
                trueV
                (and2
                    (callR "Rt.deepEq"
                        [ Unsafe (RawVecLoad { vec = wOf (v a), index = wOf (v i) })
                        , Unsafe (RawVecLoad { vec = wOf (v bb), index = wOf (v i) })
                        ]
                    )
                    (callR "Rt.vecEq" [ v a, v bb, mkNum (iadd (wOf (v i)) (n 1)) ])
                )
    in
    lam "Rt.vecEq" [ a, bb, i ] body


{-| asF x — the M4 numeric promote: a float is itself, a number widens.
-}
asFDefun : Defun
asFDefun =
    let
        x =
            p1
    in
    lam "Rt.asF" [ x ]
        (iff (mkBool (tagIs (v x) 12))
            (v x)
            (mkFlt (itof (wOf (v x))))
        )


{-| toI32 x — the Bitwise operand conversion (prims.zig bitOperand): float
truncates toward zero, a number IS its low 32 bits at the w-typed use,
anything else is 0.
-}
toI32Defun : Defun
toI32Defun =
    let
        x =
            p1
    in
    lam "Rt.toI32" [ x ]
        (iff (mkBool (tagIs (v x) 12))
            (mkNum (toI32F (v x)))
            (iff (mkBool (tagIs (v x) 0))
                (v x)
                (mkNum (n 0))
            )
        )


{-| dgs n — the digits of n (n /= 0), LEAST-significant first, as a byte
list.  Negative arithmetic throughout (n and r stay negative): `r = n -
(n/10)*10` is in [-9..-1] for negative n, so the digit is 0 - r — no i64
MIN overflow, exactly the shape std.fmt's {d} uses.
-}
dgsDefun : Defun
dgsDefun =
    let
        nArg =
            p1

        q =
            b 4

        r =
            b 5

        rAbs =
            b 6

        digit =
            b 7

        body =
            iff (mkBool (cmpW RCeq (wOf (v nArg)) (n 0)))
                mkNil
                (lets
                    [ ( q, mkNum (idiv (wOf (v nArg)) (n 10)) )
                    , ( r, mkNum (isub (wOf (v nArg)) (imul (wOf (v q)) (n 10))) )

                    -- r carries n's sign (i64 div truncates): abs it, then
                    -- '0' + d.  Works for i64 MIN (everything stays
                    -- negative until the abs).
                    , ( rAbs
                      , iff (mkBool (cmpW RClts (wOf (v nArg)) (n 0)))
                            (mkNum (isub (n 0) (wOf (v r))))
                            (v r)
                      )
                    , ( digit, mkNum (iadd (n 48) (wOf (v rAbs))) )
                    ]
                    (consV (v digit) (callR "Rt.dgs" [ v q ]))
                )
    in
    lam "Rt.dgs" [ nArg ] body


{-| revGo l acc — the accumulator walk behind reverse AND append (prims.zig
primReverse/primAppend's two loops).
-}
revGoDefun : Defun
revGoDefun =
    let
        l =
            p1

        acc =
            p2
    in
    lam "Rt.revGo" [ l, acc ]
        (iff (mkBool (tagIs (v l) 4))
            (callR "Rt.revGo" [ cdrV (v l), consV (carV (v l)) (v acc) ])
            (v acc)
        )


{-| bytesOf s i — s's bytes from index i as a byte list.
-}
bytesOfDefun : Defun
bytesOfDefun =
    let
        s =
            p1

        i =
            p2
    in
    lam "Rt.bytesOf" [ s, i ]
        (iff (mkBool (cmpW RCges (wOf (v i)) (lenOf (v s))))
            mkNil
            (consV (mkNum (byteOf (v s) (wOf (v i))))
                (callR "Rt.bytesOf" [ v s, mkNum (iadd (wOf (v i)) (n 1)) ])
            )
        )


{-| numText n — a number as its decimal string, byte-exact with std.fmt's
`{d}`: sign, digits most-significant first (dgs + revGo), 0 special-cased
to "0".
-}
numTextDefun : Defun
numTextDefun =
    let
        nArg =
            p1

        digits =
            b 4

        signed =
            b 5

        digitsV =
            callR "Rt.revGo" [ callR "Rt.dgs" [ v nArg ], mkNil ]

        signedV =
            iff (mkBool (cmpW RClts (wOf (v nArg)) (n 0)))
                (consV (mkNum (n 45)) (v digits))
                (v digits)

        body =
            iff (mkBool (cmpW RCeq (wOf (v nArg)) (n 0)))
                (callR "Rt.bytesToStr" [ consV (mkNum (n 48)) mkNil ])
                (lets
                    [ ( digits, digitsV )
                    , ( signed, signedV )
                    ]
                    (callR "Rt.bytesToStr" [ v signed ])
                )
    in
    lam "Rt.numText" [ nArg ] body


{-| bytesToStr bs — the shen.bytes->string body (below) shared as a helper:
count the list, ONE RawAllocRaw, fill byte by byte, wrap.  `bufN` boxes the
buffer pointer as a NUMBER Value so the recursive filler can take it — the
collector sees a number and never chases it, and no GC can run between the
alloc and the last store (the filler allocs nothing).
-}
bytesToStrDefun : Defun
bytesToStrDefun =
    let
        bs =
            p1

        count =
            b 4

        bufW =
            b 5

        bufN =
            b 6

        body =
            lets
                [ ( count, callR "Rt.countL" [ v bs ] )
                , ( bufW, Unsafe (RawAllocRaw (iadd (wOf (v count)) (n 1))) )
                , ( bufN, mkNum (v bufW) )
                ]
                (lets
                    [ ( b 7, callR "Rt.fillGo" [ v bs, v bufN, mkNum (n 0) ] ) ]
                    (mkStr (v bufW) (wOf (v count)))
                )
    in
    lam "Rt.bytesToStr" [ bs ] body


{-| countL l — the list's length as a number.
-}
countLDefun : Defun
countLDefun =
    let
        l =
            p1
    in
    lam "Rt.countL" [ l ]
        (iff (mkBool (tagIs (v l) 5))
            (mkNum (n 0))
            (mkNum (iadd (wOf (callR "Rt.countL" [ cdrV (v l) ])) (n 1)))
        )


{-| fillGo l bufN i — store the list's bytes at buf[i++] (bufN boxes the
raw pointer; see bytesToStr).
-}
fillGoDefun : Defun
fillGoDefun =
    let
        l =
            p1

        bufN =
            p2

        i =
            p3

        body =
            lets
                [ ( b 4
                  , Unsafe
                        (RawByteStore
                            { ptr = wOf (v bufN)
                            , index = wOf (v i)
                            , value = wOf (carV (v l))
                            }
                        )
                  )
                ]
                (callR "Rt.fillGo" [ cdrV (v l), v bufN, mkNum (iadd (wOf (v i)) (n 1)) ])
    in
    lam "Rt.fillGo" [ l, bufN, i ]
        (iff (mkBool (tagIs (v l) 5))
            mkNil
            body
        )


{-| cn2 x y — concatenate two STRING values (the tail of primCn, after
strOf has coerced the operands).
-}
cn2Defun : Defun
cn2Defun =
    let
        x =
            p1

        y =
            p2
    in
    lam "Rt.cn2" [ x, y ]
        (callR "Rt.bytesToStr"
            [ callR "Rt.appendL"
                [ callR "Rt.bytesOf" [ v x, mkNum (n 0) ]
                , callR "Rt.bytesOf" [ v y, mkNum (n 0) ]
                ]
            ]
        )


{-| appendL xs ys — prims.zig primAppend's shape (reverse-reverse onto the
tail), shared by cn/repeat.
-}
appendLDefun : Defun
appendLDefun =
    let
        xs =
            p1

        ys =
            p2
    in
    lam "Rt.appendL" [ xs, ys ]
        (callR "Rt.revGo" [ callR "Rt.revGo" [ v xs, mkNil ], v ys ])


{-| symToStr s i — the null-terminated name at s's word 0 as a string.
-}
symToStrDefun : Defun
symToStrDefun =
    let
        s =
            p1

        i =
            p2

        byte =
            b 4

        body =
            -- `byte` is already the raw word (RawByteLoad); reading it again
            -- through wOf would be a value-position payload read.
            lets
                [ ( byte, Unsafe (RawByteLoad { ptr = wOf (v s), index = wOf (v i) }) ) ]
                (iff (mkBool (cmpW RCeq (v byte) (n 0)))
                    (callR "Rt.bytesToStr" [ mkNil ])
                    (callR "Rt.bytesToStr"
                        [ consV (mkNum (v byte))
                            (callR "Rt.nameBytes" [ v s, mkNum (iadd (wOf (v i)) (n 1)) ])
                        ]
                    )
                )
    in
    lam "Rt.symToStr" [ s, i ] body


{-| nameBytes s i — the name's bytes from i as a list.
-}
nameBytesDefun : Defun
nameBytesDefun =
    let
        s =
            p1

        i =
            p2

        byte =
            b 4

        body =
            lets
                [ ( byte, Unsafe (RawByteLoad { ptr = wOf (v s), index = wOf (v i) }) ) ]
                (iff (mkBool (cmpW RCeq (v byte) (n 0)))
                    mkNil
                    (consV (mkNum (v byte))
                        (callR "Rt.nameBytes" [ v s, mkNum (iadd (wOf (v i)) (n 1)) ])
                    )
                )
    in
    lam "Rt.nameBytes" [ s, i ] body


{-| strOf x — primCn's per-operand coercion: string as-is, number via
numText, symbol via its name, boolean/nil/composite as the C literals.
-}
strOfDefun : Defun
strOfDefun =
    let
        x =
            p1
    in
    lam "Rt.strOf" [ x ]
        (iff (mkBool (tagIs (v x) 1))
            (v x)
            (iff (mkBool (tagIs (v x) 0))
                (callR "Rt.numText" [ v x ])
                (iff (mkBool (tagIs (v x) 2))
                    (callR "Rt.symToStr" [ v x, mkNum (n 0) ])
                    (iff (mkBool (tagIs (v x) 3))
                        (iff (mkBool (cmpW RCne (w32Of (v x)) (n 0)))
                            (Lit (LString "true"))
                            (Lit (LString "false"))
                        )
                        (iff (mkBool (tagIs (v x) 5))
                            (Lit (LString "[]"))
                            (Lit (LString "[?]"))
                        )
                    )
                )
            )
        )


{-| assocGo k l — primAssoc's walk: the first pair whose car is a cons and
whose key deep-equals k.  A non-list input is primAssoc's throwShen — the
halt arm here (module header GAPS).
-}
assocGoDefun : Defun
assocGoDefun =
    let
        k =
            p1

        l =
            p2

        pair =
            b 4
    in
    lam "Rt.assocGo" [ k, l ]
        (iff (mkBool (tagIs (v l) 4))
            (lets [ ( pair, carV (v l) ) ]
                (iff (and2 (mkBool (tagIs (v pair) 4)) (callR "Rt.deepEq" [ v k, carV (v pair) ]))
                    (v pair)
                    (callR "Rt.assocGo" [ v k, cdrV (v l) ])
                )
            )
            (iff (mkBool (tagIs (v l) 5))
                mkNil
                haltV
            )
        )


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


{-| `Rt.recGet rec field` — E's tag-14 record read, the WALK form (closed-row
sites load data[rank] directly; this is the open/absent/non-Var fallback).
Walks the static names array (word 2) and byte-compares each name against
`field` (a symbol Value) via symEq, boxing the 8-byte name pointer as a symbol
Value (tag 2, word 0 = the pointer — the SAME layout symEq already reads).
-}
recGetDefun : Defun
recGetDefun =
    let
        rec =
            p1

        field =
            p2
    in
    lam "Rt.recGet" [ rec, field ]
        (callR "Rt.recGetGo" [ v rec, v field, mkNum (n 0) ])


recGetGoDefun : Defun
recGetGoDefun =
    let
        rec =
            p1

        field =
            p2

        i =
            p3

        nameSym =
            b 4

        nameSymVal =
            Unsafe (RawVecLoad { vec = Unsafe (RawPayload { value = v rec, word = 2 }), index = wOf (v i) })
    in
    lam "Rt.recGetGo" [ rec, field, i ]
        (iff (mkBool (cmpW RCges (wOf (v i)) (recLenOf (v rec))))
            haltV
            (lets [ ( nameSym, nameSymVal ) ]
                (iff (callR "Rt.symEq" [ v nameSym, v field, mkNum (n 0) ])
                    (Unsafe (RawVecLoad { vec = Unsafe (RawPayload { value = v rec, word = 0 }), index = wOf (v i) }))
                    (callR "Rt.recGetGo" [ v rec, v field, mkNum (iadd (wOf (v i)) (n 1)) ])
                )
            )
        )


{-| `Rt.recUpd rec field newv` — E's tag-14 record update (the walk form):
find the field's index (recUpdFind), allocate the copy, copy all values
(recUpdCopy), overwrite the found slot, wrap reusing the base's names pointer.
Every defun here is <= 3 params (the lean ABI's direct_arity bound), so the
walk is split into two 3-param passes rather than one 5-param loop.
-}
recUpdDefun : Defun
recUpdDefun =
    let
        rec =
            p1

        field =
            p2

        newv =
            p3

        find =
            b 4

        nd =
            b 5

        ndN =
            b 6

        copied =
            b 7

        overwrote =
            b 8
    in
    lam "Rt.recUpd" [ rec, field, newv ]
        (lets
            [ ( find, callR "Rt.recUpdFind" [ v rec, v field, mkNum (n 0) ] )
            , ( nd, Unsafe (RawAllocVector (recLenOf (v rec))) )
            , ( ndN, mkNum (v nd) )
            , ( copied, callR "Rt.recUpdCopy" [ v rec, v ndN, mkNum (n 0) ] )
            , ( overwrote
              , Unsafe (RawVecStore { vec = wOf (v ndN), index = wOf (v find), value = v newv })
              )
            ]
            (Unsafe
                (RawMkValue
                    { tag = RtLayout.tagRecord
                    , words =
                        [ Unsafe (RawVecAddr { vec = wOf (v ndN), index = n 0 })
                        , recLenOf (v rec)
                        , Unsafe (RawPayload { value = v rec, word = 2 })
                        ]
                    }
                )
            )
        )


recUpdFindDefun : Defun
recUpdFindDefun =
    let
        rec =
            p1

        field =
            p2

        i =
            p3

        nameSym =
            b 4

        nameSymVal =
            Unsafe (RawVecLoad { vec = Unsafe (RawPayload { value = v rec, word = 2 }), index = wOf (v i) })
    in
    lam "Rt.recUpdFind" [ rec, field, i ]
        (iff (mkBool (cmpW RCges (wOf (v i)) (recLenOf (v rec))))
            (mkNum (n -1))
            (lets [ ( nameSym, nameSymVal ) ]
                (iff (callR "Rt.symEq" [ v nameSym, v field, mkNum (n 0) ])
                    (mkNum (wOf (v i)))
                    (callR "Rt.recUpdFind" [ v rec, v field, mkNum (iadd (wOf (v i)) (n 1)) ])
                )
            )
        )


recUpdCopyDefun : Defun
recUpdCopyDefun =
    let
        rec =
            p1

        newdata =
            p2

        i =
            p3

        stored =
            b 4

        storedVal =
            Unsafe
                (RawVecStore
                    { vec = wOf (v newdata)
                    , index = wOf (v i)
                    , value = Unsafe (RawVecLoad { vec = Unsafe (RawPayload { value = v rec, word = 0 }), index = wOf (v i) })
                    }
                )
    in
    lam "Rt.recUpdCopy" [ rec, newdata, i ]
        (iff (mkBool (cmpW RCges (wOf (v i)) (recLenOf (v rec))))
            mkNil
            (lets [ ( stored, storedVal ) ]
                (callR "Rt.recUpdCopy" [ v rec, v newdata, mkNum (iadd (wOf (v i)) (n 1)) ])
            )
        )


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


{-| `Rt.recAppendFind rec field i` — the SORTED position the new field must
take: the first index i whose name sorts after `field` (symLess field
names[i]), else len.  Keeps every tag-14 data/names array in canonical order.
-}
recAppendFindDefun : Defun
recAppendFindDefun =
    let
        rec =
            p1

        field =
            p2

        i =
            p3

        nameSym =
            b 4

        nameSymVal =
            Unsafe (RawVecLoad { vec = Unsafe (RawPayload { value = v rec, word = 2 }), index = wOf (v i) })
    in
    lam "Rt.recAppendFind" [ rec, field, i ]
        (iff (mkBool (cmpW RCges (wOf (v i)) (recLenOf (v rec))))
            (mkNum (wOf (v i)))
            (lets [ ( nameSym, nameSymVal ) ]
                (iff (callR "Rt.symLess" [ v field, v nameSym, mkNum (n 0) ])
                    (mkNum (wOf (v i)))
                    (callR "Rt.recAppendFind" [ v rec, v field, mkNum (iadd (wOf (v i)) (n 1)) ])
                )
            )
        )


{-| `Rt.recAppendDataGo rec newdata packed` — copy the base's data into the
one-longer array, leaving a HOLE at the sorted insert position.  `packed` =
pos*65536 + j (the destination slot 0..len; records have < 65536 fields).
-}
recAppendDataGoDefun : Defun
recAppendDataGoDefun =
    let
        rec =
            p1

        newdata =
            p2

        packed =
            p3

        j =
            b 4

        pos =
            b 5

        store =
            b 6
    in
    lam "Rt.recAppendDataGo" [ rec, newdata, packed ]
        (lets
            [ ( j, mkNum (iand (wOf (v packed)) (n 65535)) )
            , ( pos, mkNum (shrW (wOf (v packed)) (n 16)) )
            ]
            (iff (mkBool (cmpW RCgts (wOf (v j)) (recLenOf (v rec))))
                mkNil
                (lets
                    [ ( store
                      , iff (mkBool (cmpW RClts (wOf (v j)) (wOf (v pos))))
                            (Unsafe
                                (RawVecStore
                                    { vec = wOf (v newdata)
                                    , index = wOf (v j)
                                    , value = Unsafe (RawVecLoad { vec = Unsafe (RawPayload { value = v rec, word = 0 }), index = wOf (v j) })
                                    }
                                )
                            )
                            (iff (mkBool (cmpW RCeq (wOf (v j)) (wOf (v pos))))
                                mkNil
                                (Unsafe
                                    (RawVecStore
                                        { vec = wOf (v newdata)
                                        , index = wOf (v j)
                                        , value = Unsafe (RawVecLoad { vec = Unsafe (RawPayload { value = v rec, word = 0 }), index = isub (wOf (v j)) (n 1) })
                                        }
                                    )
                                )
                            )
                      )
                    ]
                    (callR "Rt.recAppendDataGo" [ v rec, v newdata, mkNum (iadd (wOf (v packed)) (n 1)) ])
                )
            )
        )


{-| `Rt.recAppendNamesGo rec newnames packed` — the names-array twin of
recAppendDataGo (word 2 instead of word 0).
-}
recAppendNamesGoDefun : Defun
recAppendNamesGoDefun =
    let
        rec =
            p1

        newnames =
            p2

        packed =
            p3

        j =
            b 4

        pos =
            b 5

        store =
            b 6
    in
    lam "Rt.recAppendNamesGo" [ rec, newnames, packed ]
        (lets
            [ ( j, mkNum (iand (wOf (v packed)) (n 65535)) )
            , ( pos, mkNum (shrW (wOf (v packed)) (n 16)) )
            ]
            (iff (mkBool (cmpW RCgts (wOf (v j)) (recLenOf (v rec))))
                mkNil
                (lets
                    [ ( store
                      , iff (mkBool (cmpW RClts (wOf (v j)) (wOf (v pos))))
                            (Unsafe
                                (RawVecStore
                                    { vec = wOf (v newnames)
                                    , index = wOf (v j)
                                    , value = Unsafe (RawVecLoad { vec = Unsafe (RawPayload { value = v rec, word = 2 }), index = wOf (v j) })
                                    }
                                )
                            )
                            (iff (mkBool (cmpW RCeq (wOf (v j)) (wOf (v pos))))
                                mkNil
                                (Unsafe
                                    (RawVecStore
                                        { vec = wOf (v newnames)
                                        , index = wOf (v j)
                                        , value = Unsafe (RawVecLoad { vec = Unsafe (RawPayload { value = v rec, word = 2 }), index = isub (wOf (v j)) (n 1) })
                                        }
                                    )
                                )
                            )
                      )
                    ]
                    (callR "Rt.recAppendNamesGo" [ v rec, v newnames, mkNum (iadd (wOf (v packed)) (n 1)) ])
                )
            )
        )


{-| `Rt.recAppend rec field newv` — INSERT a NEW field (the `<-` insertion's
absent case) at its SORTED position, keeping the data/names arrays canonical.
Allocates one-longer arrays, shifts around the insert position, stores the
value and the field symbol, wraps.
-}
recAppendDefun : Defun
recAppendDefun =
    let
        rec =
            p1

        field =
            p2

        newv =
            p3

        pos =
            b 4

        nd =
            b 5

        ndN =
            b 6

        nn =
            b 7

        nnN =
            b 8

        packed =
            b 9

        dataCopied =
            b 10

        namesCopied =
            b 11

        storeNewv =
            b 12

        storeField =
            b 13
    in
    lam "Rt.recAppend" [ rec, field, newv ]
        (lets
            [ ( pos, callR "Rt.recAppendFind" [ v rec, v field, mkNum (n 0) ] )
            , ( nd, Unsafe (RawAllocVector (iadd (recLenOf (v rec)) (n 1))) )
            , ( ndN, mkNum (v nd) )
            , ( nn, Unsafe (RawAllocVector (iadd (recLenOf (v rec)) (n 1))) )
            , ( nnN, mkNum (v nn) )
            , ( packed, mkNum (imul (wOf (v pos)) (n 65536)) )
            , ( dataCopied, callR "Rt.recAppendDataGo" [ v rec, v ndN, v packed ] )
            , ( namesCopied, callR "Rt.recAppendNamesGo" [ v rec, v nnN, v packed ] )
            , ( storeNewv
              , Unsafe (RawVecStore { vec = wOf (v ndN), index = wOf (v pos), value = v newv })
              )
            , ( storeField
              , Unsafe (RawVecStore { vec = wOf (v nnN), index = wOf (v pos), value = v field })
              )
            ]
            (Unsafe
                (RawMkValue
                    { tag = RtLayout.tagRecord
                    , words =
                        [ Unsafe (RawVecAddr { vec = wOf (v ndN), index = n 0 })
                        , iadd (recLenOf (v rec)) (n 1)
                        , Unsafe (RawVecAddr { vec = wOf (v nnN), index = n 0 })
                        ]
                    }
                )
            )
        )


{-| `Rt.recInsert rec field newv` — the `<-` INSERTION-or-update: if the field
is present, update (recUpd); if absent, append (recAppend).
-}
recInsertDefun : Defun
recInsertDefun =
    let
        rec =
            p1

        field =
            p2

        newv =
            p3

        find =
            b 4
    in
    lam "Rt.recInsert" [ rec, field, newv ]
        (lets [ ( find, callR "Rt.recUpdFind" [ v rec, v field, mkNum (n 0) ] ) ]
            (iff (mkBool (cmpW RCges (wOf (v find)) (n 0)))
                (callR "Rt.recUpd" [ v rec, v field, v newv ])
                (callR "Rt.recAppend" [ v rec, v field, v newv ])
            )
        )


{-| `Rt.recToChain rec` — convert a positional record to an assoc chain (the
representation `Prelude.removeFieldImpl` walks).  Used by the trusted
removeFieldImpl body so `Record.remove` works on compiled (tag-14) records.
-}
recToChainDefun : Defun
recToChainDefun =
    let
        rec =
            p1
    in
    lam "Rt.recToChain" [ rec ]
        (iff (mkBool (tagIs (v rec) 14))
            (callR "Rt.recToChainGo" [ v rec, mkNum (n 0), mkNil ])
            (v rec)
        )


recToChainGoDefun : Defun
recToChainGoDefun =
    let
        rec =
            p1

        i =
            p2

        acc =
            p3

        pair =
            callR "Rt.@p"
                [ Unsafe (RawVecLoad { vec = Unsafe (RawPayload { value = v rec, word = 2 }), index = wOf (v i) })
                , Unsafe (RawVecLoad { vec = Unsafe (RawPayload { value = v rec, word = 0 }), index = wOf (v i) })
                ]
    in
    lam "Rt.recToChainGo" [ rec, i, acc ]
        (iff (mkBool (cmpW RCges (wOf (v i)) (recLenOf (v rec))))
            (v acc)
            (callR "Rt.recToChainGo" [ v rec, mkNum (iadd (wOf (v i)) (n 1)), consV pair (v acc) ])
        )


-- ============================ FD PRIMS (zigretire stage 3 GROUP 1) ============================
-- The fd layer (write-byte, read-byte, open, close) as Mid bodies over
-- RawCallRaw libc seats (write/read/openat/close/__errno_location) plus three
-- Zig registry seats (rt_ss_in/rt_ss_readbyte/rt_ss_close, tools/qbe/rt.zig)
-- for the string-stream arms.  read-file-as-string is the NEXT landing (its
-- copy-on-grow page-allocator accumulator is a distinct mechanism).
--
-- The stream Value layout (gc/types.zig stream extern struct): payload word 0
-- = file (?*anyopaque, an fd-int-in-pointer; null = fd 0), payload word 1 =
-- is_input (LOW half) | is_string (HIGH half).  is_string is read by shifting
-- the packed word right 32 (is_input is the RawPayload32 half).


{-| The stream Value's `is_string` i32 field as a 0/1 word.  Payload word 1 is
is_input (LOW half) | is_string (HIGH half); is_input is always 0 or 1, so the
packed word is > 1 exactly when is_string is set (no 64-bit shift exists in
Mid — the i32 family is 32-bit only).
-}
isStringOf : Exp -> Exp
isStringOf x =
    cmpW RCgts (Unsafe (RawPayload { value = x, word = 1 })) (n 1)


{-| Build a stream Value (tag 11): the file word plus the packed
is_input/is_string word (is_input low, is_string high — `is_string * 2^32`
computed as a 64-bit multiply, since the shift family is 32-bit).
-}
mkStream : Exp -> Exp -> Exp -> Exp
mkStream fileW isInW isStrW =
    Unsafe (RawMkValue { tag = RtLayout.tagStream, words = [ fileW, iadd isInW (imul (n 4294967296) isStrW) ] })


{-| errno as a word: __errno_location() then the low byte.  Linux errnos are
all < 256 and this target is little-endian, so the low byte IS the value.
-}
errnoOf : Exp
errnoOf =
    Unsafe (RawByteLoad { ptr = callW "__errno_location" [], index = n 0 })


{-| readFull fdN bufN countN — `read` with the EINTR retry Zig's std.posix.read
gives (raw libc read does not).  All args boxed as numbers (the recursive
helpers' discipline).  Returns the byte count as a number, -1 on a non-EINTR
error.  Non-allocating: the bufN pointer stays valid through the recursion.
-}
readFullDefun : Defun
readFullDefun =
    let
        fdN =
            p1

        bufN =
            p2

        countN =
            p3

        nW =
            b 4
    in
    lam "Rt.readFull" [ fdN, bufN, countN ]
        (lets
            [ ( nW, callW "read" [ wOf (v fdN), wOf (v bufN), wOf (v countN) ] ) ]
            (iff (mkBool (cmpW RClts (v nW) (n 0)))
                (iff (mkBool (cmpW RCeq errnoOf (n 4)))
                    (callR "Rt.readFull" [ v fdN, v bufN, v countN ])
                    (mkNum (n (-1)))
                )
                (mkNum (v nW))
            )
        )


{-| cStrFill bufN str i — fill buf[0..len] with str's bytes and buf[len] with
the NUL terminator.  `bufN` boxes the raw buffer pointer (a number the
collector never chases); `str` is re-read fresh each step (RawStrByte) so a
post-alloc move of the string is handled.  Returns bufN.

SELF-TAIL LOOP (the SF2 fix): the recursion goes through `App` on this
defun's own key — the in-frame loop (`countdown`'s mechanism), not the
per-byte native frame `callR` compiles to on the default route (MEASURED:
one ~800 B frame per byte; a path longer than the old Zig 4095 truncation
bound exhausted the driver's 64 MiB stack).  Stays FRAME-FREE (alloc8
scratch — the classifier treats the self-App as an edge) and non-allocating:
no safepoint in the loop, which is what keeps cd/getenv/setenv/open's
raw-buffer windows sound.  Never allocate here.
-}
cStrFillDefun : Defun
cStrFillDefun =
    let
        bufN =
            p1

        str =
            p2

        i =
            p3
    in
    lam "Rt.cStrFill" [ bufN, str, i ]
        (iff (mkBool (cmpW RCges (wOf (v i)) (lenOf (v str))))
            (lets
                [ ( b 4, Unsafe (RawByteStore { ptr = wOf (v bufN), index = wOf (v i), value = n 0 })) ]
                (v bufN)
            )
            (lets
                [ ( b 5, Unsafe (RawByteStore { ptr = wOf (v bufN), index = wOf (v i), value = Unsafe (RawStrByte { str = v str, index = wOf (v i) }) })) ]
                (App { fn = GRef { key = "Rt.cStrFill", force = False }, args = [ v bufN, v str, mkNum (iadd (wOf (v i)) (n 1)) ] })
            )
        )


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


{-| write-byte (2 args: byte, stream) — raw one-byte write to the stream's fd,
returns the byte.  The byte is the number payload's low byte (Zig's
`@truncate(@bitCast(number))`); the write result is ignored exactly as Zig
ignores it (`_ = std.posix.system.write`).
-}
writeByteDefun : Defun
writeByteDefun =
    let
        byte =
            p1

        stream =
            p2

        bufW =
            b 3
    in
    lam "Rt.write-byte" [ byte, stream ]
        (lets
            [ ( bufW, Unsafe (RawAllocRaw (n 1)) )
            , ( b 4, Unsafe (RawByteStore { ptr = v bufW, index = n 0, value = wOf (v byte) }) )
            , ( b 5, callW "write" [ wOf (v stream), v bufW, n 1 ] )
            ]
            (v byte)
        )


{-| read-byte (1 arg: stream).  String stream: the registry seat; file stream:
one read with EINTR retry, EOF/error -> -1.
-}
readByteDefun : Defun
readByteDefun =
    let
        stream =
            p1

        isStr =
            b 3

        fileArm =
            let
                fd =
                    b 4

                bufW =
                    b 5

                nVal =
                    b 6
            in
            lets
                [ ( fd, wOf (v stream) )
                , ( bufW, Unsafe (RawAllocRaw (n 1)) )
                , ( nVal, callR "Rt.readFull" [ mkNum (v fd), mkNum (v bufW), mkNum (n 1) ] )
                ]
                (iff (mkBool (cmpW RCeq (wOf (v nVal)) (n 1)))
                    (mkNum (Unsafe (RawByteLoad { ptr = v bufW, index = n 0 })))
                    (mkNum (n (-1)))
                )

        stringArm =
            let
                i =
                    b 7

                r =
                    b 8
            in
            lets
                [ ( i, wOf (v stream) )
                , ( r, callW "rt_ss_readbyte" [ v i ] )
                ]
                (iff (mkBool (cmpW RCeq (v r) (n (-2))))
                    haltV
                    (mkNum (v r))
                )
    in
    lam "Rt.read-byte" [ stream ]
        (lets
            [ ( isStr, isStringOf (v stream) ) ]
            (iff (mkBool (v isStr))
                stringArm
                fileArm
            )
        )


{-| open (2 args: path, dir).  dir is "in" (O_RDONLY; ENOENT -> a string
stream of the path) or "out" (O_WRONLY|O_CREAT|O_TRUNC 0666); neither leaves
the accumulator as number 0 (C's fall-through on a zeroed acc).
-}
openDefun : Defun
openDefun =
    let
        path =
            p1

        dir =
            p2

        dirIsIn =
            callR "Rt.=" [ v dir, Lit (LString "in") ]

        dirIsOut =
            callR "Rt.=" [ v dir, Lit (LString "out") ]

        inArm =
            let
                ( cstrBinds, cstr ) =
                    cStrOf 10 (v path)

                fd =
                    b 14
            in
            lets
                (cstrBinds ++ [ ( fd, callW "openat" [ n (-100), cstr, n 0, n 0 ] ) ])
                (iff (mkBool (cmpW RClts (v fd) (n 0)))
                    (iff (mkBool (cmpW RCeq errnoOf (n 2)))
                        (let
                            idx =
                                b 15
                         in
                         lets
                            [ ( idx, callW "rt_ss_in" [ cstr, lenOf (v path) ] ) ]
                            (iff (mkBool (cmpW RClts (v idx) (n 0)))
                                haltV
                                (mkStream (v idx) (n 1) (n 1))
                            )
                        )
                        falseV
                    )
                    (mkStream (v fd) (n 1) (n 0))
                )

        outArm =
            let
                ( cstrBinds, cstr ) =
                    cStrOf 20 (v path)

                fd =
                    b 24
            in
            lets
                (cstrBinds ++ [ ( fd, callW "openat" [ n (-100), cstr, n 577, n 438 ] ) ])
                (iff (mkBool (cmpW RClts (v fd) (n 0)))
                    falseV
                    (mkStream (v fd) (n 0) (n 0))
                )
    in
    lam "Rt.open" [ path, dir ]
        (iff dirIsIn
            inArm
            (iff dirIsOut
                outArm
                (mkNum (n 0))
            )
        )


{-| close (1 arg: stream).  String stream: free the registry slot (idempotent;
the slot index stays consumed); file stream: close only when the file pointer
is non-null (C's guard against closing the absent stdin).  Returns nil.
-}
closeDefun : Defun
closeDefun =
    let
        stream =
            p1

        isStr =
            b 3

        stringArm =
            let
                r =
                    b 4
            in
            lets
                [ ( r, callW "rt_ss_close" [ wOf (v stream) ] ) ]
                (iff (mkBool (cmpW RCeq (v r) (n (-2))))
                    haltV
                    mkNil
                )

        fileArm =
            let
                f =
                    b 5
            in
            lets
                [ ( f, wOf (v stream) ) ]
                (iff (mkBool (cmpW RCne (v f) (n 0)))
                    (lets
                        [ ( b 6, callW "close" [ v f ] ) ]
                        mkNil
                    )
                    mkNil
                )
    in
    lam "Rt.close" [ stream ]
        (lets
            [ ( isStr, isStringOf (v stream) ) ]
            (iff (mkBool (v isStr))
                stringArm
                fileArm
            )
        )


-- ============================ VM STATE + str (GROUP 2) ============================
-- The value / intern / str prims as Mid bodies over alloc-free Zig seats in
-- tools/qbe/rt.zig (rt_value_slot / rt_sym_intern / rt_float_text — the
-- BRIDGES-table entries).  All three are frame-free reads (page_allocator /
-- static BSS only in the seats) EXCEPT Rt.str, which RawAllocRaw's a GC string
-- and is therefore framed.  The Zig handlers they port are prims.primValue /
-- primIntern / primStr's float arm (vendor/osier-rt/src/rt/prims.zig).


{-| `Rt.intern s` — primIntern: intern the string's bytes (255-byte cap) into
the symbol table and return the symbol Value (tag 2, the canonical name
pointer).  `rt_sym_intern` owns the open-addressed interner (page_allocator,
immortal names, never GC-reclaimed).
-}
internDefun : Defun
internDefun =
    let
        str =
            p1

        dataPtr =
            b 3

        len =
            b 4

        canon =
            b 5
    in
    lam "Rt.intern" [ str ]
        (lets
            [ ( dataPtr, wOf (v str) )
            , ( len, lenOf (v str) )
            , ( canon, callW "rt_sym_intern" [ v dataPtr, v len ] )
            ]
            (Unsafe (RawMkValue { tag = RtLayout.tagSymbol, words = [ v canon ] }))
        )


{-| `Rt.value sym` — primValue: the open-addressed values-table lookup, blitting
the slot's Value out of the table (a stable page_allocator slot).  The result
is whatever the host registered (a stream fd-int Value, or the *argv* cons
list); the host-IO soundness hole for *argv* is unchanged by this port (the
refusal stays in Lower's nurseryHostPrims under QBE_MIDGC=1).

The seat NEVER returns null: found -> `&e.value`; absent -> `&value_fallback_slot`
(the valSymbol bare-symbol fallback, done INSIDE the seat — rt.zig rt_value_slot).
So the body blits the slot unconditionally; there is no second fallback path
here (a null would be a loud SEGV on the blit, not a silent mis-dispatch).
-}
valueDefun : Defun
valueDefun =
    let
        sym =
            p1

        namePtr =
            b 3

        slotPtr =
            b 4
    in
    lam "Rt.value" [ sym ]
        (lets
            [ ( namePtr, wOf (v sym) )
            , ( slotPtr, callW "rt_value_slot" [ v namePtr ] )
            ]
            (Unsafe (RawVecLoad { vec = v slotPtr, index = n 0 }))
        )


{-| `Rt.str x` — primStr's two REACHABLE arms (compiled Elm can only pass a
Float-typed value, which at run time is either a FLOAT or a NUMBER — the
`basicsToFloat n = n` identity in Prelude.elm:1395 lets an integer token reach
`str` tagged 0).  FLOAT: render the f64 through rt_float_text
(values.floatText: shortest-round-trip `{d}` + the mandatory ".0" on
integrals; NaN/±Infinity pass through) into a STATIC BSS buffer, then COPY the
bytes into a GC string — the copy is what closes the host-IO hole: the final
string is GC-allocated, never the Zig-nursery string primStr's `valString`
produced, so a kept NaN/±Infinity text survives the scavenge (the midgc-str
probe's pinned shape).  NUMBER: Rt.numText (the `{d}` integer render, no ".0").
The other primStr arms (string/symbol/boolean/composite) are unreachable from
String.fromFloat.  Allocates -> framed.  (The single static-BSS scratch's
re-entrancy invariant — valid only render-through-copy, one safepoint — is
named at rt.zig's rt_float_text seat.)
-}
strDefun : Defun
strDefun =
    let
        x =
            p1

        outPtr =
            b 3

        lenN =
            b 4

        outN =
            b 5

        bufW =
            b 6

        bufN =
            b 7

        floatArm =
            lets
                [ ( outPtr, callW "rt_float_text" [ wOf (v x) ] )
                , ( lenN, mkNum (Unsafe (RawWordLoad { ptr = v outPtr, index = n 0 })) )
                , ( outN, mkNum (v outPtr) )
                , ( bufW, Unsafe (RawAllocRaw (wOf (v lenN))) )
                , ( bufN, mkNum (v bufW) )
                , ( b 8, callR "Rt.floatCopy" [ v outN, v bufN, mkNum (isub (wOf (v lenN)) (n 1)) ] )
                ]
                (mkStr (v bufW) (wOf (v lenN)))
    in
    lam "Rt.str" [ x ]
        (iff (mkBool (tagIs (v x) 12))
            floatArm
            (iff (mkBool (tagIs (v x) 0))
                (callR "Rt.numText" [ v x ])
                haltV
            )
        )


{-| Rt.floatCopy outN bufN i — copy byte i of the static float-text buffer
(`outN` boxes the buffer pointer + 8 = data start) into the GC string at
`bufN`, counting DOWN from len-1 to 0 (arity 3: the lean ABI's direct bound).
`outN`/`bufN` box pointers as numbers (the collector never chases them); the
static BSS source is not moved by the GC, so it stays valid across the
caller's alloc.  Non-allocating -> frame-free.
-}
floatCopyDefun : Defun
floatCopyDefun =
    let
        outN =
            p1

        bufN =
            p2

        i =
            p3
    in
    lam "Rt.floatCopy" [ outN, bufN, i ]
        (iff (mkBool (cmpW RClts (wOf (v i)) (n 0)))
            mkNil
            (lets
                [ ( b 4
                  , Unsafe
                        (RawByteStore
                            { ptr = wOf (v bufN)
                            , index = wOf (v i)
                            , value = Unsafe (RawByteLoad { ptr = iadd (wOf (v outN)) (n 8), index = wOf (v i) })
                            }
                        )
                  )
                ]
                (callR "Rt.floatCopy" [ v outN, v bufN, mkNum (isub (wOf (v i)) (n 1)) ])
            )
        )


-- ============================ PROCESS LAYER (GROUP 3A) ============================
-- The simple libc-backed process prims (getpid, getcwd, cd, getenv, setenv)
-- as Mid bodies over RawCallRaw libc seats (getpid/getcwd/chdir/getenv/
-- setenv).  The Zig originals are vendor/osier-rt/src/rt/execplan.zig
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
-- The empty-result strings use `Lit (LString "")` (a STATIC empty string)
-- where the Zig used `valString(g, "")` — behaviourally identical (a String
-- Value, len 0), and the static literal is never GC-reclaimed, so it is no
-- soundness concern under the hatch gate.


{-| cStrLenGo ptrN i — the length of the NUL-terminated C string at `ptrN`,
counted from index i (entered at 0): walk RawByteLoad until the 0 byte.  The
pointer is boxed as a NUMBER Value (the collector never chases it) and must be
STABLE across the walk — a libc-owned pointer (getenv's result) or a GC buffer
with no intervening allocation (getcwd's own buffer).

SELF-TAIL LOOP (the SF2 fix): the recursion goes through `App` on THIS defun's
own key, which Lower compiles as the in-frame loop (`countdown`'s mechanism —
stage args, blit into the param slots, `jmp @body`), NOT the per-byte native
frame the `callR` shape compiles to on the default route (the RawCall
self-tail is midGc-gated).  The byte count is therefore O(1) native stack
(MEASURED: the `callR` shape died at a ~100 KB env value against the driver's
64 MiB stack raise; the loop shape has no per-element cost).  The defun
stays FRAME-FREE (alloc8 scratch, no pooled frame: the classifier treats the
self-App as an edge — Mid.Rt safepoint's App arm — so `Rt.allocating` keeps
it out) and NON-ALLOCATING: no safepoint anywhere in the loop, which is what
keeps the callers' raw-buffer windows sound.  Never allocate here.
-}
cStrLenGoDefun : Defun
cStrLenGoDefun =
    let
        ptrN =
            p1

        i =
            p2

        byte =
            b 4
    in
    lam "Rt.cStrLenGo" [ ptrN, i ]
        (lets
            [ ( byte, Unsafe (RawByteLoad { ptr = wOf (v ptrN), index = wOf (v i) }) ) ]
            (iff (mkBool (cmpW RCeq (v byte) (n 0)))
                (mkNum (wOf (v i)))
                (App { fn = GRef { key = "Rt.cStrLenGo", force = False }, args = [ v ptrN, mkNum (iadd (wOf (v i)) (n 1)) ] })
            )
        )


{-| cStrCopyGo srcN dstN i — copy byte i of the NUL-terminated C string at
`srcN` into the GC string buffer at `dstN`, stopping AT the NUL: the NUL
itself is NOT copied into [0..len) (the Value's len excludes it) but IS
written at dst[len], restoring Zig valString's terminator parity
(values.zig wrote dst[data.len] = 0; the caller allocates len+1).  `srcN` is
stable (libc-owned) across the copy; `dstN` is the freshly-allocated GC
buffer, used before any further allocation.  SELF-TAIL LOOP like cStrLenGo
(App on its own key — O(1) native stack); non-allocating, never allocate
here.
-}
cStrCopyGoDefun : Defun
cStrCopyGoDefun =
    let
        srcN =
            p1

        dstN =
            p2

        i =
            p3

        byte =
            b 4
    in
    lam "Rt.cStrCopyGo" [ srcN, dstN, i ]
        (lets
            [ ( byte, Unsafe (RawByteLoad { ptr = wOf (v srcN), index = wOf (v i) }) ) ]
            (iff (mkBool (cmpW RCeq (v byte) (n 0)))
                (lets
                    [ ( b 5, Unsafe (RawByteStore { ptr = wOf (v dstN), index = wOf (v i), value = n 0 })) ]
                    mkNil
                )
                (lets
                    [ ( b 6, Unsafe (RawByteStore { ptr = wOf (v dstN), index = wOf (v i), value = v byte })) ]
                    (App { fn = GRef { key = "Rt.cStrCopyGo", force = False }, args = [ v srcN, v dstN, mkNum (iadd (wOf (v i)) (n 1)) ] })
                )
            )
        )


{-| `Rt.getpid _` — primGetpid: getpid() as a number.  Arity 1: the nullary
surface prim stages a dummy slot (the Zig handler pops it if present); the
dummy is ignored here.
-}
getpidDefun : Defun
getpidDefun =
    let
        dummy =
            p1
    in
    lam "Rt.getpid" [ dummy ]
        (mkNum (callW "getpid" []))


{-| `Rt.cd path` — primCd: chdir to the NUL-terminated copy of `path`, return
the boolean success.  The copy is a GC buffer filled via cStrFill (which
re-reads `path` fresh, so a prior move is handled); chdir runs before any
further allocation, so the buffer is valid at the call.
-}
cdDefun : Defun
cdDefun =
    let
        path =
            p1

        ( cstrBinds, cstr ) =
            cStrOf 10 (v path)

        rc =
            b 14
    in
    lam "Rt.cd" [ path ]
        (lets
            (cstrBinds ++ [ ( rc, callW "chdir" [ cstr ] ) ])
            (mkBool (cmpW RCeq (v rc) (n 0)))
        )


{-| `Rt.getcwd _` — primGetcwd: getcwd into a PATH_MAX (4096) GC buffer and
return it AS the string with its NUL-measured length.  Reusing the same buffer
avoids a second allocation (which would MOVE the buffer under the moving Zig
GC — cStrLenGo's contract).  Failure (getcwd NULL) -> "".  TRADE, named: the
result string PINS the full 4096-byte block for its lifetime (Zig allocated
len+1) — the sound alternative (the getenv shape: strlen, alloc len+1, copy)
costs one more allocation; the cwd is short-lived and 4 KiB is cheap, so the
single-alloc shape is kept deliberately.
-}
getcwdDefun : Defun
getcwdDefun =
    let
        dummy =
            p1

        bufW =
            b 3

        r =
            b 4

        len =
            b 5
    in
    lam "Rt.getcwd" [ dummy ]
        (lets
            [ ( bufW, Unsafe (RawAllocRaw (n 4096)) )
            , ( r, callW "getcwd" [ v bufW, n 4096 ] )
            ]
            (iff (mkBool (cmpW RCeq (v r) (n 0)))
                (Lit (LString ""))
                (lets
                    [ ( len, callR "Rt.cStrLenGo" [ mkNum (v bufW), mkNum (n 0) ] ) ]
                    (mkStr (v bufW) (wOf (v len)))
                )
            )
        )


{-| `Rt.getenv name` — primGetenv: getenv of the NUL-terminated copy of
`name`, copied into a GC string (the env pointer is libc-owned and stable
across the alloc); absent -> "".
-}
getenvDefun : Defun
getenvDefun =
    let
        name =
            p1

        ( cstrBinds, cstr ) =
            cStrOf 10 (v name)

        r =
            b 14

        len =
            b 15

        dstW =
            b 16

        dstN =
            b 17
    in
    lam "Rt.getenv" [ name ]
        (lets
            (cstrBinds ++ [ ( r, callW "getenv" [ cstr ] ) ])
            (iff (mkBool (cmpW RCeq (v r) (n 0)))
                (Lit (LString ""))
                (lets
                    [ ( len, callR "Rt.cStrLenGo" [ mkNum (v r), mkNum (n 0) ] )
                    , ( dstW, Unsafe (RawAllocRaw (iadd (wOf (v len)) (n 1))) )
                    , ( dstN, mkNum (v dstW) )
                    , ( b 18, callR "Rt.cStrCopyGo" [ mkNum (v r), v dstN, mkNum (n 0) ] )
                    ]
                    (mkStr (v dstW) (wOf (v len)))
                )
            )
        )


{-| `Rt.setenv name value` — primSetenv: setenv(name, value, 1) with BOTH
copies packed into ONE GC buffer (name at 0, value at nameLen+1), so the two
NUL-terminated pointers are live at the single call without a second
allocation (which would move the first buffer).  Always returns true.
-}
setenvDefun : Defun
setenvDefun =
    let
        name =
            p1

        value =
            p2

        nameLen =
            b 3

        valueLen =
            b 4

        bufW =
            b 5

        bufN =
            b 6

        valPtrW =
            b 7

        valPtrN =
            b 8
    in
    lam "Rt.setenv" [ name, value ]
        (lets
            [ ( nameLen, lenOf (v name) )
            , ( valueLen, lenOf (v value) )
            , ( bufW, Unsafe (RawAllocRaw (iadd (iadd (v nameLen) (v valueLen)) (n 2))) )
            , ( bufN, mkNum (v bufW) )
            , ( b 9, callR "Rt.cStrFill" [ v bufN, v name, mkNum (n 0) ] )
            , ( valPtrW, iadd (v bufW) (iadd (v nameLen) (n 1)) )
            , ( valPtrN, mkNum (v valPtrW) )
            , ( b 10, callR "Rt.cStrFill" [ v valPtrN, v value, mkNum (n 0) ] )
            , ( b 11, callW "setenv" [ v bufW, v valPtrW, n 1 ] )
            ]
            trueV
        )


-- ===================== glob (zigretire stage 3 GROUP 3B) =====================
-- primGlob (execplan.zig:1309) as a Mid body: split the pattern at the LAST
-- '/', opendir/readdir/fnmatch the base over the directory's names, cap at
-- 1024 matches, sort strcmp-order (unsigned bytes), and build the tagged
-- list inside-out.  No new Zig seat — opendir/readdir/closedir/fnmatch AND
-- malloc/free are plain libc symbols under RawCallRaw (no whitelist).
--
-- THE ALLOCATOR SPLIT (the whole design): the match table and every matched
-- name live on the C HEAP (malloc/free) — NON-MOVING, so raw pointers into
-- them stay valid across EVERY safepoint, exactly the page_allocator shape
-- of the Zig original (dupeZ / ca.alloc).  The GC heap holds only the
-- pattern's NUL-copy (cStrOf) and the final strings/list.  The moving-GC
-- window is therefore bounded and mechanical: from cStrOf's alloc to the
-- end of the scan loop there is NO GC safepoint (scan/sort/helpers are
-- frame-free; malloc/readdir/fnmatch are raw calls), so the base/dir raw
-- temps into the pattern buffer cannot go stale; the build loop's only raw
-- temps are C-heap pointers.
--
-- PARITY NOTES (deliberate divergences, the group-3A getenv/setenv
-- precedent — "more correct", documented, unreachable from sane patterns):
-- the Zig pattern copy truncated at PATH_MAX-1 and the dir copy at
-- PATH_MAX; the Mid body passes the FULL pattern (cStrOf is exact-length),
-- and a too-long dir simply fails opendir (ENAMETOOLONG -> NULL -> nil,
-- the same observable result as the truncation path).  The 1024-match cap
-- is kept EXACTLY (the loop bound).
--
-- THE DOTFILE GUARD is Zig's `!fm(base, ".") && !fm(base, "..")` with
-- fm(PATTERN, string) — the BASE IS THE PATTERN, so any wildcard base that
-- happens to match "." / ".." ("?", ".*", "[.]", "\.") ADMITS the dotfile
-- pair.  The Mid body reproduces this with REAL fnmatch calls against the
-- two NUL literals in the cbuf (fix-1: the first cut rewrote it as byte
-- equality on base, which inverted the argument roles and silently DROPPED
-- ./.. for every wildcard base — a measured wrong answer on the most
-- common patterns).  The NAME-side tests (name is "." / "..") stay byte
-- equality, as in Zig (std.mem.eql).
--
-- OOM DIVERGENCE, loud not silent: Zig threw "glob: out of memory" when
-- dupeZ/the match alloc failed (freeing the dupes first); Mid has no error
-- mechanism, so both malloc failure points (the cbuf, each dupe) branch to
-- the rt_halt seat instead — a loud abort, never a NULL deref.


{-| globLastSlash ptrN iN — the index of the LAST '/' in the pattern
(NUL-copied at ptrN), searching BACKWARD from iN (entered at len-1): the
first hit walking back is the last slash, or -1 at the top (the strrchr of
the Zig split).  SELF-TAIL LOOP (the SF2 pattern: App on this defun's own
key = the in-frame jmp @body loop), so the walk is O(1) native stack;
frame-free and non-allocating.  `ptrN` is the NUL-copied pattern buffer —
valid across the walk because the caller's window has no safepoint.
(Backward, not forward, so TWO params fit the RawCall 3-arg lean-ABI cap.)
-}
globLastSlashDefun : Defun
globLastSlashDefun =
    let
        ptrN =
            p1

        iN =
            p2

        byte =
            b 4
    in
    lam "Rt.globLastSlash" [ ptrN, iN ]
        (iff (mkBool (cmpW RClts (wOf (v iN)) (n 0)))
            (mkNum (n (-1)))
            (lets
                [ ( byte, Unsafe (RawByteLoad { ptr = wOf (v ptrN), index = wOf (v iN) }) ) ]
                (iff (mkBool (cmpW RCeq (v byte) (n 47)))
                    (mkNum (wOf (v iN)))
                    (App { fn = GRef { key = "Rt.globLastSlash", force = False }, args = [ v ptrN, mkNum (isub (wOf (v iN)) (n 1)) ] })
                )
            )
        )


{-| globIsDot ptrN / globIsDotDot ptrN — byte-exact "." / ".." tests on a
NUL-terminated C string (the dotfile guard's operands).  Non-recursive,
frame-free, non-allocating; reading one byte past a 1-byte name is safe
(readdir's d_name is a 256-byte array, NUL-terminated by contract).
-}
globIsDotDefun : Defun
globIsDotDefun =
    let
        ptrN =
            p1

        c0 =
            b 4

        c1 =
            b 5
    in
    lam "Rt.globIsDot" [ ptrN ]
        (lets
            [ ( c0, Unsafe (RawByteLoad { ptr = wOf (v ptrN), index = n 0 }) )
            , ( c1, Unsafe (RawByteLoad { ptr = wOf (v ptrN), index = n 1 }) )
            ]
            (and2 (mkBool (cmpW RCeq (v c0) (n 46)))
                (mkBool (cmpW RCeq (v c1) (n 0)))
            )
        )


globIsDotDotDefun : Defun
globIsDotDotDefun =
    let
        ptrN =
            p1

        c0 =
            b 4

        c1 =
            b 5

        c2 =
            b 6
    in
    lam "Rt.globIsDotDot" [ ptrN ]
        (lets
            [ ( c0, Unsafe (RawByteLoad { ptr = wOf (v ptrN), index = n 0 }) )
            , ( c1, Unsafe (RawByteLoad { ptr = wOf (v ptrN), index = n 1 }) )
            , ( c2, Unsafe (RawByteLoad { ptr = wOf (v ptrN), index = n 2 }) )
            ]
            (and2 (mkBool (cmpW RCeq (v c0) (n 46)))
                (and2 (mkBool (cmpW RCeq (v c1) (n 46)))
                    (mkBool (cmpW RCeq (v c2) (n 0)))
                )
            )
        )


{-| globScanGo stateN — the readdir/fnmatch loop, all live state in a
5-word C-heap STATE BLOCK (slot 0 the DIR*, 1 the base pointer, 2 the
table pointer, 3 the skip-dotfiles flag, 4 the match count) so the defun
takes ONE param (the RawCall lean-ABI cap is 3).  Walks entries while
n < 1024 (the Zig cap), fnmatch(base, d_name, 0), skips the dotfile pair
unless the base IS "." / ".." byte-exactly (see the parity note above),
and dupes each match onto the C HEAP (malloc len+1, cStrCopyGo — which
re-terminates at dst[len]) storing the pointer at tbl[n] (raw WORD
slots).  SELF-TAIL LOOP; frame-free and non-allocating end to end —
malloc/readdir/fnmatch are raw calls, the helpers are frame-free — which
is what keeps the caller's pattern-buffer raw temps valid for the whole
loop (state[1] names bytes inside the GC pattern buffer).  Never allocate
here.
-}
globScanGoDefun : Defun
globScanGoDefun =
    let
        stateN =
            p1

        dW =
            b 4

        baseW =
            b 5

        tblW =
            b 6

        guardW =
            b 7

        nW =
            b 8

        entW =
            b 9

        nameW =
            b 10

        fmW =
            b 11

        nameDot =
            b 12

        nameDD =
            b 13

        lenN =
            b 14

        pW =
            b 15
    in
    lam "Rt.globScanGo" [ stateN ]
        (lets
            [ ( dW, Unsafe (RawWordLoad { ptr = wOf (v stateN), index = n 0 }) )
            , ( baseW, Unsafe (RawWordLoad { ptr = wOf (v stateN), index = n 1 }) )
            , ( tblW, Unsafe (RawWordLoad { ptr = wOf (v stateN), index = n 2 }) )
            , ( guardW, Unsafe (RawWordLoad { ptr = wOf (v stateN), index = n 3 }) )
            , ( nW, Unsafe (RawWordLoad { ptr = wOf (v stateN), index = n 4 }) )
            ]
            (iff (mkBool (cmpW RCges (v nW) (n 1024)))
                (mkNum (v nW))
                (lets
                    [ ( entW, callW "readdir" [ v dW ] ) ]
                    (iff (mkBool (cmpW RCeq (v entW) (n 0)))
                        (mkNum (v nW))
                        (lets
                            [ ( nameW, iadd (v entW) (n RtLayout.direntNameOffset) )
                            , ( fmW, callW "fnmatch" [ v baseW, v nameW, n 0 ] )
                            ]
                            (iff (mkBool (cmpW RCne (v fmW) (n 0)))
                                (App { fn = GRef { key = "Rt.globScanGo", force = False }, args = [ v stateN ] })
                                (lets
                                    [ ( nameDot, callR "Rt.globIsDot" [ mkNum (v nameW) ] )
                                    , ( nameDD, callR "Rt.globIsDotDot" [ mkNum (v nameW) ] )
                                    ]
                                    (iff (and2 (or2 (v nameDot) (v nameDD)) (mkBool (cmpW RCne (v guardW) (n 0))))
                                        (App { fn = GRef { key = "Rt.globScanGo", force = False }, args = [ v stateN ] })
                                        (lets
                                            [ ( lenN, callR "Rt.cStrLenGo" [ mkNum (v nameW), mkNum (n 0) ] )
                                            , ( pW, callW "malloc" [ iadd (wOf (v lenN)) (n 1) ] )
                                            , -- dupe OOM: LOUD halt (rt_halt is
                                              -- a raw call — scanGo stays
                                              -- non-allocating).
                                              ( b 19, iff (mkBool (cmpW RCeq (v pW) (n 0))) haltV (mkNum (n 0)) )
                                            , ( b 16, callR "Rt.cStrCopyGo" [ mkNum (v nameW), mkNum (v pW), mkNum (n 0) ] )
                                            , ( b 17, Unsafe (RawWordStore { ptr = v tblW, index = v nW, value = v pW }) )
                                            , ( b 18, Unsafe (RawWordStore { ptr = wOf (v stateN), index = n 4, value = iadd (v nW) (n 1) }) )
                                            ]
                                            (App { fn = GRef { key = "Rt.globScanGo", force = False }, args = [ v stateN ] })
                                        )
                                    )
                                )
                            )
                        )
                    )
                )
            )
        )


{-| globStrLess aN bN iN — strcmp order (unsigned bytes, RawByteLoad is
zero-extended) on two NUL-terminated C strings: a prefix sorts before its
extensions, equals are not less.  Frame-free SELF-TAIL LOOP; the pointers
are C-heap (stable), but no safepoint exists here regardless.
-}
globStrLessDefun : Defun
globStrLessDefun =
    let
        aN =
            p1

        bN =
            p2

        iN =
            p3

        ca =
            b 4

        cb =
            b 5
    in
    lam "Rt.globStrLess" [ aN, bN, iN ]
        (lets
            [ ( ca, Unsafe (RawByteLoad { ptr = wOf (v aN), index = wOf (v iN) }) )
            , ( cb, Unsafe (RawByteLoad { ptr = wOf (v bN), index = wOf (v iN) }) )
            ]
            (iff (mkBool (cmpW RClts (v ca) (v cb)))
                trueV
                (iff (mkBool (cmpW RCgts (v ca) (v cb)))
                    falseV
                    (iff (mkBool (cmpW RCeq (v ca) (n 0)))
                        falseV
                        (App { fn = GRef { key = "Rt.globStrLess", force = False }, args = [ v aN, v bN, mkNum (iadd (wOf (v iN)) (n 1)) ] })
                    )
                )
            )
        )


{-| globSortShift tblN jN keyN — the insertion-sort inner shift: while
tbl[j] > key, slide it right; returns the index key belongs at (j+1).
Frame-free SELF-TAIL LOOP over C-heap slots only.
-}
globSortShiftDefun : Defun
globSortShiftDefun =
    let
        tblN =
            p1

        jN =
            p2

        keyN =
            p3

        curW =
            b 4

        lessB =
            b 5

        stW =
            b 6
    in
    lam "Rt.globSortShift" [ tblN, jN, keyN ]
        (iff (mkBool (cmpW RClts (wOf (v jN)) (n 0)))
            (mkNum (wOf (v jN)))
            (lets
                [ ( curW, Unsafe (RawWordLoad { ptr = wOf (v tblN), index = wOf (v jN) }) )
                , ( lessB, callR "Rt.globStrLess" [ v keyN, mkNum (v curW), mkNum (n 0) ] )
                ]
                (iff (v lessB)
                    (lets
                        [ ( stW, Unsafe (RawWordStore { ptr = wOf (v tblN), index = iadd (wOf (v jN)) (n 1), value = v curW }) ) ]
                        (App { fn = GRef { key = "Rt.globSortShift", force = False }, args = [ v tblN, mkNum (isub (wOf (v jN)) (n 1)), v keyN ] })
                    )
                    (mkNum (wOf (v jN)))
                )
            )
        )


{-| globSortGo tblN iN nN — insertion sort of tbl[0..nN) (Zig's
std.sort.block; directory names are unique so any correct sort agrees).
The key rides a raw word across the globSortShift call — sound because
shift is non-allocating (and the table is C-heap regardless).  Frame-free
SELF-TAIL LOOP.
-}
globSortGoDefun : Defun
globSortGoDefun =
    let
        tblN =
            p1

        iN =
            p2

        nN =
            p3

        keyW =
            b 4

        jN =
            b 5

        stW =
            b 6
    in
    lam "Rt.globSortGo" [ tblN, iN, nN ]
        (iff (mkBool (cmpW RCges (wOf (v iN)) (wOf (v nN))))
            (mkNum (wOf (v nN)))
            (lets
                [ ( keyW, Unsafe (RawWordLoad { ptr = wOf (v tblN), index = wOf (v iN) }) )
                , ( jN, callR "Rt.globSortShift" [ v tblN, mkNum (isub (wOf (v iN)) (n 1)), mkNum (v keyW) ] )
                , ( stW, Unsafe (RawWordStore { ptr = wOf (v tblN), index = iadd (wOf (v jN)) (n 1), value = v keyW }) )
                ]
                (App { fn = GRef { key = "Rt.globSortGo", force = False }, args = [ v tblN, mkNum (iadd (wOf (v iN)) (n 1)), v nN ] })
            )
        )


{-| globBuildGo tblN iN acc — the result list, inside-out from the sorted
table (Zig's root dance as one loop): for each i (descending), copy the
C-heap match into a fresh GC string (the getenv shape: len, alloc len+1,
cStrCopyGo, mkStr — the fresh block is the string's own data, no interior
pointer), free the C copy, cons onto acc.  ALLOCATING (Rt.cons, RawAllocRaw)
— this is the loop where safepoints live; `acc` rides a PARAM slot of a
framed defun (rooted), and every raw temp EXCEPT bufW is a C-heap pointer
(stable across collections).  bufW (the RawAllocRaw result) is a NURSERY
raw temp — valid only to the next safepoint — and the body is sound ONLY
because mkStr consumes it into a ROOTED frame slot (RawMkValue stores the
data word, no allocation) BEFORE the first Rt.cons allocation, and App
args lower head-to-tail innermost-first.  THE EVALUATION ORDER IS
LOAD-BEARING: a purely local reorder of the consV argument tree (moving a
consV to the LEFT of the mkStr chain) would hold bufW across a scavenge
and silently reintroduce a stale data pointer — no instrument catches a
reorder, so do not make one.  SELF-TAIL LOOP (App on its own key): the
pooled frame stays entered across the jmp @body, so the re-blitted param
slots stay rooted.
-}
globBuildGoDefun : Defun
globBuildGoDefun =
    let
        tblN =
            p1

        iN =
            p2

        acc =
            p3

        pW =
            b 4

        lenN =
            b 5

        bufW =
            b 6
    in
    lam "Rt.globBuildGo" [ tblN, iN, acc ]
        (iff (mkBool (cmpW RClts (wOf (v iN)) (n 0)))
            (v acc)
            (lets
                [ ( pW, Unsafe (RawWordLoad { ptr = wOf (v tblN), index = wOf (v iN) }) )
                , ( lenN, callR "Rt.cStrLenGo" [ mkNum (v pW), mkNum (n 0) ] )
                , ( bufW, Unsafe (RawAllocRaw (iadd (wOf (v lenN)) (n 1))) )
                , ( b 7, callR "Rt.cStrCopyGo" [ mkNum (v pW), mkNum (v bufW), mkNum (n 0) ] )
                , ( b 8, callW "free" [ v pW ] )
                ]
                -- The TAGGED shape (makeTaggedCons/makeTaggedString/
                -- makeTaggedNil, execplan.zig:168-210): [cons H T] is the
                -- 3-element list (cons . (H . (T . nil))), [string S] is
                -- (string . (S . nil)), the empty tagged list is (cons).
                -- decodeStringList walks EXACTLY this — a plain Elm list
                -- would decode as empty.
                (App { fn = GRef { key = "Rt.globBuildGo", force = False }, args = [ v tblN, mkNum (isub (wOf (v iN)) (n 1)), consV (callR "Rt.intern" [ Lit (LString "cons") ]) (consV (consV (callR "Rt.intern" [ Lit (LString "string") ]) (consV (mkStr (v bufW) (wOf (v lenN))) mkNil)) (consV (v acc) mkNil)) ] })
            )
        )


{-| `Rt.glob pattern` — primGlob: the sorted tagged list of matches.
Layout of the ONE C scratch block (8240 bytes): [0..2) the "." literal for
the no-slash dir default, [8..8200) the 1024-slot pointer table (word
slots), [8200..8240) the 5-word scan STATE BLOCK (DIR*, base, table,
skip-dotfiles, count — one param for the lean-ABI cap).  The pattern's
NUL-copy is a GC buffer (cStrOf); the LAST-slash split NULs over the '/'
in place (base starts past it, so the fill is dead bytes to fnmatch) —
the no-slash case leaves the pattern intact and dirs to the block's "."
literal.  opendir failure -> nil (Zig's opendir("")-fails quirk for a
leading '/' included: dlen==0 dirs to the NUL'd pattern head, an empty
string, which opendir rejects).
-}
globDefun : Defun
globDefun =
    let
        pattern =
            p1

        ( patBinds, patW ) =
            cStrOf 40 (v pattern)

        siN =
            b 44

        cbufW =
            b 45

        tblW =
            b 46

        hasS =
            b 47

        dirN =
            b 48

        baseN =
            b 49

        dW =
            b 52

        baseDot =
            b 53

        baseDD =
            b 54

        stateW =
            b 55

        nN =
            b 56

        res =
            b 60
    in
    lam "Rt.glob" [ pattern ]
        (lets
            (patBinds
                ++ [ ( siN, callR "Rt.globLastSlash" [ mkNum patW, mkNum (isub (lenOf (v pattern)) (n 1)) ] )
                   , ( cbufW, callW "malloc" [ n 8240 ] )
                   , -- OOM is LOUD (Zig threw "glob: out of memory"; Mid
                     -- has no error mechanism — halt, never a NULL deref).
                     ( b 115, iff (mkBool (cmpW RCeq (v cbufW) (n 0))) haltV (mkNum (n 0)) )
                   , ( b 50, Unsafe (RawByteStore { ptr = v cbufW, index = n 0, value = n 46 }) )
                   , ( b 51, Unsafe (RawByteStore { ptr = v cbufW, index = n 1, value = n 0 }) )
                   , -- the ".." literal for the dotfile guard's fnmatch
                     -- (review B1): [2..5) = '.', '.', NUL; [5..8) pad.
                     ( b 112, Unsafe (RawByteStore { ptr = v cbufW, index = n 2, value = n 46 }) )
                   , ( b 113, Unsafe (RawByteStore { ptr = v cbufW, index = n 3, value = n 46 }) )
                   , ( b 114, Unsafe (RawByteStore { ptr = v cbufW, index = n 4, value = n 0 }) )
                   , ( tblW, iadd (v cbufW) (n 8) )
                   , ( stateW, iadd (v cbufW) (n 8200) )
                   , ( hasS, mkBool (cmpW RCges (wOf (v siN)) (n 0)) )
                   , ( dirN, iff (v hasS) (mkNum patW) (mkNum (v cbufW)) )
                   , ( baseN, iff (v hasS) (mkNum (iadd patW (iadd (wOf (v siN)) (n 1)))) (mkNum patW) )
                   , -- NUL over the LAST '/', in the slash arm only (si == -1
                     -- would write one byte BEFORE the buffer): the dir
                     -- prefix becomes a C string, and base (si+1..] never
                     -- reads it back.
                     ( b 110, iff (v hasS) (lets [ ( b 111, Unsafe (RawByteStore { ptr = patW, index = wOf (v siN), value = n 0 }) ) ] (mkNum (n 0))) (mkNum (n 0)) )
                   , ( dW, callW "opendir" [ wOf (v dirN) ] )
                   ]
            )
            (iff (mkBool (cmpW RCeq (v dW) (n 0)))
                (lets [ ( b 57, callW "free" [ v cbufW ] ) ] mkNil)
                (lets
                    -- B1 (review): Zig's guard is !fm(base, ".") &&
                    -- !fm(base, "..") with fm(PATTERN, string) — the BASE is
                    -- the pattern, so a WILDCARD base that matches "." / ".."
                    -- (e.g. "?", ".*", "[.]") ADMITS the dotfiles.  Real
                    -- fnmatch calls against the two cbuf literals, byte
                    -- equality only covered the literal bases.
                    [ ( baseDot, mkBool (cmpW RCeq (callW "fnmatch" [ wOf (v baseN), v cbufW, n 0 ]) (n 0)) )
                    , ( baseDD, mkBool (cmpW RCeq (callW "fnmatch" [ wOf (v baseN), iadd (v cbufW) (n 2), n 0 ]) (n 0)) )
                    , -- state[0..4] = DIR*, base, table, skip-dotfiles
                      -- (1 iff the base is NOT "." / ".."), 0 matches.
                      ( b 62, Unsafe (RawWordStore { ptr = v stateW, index = n 0, value = v dW }) )
                    , ( b 63, Unsafe (RawWordStore { ptr = v stateW, index = n 1, value = wOf (v baseN) }) )
                    , ( b 64, Unsafe (RawWordStore { ptr = v stateW, index = n 2, value = v tblW }) )
                    , ( b 65, Unsafe (RawWordStore { ptr = v stateW, index = n 3, value = wOf (iff (or2 (v baseDot) (v baseDD)) (mkNum (n 0)) (mkNum (n 1))) }) )
                    , ( b 66, Unsafe (RawWordStore { ptr = v stateW, index = n 4, value = n 0 }) )
                    , ( nN, callR "Rt.globScanGo" [ mkNum (v stateW) ] )
                    , ( b 58, callW "closedir" [ v dW ] )
                    , ( b 59, callR "Rt.globSortGo" [ mkNum (v tblW), mkNum (n 1), v nN ] )
                    , ( res, callR "Rt.globBuildGo" [ mkNum (v tblW), mkNum (isub (wOf (v nN)) (n 1)), consV (callR "Rt.intern" [ Lit (LString "cons") ]) mkNil ] )
                    , ( b 61, callW "free" [ v cbufW ] )
                    ]
                    (v res)
                )
            )
        )


{-| exec-plan DECODE (zigretire stage 3 GROUP 3B-2a) — planDecode as Mid.

execplan.zig's planDecode walks the TAGGED plan Value (the Shen demarshal
shape the Plan.* builders produce: EMPTY = [cons] = cons(sym"cons", nil),
NODE = [cons H T] = cons(sym"cons", cons(H, cons(T, nil))) with T the tagged
tail — a plain Elm list decodes as EMPTY-or-MALFORMED, never as a plan) and
builds a C-heap RProg blob per Mid.RtLayout's ep* constants.  The blob is
handed to the rt_exec_run seat (tools/qbe/rt.zig), which rebuilds the Zig
RProg tree, runs/slurps/builds the tagged result — the parts that stay Zig
until GROUP 3B-2b/3B-2c.

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
execPlanDefun : Defun
execPlanDefun =
    let
        plan =
            p1

        cbufW =
            b 40

        stW =
            b 41

        progN =
            b 42

        res =
            b 45

        chainsW =
            b 46

        -- One word per tag/op name, NUL padded to 8 bytes (the high bytes
        -- stay zero, so every value fits a JS-safe Int).  The FIRST byte of
        -- the name is the LOW byte of the word (little-endian stores).  The
        -- BYTE offsets are Mid-private (the seat never reads the cbuf).
        lit : List Int -> Int
        lit bytes =
            List.foldl (\byte acc -> acc * 256 + byte) 0 (List.reverse bytes)

        litStores =
            [ ( "cons", lit [ 99, 111, 110, 115 ] )
            , ( "string", lit [ 115, 116, 114, 105, 110, 103 ] )
            , ( "number", lit [ 110, 117, 109, 98, 101, 114 ] )
            , ( "symbol", lit [ 115, 121, 109, 98, 111, 108 ] )
            , ( "seq", lit [ 115, 101, 113 ] )
            , ( "and", lit [ 97, 110, 100 ] )
            , ( "or", lit [ 111, 114 ] )
            , ( "in", lit [ 105, 110 ] )
            , ( "out", lit [ 111, 117, 116 ] )
            , ( "append", lit [ 97, 112, 112, 101, 110, 100 ] )
            , ( "dup", lit [ 100, 117, 112 ] )
            , ( "hdoc", lit [ 104, 100, 111, 99 ] )
            , ( "hstr", lit [ 104, 115, 116, 114 ] )
            ]

        litBinds =
            litStores
                |> List.indexedMap
                    (\i ( _, word ) ->
                        ( b (50 + i)
                        , Unsafe
                            (RawWordStore
                                { ptr = v cbufW
                                , index = n i
                                , value = n word
                                }
                            )
                        )
                    )

        stBinds =
            [ ( b 63, Unsafe (RawWordStore { ptr = v stW, index = n 0, value = v cbufW }) )
            , ( b 64, Unsafe (RawWordStore { ptr = v stW, index = n 1, value = n 0 }) )
            , ( b 65, Unsafe (RawWordStore { ptr = v stW, index = n 2, value = n 0 }) )
            ]
    in
    lam "Rt.exec-plan" [ plan ]
        (lets
            ([ ( cbufW, callW "malloc" [ n 104 ] )
               , -- OOM is LOUD (glob's precedent: halt, never a NULL write).
                 ( b 43, iff (mkBool (cmpW RCeq (v cbufW) (n 0))) haltV (mkNum (n 0)) )
               , ( stW, callW "malloc" [ n 24 ] )
               , ( b 44, iff (mkBool (cmpW RCeq (v stW) (n 0))) haltV (mkNum (n 0)) )
               ]
                ++ litBinds
                ++ stBinds
                ++ [ ( progN, callR "Rt.epProg" [ v plan, mkNum (v stW) ] )
                   ]
            )
            (iff (mkBool (cmpW RClts (wOf (v progN)) (n 0)))
                -- malformed: every level already freed its decoded prefix on
                -- the way out; free the scratch blocks, then the LOUD halt
                -- (the module header's error-model gap note).
                (lets
                    [ ( b 70, callW "free" [ v stW ] )
                    , ( b 71, callW "free" [ v cbufW ] )
                    ]
                    haltV
                )
                (lets
                    [ ( res
                      , Unsafe
                            (RawVecLoad
                                { vec = callW "rt_exec_run" [ wOf (v progN) ]
                                , index = n 0
                                }
                            )
                      )
                    , ( chainsW
                      , Unsafe
                            (RawWordLoad
                                { ptr = wOf (v progN)
                                , index = n RtLayout.epProgChainsIdx
                                }
                            )
                      )
                    , ( b 67
                      , callR "Rt.epFreeChains"
                            [ v progN
                            , mkNum (v chainsW)
                            , mkNum (n 0)
                            ]
                      )
                    , ( b 68, callW "free" [ v stW ] )
                    , ( b 69, callW "free" [ v cbufW ] )
                    ]
                    (v res)
                )
            )
        )


{-| epSymIs sym litN i — the symbol's name vs the NUL-terminated literal at
litN (a cbuf offset), byte for byte from i: full std.mem.eql parity
(length-sensitive — a longer name whose prefix matches is NOT equal).
-}
epSymIsDefun : Defun
epSymIsDefun =
    let
        sym =
            p1

        litN =
            p2

        i =
            p3

        la =
            b 4

        lb =
            b 5
    in
    lam "Rt.epSymIs" [ sym, litN, i ]
        (lets
            [ ( la, byteOf (v sym) (wOf (v i)) )
            , ( lb, Unsafe (RawByteLoad { ptr = wOf (v litN), index = wOf (v i) }) )
            ]
            (iff (mkBool (cmpW RCeq (v lb) (n 0)))
                (mkBool (cmpW RCeq (v la) (n 0)))
                (iff (mkBool (cmpW RCeq (v la) (v lb)))
                    (App
                        { fn = GRef { key = "Rt.epSymIs", force = False }
                        , args = [ v sym, v litN, mkNum (iadd (wOf (v i)) (n 1)) ]
                        }
                    )
                    falseV
                )
            )
        )


{-| epCount v stN accN — the tagged list's length (Zig tdlLen/tdlCollect's
count), or -1 malformed.  st = [cbuf, depth, limit]: the walk BAILS at
acc > limit (returning acc, i.e. a count strictly greater than the caller's
bound) so absurd inputs cannot walk unbounded — the verdict is Zig-parity
either way, because a bail means "more elements than the caller accepts".
The ==2/==3 callers set limit 8; the collect sites set 64/256/64.
-}
epCountDefun : Defun
epCountDefun =
    let
        vv =
            p1

        stN =
            p2

        accN =
            p3

        cbufW =
            b 4

        limW =
            b 5

        stV =
            b 10

        t1 =
            b 7
    in
    lam "Rt.epCount" [ vv, stN, accN ]
        (lets
            [ ( cbufW, Unsafe (RawWordLoad { ptr = wOf (v stN), index = n 0 }) )
            , ( limW, Unsafe (RawWordLoad { ptr = wOf (v stN), index = n 2 }) )
            ]
            (lets
                [ ( stV, tagCountState (v vv) (v cbufW) ) ]
                (iff (mkBool (cmpW RCeq (wOf (v stV)) (n 2)))
                (mkNum (n (-1)))
                (iff (mkBool (cmpW RCeq (wOf (v stV)) (n 0)))
                    (v accN)
                    (lets
                        [ ( t1, cdrV (cdrV (v vv)) )
                        ]
                        (iff (mkBool (cmpW RCgts (wOf (v accN)) (v limW)))
                            (v accN)
                            (iff (mkBool (cmpW RCeq (tagIs (v t1) RtLayout.tagCons) (n 0)))
                                (mkNum (n (-1)))
                                (App
                                    { fn = GRef { key = "Rt.epCount", force = False }
                                    , args =
                                        [ carV (v t1)
                                        , v stN
                                        , mkNum (iadd (wOf (v accN)) (n 1))
                                        ]
                                    }
                                )
                            )
                        )
                    )
                )
            )
            )
        )


{-| The tdlIsEmpty state as a WORD: 0 empty, 1 node, 2 malformed.  Shared by
epCount (and inlined nowhere else — the fill loops spell their own checks).
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


{-| epElem v iN tgtN — the tgt'th element of the tagged list, or mkNil (a
sentinel every consumer's tag check rejects).  STRUCTURAL walk only: no
head-symbol re-check, sound because every caller ran epCount over the same
immutable spine first (Zig's tdlElem re-checks, but the verdict cannot
differ — the spine cannot change between the two walks).
-}
epElemDefun : Defun
epElemDefun =
    let
        vv =
            p1

        iN =
            p2

        tgtN =
            p3

        t1 =
            b 4
    in
    lam "Rt.epElem" [ vv, iN, tgtN ]
        (iff (mkBool (cmpW RCeq (tagIs (v vv) RtLayout.tagCons) (n 0)))
            mkNil
            (iff (mkBool (cmpW RCne (tagIs (cdrV (v vv)) RtLayout.tagNil) (n 0)))
                mkNil
                (iff (mkBool (cmpW RCeq (tagIs (cdrV (v vv)) RtLayout.tagCons) (n 0)))
                    mkNil
                    (iff (mkBool (cmpW RCeq (wOf (v iN)) (wOf (v tgtN))))
                        (carV (cdrV (v vv)))
                        (lets
                            [ ( t1, cdrV (cdrV (v vv)) ) ]
                            (iff (mkBool (cmpW RCeq (tagIs (v t1) RtLayout.tagCons) (n 0)))
                                mkNil
                                (App
                                    { fn = GRef { key = "Rt.epElem", force = False }
                                    , args = [ carV (v t1), mkNum (iadd (wOf (v iN)) (n 1)), v tgtN ]
                                    }
                                )
                            )
                        )
                    )
                )
            )
        )


{-| epNum v cbufN — [number N] -> N's Value, or mkNil (Zig tdNumber).
epStr v cbufN — [string S] -> S's Value (NOT copied; callers dupeZ it), or
mkNil (Zig tdString).  epSymOf v cbufN — [symbol X] -> X's symbol Value, or
mkNil (Zig tdSymbol).-}
epUnwrapDefun : String -> Int -> Int -> Defun
epUnwrapDefun key litOff wantTag =
    let
        vv =
            p1

        cbufN =
            p2
    in
    lam key [ vv, cbufN ]
        (iff (mkBool (cmpW RCeq (tagIs (v vv) RtLayout.tagCons) (n 0)))
            mkNil
            (iff (mkBool (cmpW RCeq (tagIs (carV (v vv)) RtLayout.tagSymbol) (n 0)))
                mkNil
                (iff (callR "Rt.epSymIs" [ carV (v vv), mkNum (iadd (wOf (v cbufN)) (n litOff)), mkNum (n 0) ])
                    (iff (mkBool (cmpW RCeq (tagIs (cdrV (v vv)) RtLayout.tagCons) (n 0)))
                        mkNil
                        (iff (mkBool (cmpW RCeq (tagIs (carV (cdrV (v vv))) wantTag) (n 0)))
                            mkNil
                            (carV (cdrV (v vv)))
                        )
                    )
                    mkNil
                )
            )
        )


{-| epProg v stN — decodeProgram: the tagged chain list -> a malloc'd prog
record [nchains, chains*] (Mid.RtLayout ep* layout), or -1 malformed (every
failure path frees its own decoded prefix first).  An EMPTY program is legal
(runs nothing, exit 0) — chains* stays 0.
-}
epProgDefun : Defun
epProgDefun =
    let
        vv =
            p1

        stN =
            p2

        limStore =
            b 4

        cnt =
            b 5

        progW =
            b 6

        chainsW =
            b 8

        go =
            b 9
    in
    lam "Rt.epProg" [ vv, stN ]
        (lets
            [ ( limStore, Unsafe (RawWordStore { ptr = wOf (v stN), index = n 2, value = n 256 }) )
            , ( cnt, callR "Rt.epCount" [ v vv, v stN, mkNum (n 0) ] )
            ]
            (iff (or2 (mkBool (cmpW RClts (wOf (v cnt)) (n 0))) (mkBool (cmpW RCgts (wOf (v cnt)) (n 256))))
                (mkNum (n (-1)))
                (lets
                    [ ( progW, callW "malloc" [ n 16 ] )
                    , ( b 7, iff (mkBool (cmpW RCeq (v progW) (n 0))) haltV (mkNum (n 0)) )
                    , ( b 10, Unsafe (RawWordStore { ptr = v progW, index = n RtLayout.epProgCountIdx, value = n 0 }) )
                    , ( b 11, Unsafe (RawWordStore { ptr = v progW, index = n RtLayout.epProgChainsIdx, value = n 0 }) )
                    ]
                    (iff (mkBool (cmpW RCeq (wOf (v cnt)) (n 0)))
                        (mkNum (v progW))
                        (lets
                            [ ( chainsW, callW "malloc" [ imul (wOf (v cnt)) (n (8 * RtLayout.epChainWords)) ] )
                            , ( b 12, iff (mkBool (cmpW RCeq (v chainsW) (n 0))) haltV (mkNum (n 0)) )
                            , ( b 13
                              , Unsafe
                                    (RawWordStore
                                        { ptr = v progW
                                        , index = n RtLayout.epProgChainsIdx
                                        , value = v chainsW
                                        }
                                    )
                              )
                            , ( go, callR "Rt.epProgGo" [ v vv, v stN, mkNum (v progW) ] )
                            ]
                            (iff (mkBool (cmpW RClts (wOf (v go)) (n 0)))
                                (lets
                                    [ ( b 14
                                      , callR "Rt.epFreeChains"
                                            [ mkNum (v progW)
                                            , mkNum (v chainsW)
                                            , mkNum (n 0)
                                            ]
                                      )
                                    ]
                                    (mkNum (n (-1)))
                                )
                                (mkNum (v progW))
                            )
                        )
                    )
                )
            )
        )


{-| epProgGo v stN progN — the chain fill loop.  prog[0] IS the running
count (the partial-free discipline): the chain record address is re-derived
from it each iteration, and epFreeChains frees exactly chains[0..prog[0]).
SELF-TAIL LOOP; frame-free, non-allocating.
-}
epProgGoDefun : Defun
epProgGoDefun =
    let
        vv =
            p1

        stN =
            p2

        progN =
            p3

        cbufW =
            b 4

        iW =
            b 5

        chainsW =
            b 6

        chAddr =
            b 7

        r =
            b 8

        t1 =
            b 9
        stV =
            b 11

    in
    lam "Rt.epProgGo" [ vv, stN, progN ]
        (lets
            [ ( cbufW, Unsafe (RawWordLoad { ptr = wOf (v stN), index = n 0 }) )
            , ( iW, Unsafe (RawWordLoad { ptr = wOf (v progN), index = n RtLayout.epProgCountIdx }) )
            , ( chainsW, Unsafe (RawWordLoad { ptr = wOf (v progN), index = n RtLayout.epProgChainsIdx }) )
            ]
            (lets
                [ ( stV, tagCountState (v vv) (v cbufW) ) ]
                (iff (mkBool (cmpW RCeq (wOf (v stV)) (n 2)))
                (mkNum (n (-1)))
                (iff (mkBool (cmpW RCeq (wOf (v stV)) (n 0)))
                    (mkNum (n 0))
                    (lets
                        [ ( t1, cdrV (cdrV (v vv)) )
                        , ( chAddr, iadd (v chainsW) (imul (v iW) (n (8 * RtLayout.epChainWords))) )
                        , ( r, callR "Rt.epChain" [ carV (cdrV (v vv)), v stN, mkNum (v chAddr) ] )
                        ]
                        (iff (mkBool (cmpW RClts (wOf (v r)) (n 0)))
                            (mkNum (n (-1)))
                            (lets
                                [ ( b 10
                                  , Unsafe
                                        (RawWordStore
                                            { ptr = wOf (v progN)
                                            , index = n RtLayout.epProgCountIdx
                                            , value = iadd (v iW) (n 1)
                                            }
                                        )
                                  )
                                ]
                                (App
                                    { fn = GRef { key = "Rt.epProgGo", force = False }
                                    , args = [ carV (v t1), v stN, v progN ]
                                    }
                                )
                            )
                        )
                    )
                )
            )
            )
        )


{-| epChain e stN chAddrN — decodeChain: [op Pipeline], len 2, op one of
seq/and/or (Mid.RtLayout epOp* codes, stored at chAddr[epChainOpIdx]); the
pipe record pointer is stored only on success.  Zig's order: the op is
validated BEFORE the pipeline decode, so a bad-op chain never allocates.
The three literal offsets are cbuf words 4/5/6 (seq/and/or).
-}
epChainDefun : Defun
epChainDefun =
    let
        e =
            p1

        stN =
            p2

        chAddrN =
            p3

        limStore =
            b 4

        cnt =
            b 5

        cbufW =
            b 8

        opv =
            b 6

        pipev =
            b 7

        xsym =
            b 9

        isSeq =
            b 10

        isAnd =
            b 11

        isOr =
            b 12

        opV =
            b 13

        pipeN =
            b 14
    in
    lam "Rt.epChain" [ e, stN, chAddrN ]
        (lets
            [ ( limStore, Unsafe (RawWordStore { ptr = wOf (v stN), index = n 2, value = n 8 }) )
            , ( cnt, callR "Rt.epCount" [ v e, v stN, mkNum (n 0) ] )
            , ( cbufW, Unsafe (RawWordLoad { ptr = wOf (v stN), index = n 0 }) )
            ]
            (iff (mkBool (cmpW RCne (wOf (v cnt)) (n 2)))
                (mkNum (n (-1)))
                (lets
                    [ ( opv, callR "Rt.epElem" [ v e, mkNum (n 0), mkNum (n 0) ] )
                    , ( pipev, callR "Rt.epElem" [ v e, mkNum (n 0), mkNum (n 1) ] )
                    , ( xsym, callR "Rt.epSymOf" [ v opv, mkNum (v cbufW) ] )
                    ]
                    (iff (mkBool (cmpW RCeq (tagIs (v xsym) RtLayout.tagSymbol) (n 0)))
                        (mkNum (n (-1)))
                        (lets
                            [ ( isSeq, callR "Rt.epSymIs" [ v xsym, mkNum (iadd (v cbufW) (n 32)), mkNum (n 0) ] )
                            , ( isAnd, callR "Rt.epSymIs" [ v xsym, mkNum (iadd (v cbufW) (n 40)), mkNum (n 0) ] )
                            , ( isOr, callR "Rt.epSymIs" [ v xsym, mkNum (iadd (v cbufW) (n 48)), mkNum (n 0) ] )
                            , ( opV
                              , iff (v isSeq)
                                    (mkNum (n RtLayout.epOpSeq))
                                    (iff (v isAnd)
                                        (mkNum (n RtLayout.epOpAnd))
                                        (iff (v isOr)
                                            (mkNum (n RtLayout.epOpOr))
                                            (mkNum (n (-1)))
                                        )
                                    )
                              )
                            ]
                            (iff (mkBool (cmpW RClts (wOf (v opV)) (n 0)))
                                (mkNum (n (-1)))
                                (lets
                                    [ ( pipeN, callR "Rt.epPipeline" [ v pipev, v stN ] )
                                    ]
                                    (iff (mkBool (cmpW RClts (wOf (v pipeN)) (n 0)))
                                        (mkNum (n (-1)))
                                        (lets
                                            [ ( b 15
                                              , Unsafe
                                                    (RawWordStore
                                                        { ptr = wOf (v chAddrN)
                                                        , index = n RtLayout.epChainOpIdx
                                                        , value = wOf (v opV)
                                                        }
                                                    )
                                              )
                                            , ( b 16
                                              , Unsafe
                                                    (RawWordStore
                                                        { ptr = wOf (v chAddrN)
                                                        , index = n RtLayout.epChainPipeIdx
                                                        , value = wOf (v pipeN)
                                                        }
                                                    )
                                              )
                                            ]
                                            (mkNum (n 0))
                                        )
                                    )
                                )
                            )
                        )
                    )
                )
            )
        )


{-| epPipeline v stN — decodePipeline: >= 1 command, <= 64; returns the
malloc'd pipe record [ncmds, cmds*] or -1 (own partial state freed).
-}
epPipelineDefun : Defun
epPipelineDefun =
    let
        vv =
            p1

        stN =
            p2

        limStore =
            b 4

        cnt =
            b 5

        pipeW =
            b 6

        cmdsW =
            b 7

        go =
            b 9
    in
    lam "Rt.epPipeline" [ vv, stN ]
        (lets
            [ ( limStore, Unsafe (RawWordStore { ptr = wOf (v stN), index = n 2, value = n 64 }) )
            , ( cnt, callR "Rt.epCount" [ v vv, v stN, mkNum (n 0) ] )
            ]
            (iff (or2 (mkBool (cmpW RClts (wOf (v cnt)) (n 1))) (mkBool (cmpW RCgts (wOf (v cnt)) (n 64))))
                (mkNum (n (-1)))
                (lets
                    [ ( pipeW, callW "malloc" [ n 16 ] )
                    , ( b 8, iff (mkBool (cmpW RCeq (v pipeW) (n 0))) haltV (mkNum (n 0)) )
                    , ( b 10, Unsafe (RawWordStore { ptr = v pipeW, index = n RtLayout.epPipeCmdCountIdx, value = n 0 }) )
                    , ( b 11, Unsafe (RawWordStore { ptr = v pipeW, index = n RtLayout.epPipeCmdArrIdx, value = n 0 }) )
                    , ( cmdsW, callW "malloc" [ imul (wOf (v cnt)) (n (8 * RtLayout.epCmdWords)) ] )
                    , ( b 12, iff (mkBool (cmpW RCeq (v cmdsW) (n 0))) haltV (mkNum (n 0)) )
                    , ( b 13, Unsafe (RawWordStore { ptr = v pipeW, index = n RtLayout.epPipeCmdArrIdx, value = v cmdsW }) )
                    , ( go, callR "Rt.epPipeGo" [ v vv, v stN, mkNum (v pipeW) ] )
                    ]
                    (iff (mkBool (cmpW RClts (wOf (v go)) (n 0)))
                        (lets
                            [ ( b 14, callR "Rt.epFreeCmds" [ mkNum (v pipeW), mkNum (v cmdsW), mkNum (n 0) ] ) ]
                            (mkNum (n (-1)))
                        )
                        (mkNum (v pipeW))
                    )
                )
            )
        )


{-| epPipeGo v stN pipeN — the command fill loop; pipe[0] IS the running
count (the partial-free discipline).  SELF-TAIL; frame-free.
-}
epPipeGoDefun : Defun
epPipeGoDefun =
    let
        vv =
            p1

        stN =
            p2

        pipeN =
            p3

        cbufW =
            b 4

        iW =
            b 5

        cmdsW =
            b 6

        cAddr =
            b 7

        r =
            b 8

        t1 =
            b 9
        stV =
            b 11

    in
    lam "Rt.epPipeGo" [ vv, stN, pipeN ]
        (lets
            [ ( cbufW, Unsafe (RawWordLoad { ptr = wOf (v stN), index = n 0 }) )
            , ( iW, Unsafe (RawWordLoad { ptr = wOf (v pipeN), index = n RtLayout.epPipeCmdCountIdx }) )
            , ( cmdsW, Unsafe (RawWordLoad { ptr = wOf (v pipeN), index = n RtLayout.epPipeCmdArrIdx }) )
            ]
            (lets
                [ ( stV, tagCountState (v vv) (v cbufW) ) ]
                (iff (mkBool (cmpW RCeq (wOf (v stV)) (n 2)))
                (mkNum (n (-1)))
                (iff (mkBool (cmpW RCeq (wOf (v stV)) (n 0)))
                    (mkNum (n 0))
                    (lets
                        [ ( t1, cdrV (cdrV (v vv)) )
                        , ( cAddr, iadd (v cmdsW) (imul (v iW) (n (8 * RtLayout.epCmdWords))) )
                        , ( r, callR "Rt.epCmd" [ carV (cdrV (v vv)), v stN, mkNum (v cAddr) ] )
                        ]
                        (iff (mkBool (cmpW RClts (wOf (v r)) (n 0)))
                            (mkNum (n (-1)))
                            (lets
                                [ ( b 10
                                  , Unsafe
                                        (RawWordStore
                                            { ptr = wOf (v pipeN)
                                            , index = n RtLayout.epPipeCmdCountIdx
                                            , value = iadd (v iW) (n 1)
                                            }
                                        )
                                  )
                                ]
                                (App
                                    { fn = GRef { key = "Rt.epPipeGo", force = False }
                                    , args = [ carV (v t1), v stN, v pipeN ]
                                    }
                                )
                            )
                        )
                    )
                )
            )
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

        t1 =
            b 22

        nstdin =
            b 23

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
            lets
                [ ( b 24
                  , callR "Rt.epFreeChains"
                        [ mkNum (Unsafe (RawWordLoad { ptr = Unsafe (RawWordLoad { ptr = wOf (v cAddrN), index = n RtLayout.epCmdSubIdx }), index = n RtLayout.epProgChainsIdx }))
                        , mkNum (Unsafe (RawWordLoad { ptr = Unsafe (RawWordLoad { ptr = wOf (v cAddrN), index = n RtLayout.epCmdSubIdx }), index = n RtLayout.epProgChainsIdx }))
                        , mkNum (n 0)
                        ]
                  )
                , ( b 25, callW "free" [ Unsafe (RawWordLoad { ptr = wOf (v cAddrN), index = n RtLayout.epCmdSubIdx }) ] )
                ]
                mkNil

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
                        (iff (mkBool (cmpW RCeq (wOf (v acnt)) (n 0)))
                            (mkNum (n 0))
                            (lets
                                [ ( argvW, callW "malloc" [ imul (wOf (v acnt)) (n 8) ] )
                                , ( b 36, iff (mkBool (cmpW RCeq (v argvW) (n 0))) haltV (mkNum (n 0)) )
                                , ( b 37, Unsafe (RawWordStore { ptr = wOf (v cAddrN), index = n RtLayout.epCmdArgvIdx, value = v argvW }) )
                                , ( ago, callR "Rt.epArgvGo" [ v argvv, v stN, v cAddrN ] )
                                ]
                                (iff (mkBool (cmpW RClts (wOf (v ago)) (n 0)))
                                    -- epArgvGo already freed the strings and
                                    -- the array; clear the slot and stop.
                                    (lets [ ( b 38, clearArgv ) ] (mkNum (n (-1))))
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
                                            (iff (mkBool (cmpW RCeq (wOf (v rcnt)) (n 0)))
                                                (mkNum (n 0))
                                                (lets
                                                    [ ( redirsW, callW "malloc" [ imul (wOf (v rcnt)) (n (8 * RtLayout.epRedirWords)) ] )
                                                    , ( b 41, iff (mkBool (cmpW RCeq (v redirsW) (n 0))) haltV (mkNum (n 0)) )
                                                    , ( b 42, Unsafe (RawWordStore { ptr = wOf (v cAddrN), index = n RtLayout.epCmdRedirsIdx, value = v redirsW }) )
                                                    , ( rgo, callR "Rt.epRedirsGo" [ v redirsv, v stN, v cAddrN ] )
                                                    ]
                                                    (iff (mkBool (cmpW RClts (wOf (v rgo)) (n 0)))
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
                                                        (lets
                                                            [ ( subState, tagCountState (v subv) (v cbufW) )
                                                            ]
                                                            (iff (mkBool (cmpW RCeq (wOf (v subState)) (n 2)))
                                                                (unwindAll)
                                                                (iff (mkBool (cmpW RCeq (wOf (v subState)) (n 0)))
                                                                    -- plain command: empty argv is illegal (C:1343)
                                                                    (iff (mkBool (cmpW RCeq (Unsafe (RawWordLoad { ptr = wOf (v cAddrN), index = n RtLayout.epCmdArgvIdx })) (n 0)))
                                                                        (unwindAll)
                                                                        (mkNum (n 0))
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
                                                                                    [ ( t1, cdrV (cdrV (v subv)) )
                                                                                    , ( b 46, Unsafe (RawWordStore { ptr = wOf (v stN), index = n 1, value = iadd (v depthW) (n 1) }) )
                                                                                    , ( subN, callR "Rt.epProg" [ v subv, v stN ] )
                                                                                    , ( b 47, Unsafe (RawWordStore { ptr = wOf (v stN), index = n 1, value = v depthW }) )
                                                                                    ]
                                                                                    (iff (mkBool (cmpW RClts (wOf (v subN)) (n 0)))
                                                                                        (unwindAll)
                                                                                        (lets
                                                                                            [ ( b 48, Unsafe (RawWordStore { ptr = wOf (v cAddrN), index = n RtLayout.epCmdSubIdx, value = wOf (v subN) }) )
                                                                                            , ( nstdin
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
            )
        )


{-| epArgvGo v stN cAddrN — dupeZ each argv string into cmd's char* array
(argc at cAddr[epCmdArgcIdx] is the running count).  On a malformed element
it frees the decoded prefix (strings + array) itself and returns -1.
SELF-TAIL; frame-free, non-allocating.  Zig parity note: tdlCollect counted
first and copied after; here the dupe happens inline — same verdicts, same
bytes, one pass.
-}
epArgvGoDefun : Defun
epArgvGoDefun =
    let
        vv =
            p1

        stN =
            p2

        cAddrN =
            p3

        cbufW =
            b 4

        argvW =
            b 5

        jW =
            b 6

        sN =
            b 7

        bufW =
            b 8

        t1 =
            b 9

        bad =
            lets
                [ ( b 10
                  , callR "Rt.epFreeArgv"
                        [ mkNum (Unsafe (RawWordLoad { ptr = wOf (v cAddrN), index = n RtLayout.epCmdArgvIdx }))
                        , mkNum (n 0)
                        , mkNum (Unsafe (RawWordLoad { ptr = wOf (v cAddrN), index = n RtLayout.epCmdArgcIdx }))
                        ]
                  )
                , ( b 11, Unsafe (RawWordStore { ptr = wOf (v cAddrN), index = n RtLayout.epCmdArgvIdx, value = n 0 }) )
                ]
                (mkNum (n (-1)))
        stV =
            b 20

    in
    lam "Rt.epArgvGo" [ vv, stN, cAddrN ]
        (lets
            [ ( cbufW, Unsafe (RawWordLoad { ptr = wOf (v stN), index = n 0 }) )
            , ( argvW, Unsafe (RawWordLoad { ptr = wOf (v cAddrN), index = n RtLayout.epCmdArgvIdx }) )
            , ( jW, Unsafe (RawWordLoad { ptr = wOf (v cAddrN), index = n RtLayout.epCmdArgcIdx }) )
            ]
            (lets
                [ ( stV, tagCountState (v vv) (v cbufW) ) ]
                (iff (mkBool (cmpW RCeq (wOf (v stV)) (n 2)))
                (bad)
                (iff (mkBool (cmpW RCeq (wOf (v stV)) (n 0)))
                    (mkNum (n 0))
                    (lets
                        [ ( sN, callR "Rt.epStr" [ carV (cdrV (v vv)), mkNum (v cbufW) ] )
                        ]
                        (iff (mkBool (cmpW RCeq (tagIs (v sN) RtLayout.tagString) (n 0)))
                            (bad)
                            (lets
                                [ ( bufW, callW "malloc" [ iadd (lenOf (v sN)) (n 1) ] )
                                , ( b 12, iff (mkBool (cmpW RCeq (v bufW) (n 0))) haltV (mkNum (n 0)) )
                                , ( b 13, callR "Rt.cStrFill" [ mkNum (v bufW), v sN, mkNum (n 0) ] )
                                , ( b 14, Unsafe (RawWordStore { ptr = v argvW, index = v jW, value = v bufW }) )
                                , ( b 15, Unsafe (RawWordStore { ptr = wOf (v cAddrN), index = n RtLayout.epCmdArgcIdx, value = iadd (v jW) (n 1) }) )
                                , ( t1, cdrV (cdrV (v vv)) )
                                ]
                                (iff (mkBool (cmpW RCeq (tagIs (v t1) RtLayout.tagCons) (n 0)))
                                    (bad)
                                    (App
                                        { fn = GRef { key = "Rt.epArgvGo", force = False }
                                        , args = [ carV (v t1), v stN, v cAddrN ]
                                        }
                                    )
                                )
                            )
                        )
                    )
                )
            )
            )
        )


{-| epRedirsGo v stN cAddrN — decode each redir into cmd's word array
(nredirs at cAddr[epCmdNredirsIdx] is the running count); frees its own
prefix + array on failure.  SELF-TAIL; frame-free.
-}
epRedirsGoDefun : Defun
epRedirsGoDefun =
    let
        vv =
            p1

        stN =
            p2

        cAddrN =
            p3

        cbufW =
            b 4

        arrW =
            b 5

        jW =
            b 6

        rAddr =
            b 7

        r =
            b 8

        t1 =
            b 9

        bad =
            lets
                [ ( b 10
                  , callR "Rt.epFreeRedirs"
                        [ mkNum (Unsafe (RawWordLoad { ptr = wOf (v cAddrN), index = n RtLayout.epCmdRedirsIdx }))
                        , mkNum (n 0)
                        , mkNum (Unsafe (RawWordLoad { ptr = wOf (v cAddrN), index = n RtLayout.epCmdNredirsIdx }))
                        ]
                  )
                , ( b 11, Unsafe (RawWordStore { ptr = wOf (v cAddrN), index = n RtLayout.epCmdRedirsIdx, value = n 0 }) )
                ]
                (mkNum (n (-1)))
        stV =
            b 13

    in
    lam "Rt.epRedirsGo" [ vv, stN, cAddrN ]
        (lets
            [ ( cbufW, Unsafe (RawWordLoad { ptr = wOf (v stN), index = n 0 }) )
            , ( arrW, Unsafe (RawWordLoad { ptr = wOf (v cAddrN), index = n RtLayout.epCmdRedirsIdx }) )
            , ( jW, Unsafe (RawWordLoad { ptr = wOf (v cAddrN), index = n RtLayout.epCmdNredirsIdx }) )
            ]
            (lets
                [ ( stV, tagCountState (v vv) (v cbufW) ) ]
                (iff (mkBool (cmpW RCeq (wOf (v stV)) (n 2)))
                (bad)
                (iff (mkBool (cmpW RCeq (wOf (v stV)) (n 0)))
                    (mkNum (n 0))
                    (lets
                        [ ( rAddr, iadd (v arrW) (imul (v jW) (n (8 * RtLayout.epRedirWords))) )
                        , ( r, callR "Rt.epRedir" [ carV (cdrV (v vv)), v stN, mkNum (v rAddr) ] )
                        , ( t1, cdrV (cdrV (v vv)) )
                        ]
                        (iff (mkBool (cmpW RClts (wOf (v r)) (n 0)))
                            (bad)
                            (lets
                                [ ( b 12, Unsafe (RawWordStore { ptr = wOf (v cAddrN), index = n RtLayout.epCmdNredirsIdx, value = iadd (v jW) (n 1) }) )
                                ]
                                (iff (mkBool (cmpW RCeq (tagIs (v t1) RtLayout.tagCons) (n 0)))
                                    (bad)
                                    (App
                                        { fn = GRef { key = "Rt.epRedirsGo", force = False }
                                        , args = [ carV (v t1), v stN, v cAddrN ]
                                        }
                                    )
                                )
                            )
                        )
                    )
                )
            )
            )
        )


{-| epRedir e stN rAddrN — decodeRedir: [op fd target], len 3, op one of
in/out/append/dup/hdoc/hstr; fd must be 0 for in/hdoc/hstr and 1|2 for
out/append/dup (Zig's exact validation); a dup targets a NUMBER fd 1|2, the
others target [string S], dupeZ'd — hstr appends the trailing newline Zig's
decode writes (one malloc where Zig used two, the same bytes out).  All five
words are stored only on success, so a failed entry holds nothing malloc'd.
The literal offsets are cbuf words 7..12 (in/out/append/dup/hdoc/hstr).
-}
epRedirDefun : Defun
epRedirDefun =
    let
        e =
            p1

        stN =
            p2

        rAddrN =
            p3

        limStore =
            b 4

        cnt =
            b 5

        cbufW =
            b 6

        opv =
            b 7

        fdv =
            b 8

        tgv =
            b 9

        xsym =
            b 10

        isIn =
            b 11

        isOut =
            b 12

        isAppend =
            b 13

        isDup =
            b 14

        isHdoc =
            b 15

        isHstr =
            b 16

        kindV =
            b 17

        fdN =
            b 18

        fdOk =
            b 19

        dfdN =
            b 20

        sN =
            b 21

        bufW =
            b 22

        inHdocHstr =
            or2 (v isIn) (or2 (v isHdoc) (v isHstr))

        hdocHstr =
            or2 (v isHdoc) (v isHstr)

        storeDup =
            lets
                [ ( b 23, Unsafe (RawWordStore { ptr = wOf (v rAddrN), index = n RtLayout.epRedirKindIdx, value = wOf (v kindV) }) )
                , ( b 24, Unsafe (RawWordStore { ptr = wOf (v rAddrN), index = n RtLayout.epRedirFdIdx, value = wOf (v fdN) }) )
                , ( b 25, Unsafe (RawWordStore { ptr = wOf (v rAddrN), index = n RtLayout.epRedirPathIdx, value = n 0 }) )
                , ( b 26, Unsafe (RawWordStore { ptr = wOf (v rAddrN), index = n RtLayout.epRedirDupfdIdx, value = wOf (v dfdN) }) )
                , ( b 27, Unsafe (RawWordStore { ptr = wOf (v rAddrN), index = n RtLayout.epRedirBodyIdx, value = n 0 }) )
                ]
                (mkNum (n 0))

        storeBody =
            lets
                [ ( b 28, Unsafe (RawWordStore { ptr = wOf (v rAddrN), index = n RtLayout.epRedirKindIdx, value = wOf (v kindV) }) )
                , ( b 29, Unsafe (RawWordStore { ptr = wOf (v rAddrN), index = n RtLayout.epRedirFdIdx, value = wOf (v fdN) }) )
                , ( b 30, Unsafe (RawWordStore { ptr = wOf (v rAddrN), index = n RtLayout.epRedirPathIdx, value = n 0 }) )
                , ( b 31, Unsafe (RawWordStore { ptr = wOf (v rAddrN), index = n RtLayout.epRedirDupfdIdx, value = n 0 }) )
                , ( b 32, Unsafe (RawWordStore { ptr = wOf (v rAddrN), index = n RtLayout.epRedirBodyIdx, value = v bufW }) )
                ]
                (mkNum (n 0))

        storePath =
            lets
                [ ( b 33, Unsafe (RawWordStore { ptr = wOf (v rAddrN), index = n RtLayout.epRedirKindIdx, value = wOf (v kindV) }) )
                , ( b 34, Unsafe (RawWordStore { ptr = wOf (v rAddrN), index = n RtLayout.epRedirFdIdx, value = wOf (v fdN) }) )
                , ( b 35, Unsafe (RawWordStore { ptr = wOf (v rAddrN), index = n RtLayout.epRedirPathIdx, value = v bufW }) )
                , ( b 36, Unsafe (RawWordStore { ptr = wOf (v rAddrN), index = n RtLayout.epRedirDupfdIdx, value = n 0 }) )
                , ( b 37, Unsafe (RawWordStore { ptr = wOf (v rAddrN), index = n RtLayout.epRedirBodyIdx, value = n 0 }) )
                ]
                (mkNum (n 0))
    in
    lam "Rt.epRedir" [ e, stN, rAddrN ]
        (lets
            [ ( limStore, Unsafe (RawWordStore { ptr = wOf (v stN), index = n 2, value = n 8 }) )
            , ( cnt, callR "Rt.epCount" [ v e, v stN, mkNum (n 0) ] )
            , ( cbufW, Unsafe (RawWordLoad { ptr = wOf (v stN), index = n 0 }) )
            ]
            (iff (mkBool (cmpW RCne (wOf (v cnt)) (n 3)))
                (mkNum (n (-1)))
                (lets
                    [ ( opv, callR "Rt.epElem" [ v e, mkNum (n 0), mkNum (n 0) ] )
                    , ( fdv, callR "Rt.epElem" [ v e, mkNum (n 0), mkNum (n 1) ] )
                    , ( tgv, callR "Rt.epElem" [ v e, mkNum (n 0), mkNum (n 2) ] )
                    , ( xsym, callR "Rt.epSymOf" [ v opv, mkNum (v cbufW) ] )
                    ]
                    (iff (mkBool (cmpW RCeq (tagIs (v xsym) RtLayout.tagSymbol) (n 0)))
                        (mkNum (n (-1)))
                        (lets
                            [ ( isIn, callR "Rt.epSymIs" [ v xsym, mkNum (iadd (v cbufW) (n 56)), mkNum (n 0) ] )
                            , ( isOut, callR "Rt.epSymIs" [ v xsym, mkNum (iadd (v cbufW) (n 64)), mkNum (n 0) ] )
                            , ( isAppend, callR "Rt.epSymIs" [ v xsym, mkNum (iadd (v cbufW) (n 72)), mkNum (n 0) ] )
                            , ( isDup, callR "Rt.epSymIs" [ v xsym, mkNum (iadd (v cbufW) (n 80)), mkNum (n 0) ] )
                            , ( isHdoc, callR "Rt.epSymIs" [ v xsym, mkNum (iadd (v cbufW) (n 88)), mkNum (n 0) ] )
                            , ( isHstr, callR "Rt.epSymIs" [ v xsym, mkNum (iadd (v cbufW) (n 96)), mkNum (n 0) ] )
                            , ( kindV
                              , iff (v isIn)
                                    (mkNum (n RtLayout.epKindIn))
                                    (iff (v isOut)
                                        (mkNum (n RtLayout.epKindOut))
                                        (iff (v isAppend)
                                            (mkNum (n RtLayout.epKindAppend))
                                            (iff (v isDup)
                                                (mkNum (n RtLayout.epKindDup))
                                                (iff (v isHdoc)
                                                    (mkNum (n RtLayout.epKindHdoc))
                                                    (iff (v isHstr)
                                                        (mkNum (n RtLayout.epKindHstr))
                                                        (mkNum (n (-1)))
                                                    )
                                                )
                                            )
                                        )
                                    )
                              )
                            , ( fdN, callR "Rt.epNum" [ v fdv, mkNum (v cbufW) ] )
                            , ( fdOk
                              , iff (inHdocHstr)
                                    (mkBool (cmpW RCeq (wOf (v fdN)) (n 0)))
                                    (or2 (mkBool (cmpW RCeq (wOf (v fdN)) (n 1))) (mkBool (cmpW RCeq (wOf (v fdN)) (n 2))))
                              )
                            ]
                            (iff (mkBool (cmpW RClts (wOf (v kindV)) (n 0)))
                                (mkNum (n (-1)))
                                (iff (mkBool (cmpW RCeq (tagIs (v fdN) RtLayout.tagNumber) (n 0)))
                                    (mkNum (n (-1)))
                                    (iff (v fdOk)
                                        (iff (v isDup)
                                            (lets
                                                [ ( dfdN, callR "Rt.epNum" [ v tgv, mkNum (v cbufW) ] ) ]
                                                (iff (mkBool (cmpW RCeq (tagIs (v dfdN) RtLayout.tagNumber) (n 0)))
                                                    (mkNum (n (-1)))
                                                    (iff (or2 (mkBool (cmpW RCeq (wOf (v dfdN)) (n 1))) (mkBool (cmpW RCeq (wOf (v dfdN)) (n 2))))
                                                        (storeDup)
                                                        (mkNum (n (-1)))
                                                    )
                                                )
                                            )
                                            (lets
                                                [ ( sN, callR "Rt.epStr" [ v tgv, mkNum (v cbufW) ] ) ]
                                                (iff (mkBool (cmpW RCeq (tagIs (v sN) RtLayout.tagString) (n 0)))
                                                    (mkNum (n (-1)))
                                                    (lets
                                                        [ ( bufW
                                                          , callW "malloc"
                                                                [ iadd (lenOf (v sN))
                                                                        (wOf (iff (v isHstr) (mkNum (n 1)) (mkNum (n 0))))
                                                                ]
                                                          )
                                                        , ( b 38, iff (mkBool (cmpW RCeq (v bufW) (n 0))) haltV (mkNum (n 0)) )
                                                        , ( b 39, callR "Rt.cStrFill" [ mkNum (v bufW), v sN, mkNum (n 0) ] )
                                                        , ( b 40
                                                          , iff (v isHstr)
                                                                (lets
                                                                    [ ( b 41, Unsafe (RawByteStore { ptr = v bufW, index = lenOf (v sN), value = n 10 }) ) ]
                                                                    (lets
                                                                        [ ( b 42, Unsafe (RawByteStore { ptr = v bufW, index = iadd (lenOf (v sN)) (n 1), value = n 0 }) ) ]
                                                                        mkNil
                                                                    )
                                                                )
                                                                mkNil
                                                          )
                                                        ]
                                                        (iff (hdocHstr)
                                                            (storeBody)
                                                            (storePath)
                                                        )
                                                    )
                                                )
                                            )
                                        )
                                        (mkNum (n (-1)))
                                    )
                                )
                            )
                        )
                    )
                )
            )
        )




{-| epCountStdin arrN jN accN — redirs[0..j) with fd == 0, counting j DOWN
(the caller passes nredirs).  TAIL; a NULL array is legal (count 0).
-}
epCountStdinDefun : Defun
epCountStdinDefun =
    let
        arrN =
            p1

        jN =
            p2

        accN =
            p3

        fdW =
            b 4
    in
    lam "Rt.epCountStdin" [ arrN, jN, accN ]
        (iff (mkBool (cmpW RCles (wOf (v jN)) (n 1)))
            (v accN)
            (lets
                [ ( fdW, Unsafe (RawWordLoad { ptr = wOf (v arrN), index = iadd (imul (isub (wOf (v jN)) (n 1)) (n RtLayout.epRedirWords)) (n RtLayout.epRedirFdIdx) }) ) ]
                (App
                    { fn = GRef { key = "Rt.epCountStdin", force = False }
                    , args =
                        [ v arrN
                        , mkNum (isub (wOf (v jN)) (n 1))
                        , mkNum (iadd (wOf (v accN)) (cmpW RCeq (v fdW) (n 0)))
                        ]
                    }
                )
            )
        )


{-| The decode-tree free walk — Zig's planFree/pipeFree/cmdFree over the
flat blob, reading each level's COUNT so exactly the decoded prefix is
freed (the running-count discipline above).  free(0) is a C no-op; a NULL
array is never walked.  All three loops are SELF-TAIL; frame-free,
non-allocating (free is a raw call).
-}
epFreeChainsDefun : Defun
epFreeChainsDefun =
    let
        progN =
            p1

        chainsN =
            p2

        iN =
            p3

        nW =
            b 4

        pipeW =
            b 5
    in
    lam "Rt.epFreeChains" [ progN, chainsN, iN ]
        (lets
            [ ( nW, Unsafe (RawWordLoad { ptr = wOf (v progN), index = n RtLayout.epProgCountIdx }) ) ]
            (iff (mkBool (cmpW RCges (wOf (v iN)) (v nW)))
                (lets
                    [ ( b 6, callW "free" [ wOf (v chainsN) ] )
                    , ( b 7, callW "free" [ wOf (v progN) ] )
                    ]
                    mkNil
                )
                (lets
                    [ ( pipeW, Unsafe (RawWordLoad { ptr = wOf (v chainsN), index = iadd (imul (wOf (v iN)) (n RtLayout.epChainWords)) (n RtLayout.epChainPipeIdx) }) ) ]
                    (iff (mkBool (cmpW RCne (v pipeW) (n 0)))
                        (lets
                            [ ( b 8
                              , callR "Rt.epFreeCmds"
                                    [ mkNum (v pipeW)
                                    , mkNum (Unsafe (RawWordLoad { ptr = v pipeW, index = n RtLayout.epPipeCmdArrIdx }))
                                    , mkNum (n 0)
                                    ]
                              )
                            ]
                            (App { fn = GRef { key = "Rt.epFreeChains", force = False }, args = [ v progN, v chainsN, mkNum (iadd (wOf (v iN)) (n 1)) ] })
                        )
                        (App { fn = GRef { key = "Rt.epFreeChains", force = False }, args = [ v progN, v chainsN, mkNum (iadd (wOf (v iN)) (n 1)) ] })
                    )
                )
            )
        )


epFreeCmdsDefun : Defun
epFreeCmdsDefun =
    let
        pipeN =
            p1

        cmdsN =
            p2

        iN =
            p3

        nW =
            b 4
    in
    lam "Rt.epFreeCmds" [ pipeN, cmdsN, iN ]
        (lets
            [ ( nW, Unsafe (RawWordLoad { ptr = wOf (v pipeN), index = n RtLayout.epPipeCmdCountIdx }) ) ]
            (iff (mkBool (cmpW RCges (wOf (v iN)) (v nW)))
                (lets
                    [ ( b 5, callW "free" [ wOf (v cmdsN) ] )
                    , ( b 6, callW "free" [ wOf (v pipeN) ] )
                    ]
                    mkNil
                )
                (lets
                    [ ( b 7
                      , callR "Rt.epFreeCmd"
                            [ mkNum (iadd (wOf (v cmdsN)) (imul (wOf (v iN)) (n (8 * RtLayout.epCmdWords)))) ]
                      )
                    ]
                    (App { fn = GRef { key = "Rt.epFreeCmds", force = False }, args = [ v pipeN, v cmdsN, mkNum (iadd (wOf (v iN)) (n 1)) ] })
                )
            )
        )


epFreeCmdDefun : Defun
epFreeCmdDefun =
    let
        cmdAddrN =
            p1

        argvW =
            b 4

        redirsW =
            b 6

        subW =
            b 8
    in
    lam "Rt.epFreeCmd" [ cmdAddrN ]
        (lets
            [ ( argvW, Unsafe (RawWordLoad { ptr = wOf (v cmdAddrN), index = n RtLayout.epCmdArgvIdx }) )
            , ( b 5
              , iff (mkBool (cmpW RCne (v argvW) (n 0)))
                    (callR "Rt.epFreeArgv"
                        [ mkNum (v argvW)
                        , mkNum (n 0)
                        , mkNum (Unsafe (RawWordLoad { ptr = wOf (v cmdAddrN), index = n RtLayout.epCmdArgcIdx }))
                        ]
                    )
                    mkNil
              )
            , ( redirsW, Unsafe (RawWordLoad { ptr = wOf (v cmdAddrN), index = n RtLayout.epCmdRedirsIdx }) )
            , ( b 7
              , iff (mkBool (cmpW RCne (v redirsW) (n 0)))
                    (callR "Rt.epFreeRedirs"
                        [ mkNum (v redirsW)
                        , mkNum (n 0)
                        , mkNum (Unsafe (RawWordLoad { ptr = wOf (v cmdAddrN), index = n RtLayout.epCmdNredirsIdx }))
                        ]
                    )
                    mkNil
              )
            , ( subW, Unsafe (RawWordLoad { ptr = wOf (v cmdAddrN), index = n RtLayout.epCmdSubIdx }) )
            , ( b 9
              , iff (mkBool (cmpW RCne (v subW) (n 0)))
                    (lets
                        [ ( b 10
                          , callR "Rt.epFreeChains"
                                [ mkNum (v subW)
                                , mkNum (Unsafe (RawWordLoad { ptr = v subW, index = n RtLayout.epProgChainsIdx }))
                                , mkNum (n 0)
                                ]
                          )
                        , ( b 11, callW "free" [ v subW ] )
                        ]
                        mkNil
                    )
                    mkNil
              )
            ]
            mkNil
        )


epFreeArgvDefun : Defun
epFreeArgvDefun =
    let
        arrN =
            p1

        jN =
            p2

        nN =
            p3
    in
    lam "Rt.epFreeArgv" [ arrN, jN, nN ]
        (iff (mkBool (cmpW RCges (wOf (v jN)) (wOf (v nN))))
            (lets [ ( b 4, callW "free" [ wOf (v arrN) ] ) ] mkNil)
            (lets
                [ ( b 5, callW "free" [ Unsafe (RawWordLoad { ptr = wOf (v arrN), index = wOf (v jN) }) ] ) ]
                (App { fn = GRef { key = "Rt.epFreeArgv", force = False }, args = [ v arrN, mkNum (iadd (wOf (v jN)) (n 1)), v nN ] })
            )
        )


epFreeRedirsDefun : Defun
epFreeRedirsDefun =
    let
        arrN =
            p1

        jN =
            p2

        nN =
            p3
    in
    lam "Rt.epFreeRedirs" [ arrN, jN, nN ]
        (iff (mkBool (cmpW RCges (wOf (v jN)) (wOf (v nN))))
            (lets [ ( b 4, callW "free" [ wOf (v arrN) ] ) ] mkNil)
            (lets
                [ ( b 5, callW "free" [ Unsafe (RawWordLoad { ptr = wOf (v arrN), index = iadd (imul (wOf (v jN)) (n RtLayout.epRedirWords)) (n RtLayout.epRedirPathIdx) }) ] )
                , ( b 6, callW "free" [ Unsafe (RawWordLoad { ptr = wOf (v arrN), index = iadd (imul (wOf (v jN)) (n RtLayout.epRedirWords)) (n RtLayout.epRedirBodyIdx) }) ] )
                ]
                (App { fn = GRef { key = "Rt.epFreeRedirs", force = False }, args = [ v arrN, mkNum (iadd (wOf (v jN)) (n 1)), v nN ] })
            )
        )


helperDefuns : Bool -> List Defun
helperDefuns rec =
    [ deepEqDefun rec
    , bytesEqGoDefun
    , symEqDefun
    , vecEqDefun
    , asFDefun
    , toI32Defun
    , dgsDefun
    , revGoDefun
    , bytesOfDefun
    , numTextDefun
    , bytesToStrDefun
    , countLDefun
    , fillGoDefun
    , cn2Defun
    , appendLDefun
    , symToStrDefun
    , nameBytesDefun
    , strOfDefun
    , assocGoDefun
    , subGoDefun
    , repGoDefun
    , bytesBuildDefun
    , recGetDefun
    , recGetGoDefun
    , recUpdDefun
    , recUpdFindDefun
    , recUpdCopyDefun
    , symLessDefun
    , recAppendFindDefun
    , recAppendDataGoDefun
    , recAppendNamesGoDefun
    , recAppendDefun
    , recInsertDefun
    , recToChainDefun
    , recToChainGoDefun
    , readFullDefun
    , cStrFillDefun
    , floatCopyDefun
    , cStrLenGoDefun
    , globLastSlashDefun
    , globIsDotDefun
    , globIsDotDotDefun
    , globScanGoDefun
    , globStrLessDefun
    , globSortShiftDefun
    , globSortGoDefun
    , globBuildGoDefun
    , cStrCopyGoDefun
    , epUnwrapDefun "Rt.epNum" 16 RtLayout.tagNumber
    , epUnwrapDefun "Rt.epStr" 8 RtLayout.tagString
    , epUnwrapDefun "Rt.epSymOf" 24 RtLayout.tagSymbol
    , epSymIsDefun
    , epCountDefun
    , epElemDefun
    , epProgDefun
    , epProgGoDefun
    , epChainDefun
    , epPipelineDefun
    , epPipeGoDefun
    , epCmdDefun
    , epArgvGoDefun
    , epRedirsGoDefun
    , epRedirDefun
    , epCountStdinDefun
    , epFreeChainsDefun
    , epFreeCmdsDefun
    , epFreeCmdDefun
    , epFreeArgvDefun
    , epFreeRedirsDefun
    ]


-- ============================ PRIM DEFUNS ============================


{-| `Rt.cons car cdr` — the spike's port of values.zig valCons (C:
zincvm.c:274-294, the P1 FUSED PAIR): ONE 2-element value array, car =
&pair[0], cdr = &pair[1] (interior pointers into the same array — the
scan-time discriminator `cdr == car + sizeof(Value)` in scan.zig is what
makes this shape legal), and the returned Value is tag 4 (VAL_CONS) with
those two addresses as payload words 0 and 1.

The Zig original roots car/cdr across the single alloc; here that is the
`WithRoots` (a QBE no-op by the rooted-frame construction, real on any
backend without it) and the body's evaluation order: the alloc is the first
effect, both stores read the already-rooted param slots, and nothing after
the alloc can move the heap (`rt_vec_store`'s barrier path is malloc-class,
MEASURED in heap.zig dirtyVectorsAdd), so the raw `pair` temp stays valid to
the end of the body.

Binder ids are unique within the defun (params 1, 2; then 3, 4, 5) — the
same convention FromAst's per-defun counter produces.

`consArr` selects the representation: True = (A) ONE pointer (the RawMkValue
carries only the pair head; the cdr word stays ZERO — storeValueWords zeroes
unwritten words — and every cdr reader derives it as pair[1]); False = the
pre-(A) two-word fused pair (the QBE_NOCONSARR=1 hatch, which reproduces the
00cc7da corpus byte-for-byte).
-}
consDefun : Bool -> Defun
consDefun consArr =
    let
        car =
            { id = 1, name = "car" }

        cdr =
            { id = 2, name = "cdr" }

        pair =
            { id = 3, name = "pair" }

        word : Int -> Exp
        word m =
            Lit (LNumber m)

        consWords : List Exp
        consWords =
            if consArr then
                [ Unsafe (RawVecAddr { vec = Var pair.id, index = word 0 }) ]

            else
                [ Unsafe (RawVecAddr { vec = Var pair.id, index = word 0 })
                , Unsafe (RawVecAddr { vec = Var pair.id, index = word 1 })
                ]

        body : Exp
        body =
            Unsafe
                (WithRoots
                    { binders = [ car, cdr ]
                    , body =
                        Let
                            { binders =
                                [ LetBind
                                    { binder = pair
                                    , value = Unsafe (RawAllocVector (word 2))
                                    }
                                , LetBind
                                    { binder = { id = 4, name = "fill-car" }
                                    , value =
                                        Unsafe
                                            (RawVecStore
                                                { vec = Var pair.id
                                                , index = word 0
                                                , value = Var car.id
                                                }
                                            )
                                    }
                                , LetBind
                                    { binder = { id = 5, name = "fill-cdr" }
                                    , value =
                                        Unsafe
                                            (RawVecStore
                                                { vec = Var pair.id
                                                , index = word 1
                                                , value = Var cdr.id
                                                }
                                            )
                                    }
                                ]
                            , body =
                                Unsafe
                                    (RawMkValue
                                        { tag = RtLayout.tagCons
                                        , words = consWords
                                        }
                                    )
                            }
                    }
                )
    in
    { key = "Rt.cons"
    , value =
        Lam
            { params = [ car, cdr ]
            , body = body
            }
    }


{-| `Rt.@p a b` — prims.zig primAtP: `acc.* = values.valCons(vm.gc, a1,
a2)`.  The IDENTICAL fused-pair body as cons (that is the whole of @p), and
the resolution of the spike/plan discrepancy: the compiled call sites
(tuple/record desugars) route here, while effectloop's OWN runPrim("@p")
calls (stat/listdir/glob result building) keep the Zig body — the flip's
deletion list must exclude primAtP, or first rewrite those three host call
sites to values.valCons directly.
-}
atpDefun : Bool -> Defun
atpDefun consArr =
    let
        c =
            consDefun consArr
    in
    { c | key = "Rt.@p" }


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


{-| `Rt.emptylist a` — primEmptylist: (number 0) -> nil; anything else is
error.Halt in Zig (C falls through to unknown) -> the rt_halt seat here
(module header GAPS).
-}
emptylistDefun : Defun
emptylistDefun =
    let
        a =
            p1
    in
    lam "Rt.emptylist" [ a ]
        (iff (and2 (mkBool (tagIs (v a) 0)) (mkBool (cmpW RCeq (wOf (v a)) (n 0))))
            mkNil
            haltV
        )


{-| `Rt.= a b` — primEq's full chain, in order: numbers, strings (len32 +
byte walk), symbols (name walk), booleans (payload32), the Int/Float
promote pair, cons-vs-symbol false, symbol/prim both ways (the name walk),
cons/cons and vector/vector through deepEq, else both-nil.

eqPtrFast (QBE_NOEQPTRFAST=1 turns it off) adds a pointer-identity fast path
to every name-walk arm: two symbols (or a symbol and a prim) whose word-0
name POINTERS are equal are equal, full stop — same pointer is same bytes.
The byte walk (`Rt.symEq`) stays as the exact fallback for the intern-vs-
static case (a runtime-interned symbol has a different pointer than a static
`sym:` data item for the same name, and still compares equal through the
walk).  Zig's primEq reached the same answer with an inlined `std.mem.eql`
byte compare, not a pointer compare; the interned canonical pointers are what
make the pointer compare EXACT here — per-byte walk only where pointers differ.
Strings are DELIBERATELY left out: runtime strings are always copied (never
interned), so two static `str:` items are the only pointer-stable case and a
string fast path would buy almost nothing while complicating the fallback.
-}
eqDefun : Bool -> Bool -> Defun
eqDefun rec eqPtrFast =
    let
        a =
            p1

        bb =
            p2

        -- word 0 of a symbol or prim Value is its name pointer; equal
        -- pointers are equal names (the byte walk is the exact fallback).
        symFast l r =
            if eqPtrFast then
                or2 (mkBool (cmpW RCeq (wOf l) (wOf r)))
                    (callR "Rt.symEq" [ l, r, mkNum (n 0) ])

            else
                callR "Rt.symEq" [ l, r, mkNum (n 0) ]
    in
    lam "Rt.=" [ a, bb ]
        (iff (and2 (mkBool (tagIs (v a) 0)) (mkBool (tagIs (v bb) 0)))
            (mkBool (cmpW RCeq (wOf (v a)) (wOf (v bb))))
            (iff (and2 (mkBool (tagIs (v a) 1)) (mkBool (tagIs (v bb) 1)))
                (and2 (mkBool (cmpW RCeq (lenOf (v a)) (lenOf (v bb))))
                    (callR "Rt.bytesEqGo" [ v a, v bb, mkNum (n 0) ])
                )
                (iff (and2 (mkBool (tagIs (v a) 2)) (mkBool (tagIs (v bb) 2)))
                    (symFast (v a) (v bb))
                    (iff (and2 (mkBool (tagIs (v a) 3)) (mkBool (tagIs (v bb) 3)))
                        (mkBool (cmpW RCeq (w32Of (v a)) (w32Of (v bb))))
                        (iff (and2
                                (or2 (mkBool (tagIs (v a) 0)) (mkBool (tagIs (v a) 12)))
                                (or2 (mkBool (tagIs (v bb) 0)) (mkBool (tagIs (v bb) 12)))
                             )
                            (mkBool (fcmp RFEq (flOf (callR "Rt.asF" [ v a ])) (flOf (callR "Rt.asF" [ v bb ]))))
                            (iff (or2
                                    (and2 (mkBool (tagIs (v a) 4)) (mkBool (tagIs (v bb) 2)))
                                    (and2 (mkBool (tagIs (v a) 2)) (mkBool (tagIs (v bb) 4)))
                                 )
                                falseV
                                (iff (and2 (mkBool (tagIs (v a) 2)) (mkBool (tagIs (v bb) 8)))
                                    (symFast (v a) (v bb))
                                    (iff (and2 (mkBool (tagIs (v a) 8)) (mkBool (tagIs (v bb) 2)))
                                        (symFast (v a) (v bb))
                                        (iff (and2 (mkBool (tagIs (v a) 4)) (mkBool (tagIs (v bb) 4)))
                                            (callR "Rt.deepEq" [ v a, v bb ])
                                            (if rec then
                                                (iff (and2 (mkBool (tagIs (v a) 14)) (mkBool (tagIs (v bb) 14)))
                                                    (callR "Rt.deepEq" [ v a, v bb ])
                                                    (iff (and2 (mkBool (tagIs (v a) 10)) (mkBool (tagIs (v bb) 10)))
                                                        (callR "Rt.deepEq" [ v a, v bb ])
                                                        (and2 (mkBool (tagIs (v a) 5)) (mkBool (tagIs (v bb) 5)))
                                                    )
                                                )

                                             else
                                                (iff (and2 (mkBool (tagIs (v a) 10)) (mkBool (tagIs (v bb) 10)))
                                                    (callR "Rt.deepEq" [ v a, v bb ])
                                                    (and2 (mkBool (tagIs (v a) 5)) (mkBool (tagIs (v bb) 5)))
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


{-| `Rt.c-strlen s` — the i32 len field (lenOf — the word-1 i32 length; booleans keep w32Of).
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


{-| `Rt.absvector n` — primAbsvector: valVector of n elements.  The i32
truncation of n is RawAllocVector's `w`-typed argument (parity with C's
`(int)a.number`); the vector len field stores n as the i64 word (Zig reads
the i32 low half — identical observable).  Elements are UNINITIALIZED on
both sides (valVector zero-fills nothing; neither does RawAllocVector).
-}
absvectorDefun : Defun
absvectorDefun =
    let
        cnt =
            p1

        vec =
            b 4
    in
    lam "Rt.absvector" [ cnt ]
        (lets [ ( vec, Unsafe (RawAllocVector (wOf (v cnt))) ) ]
            (mkVec (v vec) (wOf (v cnt)))
        )


{-| `Rt.address-> v i x` — primAddressSet: the barrier store at v.data[i];
returns v.  (i's 64-bit payload feeds the `w`-typed index argument — the
32-bit truncation both sides share.)
-}
addressSetDefun : Defun
addressSetDefun =
    let
        vec =
            p1

        i =
            p2

        x =
            p3
    in
    lam "Rt.address->" [ vec, i, x ]
        (lets [ ( b 4, Unsafe (RawVecStore { vec = wOf (v vec), index = wOf (v i), value = v x }) ) ]
            (v vec)
        )


{-| `Rt.<-address v i` — primAddressGet: v.data[i] (no bounds guard — the
parity crash).
-}
addressGetDefun : Defun
addressGetDefun =
    let
        vec =
            p1

        i =
            p2
    in
    lam "Rt.<-address" [ vec, i ]
        (Unsafe (RawVecLoad { vec = wOf (v vec), index = wOf (v i) }))


{-| `Rt.assoc k l` — primAssoc: assocGo's walk (deepEq on keys).  Non-list
inputs throw in Zig (throwShen) — the halt arm here (module header GAPS).
-}
assocDefun : Defun
assocDefun =
    let
        k =
            p1

        l =
            p2
    in
    lam "Rt.assoc" [ k, l ]
        (callR "Rt.assocGo" [ v k, v l ])


{-| `Rt.snd x` — primSnd: the cdr (no nil guard — the parity crash reads
nil's zero payload as a pointer and faults, BOTH arms).
-}
sndDefun : Defun
sndDefun =
    let
        x =
            p1
    in
    lam "Rt.snd" [ x ] (cdrV (v x))


primDefuns : Bool -> Bool -> Bool -> List Defun
primDefuns consArr rec eqPtrFast =
    [ consDefun consArr
    , atpDefun consArr
    , conDefun
    , conFillDefun
    , closureDefun
    , closureFillDefun
    , emptylistDefun
    , eqDefun rec eqPtrFast
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
    , absvectorDefun
    , addressSetDefun
    , addressGetDefun
    , assocDefun
    , sndDefun
    , writeByteDefun
    , readByteDefun
    , openDefun
    , closeDefun
    , internDefun
    , valueDefun
    , strDefun
    , getpidDefun
    , getcwdDefun
    , cdDefun
    , getenvDefun
    , setenvDefun
    , globDefun
    , execPlanDefun
    ]
