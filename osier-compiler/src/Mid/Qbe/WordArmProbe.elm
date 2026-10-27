module Mid.Qbe.WordArmProbe exposing (Module(..), modules, name, defun, defuns, arity)

{-| Mid.Qbe.WordArmProbe — THE WORD ARM'S BEHAVIOUR PROBES, in ONE place.

WHY THIS MODULE EXISTS (perf VR3b3 FIX F2).  Under `QBE_VALREP=word` no program
compiled through `run.js` can run: the runtime is always injected, so the
emitted set always reaches `Rt.main`, and the runtime's first call stops the arm
at AREA 6.  That means the emitter's heap side — the tag writes, the payload
reads, the kind tests, the string cell — has NO executable oracle on the arm it
targets, and text pins cannot replace one: on this arm a text pin asserts the
shape the author WROTE, so it cannot see a wrong shape that is one instruction
away.  MEASURED: five such bugs shipped past every pin in the first commit of
this unit, and a sixth (a boolean `tagis` fold) past the second.

So each probe below is a defun the emitter can lower under the word arm with NO
runtime key in its reachable set, and `tools/qbe/word-arm-probe.sh` assembles,
links and RUNS the emitted module against the runtime seats' contract.  TWO
consumers, ONE definition:

  * `Main.elm` emits the module for `QBE_WORDARM_PROBE=<name>` (the CLI route
    the probe script uses);
  * `TestMain` pins the emitted text of the same defun on BOTH arms.

A probe must stay RUNTIME-FREE: no `RawCall`, no `RawCallAgg`, no `RawCallRaw`,
no `RawAllocN`.  A probe MAY however contain a CALL to another PROBE defun (the
`call` probe does): that is `App` with a `GRef` head, the emitter's own
closure-ABI call, and it is exactly the construct AREA 6 ported — the callee is
a surface defun of the same module, not a runtime key, so the module stays
runtime-free.  `Rt.allocRaw` is reached through the emitter's own seat call
(`RawAllocRaw`/`midGcAllocSeat`), which is a plain `Call` the module emits
itself — the probe script stubs that seat to the CONTRACT `runtime.mid` states.
-}

import Mid.Ir exposing (Defun, Exp(..), LetBinder(..), Lit(..), RawBinOp(..), UnsafeNode(..))
import Mid.RtLayout as RtLayout


{-| The probe set.  The constructor name IS the `QBE_WORDARM_PROBE` value. -}
type Module
    = Str
    | Payload
    | Len
    | TagHeap
    | TagNil
    | TagBool
    | Call
    | Vec
    | VecLen
    | Rec
    | Sym


modules : List Module
modules =
    [ Str, Payload, Len, TagHeap, TagNil, TagBool, Call, Vec, VecLen, Rec, Sym ]


name : Module -> String
name m =
    case m of
        Str ->
            "str"

        Payload ->
            "payload"

        Len ->
            "len"

        TagHeap ->
            "tagheap"

        TagNil ->
            "tagnil"

        TagBool ->
            "tagbool"

        Call ->
            "call"

        Vec ->
            "vec"

        VecLen ->
            "veclen"

        Rec ->
            "rec"

        Sym ->
            "sym"


{-| The probe's DEFUN KEY — what `QBE_WORDARM_PROBE` compiles as its entry. -}
defun : Module -> Defun
defun m =
    case m of
        Str ->
            strProbe

        Payload ->
            payloadProbe

        Len ->
            lenProbe

        TagHeap ->
            tagProbe

        TagNil ->
            nilTagProbe

        TagBool ->
            boolTagProbe

        Call ->
            callProbe

        Vec ->
            vecProbe

        VecLen ->
            vecLenProbe

        Rec ->
            recProbe

        Sym ->
            symProbe


{-| A defun's declared arity — what the probe module's arity table must carry,
or `lowerApp` treats the call as under-applied and routes it through the
runtime's generic apply instead of the direct call this probe exists to run.
-}
arity : Defun -> Int
arity d =
    case d.value of
        Lam lambda ->
            List.length lambda.params

        _ ->
            0


{-| EVERY defun a probe's module needs, ENTRY FIRST (AREA 6's `call` probe is
the first probe that is more than one defun: a CALL needs a callee).
-}
defuns : Module -> List Defun
defuns m =
    case m of
        Call ->
            [ callProbe, callCallee ]

        Rec ->
            -- THE RECORD LAYOUT's four reads, all reachable from the entry:
            -- `lowerWith` emits only the REACHABLE set, so a defun the entry
            -- does not call would not be in the module the harness links.
            [ recProbe, recCountProbe, recElemProbe, recNamesBaseProbe, recNameProbe ]

        Sym ->
            [ symProbe, symTagProbe ]

        _ ->
            [ defun m ]


