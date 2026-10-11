module Mid.RtPrims exposing (consDefun)

-- Mid.RtPrims — the PRIM BODIES of the Mid-written runtime (handoff
-- osier-consspike, TRACK 2 step 4: ONE prim end-to-end).
--
-- Each body is a Mid.Ir tree built EXACTLY as values.zig builds the same
-- Value, transcribed node for node — these are PORTS of the Zig runtime's
-- constructors, not re-designs, because the whole premise of the Mid runtime
-- is that the QBE arm and the Zig arm agree BY CONSTRUCTION and the fuzz
-- differential (tools/qbe/consdiff.sh) only has to prove the LOWERING
-- faithful.  When step 5 ports the remaining ~39 pure prims they land here,
-- one defun per prim plus the values.zig helpers they share as Rt.* defuns.
--
-- DISCIPLINE (enforced by Mid.Qbe.Lower's register-class split, loud on
-- violation): word-producing raw nodes bind to raw TEMPS, never frame slots;
-- a raw array address never crosses a safepoint; an allocation's fill
-- completes before the next one.  The ONE safepoint in cons is the
-- RawAllocVector itself, and WithRoots names the values that must survive
-- it — which the QBE backend roots by construction (the pooled frame), and a
-- future backend roots from this node.

import Mid.Ir exposing (Binder, Defun, Exp(..), LetBinder(..), Lit(..), UnsafeNode(..))


{-| `Rt.cons car cdr` — the port of values.zig `valCons` (C: zincvm.c:274-294,
the P1 FUSED PAIR): ONE 2-element value array, car = &pair[0], cdr = &pair[1]
(interior pointers into the same array — the scan-time discriminator
`cdr == car + sizeof(Value)` in scan.zig is what makes this shape legal), and
the returned Value is tag 4 (VAL_CONS) with those two addresses as payload
words 0 and 1.

The Zig original roots car/cdr across the single alloc; here that is the
`WithRoots` (a QBE no-op by the rooted-frame construction, real on any
backend without it) and the body's evaluation order: the alloc is the first
effect, both stores read the already-rooted param slots, and nothing after
the alloc can move the heap (`rt_vec_store`'s barrier path is malloc-class,
MEASURED in heap.zig dirtyVectorsAdd), so the raw `pair` temp stays valid to
the end of the body.

Binder ids are unique within the defun (params 1, 2; then 3, 4, 5) — the
same convention FromAst's per-defun counter produces.
-}
consDefun : Defun
consDefun =
    let
        car : Binder
        car =
            { id = 1, name = "car" }

        cdr : Binder
        cdr =
            { id = 2, name = "cdr" }

        pair : Binder
        pair =
            { id = 3, name = "pair" }

        word : Int -> Exp
        word n =
            Lit (LNumber n)

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
                                    { tag = 4
                                    , words =
                                        [ Unsafe (RawVecAddr { vec = Var pair.id, index = word 0 })
                                        , Unsafe (RawVecAddr { vec = Var pair.id, index = word 1 })
                                        ]
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
