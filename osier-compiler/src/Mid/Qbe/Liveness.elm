module Mid.Qbe.Liveness exposing (Analysis, Site, allSitesEmpty, analyze, frameFree)

-- Mid.Qbe.Liveness — THE SLOT-LIVENESS PRE-PASS (perf P5; the analysis P8's
-- per-safepoint descriptor maps are built from, and the only consumer of it
-- today is P5's degenerate predicate).
--
-- WHAT IT ANSWERS: for ONE defun's EMITTED blocks, for every CALL that can
-- reach a GC safepoint, WHICH FRAME SLOTS hold a live composite across it.
-- "Live across" is the ordinary backward liveness dataflow over the block
-- CFG (a use reachable before a redefinition on SOME path), run to a
-- FIXPOINT — not a forward scan — because the paths that matter are exactly
-- the ones a forward walk misses: a `case`/`if` arm that rejoins, an error
-- arm that jumps straight to @ret, and the self-tail loop's back edge
-- (Lower's `recur` compiles to `jmp @body`).
--
-- THE FRAME-SLOT MODEL, read off the emitter (Mid.Qbe.Lower): a slot address
-- is a temp holding `f + k` (slotTmp i = "s<i>" = f + 40*i, and every
-- interior address — a payload word, a staging block, a capture block — is a
-- further `Add`/constant off one of those), and a slot's 40 bytes are
-- written either by a `blit` of a whole Value or WORD BY WORD (`Store` the
-- tag at +0, the payload at +8/+16/...).  So a slot is
--   DEFINED by any store/blit into the byte range [40*i, 40*i+40),
--   USED    by any load/blit out of that range, by a `jnz`/`ret` based at it,
--           and by any CALL it is passed to as an address.
--
-- WHY A CALL ARGUMENT IS BOTH A USE AND AN ESCAPE: a Value argument crosses
-- as a POINTER to the caller's slot (VR1's convention), so the callee reads
-- that slot during the call — the value is live at the safepoint, and the
-- address has left this defun.  `escapes` records that, and a frame address
-- STORED into memory, which is the H2 shape: an aggregate result living in a
-- slot whose address leaked into a malloc'd cell or into the root registry
-- would be rooted by the frame the defun no longer has.
--
-- SOUNDNESS DIRECTION: every set here is an OVER-approximation of "holds a
-- live composite" (a slot holding a raw word is reported live; an
-- unresolvable address is reported as an escape).  The predicate
-- `frameFree` is therefore conservative in the only direction that is safe:
-- it says True only when NOTHING can be live across a safepoint.

import Dict exposing (Dict)
import Mid.Qbe.Il as Il exposing (Arg(..), BinOp(..), Block, CallArg(..), Inst(..), Jump(..), Ty(..))
import Mid.RtLayout as RtLayout
import Set exposing (Set)


vs : Int
vs =
    RtLayout.valSizeBytes


{-| Mid.Qbe.Lower's slot-address temp naming: slot i's address is the temp
`s<i>`.  The ANALYSIS cannot discover these from the body, because the
prologue that defines them (`%s<i> =l add %f, 40*i`, Mid.Qbe.Lower's
`withPrologue`) is emitted AFTER the body walk — so the map is SEEDED from
the defun's slot count instead.  An address the body derives off one of them
(`%d8 =l add %s3, 8`) then resolves transitively.
-}
slotTmp : Int -> String
slotTmp i =
    "s" ++ String.fromInt i


{-| One allocation-capable call site: which frame slots hold a live composite
across it.  `pc` is the instruction index within its block.  P8 will key its
descriptor's per-site map off this list; P5 reads only whether the sets are
empty.
-}
type alias Site =
    { block : String
    , pc : Int
    , live : Set Int
    }


type alias Analysis =
    { sites : List Site
    , escapes : List String
    }


{-| The degenerate predicate P5 consumes: no site has a non-empty live set AND
no frame address left the defun.
-}
frameFree : Analysis -> Bool
frameFree a =
    List.isEmpty a.escapes && allSitesEmpty a


allSitesEmpty : Analysis -> Bool
allSitesEmpty a =
    List.all (\s -> Set.isEmpty s.live) a.sites


type alias Ctx =
    { offs : Dict String Int
    , bad : Set String
    , retBytes : Int
    , noCollect : Set String
    }


