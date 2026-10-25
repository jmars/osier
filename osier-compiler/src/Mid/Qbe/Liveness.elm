module Mid.Qbe.Liveness exposing (Analysis, Class, Site, Sites(..), allSitesEmpty, analyze, classify, frameFree)

-- Mid.Qbe.Liveness — THE SLOT-LIVENESS PRE-PASS (perf P5; the analysis P8's
-- per-safepoint descriptor maps are built from).
--
-- TWO TIERS, because the two consumers want very different things.
--
--   TIER 1 — `classify`: a CHEAP LINEAR classification of one defun with NO
--   CFG dataflow — "does any call in this defun reach a GC safepoint?" and
--   "did a frame address leave the defun?".  This is all P5's degenerate
--   predicate needs, and `frameFree` consumes it.
--
--   TIER 2 — `analyze`: the per-safepoint slot maps (`sites`).  This is the
--   EXPENSIVE half — a backward CFG fixpoint — and P8 is its consumer.  It is
--   LAZY: a defun with no allocation-capable call site has no safepoint to
--   describe, so its map set is COMPLETE AND EMPTY and the fixpoint is not
--   run.  (Before this split the fixpoint ran for EVERY candidate defun even
--   though P5 only ever read "are the sets empty".)
--
-- WHY TIER 1 IS SOUND: P5 asks only whether a frame-free defun can hold a live
-- composite ACROSS a safepoint.  With no allocation-capable call site in the
-- defun there is no safepoint, so there is nothing to hold it across, and the
-- linear scan answers the question by itself.  The fixpoint could not have
-- said more: the `Jmp @ret` fold in `jumpUse` makes the return aggregate's
-- slots live on every path into @ret, so a defun with a safepoint reported a
-- non-empty live set anyway.  MEASURED (perf P5b): the linear rule and the
-- fixpoint rule select the SAME frame-free defuns on the 16-group gate
-- workload — the emits are BYTE-IDENTICAL.
--
-- THE EQUIVALENCE IS AN EMITTER PROPERTY, NOT A PROPERTY OF THIS ANALYSIS, so
-- it must be re-established if the emitter changes.  It rests on TWO facts
-- about the emitted IL, both of which a reader should check here rather than
-- assume: (a) the `:ret` aggregate is 80 bytes (`rvs`), so its read covers
-- SLOT 1 as well as slot 0; and (b) no defun body DEFINES `f+40..f+79` — the
-- prologue does, once, and nothing writes it again.  Given (a) and (b), slot 1
-- is live at every safepoint of every defun that has one, so the fixpoint
-- could never have returned an empty set for a defun the linear tier admits.
-- Drop either fact and the two rules diverge — and then the fixpoint is the
-- NARROWER (safe) answer while tier 1 is WRONG, not merely faster.
--
-- WHAT TIER 2 ANSWERS: for ONE defun's EMITTED blocks, for every CALL that can
-- reach a GC safepoint, WHICH FRAME SLOTS hold a live composite across it.
-- "Live across" is the ordinary backward liveness dataflow over the block CFG
-- (a use reachable before a redefinition on SOME path), run to a FIXPOINT —
-- not a forward scan — because the paths that matter are exactly the ones a
-- forward walk misses: a `case`/`if` arm that rejoins, an error arm that jumps
-- straight to @ret, and the self-tail loop's back edge (Lower's `recur`
-- compiles to `jmp @body`).
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
-- unresolvable address is reported as an escape), and `allocSite` is an
-- over-approximation of "reaches a safepoint" (an indirect call always
-- counts).  Both predicates here are therefore conservative in the only
-- direction that is safe.

import Dict exposing (Dict)
import Mid.Qbe.Il as Il exposing (Arg(..), BinOp(..), Block, CallArg(..), Inst(..), Jump(..), Ty(..))
import Mid.RtLayout as RtLayout
import Set exposing (Set)


