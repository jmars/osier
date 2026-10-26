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

import Mid.Ir exposing (Defun, Exp(..), Lit(..), UnsafeNode(..))
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


modules : List Module
modules =
    [ Str, Payload, Len, TagHeap, TagNil, TagBool, Call ]


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

        _ ->
            [ defun m ]


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
