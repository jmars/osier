module Mid.Qbe.WordArmProbe exposing (Module(..), modules, name, defun)

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
no `RawAllocN`.  `Rt.allocRaw` is reached through the emitter's own seat call
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


modules : List Module
modules =
    [ Str, Payload, Len, TagHeap, TagNil, TagBool ]


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
