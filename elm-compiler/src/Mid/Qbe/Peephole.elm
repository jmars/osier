module Mid.Qbe.Peephole exposing (optimize)

-- Mid.Qbe.Peephole — local optimizations on the QBE IL, in Elm, BEFORE
-- printing (native-backend stage 1).  QBE optimizes aggressively after SSA
-- construction; these passes exist for the things QBE is NOT asked to see:
-- the slot-machine discipline the lowering emits.
--
--  1. BLIT FORWARDING (within a block, barrier-delimited): the lowering
--     writes every value into a frame slot and reads it back for the next
--     use, which costs a 40-byte copy per hop.  A `blit S -> D` immediately
--     followed (no Call, no Store in between) by a `blit D -> T` can read S
--     directly.  Calls are barriers (a call result points into a frame block
--     that is REUSED by the next call, so forwarding a %rp source across a
--     call would read the wrong block); Stores are barriers (a literal
--     materialization writes into a slot through a derived pointer, which
--     kills that slot's forwarding).
--  2. JUMP-TO-NEXT elimination: `jmp @L` / `jnz ... @A @B` where the target
--     is the immediately following block becomes a fallthrough (QBE adds the
--     jump back if needed).
--  3. DEAD PURE DEFS: pure instructions (add/and/cmp/load/copy) whose result
--     temporary is never read are dropped, to fixpoint.
--
-- Everything here must be SOUND WITHOUT KNOWING THE LOWERING — it reasons on
-- the printed-form semantics of the IL only.

import Char
import Dict exposing (Dict)
import Mid.Qbe.Il as Il exposing (..)
import Set exposing (Set)


optimize : Module -> Module
optimize m =
    { m | funcs = List.map optimizeFunc m.funcs }


optimizeFunc : Func -> Func
optimizeFunc f =
    { f
        | blocks =
            forwardBlits f.blocks []
                |> dropJumpToNext
                |> dropDeadDefs
    }



-- ============================ 1. BLIT FORWARDING ============================


forwardBlits : List Block -> List Block -> List Block
forwardBlits blocks acc =
    case blocks of
        [] ->
            List.reverse acc

        b :: rest ->
            let
                b1 =
                    { b | body = forwardBlock b.body Dict.empty }
            in
            forwardBlits rest (b1 :: acc)


-- slotTemp -> the source it currently holds (only 40-byte blits into a
-- %s<i> temp are tracked; anything else is left untouched).
forwardBlock : List Il.Inst -> Dict String Il.Arg -> List Il.Inst
forwardBlock insts sources =
    case insts of
        [] ->
            []

        Blit src dst 40 :: rest ->
            let
                forwardedSrc =
                    case src of
                        Il.Tmp t ->
                            Dict.get t sources
                                |> Maybe.withDefault src

                        _ ->
                            src
            in
            Blit forwardedSrc dst 40 :: forwardBlock rest (track dst forwardedSrc sources)

        inst :: rest ->
            if isBarrier inst then
                inst :: forwardBlock rest Dict.empty

            else
                inst :: forwardBlock rest sources


track : Il.Arg -> Il.Arg -> Dict String Il.Arg -> Dict String Il.Arg
track dst src sources =
    case dst of
        Il.Tmp t ->
            if String.startsWith t "s" && isSlotName t then
                Dict.insert t src sources

            else
                sources

        _ ->
            sources


isSlotName : String -> Bool
isSlotName t =
    case String.uncons t of
        Just ( 's', rest ) ->
            rest /= "" && String.all Char.isDigit rest

        _ ->
            False


isBarrier : Il.Inst -> Bool
isBarrier inst =
    case inst of
        Call _ _ _ _ ->
            True

        Store _ _ _ ->
            True

        _ ->
            False



-- ============================ 2. JUMP-TO-NEXT ============================
-- Only the plain unconditional case: `jmp @L` where @L is the NEXT block
-- becomes Fallthrough (the printer then emits no jump, which QBE reads as a
-- fallthrough).  jnz targets are left alone — QBE handles them.


dropJumpToNext : List Block -> List Block
dropJumpToNext blocks =
    List.map2
        (\b next ->
            case ( b.jump, Maybe.map .label next ) of
                ( Jmp target, Just l ) ->
                    if target == l then
                        { b | jump = Fallthrough }

                    else
                        b

                _ ->
                    b
        )
        blocks
        (List.map Just (List.drop 1 blocks) ++ [ Nothing ])


-- ============================ 3. DEAD PURE DEFS ============================


dropDeadDefs : List Block -> List Block
dropDeadDefs blocks =
    let
        used =
            List.foldl (\b acc -> usedInBlock b acc) Set.empty blocks

        step bs =
            List.map
                (\b -> { b | body = List.filter (keepInst used) b.body })
                bs

        filtered =
            step blocks
    in
    if List.sum (List.map (\b -> List.length b.body) filtered)
        == List.sum (List.map (\b -> List.length b.body) blocks)
    then
        blocks

    else
        dropDeadDefs filtered


keepInst : Set String -> Il.Inst -> Bool
keepInst used inst =
    case defTmp inst of
        Just t ->
            Set.member t used || not (isPure inst)

        Nothing ->
            True


defTmp : Il.Inst -> Maybe String
defTmp inst =
    case inst of
        Bin (Just r) _ _ _ _ ->
            Just r

        Cmp (Just r) _ _ _ _ ->
            Just r

        Load (Just r) _ _ _ ->
            Just r

        Call (Just r) _ _ _ ->
            Just r

        Alloc r _ ->
            Just r

        _ ->
            Nothing


isPure : Il.Inst -> Bool
isPure inst =
    case inst of
        Bin _ _ _ _ _ ->
            True

        Cmp _ _ _ _ _ ->
            True

        Load _ _ _ _ ->
            True

        Alloc _ _ ->
            True

        _ ->
            False


usedInBlock : Block -> Set String -> Set String
usedInBlock b acc =
    let
        condTmps =
            case b.jump of
                Jnz c _ _ ->
                    argTmps c

                Ret (Just a) ->
                    argTmps a

                _ ->
                    Set.empty
    in
    Set.union condTmps (List.foldl (\i a -> Set.union a (readsTmps i)) acc b.body)


readsTmps : Il.Inst -> Set String
readsTmps inst =
    case inst of
        Bin _ _ _ a b ->
            Set.union (argTmps a) (argTmps b)

        Cmp _ _ _ a b ->
            Set.union (argTmps a) (argTmps b)

        Load _ _ _ a ->
            argTmps a

        Store _ v addr ->
            Set.union (argTmps v) (argTmps addr)

        Blit src dst _ ->
            Set.union (argTmps src) (argTmps dst)

        Call _ _ target args ->
            List.foldl
                (\ca acc ->
                    case ca of
                        ArgVal _ a ->
                            Set.union acc (argTmps a)

                        ArgEnv a ->
                            Set.union acc (argTmps a)
                )
                (argTmps target)
                args

        Alloc _ _ ->
            Set.empty

        Cmt _ ->
            Set.empty


argTmps : Il.Arg -> Set String
argTmps arg =
    case arg of
        Il.Tmp t ->
            Set.singleton t

        _ ->
            Set.empty