{-| AREA 3's ELEMENT BASE (perf word-arm-area3rt, added by the review's BLOCKER
1): `\v i -> vecload(vecbody(v), i)`.

WHY IT EXISTS.  `word-arm-diff` compiles whole PROGRAMS, and under the word arm a
program cannot construct a heap vector yet (an arg-taking entry needs a `Lam`,
which the surface lane refuses) — so the diff row exercises the boot path and
literal cells and NOTHING ELSE.  MEASURED by the reviewer: flipping `wordVecBody`'s
heap arm from `+heapHeaderBytes` to `+heapHeaderOffset` — a 32-byte-wrong element
base for EVERY heap object — left BOTH the diff row and this probe set GREEN.  No
oracle in the tree could see a wrong element base.

This probe is the cheapest instrument that can: the harness hand-builds a code-10
block (the same way probe B hand-builds a cons) and drives an element read
through `vecbody`, so the BASE is what is being measured — index 0 catches a wrong
base, indices 1 and 2 catch a wrong STRIDE.
-}
vecProbe : Defun
vecProbe =
    { key = "Vc.f"
    , value =
        Lam
            { params = [ { id = 0, name = "v" }, { id = 1, name = "i" } ]
            , body =
                Unsafe
                    (RawVecLoad
                        { vec = Unsafe (RawVecBody { value = Var 0 })
                        -- the INDEX is a raw word, so the probe takes it as a
                        -- fixnum Value and unwraps it — which also exercises
                        -- payload-of-fixnum on the way in.
                        , index = Unsafe (RawPayload { value = Var 1, word = 0 })
                        }
                    )
            }
    }


{-| AREA 3's ELEMENT COUNT (perf word-arm-area3rt, the review's BLOCKER 2):
`\v -> mknum(veclen(v))`.

WHY IT EXISTS: `veclen` is the header-count reader — the one reader that makes a
word-arm VECTOR's length correct at all — and a text pin cannot see whether it
reads the header or the body (both are one load away).  The harness builds a
code-10 block whose header count is 3 and whose body is three elements, so a
reader that answered from the BODY would return element 0's value instead.
-}
vecLenProbe : Defun
vecLenProbe =
    { key = "Vl.f"
    , value =
        Lam
            { params = [ { id = 0, name = "v" } ]
            , body = Unsafe (RawMkValue { tag = RtLayout.tagNumber, words = [ Unsafe (RawVecLen { value = Var 0 }) ] })
            }
    }


{-| AREA A + D: `\x -> "hi"`.  A word-arm string literal is a HEAP OBJECT whose
body is [byte pointer, length]; on the val arm it is the same two words inside a
40-byte Value record.  Running it proves the seat's return is consumed as a BODY
(the header 16 bytes BEFORE it), that body unit 0 is the byte pointer, and that
body unit `lenFieldWord` is the length.
-}
strProbe : Defun
strProbe =
    { key = "St.f"
    , value =
        Lam
            { params = [ { id = 0, name = "x" } ]
            , body = Lit (LString "hi")
            }
    }


{-| AREA B: `\x -> mknum(payload(x, 0))`.  A payload read is a SHAPE, not an
offset: a fixnum's payload is the word shifted DOWN, a heap object's is a body
unit, and anything else REFUSES.
-}
payloadProbe : Defun
payloadProbe =
    { key = "Pl.f"
    , value =
        Lam
            { params = [ { id = 0, name = "x" } ]
            , body =
                Unsafe
                    (RawMkValue
                        { tag = RtLayout.tagNumber
                        , words = [ Unsafe (RawPayload { value = Var 0, word = 0 }) ]
                        }
                    )
            }
    }


{-| AREA D: `\s -> mknum(payload32(s, 1))` — the i32 low half of body unit
`lenFieldWord`, i.e. where a word-arm string keeps its length.
-}
lenProbe : Defun
lenProbe =
    { key = "Ln.f"
    , value =
        Lam
            { params = [ { id = 0, name = "s" } ]
            , body =
                Unsafe
                    (RawMkValue
                        { tag = RtLayout.tagNumber
                        , words = [ Unsafe (RawPayload32 { value = Var 0, word = RtLayout.lenFieldWord }) ]
                        }
                    )
            }
    }