{-| `noCollect` is the set of CALL SYMBOLS whose execution cannot reach a GC
safepoint (Mid.Rt.allocating's complement over the Rt program, plus the
non-collecting libc entries the emitter names).  A call to anything else —
including a call through a TEMP (an indirect call, whose target is unknown) —
is treated as a safepoint.
-}
analyze : { retBytes : Int, nslots : Int, noCollect : Set String } -> List Block -> Analysis
analyze opts blocks =
    let
        ( offsBody, bad ) =
            addressOffsets blocks

        offs =
            List.foldl (\i d -> Dict.insert (slotTmp i) (vs * i) d)
                offsBody
                (List.range 0 (opts.nslots - 1))

        ctx =
            { offs = offs
            , bad = bad
            , retBytes = opts.retBytes
            , noCollect = opts.noCollect
            }

        bodies =
            List.foldl (\b acc -> Dict.insert b.label b.body acc) Dict.empty blocks

        succs =
            List.foldl (\b acc -> Dict.insert b.label (successors blocks b) acc) Dict.empty blocks

        ends =
            List.foldl (\b acc -> Dict.insert b.label (jumpUse ctx b.jump) acc) Dict.empty blocks

        -- Monotone growth makes the fixpoint terminate; the bound guards
        -- against a defect in THIS module, and running out of it denies
        -- frame-freedom rather than guessing.
        fuel =
            4 * (List.length blocks + 1) + 64
    in
    case fixpoint fuel ctx bodies succs ends of
        Nothing ->
            { sites = [], escapes = [ "liveness did not converge" ] }

        Just liveIn ->
            { sites =
                List.concatMap
                    (\b ->
                        sitesInBlock ctx b.label
                            (blockLiveOut ctx succs ends liveIn b.label)
                            b.body
                    )
                    blocks
            , escapes = escapesOf ctx blocks
            }


-- ============================ FIXPOINT ============================


fixpoint : Int -> Ctx -> Dict String (List Inst) -> Dict String (List String) -> Dict String (Set Int) -> Maybe (Dict String (Set Int))
fixpoint fuel ctx bodies succs ends =
    let
        go f live =
            if f <= 0 then
                Nothing

            else
                let
                    next =
                        Dict.map (\lbl body -> blockLiveIn ctx body (blockLiveOut ctx succs ends live lbl)) bodies
                in
                if next == live then
                    Just live

                else
                    go (f - 1) next
    in
    go fuel (Dict.map (\_ _ -> Set.empty) bodies)


blockLiveOut : Ctx -> Dict String (List String) -> Dict String (Set Int) -> Dict String (Set Int) -> String -> Set Int
blockLiveOut ctx succs ends liveIn lbl =
    let
        fromSuccs =
            List.foldl
                (\s acc -> Set.union acc (Maybe.withDefault Set.empty (Dict.get s liveIn)))
                Set.empty
                (Maybe.withDefault [] (Dict.get lbl succs))

        fromJump =
            Maybe.withDefault Set.empty (Dict.get lbl ends)
    in
    Set.union fromSuccs fromJump


blockLiveIn : Ctx -> List Inst -> Set Int -> Set Int
blockLiveIn ctx body liveAfter =
    List.foldr (\inst acc -> stepBack ctx inst acc) liveAfter body


stepBack : Ctx -> Inst -> Set Int -> Set Int
stepBack ctx inst live =
    Set.diff (Set.union (uses ctx inst) live) (defs ctx inst)


sitesInBlock : Ctx -> String -> Set Int -> List Inst -> List Site
sitesInBlock ctx lbl liveOut body =
    let
        step ( i, inst ) ( live, acc ) =
            let
                before =
                    stepBack ctx inst live
            in
            ( before
            , if allocCapable ctx inst then
                { block = lbl, pc = i, live = before } :: acc

              else
                acc
            )
    in
    Tuple.second
        (List.foldl step ( liveOut, [] )
            (List.reverse (List.indexedMap (\i inst -> ( i, inst )) body))
        )


successors : List Block -> Block -> List String
successors blocks b =
    case b.jump of
        Jmp l ->
            [ l ]

        Jnz _ t f ->
            [ t, f ]

        Ret _ ->
            []

        Hlt ->
            []

        Fallthrough ->
            -- the block that follows in EMISSION order
            case dropUntil (\x -> x == b.label) (List.map .label blocks) of
                _ :: next :: _ ->
                    [ next ]

                _ ->
                    []


dropUntil : (a -> Bool) -> List a -> List a
dropUntil pred xs =
    case xs of
        [] ->
            []

        x :: rest ->
            if pred x then
                xs

            else
                dropUntil pred rest


-- ============================ TRANSFER ============================


allocCapable : Ctx -> Inst -> Bool
allocCapable ctx inst =
    case inst of
        Call _ _ (Sym s) _ ->
            not (Set.member s ctx.noCollect)

        Call _ _ _ _ ->
            -- an INDIRECT call (through a temp): the target is unknown, so it
            -- may be any defun, including an allocating one.
            True

        _ ->
            False


