module Symeq exposing (main)

{-| THE SYMBOL-EQUALITY FAST PATH (stage-3 zigretire) — the focused,
failure-is-the-fast-path-being-wrong instrument for `Rt.=`'s pointer-identity
short-circuit (QBE_NOEQPTRFAST=1 is its hatch).  `main` is 1 iff every probe
holds; a WRONG fast path makes at least one probe fail and `main` becomes 0.

WHAT IT COVERS (the three arms changed in Rt.=`):
  * symbol/symbol, same pointer  — case dispatch on a nullary constructor
    lowers to `Rt.=` on two BARE symbol Values (the literal `sym:` item vs the
    scrutinee's head symbol, both tag 2, same name -> same pointer).  The fast
    path HITS: `match Red` must be 1, not fall through.  An always-True fast
    path makes `match Green` answer 1 (the Red arm matches first) -> RED.
  * symbol/symbol, different names — `match Green` first misses Red ("Green"
    vs "Red", pointers differ) and the exact byte walk must return False so the
    match falls to the Green arm.  An always-True fast path breaks this -> RED.
  * symbol/symbol, same name DIFFERENT pointers (intern vs static) — `Record.
    remove "x"` lowers to `Prelude.removeFieldImpl`, whose trusted body does
    `k == intern "x"`: `k` is the STATIC `sym:"x"` key, `intern "x"` is a
    runtime-interned symbol with a DIFFERENT pointer.  The byte-walk FALLBACK
    must return True (same name) or the outer x is not removed and `r.x` reads
    1 instead of 2.  A pointer-only fast path (no fallback) breaks this -> RED.
  * symbol/prim and prim/symbol — UNREACHABLE from compiled Elm (no surface
    spelling builds a prim Value), so they are NOT executable here; their
    soundness rests on the same word-0-name-pointer layout argument, and the
    emission-level TestMain row asserts the fast path is a short-circuit OR
    with the `Rt.symEq` fallback on every name-walk arm.

(The `==`-on-nullary-constructors spelling does NOT reach these arms — a
nullary constructor VALUE is a tag-10 vector `[sym:name]`, so `Red == Green`
hits `Rt.=`'s vector/vector -> deepEq arm, not symbol/symbol.  Case dispatch
and the interned field-name compare are the two REACHABLE routes.)
-}


type Color
    = Red
    | Green
    | Blue


match : Color -> Int
match c =
    case c of
        Red ->
            1

        Green ->
            2

        Blue ->
            3


removeProbe : Int
removeProbe =
    let
        dup =
            { x = 1, x = 2 }

        r =
            Record.remove "x" dup
    in
    r.x


main : Int
main =
    if match Red == 1 && match Green == 2 && match Blue == 3 && removeProbe == 2 then
        1

    else
        0