{-| AREA C: `\v -> mkbool(tagis(v, 4))` — a CONS test.  The tag must be the
shared heap tag AND the header's kind code must be 4, and a header whose code is
0 (NO CODE, a val-arm header) must REFUSE by name.
-}
tagProbe : Defun
tagProbe =
    { key = "Tg.f"
    , value =
        Lam
            { params = [ { id = 0, name = "v" } ]
            , body =
                Unsafe
                    (RawMkValue
                        { tag = RtLayout.tagBoolean
                        , words = [ Unsafe (RawTagIs { value = Var 0, tag = RtLayout.tagCons }) ]
                        }
                    )
            }
    }


{-| AREA C: `\v -> mkbool(tagis(v, 5))` — a NIL test.  Nil is VALTAG 5 and word
IMMEDIATE 2, so the compare must be against the instance's field, never the
valtag.
-}
nilTagProbe : Defun
nilTagProbe =
    { key = "Nt.f"
    , value =
        Lam
            { params = [ { id = 0, name = "v" } ]
            , body =
                Unsafe
                    (RawMkValue
                        { tag = RtLayout.tagBoolean
                        , words = [ Unsafe (RawTagIs { value = Var 0, tag = RtLayout.tagNil }) ]
                        }
                    )
            }
    }


{-| AREA C, THE TWO-IMMEDIATE FOLD (the probe BLOCKER 2 needed): `\v ->
mkbool(tagis(v, 3))`.  A boolean is ONE valtag with TWO word immediates, so this
is the only `tagis` that emits an OR of two compares — and the only one where the
tag temp and the compare result can be confused.  It must answer TRUE for BOTH
`true` (...011) and `false` (...100), and FALSE for nil: an implementation that
folds the compares into the tag temp answers FALSE for `false`, which is what
shipped before the fix and what this probe would have caught.
-}
boolTagProbe : Defun
boolTagProbe =
    { key = "Bt.f"
    , value =
        Lam
            { params = [ { id = 0, name = "v" } ]
            , body =
                Unsafe
                    (RawMkValue
                        { tag = RtLayout.tagBoolean
                        , words = [ Unsafe (RawTagIs { value = Var 0, tag = RtLayout.tagBoolean }) ]
                        }
                    )
            }
    }

{-| AREA 6 — THE CALL ABI, EXECUTED.  `\x -> Ca.g(x) + nothing`: the body is a
saturated `App` to another SURFACE defun of the same module, which is the ONE
construct AREA 6 ported (`lowerApp` -> `directCall` -> `argOperands`).  What the
probe proves by RUNNING:

  * the ARGUMENT crosses as the VALUE WORD in an `l` register (the word arm's
    `:val` is 8 bytes), not as a pointer to the caller's slot — a pointer would
    make the callee's `storel %a0, %s1` prologue store the ADDRESS;
  * the callee STORES that register into its own slot (`paramWords`) and reads
    it back;
  * the RESULT is the same `:val` class at 8 bytes — one word in a register, no
    sret block and no `:ret` kind word (`closureRetClass` is one answer).

`Ca.g` returns `x` unchanged, so the probe is an identity through a real call:
the harness passes a tagged fixnum and checks the SAME word comes back, plus the
arithmetic-free property that no slot address leaked (a leaked address is not
`n * 8` and the check would see it).
-}
callProbe : Defun
callProbe =
    { key = "Ca.f"
    , value =
        Lam
            { params = [ { id = 0, name = "x" } ]
            , body =
                -- A NESTED call on purpose: the INNER `Ca.g(x)` is an ordinary
                -- call (argOperands + a result blit into a slot) and the OUTER
                -- one is in TAIL position (a real `tcall`, whose C4 class check
                -- is the strictest form of the same ABI).  One probe, both
                -- shapes.
                App
                    { fn = GRef { key = "Ca.g", force = False }
                    , args =
                        [ App
                            { fn = GRef { key = "Ca.g", force = False }
                            , args = [ Var 0 ]
                            }
                        ]
                    }
            }
    }


{-| The callee: `\x -> x`.  Two things matter here and both are the ABI: its
parameter arrives as a WORD (so its prologue stores the register) and its body
copies that word to the result slot.
-}
callCallee : Defun
callCallee =
    { key = "Ca.g"
    , value =
        Lam
            { params = [ { id = 0, name = "x" } ]
            , body = Var 0
            }
    }