-- VR3a: the slot stride is NOT a constant here — it is a field of the Value
-- layout INSTANCE the analysis is run for (`opts.layout`, threaded from
-- Mid.Qbe.Lower's state).  Every "byte offset -> slot index" conversion below
-- divides by it, so the word arm needs no edit in this module.


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


-- ======================= TIER 1: THE LINEAR CLASSIFICATION =======================


{-| The cheap per-defun answer: two linear passes over the emitted instructions
and NO CFG dataflow.  `allocSite` is "some call in this defun can reach a GC
safepoint"; `escapes` is the frame-address-escape evidence (see `escapesOf`).
-}
type alias Class =
    { allocSite : Bool
    , escapes : List String
    }


{-| P5's predicate: no safepoint anywhere in the defun AND no frame address left
it.  A NON-CONVERGENT analysis cannot reach here at all — this tier has no
fixpoint to fail — and the escape conjunct is the conservative one that
`analyze` shares.
-}
frameFree : Class -> Bool
frameFree c =
    List.isEmpty c.escapes && not c.allocSite


{-| `nslots` is needed even by the cheap tier, and only for `escapes`: a bare
slot address (`%s<i>`) is DEFINED by the prologue, which the emitter writes
after the body walk — so `addressOffsets` cannot see it, and an address passed
to a call or stored to memory would otherwise not be recognised as a frame
address (the H2 shape).  MEASURED (perf P5b): without the seed, 10 of the 16
gate groups' emits moved, each one a defun wrongly declared frame-free.
-}
classify : { nslots : Int, noCollect : Set String, layout : RtLayout.ValLayout } -> List Block -> Class
classify opts blocks =
    let
        ( offs, bad ) =
            slotOffsets opts.layout opts.nslots blocks

        ctx =
            { offs = offs, bad = bad, noCollect = opts.noCollect }
    in
    { allocSite = anyAllocSite ctx blocks
    , escapes = escapesOf ctx blocks
    }


anyAllocSite : { r | offs : Dict String Int, bad : Set String, noCollect : Set String } -> List Block -> Bool
anyAllocSite ctx blocks =
    List.foldl (\b acc -> acc || List.any (allocCapable ctx) b.body) False blocks


-- ======================= TIER 2: THE PER-SITE MAPS =======================


{-| One allocation-capable call site: which frame slots hold a live composite
across it.  `pc` is the instruction index within its block.  P8 will key its
descriptor's per-site map off this list; P5 reads only whether the sets are
empty — and it no longer asks for the list at all.
-}
type alias Site =
    { block : String
    , pc : Int
    , live : Set Int
    }


{-| The map set, as a SUM rather than a list, because "not computed" must never
be readable as "computed and empty": a consumer of the per-safepoint maps (P8)
gets the conservative answer BY CONSTRUCTION — `NotComputed` carries no list to
misread, and `Computed` is only produced when every allocation-capable call site
of the defun has been enumerated.  A defun with no allocation-capable call site
is `Computed []`: there is no safepoint, so the enumeration is complete and
empty.
-}
type Sites
    = Computed (List Site)
    | NotComputed String


type alias Analysis =
    { sites : Sites
    , escapes : List String
    }


{-| "No site has a non-empty live set."  A NOT-COMPUTED analysis cannot satisfy
this by accident — it has no list, and this returns False for it — so neither a
non-convergent fixpoint nor an unrun one can read as "no live slots".
-}
allSitesEmpty : Analysis -> Bool
allSitesEmpty a =
    case a.sites of
        Computed sites ->
            List.all (\s -> Set.isEmpty s.live) sites

        NotComputed _ ->
            False


type alias Ctx =
    { offs : Dict String Int
    , bad : Set String
    , retBytes : Int
    , noCollect : Set String
    , layout : RtLayout.ValLayout
    }


{-| THE EXPLICIT MAP REQUEST (P8's entry point; P5 never makes it).  `noCollect`
is the set of CALL SYMBOLS whose execution cannot reach a GC safepoint
(Mid.Rt.allocating's complement over the Rt program, plus the non-collecting
libc entries the emitter names).  A call to anything else — including a call
through a TEMP (an indirect call, whose target is unknown) — is treated as a
safepoint.

The fixpoint runs only when there is something to compute: with no
allocation-capable call site the map set is `Computed []`.
-}
analyze : { retBytes : Int, nslots : Int, noCollect : Set String, layout : RtLayout.ValLayout } -> List Block -> Analysis
analyze opts blocks =
    let
        ( offs, bad ) =
            slotOffsets opts.layout opts.nslots blocks

        ctx =
            { offs = offs
            , bad = bad
            , retBytes = opts.retBytes
            , noCollect = opts.noCollect
            , layout = opts.layout
            }

        escapes =
            escapesOf ctx blocks
    in
    if not (anyAllocSite ctx blocks) then
        -- THE LAZY HALF.  No allocation-capable call site, so no safepoint and
        -- no live-set to compute: the map set is complete and empty, and the
        -- backward fixpoint — the expensive part of this module — is not run.
        { sites = Computed [], escapes = escapes }

    else
        let
            bodies =
                List.foldl (\b acc -> Dict.insert b.label b.body acc) Dict.empty blocks

            succs =
                List.foldl (\b acc -> Dict.insert b.label (successors blocks b) acc) Dict.empty blocks

            ends =
                List.foldl (\b acc -> Dict.insert b.label (jumpUse ctx b.jump) acc) Dict.empty blocks

            -- Monotone growth makes the fixpoint terminate; the bound guards
            -- against a defect in THIS module, and running out of it denies
            -- the maps rather than guessing.
            fuel =
                4 * (List.length blocks + 1) + 64
        in
        case fixpoint fuel ctx bodies succs ends of
            Nothing ->
                -- A FAILED analysis must never look like a clean one.  The
                -- failure is reported in `escapes` (which every predicate here
                -- checks), and `.sites` is the EXPORTED half — P8 reads it
                -- directly for its per-safepoint descriptor maps — so it is
                -- reported as `NotComputed`, which carries NO list.  An empty
                -- list there would say "no live slots anywhere" about a
                -- fixpoint that never converged; the sum type makes that
                -- unrepresentable instead of relying on a sentinel being
                -- noticed.
                { sites = NotComputed "liveness did not converge"
                , escapes = "liveness did not converge" :: escapes
                }

            Just liveIn ->
                { sites =
                    Computed
                        (List.concatMap
                            (\b ->
                                sitesInBlock ctx b.label
                                    (blockLiveOut ctx succs ends liveIn b.label)
                                    b.body
                            )
                            blocks
                        )
                , escapes = escapes
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


allocCapable : { r | noCollect : Set String } -> Inst -> Bool
allocCapable ctx inst =
    case inst of
        Call _ _ (Sym s) _ ->
            not (Set.member s ctx.noCollect)

        Call _ _ _ _ ->
            -- an INDIRECT call (through a temp): the target is unknown, so it
            -- may be any defun, including an allocating one.
            True

        TailCall _ _ _ ->
            -- Q1b: a tcall is a CALL in every respect this analysis cares
            -- about.  The enclosing defun is framed (PFrame) by construction —
            -- the tcall path emits its own rt_frame_leave before the tcall —
            -- so a tail-calling defun must never be classified frame-free.
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

        TailCall _ target args ->
            List.foldl (\a acc -> Set.union acc (slotOf ctx a))
                (slotOf ctx target)
                (List.filterMap callArgOperand args)

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
            Set.fromList (List.range 0 (ctx.retBytes // ctx.layout.valSizeBytes - 1))

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


slotOf : { r | offs : Dict String Int, layout : RtLayout.ValLayout } -> Arg -> Set Int
slotOf ctx a =
    case a of
        Tmp t ->
            case Dict.get t ctx.offs of
                Just off ->
                    Set.singleton (off // ctx.layout.valSizeBytes)

                Nothing ->
                    Set.empty

        _ ->
            Set.empty


slotRange : { r | offs : Dict String Int, layout : RtLayout.ValLayout } -> Int -> Arg -> Set Int
slotRange ctx n a =
    if n <= 0 then
        Set.empty

    else
        case a of
            Tmp t ->
                case Dict.get t ctx.offs of
                    Just off ->
                        Set.fromList (List.range (off // ctx.layout.valSizeBytes) ((off + n - 1) // ctx.layout.valSizeBytes))

                    Nothing ->
                        Set.empty

            _ ->
                Set.empty


isFrameAddr : { r | offs : Dict String Int, bad : Set String } -> Arg -> Bool
isFrameAddr ctx a =
    case a of
        Tmp t ->
            Dict.member t ctx.offs || Set.member t ctx.bad

        _ ->
            False


{-| The address map both tiers use: the body's own `f + k` derivations, PLUS the
`nslots` slot temps the PROLOGUE defines (`%s<i> =l add %f, 40*i`).  The seed is
not an optimisation — the prologue is emitted after the body walk, so without it
a bare `%s<i>` handed to a call or stored to memory resolves to nothing and the
escape goes unreported.
-}
slotOffsets : RtLayout.ValLayout -> Int -> List Block -> ( Dict String Int, Set String )
slotOffsets layout nslots blocks =
    let
        ( offsBody, bad ) =
            addressOffsets blocks
    in
    ( List.foldl (\i d -> Dict.insert (slotTmp i) (layout.valSizeBytes * i) d)
        offsBody
        (List.range 0 (nslots - 1))
    , bad
    )


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


escapesOf : { r | offs : Dict String Int, bad : Set String } -> List Block -> List String
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

                        TailCall _ _ args ->
                            if List.any (isFrameAddr ctx) (List.filterMap callArgOperand args) then
                                Just ("a tcall in @" ++ b.label ++ " takes a frame address")

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
