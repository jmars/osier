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
post-alloc move of the string is handled.  Returns bufN.  Non-allocating.
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
                (callR "Rt.cStrFill" [ v bufN, v str, mkNum (iadd (wOf (v i)) (n 1)) ])
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
the slot's Value out of the table (a stable page_allocator slot), with the
valSymbol bare-symbol fallback when the name is absent.  The result is whatever
the host registered (a stream fd-int Value, or the *argv* cons list); the
host-IO soundness hole for *argv* is unchanged by this port (the refusal stays
in Lower's nurseryHostPrims under QBE_MIDGC=1).
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
            (iff (mkBool (cmpW RCne (v slotPtr) (n 0)))
                (Unsafe (RawVecLoad { vec = v slotPtr, index = n 0 }))
                (lets
                    [ ( b 5, callW "rt_sym_intern" [ v namePtr, n (-1) ] ) ]
                    (Unsafe (RawMkValue { tag = RtLayout.tagSymbol, words = [ v (b 5) ] }))
                )
            )
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
String.fromFloat.  Allocates -> framed.
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
    ]