{-| THE RECORD LAYOUT (perf word-arm-records R0) — the FALSIFIABLE FIRST STEP
of the record family's port, taken BEFORE a line of record lowering exists.

WHY A HAND-BUILT BLOCK.  A word-arm record is ONE code-14 heap block whose body
is `[data_0 .. data_{n-1} | namesBase]` and whose header count is `n + 1` — the
field NAMES array base is the LAST body word, a raw pointer, deliberately not a
Value.  NAMES-LAST IS LOAD-BEARING: it is what keeps `vecload(vecbody(rec), i)`
meaning `data[i]` on BOTH arms, so `recordAccessBody`'s positional read needs no
arm fork at all.  The price is an OFF-BY-ONE the layout owns: `veclen(rec)` is
`n + 1`, so a bare `veclen` bound reads the names word as a value, and on a
write it runs off the end of the block into the NEXT heap block.

The four reads below are the design's own spelling, one per line, and the
harness drives them against a block it builds BY HAND (no compiler output
involved), so the layout is validated before anything depends on it:

    reclen(rec)   = veclen(rec) - 1
    data[i]       = vecload(vecbody(rec), i)
    namesBase     = wload(vecbody(rec), veclen(rec) - 1)      -- the LAST body word
    name_i        = wload(namesBase, i)                        -- a raw char* word

`wload` (NOT `vecload`) on the names side is not a stylistic choice: the names
array holds RAW POINTERS, so the read must produce a raw word.  `vecload` blits
a `val` (8 bytes here) and would hand the pointer to the next reader as a
FIXNUM-shaped Value, whose `payload` is the pointer shifted down by 3 — the
mixed-representation read this arm exists to prevent.  `mknum(..)` at the
boundary is the established pointer-wrap idiom (`vecbody` of a `mknum(ptr)` IS
the pointer on both arms), which is what lets the runtime's `symEq` compare
`name_i` against a field symbol with NO new prim.

WHAT THIS PROBE CANNOT SEE, stated because the arc's rule is that a row states
its own reach: the runtime's PRINTER (`Rt.pvRec`/`pvV`) cannot run in a probe
module (it is not runtime-free — it needs the byte-stream seat and `numText`),
so the byte-comparison of the rendered record is done by the HARNESS in the
printer's format, from what these four reads return.  The printer's own
word-arm splice is exercised by the `word-arm-diff` rows once a program can
BUILD a record (R2/R3), and `symEq`'s byte walk is unchanged code.
-}
recProbe : Defun
recProbe =
    { key = "Rc.f"
    , value =
        Lam
            { params = [ { id = 0, name = "v" }, { id = 1, name = "i" } ]
            , body =
                -- ONE evaluation of each read, so every defun is REACHABLE
                -- from the entry and therefore EMITTED.  The results are
                -- deliberately unused: the harness calls each defun directly
                -- (they are globalized with the entry), and what this body
                -- adds is reachability plus one execution of each.
                Let
                    { binders =
                        [ LetBind { binder = { id = 2, name = "n" }, value = recCall "Rc.n" [ Var 0 ] }
                        , LetBind { binder = { id = 3, name = "b" }, value = recCall "Rc.b" [ Var 0 ] }
                        , LetBind { binder = { id = 4, name = "e" }, value = recCall "Rc.e" [ Var 0, Var 1 ] }
                        ]
                    , body = recCall "Rc.k" [ Var 0, Var 1 ]
                    }
            }
    }


recCall : String -> List Exp -> Exp
recCall key args =
    App { fn = GRef { key = key, force = False }, args = args }


{-| THE RECORD'S LENGTH: `mknum(veclen(v) - 1)`.

This is the design's `reclen` word splice, spelled the way every runtime site
will spell it.  The `- 1` is the whole point of the probe: the header count is
`n + 1` because the names word is a body word, and a length reader that answered
`3` for a two-field record is the off-by-one that corrupts the next block.
-}
recCountProbe : Defun
recCountProbe =
    { key = "Rc.n"
    , value =
        Lam
            { params = [ { id = 0, name = "v" } ]
            , body = mknumWord recLenWord
            }
    }


{-| `veclen(v) - 1` as a RAW WORD — the one spelling of a record's length.
Every defun that uses it takes the record as parameter id 0 (`v`), which is
what `Var 0` names here; a probe that renamed its record parameter would have
to rename this too, and the harness's checks are what would fail.
-}
recLenWord : Exp
recLenWord =
    Unsafe
        (RawBin
            { op = RSub
            , a = Unsafe (RawVecLen { value = Var 0 })
            , b = Lit (LNumber 1)
            }
        )