uses : Ctx -> Inst -> Set Int
uses ctx inst =
    case inst of
        Load _ _ _ a ->
            slotOf ctx a

        Blit src _ n ->
            slotRange ctx n src

        Store _ _ addr ->
            slotOf ctx addr

        Call _ _ _ args ->
            List.foldl (\a acc -> Set.union acc (slotOf ctx a)) Set.empty (List.filterMap callArgOperand args)

        _ ->
            Set.empty


defs : Ctx -> Inst -> Set Int
defs ctx inst =
    case inst of
        Blit _ dst n ->
            slotRange ctx n dst

        Store _ _ addr ->
            slotOf ctx addr

        _ ->
            Set.empty


jumpUse : Ctx -> Jump -> Set Int
jumpUse ctx jump =
    case jump of
        -- The @ret block is built by the caller AFTER this analysis runs, so
        -- its `ret` operand (slot 0, the whole :ret aggregate) is folded into
        -- the edge that reaches it.  "ret" is the label Mid.Qbe.Lower's @ret
        -- block always takes.
        Jmp "ret" ->
            Set.fromList (List.range 0 (ctx.retBytes // vs - 1))

        Jmp _ ->
            Set.empty

        Jnz a _ _ ->
            slotOf ctx a

        Ret (Just a) ->
            slotRange ctx ctx.retBytes a

        _ ->
            Set.empty


callArgOperand : CallArg -> Maybe Arg
callArgOperand a =
    case a of
        ArgVal _ arg ->
            Just arg

        ArgEnv arg ->
            Just arg

        ArgEllipsis ->
            Nothing


-- ============================ SLOT ADDRESSES ============================


slotOf : Ctx -> Arg -> Set Int
slotOf ctx a =
    case a of
        Tmp t ->
            case Dict.get t ctx.offs of
                Just off ->
                    Set.singleton (off // vs)

                Nothing ->
                    Set.empty

        _ ->
            Set.empty


slotRange : Ctx -> Int -> Arg -> Set Int
slotRange ctx n a =
    if n <= 0 then
        Set.empty

    else
        case a of
            Tmp t ->
                case Dict.get t ctx.offs of
                    Just off ->
                        Set.fromList (List.range (off // vs) ((off + n - 1) // vs))

                    Nothing ->
                        Set.empty

            _ ->
                Set.empty


isFrameAddr : Ctx -> Arg -> Bool
isFrameAddr ctx a =
    case a of
        Tmp t ->
            Dict.member t ctx.offs || Set.member t ctx.bad

        _ ->
            False


{-| Every temp holding `f + k`, by a single forward pass over the emitted
instructions (temp names are unique within a defun: `freshTmp` is monotone
and slot temps are per-slot).  A temp that is assigned two DIFFERENT offsets
is recorded in `bad` and dropped — it is then reported as an escape wherever
it is passed or stored, never resolved to a slot.
-}
addressOffsets : List Block -> ( Dict String Int, Set String )
addressOffsets blocks =
    let
        step inst ( d, bad ) =
            case inst of
                Bin (Just t) L Add a b ->
                    case resolveOffset d a b of
                        Just off ->
                            case Dict.get t d of
                                Just old ->
                                    if old == off then
                                        ( d, bad )

                                    else
                                        ( Dict.remove t d, Set.insert t bad )

                                Nothing ->
                                    ( Dict.insert t off d, bad )

                        Nothing ->
                            ( d, bad )

                _ ->
                    ( d, bad )
    in
    List.foldl step ( Dict.singleton "f" 0, Set.empty )
        (List.concatMap .body blocks)


resolveOffset : Dict String Int -> Arg -> Arg -> Maybe Int
resolveOffset d a b =
    case ( offsetOf d a, offsetOf d b ) of
        ( Just oa, Just ob ) ->
            Just (oa + ob)

        ( Just oa, Nothing ) ->
            case b of
                Con k ->
                    Just (oa + k)

                _ ->
                    Nothing

        ( Nothing, Just ob ) ->
            case a of
                Con k ->
                    Just (k + ob)

                _ ->
                    Nothing

        ( Nothing, Nothing ) ->
            Nothing


offsetOf : Dict String Int -> Arg -> Maybe Int
offsetOf d a =
    case a of
        Tmp t ->
            Dict.get t d

        _ ->
            Nothing


-- ============================ ESCAPES ============================


escapesOf : Ctx -> List Block -> List String
escapesOf ctx blocks =
    List.concatMap
        (\b ->
            List.filterMap
                (\inst ->
                    case inst of
                        Call _ _ _ args ->
                            if List.any (isFrameAddr ctx) (List.filterMap callArgOperand args) then
                                Just ("a call in @" ++ b.label ++ " takes a frame address")

                            else
                                Nothing

                        Store _ src _ ->
                            if isFrameAddr ctx src then
                                Just ("a frame address is stored to memory in @" ++ b.label)

                            else
                                Nothing

                        _ ->
                            Nothing
                )
                b.body
        )
        blocks