{-| THE DATA SIDE, UNCHANGED ON BOTH ARMS: `vecload(vecbody(v), i)` is
`data[i]` — the positional read `recordAccessBody` already emits, which is why
that site needs no fork.
-}
recElemProbe : Defun
recElemProbe =
    { key = "Rc.e"
    , value =
        Lam
            { params = [ { id = 0, name = "v" }, { id = 1, name = "i" } ]
            , body =
                Unsafe
                    (RawVecLoad
                        { vec = Unsafe (RawVecBody { value = Var 0 })
                        , index = Unsafe (RawPayload { value = Var 1, word = 0 })
                        }
                    )
            }
    }


{-| THE NAMES BASE: the LAST body word, `wload(vecbody(v), veclen(v) - 1)`,
boxed as `mknum(ptr)` so it can cross the `:val` ABI.
-}
recNamesBaseProbe : Defun
recNamesBaseProbe =
    { key = "Rc.b"
    , value =
        Lam
            { params = [ { id = 0, name = "v" } ]
            , body =
                mknumWord
                    (Unsafe
                        (RawWordLoad
                            { ptr = Unsafe (RawVecBody { value = Var 0 })
                            , index = recLenWord
                            }
                        )
                    )
            }
    }


{-| ONE NAME: `wload(namesBase, i)` — a raw char* word, boxed with the SAME
`mknum` wrap, which is what `symEq`'s `payload(·, 0)` reads back unchanged.
-}
recNameProbe : Defun
recNameProbe =
    { key = "Rc.k"
    , value =
        Lam
            { params = [ { id = 0, name = "v" }, { id = 1, name = "i" } ]
            , body =
                mknumWord
                    (Unsafe
                        (RawWordLoad
                            { ptr =
                                Unsafe
                                    (RawWordLoad
                                        { ptr = Unsafe (RawVecBody { value = Var 0 })
                                        , index = recLenWord
                                        }
                                    )
                            , index = Unsafe (RawPayload { value = Var 1, word = 0 })
                            }
                        )
                    )
            }
    }


{-| `mknum(word)` — the fixnum box (and, for a dynamic word, the round-trip
range check `storeWordCell` emits).
-}
mknumWord : Exp -> Exp
mknumWord w =
    Unsafe (RawMkValue { tag = RtLayout.tagNumber, words = [ w ] })


{-| THE SYMBOL CELL (perf word-arm-records R1) — the record family's dependency:
a record's field NAMES are symbols, and a word-arm symbol is a HEAP BLOCK (a
word-arm symbol cannot live in `.data`, which is why the record's names array
holds raw name POINTERS and a symbol Value is materialised only where a symbol
is genuinely in a Value position).

`Sym.f` RETURNS the emitted cell, so the harness inspects what the emitter's own
`storeWordCell` path built: code 2 (the constructor), a raw body
`[byte pointer, length]`, and the value word tagged `...001`.  `Sym.g` is the
emitter's own word-arm tag test, fed the cell and two decoys by the harness —
the code is the ONLY thing that distinguishes a symbol from a string on this
arm, so a "symbol" allocated through the string seat (code 1) has to fail here.

WHY THE CELL IS EMITTED RATHER THAN HAND-BUILT (unlike the `rec` probe): the
construction IS the unit.  The harness still supplies the SEAT (`Rt.allocSym`)
the way it supplies `Rt.allocRaw`, to the contract `runtime.mid` states —
`gcAlloc` writes the 2-word header including the KIND CODE and returns
`mknum(body)`.
-}
symProbe : Defun
symProbe =
    { key = "Sy.f"
    , value =
        Lam
            { params = [ { id = 0, name = "x" } ]
            , body =
                -- ONE call to `Sy.g` so it is REACHABLE (and therefore
                -- emitted); the ENTRY returns the cell itself, which is what
                -- the harness inspects.
                Let
                    { binders =
                        [ LetBind
                            { binder = { id = 1, name = "t" }
                            , value = App { fn = GRef { key = "Sy.g", force = False }, args = [ Lit (LSymbol "x") ] }
                            }
                        ]
                    , body = Lit (LSymbol "x")
                    }
            }
    }


{-| ` -> mkbool(tagis(v, tagSymbol))` — the emitter's word-arm tag test, so the
harness asks the READER (not a C re-implementation) whether the cell it built is
a symbol.
-}
symTagProbe : Defun
symTagProbe =
    { key = "Sy.g"
    , value =
        Lam
            { params = [ { id = 0, name = "v" } ]
            , body =
                Unsafe
                    (RawMkValue
                        { tag = RtLayout.tagBoolean
                        , words = [ Unsafe (RawTagIs { value = Var 0, tag = RtLayout.tagSymbol }) ]
                        }
                    )
            }
    }
