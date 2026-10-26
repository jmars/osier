module Mid.Qbe.Encode exposing (encode)

-- Mid.Qbe.Encode — Qbe.Il -> x86-64 machine code -> ELF64 relocatable object
-- (handoff-osier-asm S1a-S1c; plan2's D-A route (c): the encoder lives IN the
-- compiler and consumes the SAME post-peephole `Qbe.Il.Module` the printer
-- renders, so there is ONE IL representation and no reader that could drift
-- from it).
--
-- WHAT IT IS: a SPILL-EVERYTHING instruction selector and encoder.  Every IL
-- temporary owns one frame slot; every operation loads its operands into
-- scratch registers, applies, and stores back.  There is NO register
-- allocator in v1 and this module does not want one (a later perf unit may
-- add it; it changes no oracle).  Consequences, all deliberate:
--   * ZERO callee-saved registers are touched (rax/rcx/rdx/rsi/rdi/r8-r11 and
--     xmm0/xmm1 only), so the moving collector's contract is kept by
--     construction: nothing a safepoint could move lives in a register across
--     a call — the IL's own rooted PFrame holds the live Values (Il.elm's
--     `isSafepoint`).
--   * The frame is FIXED for the function's whole life and 16-byte aligned
--     after the prologue, so every call site is aligned without per-call
--     fixups, and the outgoing stack-argument area is the bottom of that
--     frame (rsp+0..) rather than a `sub rsp` around each call.
--
-- ABI (D-B, TWO-PHASE): exactly QBE's amd64 SysV SUBSET plus QBE's closure
-- extension — word and double scalars in rdi/rsi/rdx/rcx/r8/r9 and xmm0-7,
-- `:val`/`:ret` aggregates as MEMORY (by value on the stack; the callee's
-- parameter is the ADDRESS of the caller's copy), aggregate returns through a
-- hidden pointer in the first GP register with rax = that pointer on return,
-- and `env` in rax.  MEASURED and matched, not invented:
--   * NO `%al` count is emitted for a variadic call — the vendored qbe never
--     emits one (`rg '%%eax' vendor/qbe/*.c vendor/qbe/amd64/*.c` = no hits;
--     Ocall in amd64/emit.c emits only `callq`), and the seed's only variadic
--     callee (`fcntl`) takes word arguments.
--   * Float compares follow qbe's isel (amd64/isel.c:466-494, emit.c's CMP
--     table): `ceqd` is (ZF=1 AND PF=0) and `cned` is (ZF=0 OR PF=1) — a NaN
--     is never equal — while <,<=,>,>= use the SWAPPED seta/setae forms,
--     which are false for unordered.
--
-- WHERE THE BYTES COME FROM: the ADT, never the printed text.  The printer is
-- untouched (`Mid.Qbe.Print`), so the emitted `.ssa` cannot move.
--
-- UNSUPPORTED SHAPES ARE LOUD, never skipped: `Base S` (no `s`-typed
-- signature or instruction exists in the measured census) and `DDouble` data
-- items (no Elm-tier float-bit-image seat exists; plan2 D-DBL) both return
-- `Err`, which the driver writes as `err <msg>` exactly like a compile error.

import Char
import Dict exposing (Dict)
import Mid.Qbe.Il as Il exposing (AbiTy(..), Arg(..), BinOp(..), Block, CallArg(..), CmpOp(..), DataDef, DataItem(..), Func, Inst(..), Jump(..), LoadOp(..), Module, StoreTy(..), Ty(..), UnaryOp(..))
import Mid.Qbe.Obj as Obj exposing (SymBind(..), SymKind(..), SymSec(..))


encode : Module -> Result String String
encode m =
    if not byteIndexed then
        Err "obj: the encoder emits raw bytes and needs the byte-indexed selfhost runtime (Char = one byte); a code-point-indexed runtime would UTF-8-expand every byte >= 0x80"

    else if List.any hasDoubleItem m.datas then
        Err "obj: a `d` (double) data item has no bit-image seat in the Elm tier (plan2 D-DBL) — refusing rather than emitting a wrong constant"

    else if List.any hasSingleTy m.funcs then
        Err "obj: an `s` (single-precision) type reaches the encoder; only w/l/d appear in the measured census, and no `s` instruction is implemented"

    else if List.any hasTailCall m.funcs then
        -- Q1b: a tcall needs the epilogue-then-jmp sequence (the callee returns
        -- to OUR caller).  The encoder has no seat for it yet, and this path is
        -- not gated, so it REFUSES LOUDLY rather than emitting a wrong call —
        -- the same polarity the vendored qbe enforces on its own side.
        Err "obj: a `tcall` reaches the encoder, which has no tail-call seat yet (the .ssa/qbe path does) — refusing rather than emitting an ordinary call"

    else
        case typeTable m of
            Err e ->
                Err e

            Ok types ->
                let
                    d =
                        emitData types m.datas

                    t =
                        emitFuncs types m.funcs

                    defined =
                        Dict.fromList (List.map (\s -> ( s.name, () )) (d.syms ++ t.syms))

                    externs =
                        externSyms defined (t.relocs ++ d.relocs)
                in
                Ok
                    (Obj.serialize
                        { text = t.bytes
                        , textRelocs = t.relocs
                        , data = d.bytes
                        , dataRelocs = d.relocs
                        , bssSize = d.bss
                        , syms = d.syms ++ t.syms ++ externs
                        }
                    )


-- MEASURED probe, the same one Mid.Qbe.Print uses: a Char is one BYTE in the
-- selfhost runtime ("é" is 2) and one code point on stock elm/node (1).
byteIndexed : Bool
byteIndexed =
    String.length "é" == 2


hasDoubleItem : DataDef -> Bool
hasDoubleItem d =
    List.any
        (\i ->
            case i of
                DDouble _ ->
                    True

                _ ->
                    False
        )
        d.items


hasSingleTy : Func -> Bool
hasSingleTy f =
    List.any (\( _, t ) -> isSingle t) f.params || isSingle f.ret


isSingle : AbiTy -> Bool
isSingle t =
    case t of
        Base S ->
            True

        _ ->
            False


hasTailCall : Func -> Bool
hasTailCall f =
    List.any (\b -> List.any isTailCall b.body) f.blocks


isTailCall : Inst -> Bool
isTailCall inst =
    case inst of
        TailCall _ _ _ ->
            True

        _ ->
            False


isAgg : AbiTy -> Bool
isAgg t =
    case t of
        Agg _ ->
            True

        _ ->
            False


-- ============================ TYPE LAYOUT ============================
-- QBE lays a type out field by field with each field's own alignment, then
-- rounds the total to the type's alignment (MEASURED against the vendored
-- qbe: `:ret` = { :val, w, l, l, l, w } is 80 bytes, not 72 — the `w` at 40
-- pads to the `l` at 48, and Mid.RtLayout's ret*Offset values agree).


type alias TyInfo =
    { size : Int
    , align : Int
    }


typeTable : Module -> Result String (Dict String TyInfo)
typeTable m =
    typeTableGo (Il.valType m.layout :: Il.retTypes m.layout ++ m.types ++ [ Il.descType ]) Dict.empty


typeTableGo : List Il.TypeDef -> Dict String TyInfo -> Result String (Dict String TyInfo)
typeTableGo defs acc =
    case defs of
        [] ->
            Ok acc

        d :: rest ->
            case layoutFields acc d.fields of
                Err e ->
                    Err ("obj: type :" ++ d.name ++ ": " ++ e)

                Ok ( size, fieldAlign ) ->
                    let
                        declared =
                            case d.align of
                                Just a ->
                                    a

                                Nothing ->
                                    1

                        a =
                            max declared fieldAlign
                    in
                    typeTableGo rest
                        (Dict.insert d.name { size = alignTo a size, align = a } acc)


layoutFields : Dict String TyInfo -> List String -> Result String ( Int, Int )
layoutFields table fields =
    layoutFieldsGo table fields 0 1


layoutFieldsGo : Dict String TyInfo -> List String -> Int -> Int -> Result String ( Int, Int )
layoutFieldsGo table fields cur maxAlign =
    case fields of
        [] ->
            Ok ( cur, maxAlign )

        f :: rest ->
            case fieldInfo table f of
                Nothing ->
                    Err ("unknown field type " ++ f)

                Just info ->
                    layoutFieldsGo table rest
                        (alignTo info.align cur + info.size)
                        (max info.align maxAlign)


fieldInfo : Dict String TyInfo -> String -> Maybe TyInfo
fieldInfo table f =
    case f of
        "w" ->
            Just { size = 4, align = 4 }

        "l" ->
            Just { size = 8, align = 8 }

        "s" ->
            Just { size = 4, align = 4 }

        "d" ->
            Just { size = 8, align = 8 }

        _ ->
            if String.startsWith ":" f then
                Dict.get (String.dropLeft 1 f) table

            else
                Dict.get f table


-- Byte size of an aggregate type, for the sret buffer and the by-value copy.
-- Every name reaching this has already been validated by `typeTable`.
typeSize : Dict String TyInfo -> String -> Int
typeSize table name =
    case Dict.get name table of
        Just info ->
            info.size

        Nothing ->
            0


-- ============================ .data / .bss ============================


type alias DataOut =
    { bytes : List Int
    , relocs : List Obj.Reloc
    , bss : Int
    , syms : List Obj.Sym
    }


emitData : Dict String TyInfo -> List DataDef -> DataOut
emitData types datas =
    emitDataGo types datas
        { rev = []
        , len = 0
        , relocs = []
        , bss = 0
        , syms = []
        }


type alias DataAcc =
    { rev : List Int
    , len : Int
    , relocs : List Obj.Reloc
    , bss : Int
    , syms : List Obj.Sym
    }


emitDataGo : Dict String TyInfo -> List DataDef -> DataAcc -> DataOut
emitDataGo types datas acc =
    case datas of
        [] ->
            { bytes = List.reverse acc.rev
            , relocs = List.reverse acc.relocs
            , bss = acc.bss
            , syms = List.reverse acc.syms
            }

        d :: rest ->
            let
                a =
                    case d.align of
                        Just n ->
                            n

                        -- QBE's default data alignment is 8 (parse.c parsedat
                        -- sets `lnk->align = 8`, overridden by an `align` spec)
                        Nothing ->
                            8

                size =
                    List.foldl (\i n -> n + itemSize i) 0 d.items

                symOf sec value =
                    { name = d.name
                    , bind =
                        if d.export_ then
                            Global

                        else
                            Local
                    , kind = SymObject
                    , sec = sec
                    , value = value
                    , size = size
                    }

                -- A definition that is ALL zeros goes to .bss, exactly where
                -- qbe puts it (emit.c emitdat's zero accumulator: a leading
                -- `z` run with no real item after it becomes `.fill` in .bss)
                allZero =
                    not (List.isEmpty d.items) && List.all isZeroItem d.items
            in
            if allZero then
                let
                    off =
                        alignTo a acc.bss
                in
                emitDataGo types rest
                    { acc | bss = off + size, syms = symOf InBss off :: acc.syms }

            else
                let
                    off =
                        alignTo a acc.len

                    ( rev, len, relocs ) =
                        emitItems d.items off acc.relocs
                in
                emitDataGo types rest
                    { rev = List.foldl (::) acc.rev (List.reverse (pad acc.len off) ++ rev)
                    , len = len
                    , relocs = relocs
                    , bss = acc.bss
                    , syms = symOf InData off :: acc.syms
                    }


isZeroItem : DataItem -> Bool
isZeroItem i =
    case i of
        DZero _ ->
            True

        _ ->
            False


itemSize : DataItem -> Int
itemSize i =
    case i of
        DByte _ ->
            1

        DWord _ ->
            4

        DLong _ ->
            8

        DDouble _ ->
            8

        DStr s ->
            String.length s

        DZero n ->
            n

        DRef _ ->
            8


-- Items are PACKED, with no per-item alignment: qbe's data items carry a type
-- only (parse.c parsedat) and emit.c writes `.byte/.int/.quad/.ascii/.fill`
-- back to back, so the item list IS the layout.
type alias ItemsAcc =
    { rev : List Int
    , len : Int
    , relocs : List Obj.Reloc
    }


emitItems : List DataItem -> Int -> List Obj.Reloc -> ( List Int, Int, List Obj.Reloc )
emitItems items off0 relocs0 =
    emitItemsGo items { rev = [], len = off0, relocs = relocs0 }


emitItemsGo : List DataItem -> ItemsAcc -> ( List Int, Int, List Obj.Reloc )
emitItemsGo items acc =
    case items of
        [] ->
            ( List.reverse acc.rev, acc.len, acc.relocs )

        i :: rest ->
            let
                ( bytes, relocs ) =
                    case i of
                        DByte n ->
                            ( [ modBy 256 n ], acc.relocs )

                        DWord n ->
                            ( le32 n, acc.relocs )

                        DLong n ->
                            ( le64 n, acc.relocs )

                        DDouble _ ->
                            -- refused up front by `encode`'s D-DBL check
                            ( [], acc.relocs )

                        DStr s ->
                            ( strBytes s, acc.relocs )

                        DZero n ->
                            ( List.repeat n 0, acc.relocs )

                        DRef name ->
                            ( le64 0
                            , { off = acc.len, kind = Obj.R64, sym = name, addend = 0 } :: acc.relocs
                            )
            in
            emitItemsGo rest
                { rev = List.foldl (::) acc.rev (List.reverse bytes)
                , len = acc.len + List.length bytes
                , relocs = relocs
                }


-- ============================ FUNCTIONS ============================


emitFuncs : Dict String TyInfo -> List Func -> TextOut
emitFuncs types funcs =
    emitFuncsGo types funcs { rev = [], len = 0, relocs = [], syms = [] }


type alias TextOut =
    { bytes : List Int
    , relocs : List Obj.Reloc
    , syms : List Obj.Sym
    }


type alias TextAcc =
    { rev : List Int
    , len : Int
    , relocs : List Obj.Reloc
    , syms : List Obj.Sym
    }


emitFuncsGo : Dict String TyInfo -> List Func -> TextAcc -> TextOut
emitFuncsGo types funcs acc =
    case funcs of
        [] ->
            { bytes = List.reverse acc.rev
            , relocs = List.reverse acc.relocs
            , syms = List.reverse acc.syms
            }

        f :: rest ->
            let
                off =
                    alignTo 16 acc.len

                plan =
                    planFunc types f

                ( bytes, relocs ) =
                    encodeFunc types plan f

                size =
                    List.length bytes

                sym =
                    { name = f.name
                    , bind =
                        if f.export_ then
                            Global

                        else
                            Local
                    , kind = SymFunc
                    , sec = InText
                    , value = off
                    , size = size
                    }
            in
            emitFuncsGo types rest
                { rev = List.foldl (::) acc.rev (List.reverse (pad acc.len off) ++ List.reverse bytes)
                , len = off + size
                , relocs = List.reverse relocs ++ acc.relocs
                , syms = sym :: acc.syms
                }


-- Every relocation that names a symbol the object does not define becomes an
-- undefined GLOBAL, in first-use order (deterministic: the reloc lists are in
-- emission order).
externSyms : Dict String () -> List Obj.Reloc -> List Obj.Sym
externSyms defined relocs =
    List.reverse (externGo relocs defined Dict.empty [])


externGo : List Obj.Reloc -> Dict String () -> Dict String () -> List Obj.Sym -> List Obj.Sym
externGo relocs defined seen acc =
    case relocs of
        [] ->
            acc

        r :: rest ->
            if Dict.member r.sym defined || Dict.member r.sym seen then
                externGo rest defined seen acc

            else
                externGo rest defined
                    (Dict.insert r.sym () seen)
                    ({ name = r.sym
                     , bind = Global
                     , kind = SymNoType
                     , sec = Undefined
                     , value = 0
                     , size = 0
                     }
                        :: acc
                    )


-- ============================ FRAME PLAN ============================


type alias Slot =
    { disp : Int
    , ty : Ty
    }


type alias Plan =
    { slots : Dict String Slot
    , sret : Dict String Int
    , frameSize : Int
    , retrDisp : Int
    }


type alias Planner =
    { cur : Int
    , slots : Dict String Slot
    , sret : Dict String Int
    , outArea : Int
    , retrDisp : Int
    }


planFunc : Dict String TyInfo -> Func -> Plan
planFunc types f =
    let
        p0 =
            { cur = 0, slots = Dict.empty, sret = Dict.empty, outArea = 0, retrDisp = 0 }

        p1 =
            if f.envParam then
                allocSlot "env" L p0

            else
                p0

        p2 =
            List.foldl (\( n, t ) p -> allocParam n t p) p1 f.params

        p3 =
            if isAgg f.ret then
                let
                    p =
                        allocSlot "@retr" L p2
                in
                { p | retrDisp = slotDispOf "@retr" p.slots }

            else
                p2

        p4 =
            List.foldl (planInst types) p3 (List.concatMap .body f.blocks)
    in
    { slots = p4.slots
    , sret = p4.sret
    , frameSize = alignTo 16 (p4.cur + p4.outArea)
    , retrDisp = p4.retrDisp
    }


slotDispOf : String -> Dict String Slot -> Int
slotDispOf name slots =
    case Dict.get name slots of
        Just s ->
            s.disp

        Nothing ->
            0


allocSlot : String -> Ty -> Planner -> Planner
allocSlot name ty p =
    { p
        | cur = p.cur + 8
        , slots = Dict.insert name { disp = -(p.cur + 8), ty = ty } p.slots
    }


allocParam : String -> AbiTy -> Planner -> Planner
allocParam name t p =
    case t of
        Base S ->
            p

        Base ty ->
            allocSlot name ty p

        -- an aggregate parameter's temp holds the ADDRESS of the caller's
        -- by-value copy (MEMORY class), so it is a word
        Agg _ ->
            allocSlot name L p


planInst : Dict String TyInfo -> Inst -> Planner -> Planner
planInst types inst p =
    case inst of
        Cmt _ ->
            p

        Bin (Just r) ty _ _ _ ->
            allocSlot r ty p

        Cmp (Just r) _ _ _ _ ->
            allocSlot r W p

        Load (Just r) ty _ _ ->
            allocSlot r ty p

        Unary (Just r) ty _ _ ->
            allocSlot r ty p

        -- the Nothing-result forms define no temporary
        Bin _ _ _ _ _ ->
            p

        Cmp _ _ _ _ _ ->
            p

        Load _ _ _ _ ->
            p

        Unary _ _ _ _ ->
            p

        Store _ _ _ ->
            p

        Blit _ _ _ ->
            p

        Alloc r n ->
            let
                extent =
                    alignTo 16 n

                cur =
                    alignTo 16 p.cur
            in
            { p
                | cur = cur + extent
                , slots = Dict.insert r { disp = -(cur + extent), ty = L } p.slots
            }

        TailCall _ _ _ ->
            -- no result, so no sret buffer: the callee returns straight to our
            -- caller and writes into OUR caller's buffer (abi1 forwards
            -- fn->retr as its hidden first argument).  Unreachable behind the
            -- up-front refusal; kept total so a future seat cannot fall through
            -- the frame-slot arithmetic.
            p

        Call dst ty _ args ->
            let
                p1 =
                    case dst of
                        Nothing ->
                            p

                        Just r ->
                            case ty of
                                Agg name ->
                                    -- one 16-aligned sret buffer per
                                    -- aggregate-returning call site, keyed by
                                    -- the temp that receives its address
                                    let
                                        extent =
                                            alignTo 16 (typeSize types name)

                                        cur =
                                            alignTo 16 p.cur
                                    in
                                    { p
                                        | cur = cur + extent
                                        , sret = Dict.insert r -(cur + extent) p.sret
                                    }

                                Base S ->
                                    p

                                Base b ->
                                    allocSlot r b p

                bytes =
                    outgoingBytes types args
            in
            { p1 | outArea = max p1.outArea bytes }


-- The stack bytes a call needs: MEMORY-class aggregates by value, plus any
-- scalar past the sixth GP / eighth XMM register, in SysV order.
outgoingBytes : Dict String TyInfo -> List CallArg -> Int
outgoingBytes types args =
    outgoingGo types args 0 0 0


outgoingGo : Dict String TyInfo -> List CallArg -> Int -> Int -> Int -> Int
outgoingGo types args gp xmm stack =
    case args of
        [] ->
            stack

        ArgEllipsis :: rest ->
            outgoingGo types rest gp xmm stack

        ArgEnv _ :: rest ->
            -- env rides in rax and takes no argument slot
            outgoingGo types rest gp xmm stack

        ArgVal t _ :: rest ->
            case t of
                Agg name ->
                    outgoingGo types rest gp xmm (alignTo 8 stack + alignTo 8 (typeSize types name))

                Base S ->
                    outgoingGo types rest gp (xmm + 1) (stack + overflow xmm 8)

                Base D ->
                    outgoingGo types rest gp (xmm + 1) (stack + overflow xmm 8)

                Base _ ->
                    outgoingGo types rest (gp + 1) xmm (stack + overflow gp 6)


overflow : Int -> Int -> Int
overflow used limit =
    if used >= limit then
        8

    else
        0


-- ============================ CODE EMISSION ============================


type alias Fixup =
    { off : Int
    , label : String
    }


type alias Emit =
    { rev : List Int
    , len : Int
    , relocs : List Obj.Reloc
    , fixups : List Fixup
    , labels : Dict String Int
    , plan : Plan
    , types : Dict String TyInfo
    , ret : AbiTy
    }


encodeFunc : Dict String TyInfo -> Plan -> Func -> ( List Int, List Obj.Reloc )
encodeFunc types plan f =
    let
        e0 =
            { rev = []
            , len = 0
            , relocs = []
            , fixups = []
            , labels = Dict.empty
            , plan = plan
            , types = types
            , ret = f.ret
            }

        e1 =
            prologue f e0

        e2 =
            List.foldl block e1 f.blocks
    in
    ( patch e2.labels (List.reverse e2.rev) (sortFixups e2.fixups) [] 0
    , List.reverse e2.relocs
    )


-- ============================ prologue ============================


prologue : Func -> Emit -> Emit
prologue f e =
    let
        e1 =
            put [ 0x55, 0x48, 0x89, 0xE5 ] e

        e2 =
            if e.plan.frameSize > 0 then
                put ([ 0x48, 0x81, 0xEC ] ++ le32 e.plan.frameSize) e1

            else
                e1

        e3 =
            if isAgg f.ret then
                put (movSlotStore rdi L e.plan.retrDisp) e2

            else
                e2

        -- the hidden sret pointer has already taken the first GP register
        gpStart =
            if isAgg f.ret then
                1

            else
                0

        e4 =
            paramsGo f.params gpStart 0 16 e3
    in
    if Dict.member "env" e.plan.slots then
        -- env arrives in rax (QBE's closure convention) and is saved before
        -- any body instruction can use rax as scratch
        put (movSlotStore rax L (slotDisp "env" e4)) e4

    else
        e4


paramsGo : List ( String, AbiTy ) -> Int -> Int -> Int -> Emit -> Emit
paramsGo params gp xmm stack e =
    case params of
        [] ->
            e

        ( n, t ) :: rest ->
            let
                disp =
                    slotDisp n e
            in
            case t of
                Base S ->
                    paramsGo rest gp xmm stack e

                Base D ->
                    if xmm < 8 then
                        paramsGo rest gp (xmm + 1) stack
                            (put ([ 0xF2, 0x0F, 0x11 ] ++ memRb xmm disp) e)

                    else
                        paramsGo rest gp (xmm + 1) (stack + 8) e

                Base W ->
                    if gp < 6 then
                        paramsGo rest (gp + 1) xmm stack
                            (put (movSlotStore (gpReg gp) W disp) e)

                    else
                        paramsGo rest (gp + 1) xmm (stack + 8) e

                Base L ->
                    if gp < 6 then
                        paramsGo rest (gp + 1) xmm stack
                            (put (movSlotStore (gpReg gp) L disp) e)

                    else
                        paramsGo rest (gp + 1) xmm (stack + 8) e

                Agg name ->
                    -- MEMORY: the temp holds the ADDRESS of the caller's copy
                    let
                        off =
                            alignTo 8 stack

                        e1 =
                            put (leaRb rax off) e

                        e2 =
                            put (movSlotStore rax L disp) e1
                    in
                    paramsGo rest gp xmm (off + alignTo 8 (typeSize e.types name)) e2


-- ============================ blocks / jumps ============================


block : Block -> Emit -> Emit
block b e =
    let
        e1 =
            { e | labels = Dict.insert b.label e.len e.labels }

        e2 =
            List.foldl inst e1 b.body
    in
    jump b.jump e2


jump : Jump -> Emit -> Emit
jump j e =
    case j of
        Fallthrough ->
            e

        Jmp label ->
            emitJump Nothing label e

        Jnz c t f ->
            case c of
                Con n ->
                    emitJump Nothing
                        (if n /= 0 then
                            t

                         else
                            f
                        )
                        e

                Tmp tm ->
                    let
                        ty =
                            slotTy tm e

                        disp =
                            slotDisp tm e

                        e1 =
                            if ty == W then
                                put ([ 0x83 ] ++ memRb 7 disp ++ [ 0x00 ]) e

                            else
                                put ([ 0x48, 0x83 ] ++ memRb 7 disp ++ [ 0x00 ]) e
                    in
                    emitJump (Just 0x5) t e1

                Sym _ ->
                    e

        Ret Nothing ->
            put [ 0xC9, 0xC3 ] e

        Ret (Just a) ->
            retValue a e

        Hlt ->
            put [ 0x0F, 0x0B ] e


retValue : Arg -> Emit -> Emit
retValue a e =
    let
        e1 =
            case e.ret of
                Agg name ->
                    let
                        size =
                            typeSize e.types name

                        e1a =
                            put (movSlotReg rdi L e.plan.retrDisp) e

                        e1b =
                            loadGPR rsi L a e1a

                        e1c =
                            put (movImm rcx W size) e1b

                        e1d =
                            put [ 0xF3, 0xA4 ] e1c
                    in
                    put (movSlotReg rax L e.plan.retrDisp) e1d

                Base D ->
                    loadXmm 0 a e

                Base W ->
                    loadGPR rax W a e

                Base _ ->
                    loadGPR rax L a e
    in
    put [ 0xC9, 0xC3 ] e1


-- ============================ instructions ============================


inst : Inst -> Emit -> Emit
inst i e =
    case i of
        Cmt _ ->
            e

        Bin dst ty op x y ->
            bin dst ty op x y e

        Cmp dst oty op x y ->
            cmp dst oty op x y e

        Load dst ty op a ->
            load dst ty op a e

        Store st v addr ->
            store st v addr e

        Blit src dst n ->
            blit src dst n e

        Call dst ty target args ->
            call dst ty target args e

        TailCall _ _ _ ->
            -- UNREACHABLE: `encode` refuses any module holding a tcall before
            -- this pass runs.  Emitting nothing here would be a silent wrong
            -- call, so the guard above is the thing that keeps this honest.
            e

        Alloc r n ->
            alloc r n e

        Unary dst ty op a ->
            unary dst ty op a e


bin : Maybe String -> Ty -> BinOp -> Arg -> Arg -> Emit -> Emit
bin dst ty op x y e =
    case ty of
        D ->
            let
                e1 =
                    loadXmm 0 x e

                e2 =
                    loadXmm 1 y e1

                e3 =
                    put (sseOp op) e2
            in
            storeXmm 0 dst e3

        _ ->
            case op of
                Div ->
                    let
                        e1 =
                            loadGPR rax ty x e

                        e2 =
                            loadGPR rcx ty y e1

                        e3 =
                            put
                                (if ty == W then
                                    [ 0x99 ]

                                 else
                                    [ 0x48, 0x99 ]
                                )
                                e2

                        e4 =
                            put (rex (ty /= W) 0 rcx ++ [ 0xF7, modrmReg 7 rcx ]) e3
                    in
                    storeGPR rax dst e4

                Shl ->
                    shifts 4 dst ty x y e

                Shr ->
                    shifts 5 dst ty x y e

                Sar ->
                    shifts 7 dst ty x y e

                Mul ->
                    let
                        e1 =
                            loadGPR rax ty x e

                        e2 =
                            loadGPR rcx ty y e1

                        e3 =
                            put (rex (ty /= W) rax rcx ++ [ 0x0F, 0xAF, modrmReg rax rcx ]) e2
                    in
                    storeGPR rax dst e3

                _ ->
                    let
                        e1 =
                            loadGPR rax ty x e

                        e2 =
                            loadGPR rcx ty y e1

                        e3 =
                            put (rex (ty /= W) rax rcx ++ [ aluOp op, modrmReg rax rcx ]) e2
                    in
                    storeGPR rax dst e3


shifts : Int -> Maybe String -> Ty -> Arg -> Arg -> Emit -> Emit
shifts ext dst ty x y e =
    let
        e1 =
            loadGPR rax ty x e

        e2 =
            loadGPR rcx ty y e1

        e3 =
            put (rex (ty /= W) 0 rax ++ [ 0xD3, modrmReg ext rax ]) e2
    in
    storeGPR rax dst e3


aluOp : BinOp -> Int
aluOp op =
    case op of
        Add ->
            0x01

        Sub ->
            0x29

        And ->
            0x21

        Or ->
            0x09

        Xor ->
            0x31

        _ ->
            0x01


sseOp : BinOp -> List Int
sseOp op =
    let
        opc =
            case op of
                Add ->
                    0x58

                Sub ->
                    0x5C

                Mul ->
                    0x59

                Div ->
                    0x5E

                _ ->
                    0x58
    in
    [ 0xF2, 0x0F, opc, modrmReg 0 1 ]


cmp : Maybe String -> Ty -> CmpOp -> Arg -> Arg -> Emit -> Emit
cmp dst oty op x y e =
    case oty of
        D ->
            let
                e1 =
                    loadXmm 0 x e

                e2 =
                    loadXmm 1 y e1

                -- qbe's isel: eq is (ZF=1 AND PF=0), ne is (ZF=0 OR PF=1), and
                -- the ordered compares use the SWAPPED seta/setae forms (both
                -- false for unordered) — see this module's header.
                ( pre, sets ) =
                    case op of
                        Ceqd ->
                            ( [ 0x66, 0x0F, 0x2E, modrmReg 0 1 ], [ ( 0x94, 0x00 ), ( 0x9B, 0x01 ), ( 0x20, 0x00 ) ] )

                        Cned ->
                            ( [ 0x66, 0x0F, 0x2E, modrmReg 0 1 ], [ ( 0x95, 0x00 ), ( 0x9A, 0x01 ), ( 0x08, 0x00 ) ] )

                        Cltd ->
                            ( [ 0x66, 0x0F, 0x2E, modrmReg 1 0 ], [ ( 0x97, 0x00 ) ] )

                        Cled ->
                            ( [ 0x66, 0x0F, 0x2E, modrmReg 1 0 ], [ ( 0x93, 0x00 ) ] )

                        Cgtd ->
                            ( [ 0x66, 0x0F, 0x2E, modrmReg 0 1 ], [ ( 0x97, 0x00 ) ] )

                        Cged ->
                            ( [ 0x66, 0x0F, 0x2E, modrmReg 0 1 ], [ ( 0x93, 0x00 ) ] )

                        _ ->
                            ( [ 0x66, 0x0F, 0x2E, modrmReg 0 1 ], [ ( 0x94, 0x00 ) ] )

                e3 =
                    put pre e2

                e4 =
                    List.foldl (\( opc, rm ) acc -> put (setcc opc rm) acc) e3 sets

                e5 =
                    put [ 0x0F, 0xB6, 0xC0 ] e4
            in
            storeGPR rax dst e5

        _ ->
            let
                wide =
                    oty /= W

                e1 =
                    loadGPR rax oty x e

                e2 =
                    loadGPR rcx oty y e1

                e3 =
                    put (rex wide rcx rax ++ [ 0x39, modrmReg rcx rax ]) e2

                cc =
                    case op of
                        Ceq ->
                            0x94

                        Cne ->
                            0x95

                        Cslt ->
                            0x9C

                        Csle ->
                            0x9E

                        Csgt ->
                            0x9F

                        Csge ->
                            0x9D

                        _ ->
                            0x94

                e4 =
                    put (setcc cc 0) e3

                e5 =
                    put [ 0x0F, 0xB6, 0xC0 ] e4
            in
            storeGPR rax dst e5


-- setcc %al / setcc %cl (mod 11)
setcc : Int -> Int -> List Int
setcc opc rm =
    [ 0x0F, opc, modrmReg 0 rm ]


load : Maybe String -> Ty -> LoadOp -> Arg -> Emit -> Emit
load dst ty op a e =
    let
        e1 =
            loadAddr r11 a e
    in
    case op of
        LoadD ->
            storeXmm 0 dst (put ([ 0xF2, 0x0F, 0x10 ] ++ memInd 0 r11) e1)

        LoadW ->
            if ty == W then
                storeGPR rax dst (put ([ 0x8B ] ++ memInd 0 r11) e1)

            else
                storeGPR rax dst (put ([ 0x48, 0x63 ] ++ memInd 0 r11) e1)

        LoadL ->
            storeGPR rax dst (put ([ 0x48, 0x8B ] ++ memInd 0 r11) e1)

        LoadUb ->
            storeGPR rax dst (put ([ 0x0F, 0xB6 ] ++ memInd 0 r11) e1)

        LoadUw ->
            storeGPR rax dst (put ([ 0x8B ] ++ memInd 0 r11) e1)

        LoadUh ->
            storeGPR rax dst (put ([ 0x0F, 0xB7 ] ++ memInd 0 r11) e1)

        LoadSh ->
            if ty == W then
                storeGPR rax dst (put ([ 0x0F, 0xBF ] ++ memInd 0 r11) e1)

            else
                storeGPR rax dst (put ([ 0x48, 0x0F, 0xBF ] ++ memInd 0 r11) e1)

        LoadSb ->
            if ty == W then
                storeGPR rax dst (put ([ 0x0F, 0xBE ] ++ memInd 0 r11) e1)

            else
                storeGPR rax dst (put ([ 0x48, 0x0F, 0xBE ] ++ memInd 0 r11) e1)


store : StoreTy -> Arg -> Arg -> Emit -> Emit
store st v addr e =
    let
        e1 =
            case st of
                StoreD ->
                    loadXmm 0 v e

                StoreL ->
                    loadGPR rax L v e

                _ ->
                    loadGPR rax W v e

        e2 =
            loadAddr r11 addr e1
    in
    case st of
        StoreW ->
            put ([ 0x89 ] ++ memInd rax r11) e2

        StoreL ->
            put ([ 0x48, 0x89 ] ++ memInd rax r11) e2

        StoreB ->
            put ([ 0x88 ] ++ memInd rax r11) e2

        StoreH ->
            put ([ 0x66, 0x89 ] ++ memInd rax r11) e2

        StoreD ->
            put ([ 0xF2, 0x0F, 0x11 ] ++ memInd 0 r11) e2


blit : Arg -> Arg -> Int -> Emit -> Emit
blit src dst n e =
    let
        e1 =
            loadAddr rsi src e

        e2 =
            loadAddr rdi dst e1

        e3 =
            put (movImm rcx W n) e2
    in
    put [ 0xF3, 0xA4 ] e3


alloc : String -> Int -> Emit -> Emit
alloc r n e =
    let
        disp =
            slotDisp r e

        e1 =
            put (leaRb rax disp) e
    in
    put (movSlotStore rax L disp) e1


unary : Maybe String -> Ty -> UnaryOp -> Arg -> Emit -> Emit
unary dst ty op a e =
    let
        -- every conversion reads a memory operand; a constant is materialized
        -- first so the register forms are never needed
        ( e1, mem ) =
            case a of
                Tmp t ->
                    ( e, Just (slotDisp t e) )

                Con n ->
                    let
                        e1a =
                            put (movImm rax (operandTy op) n) e
                    in
                    ( e1a, Nothing )

                Sym s ->
                    let
                        e1a =
                            putReloc Obj.RPc32 s (-4) (leaSym rax) e
                    in
                    ( e1a, Nothing )
    in
    case op of
        Extsw ->
            if ty == W then
                storeGPR rax dst e1

            else
                case mem of
                    Just d ->
                        storeGPR rax dst (put ([ 0x48, 0x63 ] ++ memRb 0 d) e1)

                    Nothing ->
                        storeGPR rax dst (put [ 0x48, 0x63, 0xC0 ] e1)

        Extuw ->
            if ty == W then
                storeGPR rax dst e1

            else
                case mem of
                    Just d ->
                        storeGPR rax dst (put ([ 0x8B ] ++ memRb 0 d) e1)

                    Nothing ->
                        storeGPR rax dst e1

        Sltof ->
            let
                e2 =
                    case mem of
                        Just d ->
                            put ([ 0xF2, 0x48, 0x0F, 0x2A ] ++ memRb 0 d) e1

                        Nothing ->
                            put [ 0xF2, 0x48, 0x0F, 0x2A, 0xC0 ] e1
            in
            storeXmm 0 dst e2

        Dtosi ->
            let
                e2 =
                    case mem of
                        Just d ->
                            put ([ 0xF2, 0x0F, 0x2C ] ++ memRb 0 d) e1

                        Nothing ->
                            put [ 0xF2, 0x0F, 0x2C, 0xC0 ] e1
            in
            storeGPR rax dst e2


operandTy : UnaryOp -> Ty
operandTy op =
    case op of
        Extsw ->
            W

        Extuw ->
            W

        Sltof ->
            L

        Dtosi ->
            D


-- ============================ calls ============================


call : Maybe String -> AbiTy -> Arg -> List CallArg -> Emit -> Emit
call dst ty target args e =
    let
        -- 1. stack arguments (by-value aggregates and register overflow).
        --    First, because the copy clobbers rax/r11 and nothing has been
        --    placed in an argument register yet.
        e1 =
            stackArgs args 0 0 0 e

        -- 2. the hidden sret pointer, in the first GP register
        e2 =
            case ( ty, dst ) of
                ( Agg _, Just r ) ->
                    put (leaRb rdi (sretDisp r e1)) e1

                _ ->
                    e1

        -- 3. register arguments, in declaration order
        e3 =
            regArgs args
                (if isAgg ty then
                    1

                 else
                    0
                )
                0
                e2

        -- 4. env LAST: it rides in rax, which the loaders above use as scratch
        e4 =
            case findEnv args of
                Nothing ->
                    e3

                Just a ->
                    loadGPR rax L a e3

        -- 5. the call itself
        e5 =
            case target of
                Sym s ->
                    putReloc Obj.RPlt32 s (-4) ([ 0xE8 ] ++ le32 0) e4

                Tmp t ->
                    let
                        e4a =
                            put (movSlotReg r11 L (slotDisp t e4)) e4
                    in
                    put [ 0x41, 0xFF, 0xD3 ] e4a

                Con n ->
                    put [ 0x41, 0xFF, 0xD3 ] (put (movImm r11 L n) e4)
    in
    -- 6. the result
    case dst of
        Nothing ->
            e5

        Just r ->
            case ty of
                Agg _ ->
                    put (movSlotStore rax L (slotDisp r e5)) e5

                Base D ->
                    storeXmm 0 (Just r) e5

                Base S ->
                    e5

                Base b ->
                    put (movSlotStore rax b (slotDisp r e5)) e5


findEnv : List CallArg -> Maybe Arg
findEnv args =
    case args of
        [] ->
            Nothing

        ArgEnv a :: _ ->
            Just a

        _ :: rest ->
            findEnv rest


stackArgs : List CallArg -> Int -> Int -> Int -> Emit -> Emit
stackArgs args gp xmm stack e =
    case args of
        [] ->
            e

        ArgEllipsis :: rest ->
            stackArgs rest gp xmm stack e

        ArgEnv _ :: rest ->
            stackArgs rest gp xmm stack e

        ArgVal t a :: rest ->
            case t of
                Agg name ->
                    let
                        size =
                            typeSize e.types name

                        off =
                            alignTo 8 stack

                        e1 =
                            loadAddr r11 a e

                        e2 =
                            copyWords r11 off size e1
                    in
                    stackArgs rest gp xmm (off + alignTo 8 size) e2

                Base S ->
                    if xmm >= 8 then
                        stackArgs rest gp (xmm + 1) (stack + 8) (stackScalar a stack e)

                    else
                        stackArgs rest gp (xmm + 1) stack e

                Base D ->
                    if xmm >= 8 then
                        stackArgs rest gp (xmm + 1) (stack + 8) (stackScalar a stack e)

                    else
                        stackArgs rest gp (xmm + 1) stack e

                Base _ ->
                    if gp >= 6 then
                        stackArgs rest (gp + 1) xmm (stack + 8) (stackScalar a stack e)

                    else
                        stackArgs rest (gp + 1) xmm stack e


stackScalar : Arg -> Int -> Emit -> Emit
stackScalar a off e =
    let
        e1 =
            loadGPR r11 L a e
    in
    put (movSlotStore r11 L (outDisp off e)) e1


regArgs : List CallArg -> Int -> Int -> Emit -> Emit
regArgs args gp xmm e =
    case args of
        [] ->
            e

        ArgEllipsis :: rest ->
            regArgs rest gp xmm e

        ArgEnv _ :: rest ->
            regArgs rest gp xmm e

        ArgVal t a :: rest ->
            case t of
                Agg _ ->
                    regArgs rest gp xmm e

                Base S ->
                    regArgs rest gp (xmm + 1) e

                Base D ->
                    if xmm >= 8 then
                        regArgs rest gp (xmm + 1) e

                    else
                        regArgs rest gp (xmm + 1) (loadXmmSlot xmm a e)

                Base ty ->
                    if gp >= 6 then
                        regArgs rest (gp + 1) xmm e

                    else
                        regArgs rest (gp + 1) xmm (loadGPR (gpReg gp) ty a e)


gpReg : Int -> Int
gpReg i =
    case i of
        0 ->
            rdi

        1 ->
            rsi

        2 ->
            rdx

        3 ->
            rcx

        4 ->
            r8

        5 ->
            r9

        _ ->
            rdi


-- ============================ operand loads / stores ============================


loadGPR : Int -> Ty -> Arg -> Emit -> Emit
loadGPR reg ty a e =
    case a of
        Con n ->
            put (movImm reg ty n) e

        Tmp t ->
            put (movSlotReg reg ty (slotDisp t e)) e

        Sym s ->
            putReloc Obj.RPc32 s (-4) (leaSym reg) e


loadXmm : Int -> Arg -> Emit -> Emit
loadXmm n a e =
    case a of
        Tmp t ->
            put ([ 0xF2, 0x0F, 0x10 ] ++ memRb n (slotDisp t e)) e

        Con _ ->
            -- no double constants exist in this IL (Il.Arg's Con is an Int);
            -- a `d` operand is always a temporary
            e

        Sym _ ->
            e


loadXmmSlot : Int -> Arg -> Emit -> Emit
loadXmmSlot n a e =
    loadXmm n a e


-- the address a pointer operand holds
loadAddr : Int -> Arg -> Emit -> Emit
loadAddr reg a e =
    loadGPR reg L a e


storeGPR : Int -> Maybe String -> Emit -> Emit
storeGPR reg dst e =
    case dst of
        Nothing ->
            e

        Just t ->
            put (movSlotStore reg (slotTy t e) (slotDisp t e)) e


storeXmm : Int -> Maybe String -> Emit -> Emit
storeXmm n dst e =
    case dst of
        Nothing ->
            e

        Just t ->
            put ([ 0xF2, 0x0F, 0x11 ] ++ memRb n (slotDisp t e)) e


slotDisp : String -> Emit -> Int
slotDisp t e =
    case Dict.get t e.plan.slots of
        Just s ->
            s.disp

        Nothing ->
            0


slotTy : String -> Emit -> Ty
slotTy t e =
    case Dict.get t e.plan.slots of
        Just s ->
            s.ty

        Nothing ->
            L


sretDisp : String -> Emit -> Int
sretDisp r e =
    case Dict.get r e.plan.sret of
        Just d ->
            d

        Nothing ->
            0


outDisp : Int -> Emit -> Int
outDisp k e =
    -(e.plan.frameSize - k)


copyWords : Int -> Int -> Int -> Emit -> Emit
copyWords srcReg off size e =
    copyWordsGo srcReg off size 0 e


copyWordsGo : Int -> Int -> Int -> Int -> Emit -> Emit
copyWordsGo srcReg off size k e =
    if k + 8 > size then
        e

    else
        let
            e1 =
                put ([ 0x48, 0x8B ] ++ memIndOff rax srcReg k) e

            e2 =
                put (movSlotStore rax L (outDisp (off + k) e1)) e1
        in
        copyWordsGo srcReg off size (k + 8) e2


-- ============================ raw encoders ============================


put : List Int -> Emit -> Emit
put bs e =
    { e | rev = List.foldl (::) e.rev bs, len = e.len + List.length bs }


putReloc : Obj.RelocKind -> String -> Int -> List Int -> Emit -> Emit
putReloc kind sym addend bs e =
    { e
        | rev = List.foldl (::) e.rev bs
        , len = e.len + List.length bs
        , relocs = { off = e.len, kind = kind, sym = sym, addend = addend } :: e.relocs
    }


-- A branch: the displacement field is patched once every block's offset is
-- known (a forward reference costs nothing).
emitJump : Maybe Int -> String -> Emit -> Emit
emitJump cc label e =
    let
        opc =
            case cc of
                Nothing ->
                    [ 0xE9 ]

                Just c ->
                    [ 0x0F, 0x80 + c ]

        fix =
            { off = e.len + List.length opc, label = label }

        e1 =
            put (opc ++ le32 0) e
    in
    { e1 | fixups = fix :: e1.fixups }


-- ============================ fixups ============================


sortFixups : List Fixup -> List Fixup
sortFixups pending =
    sortGo pending []


sortGo : List Fixup -> List Fixup -> List Fixup
sortGo pending done =
    case pending of
        [] ->
            done

        f :: rest ->
            sortGo rest (insertFixup f done)


insertFixup : Fixup -> List Fixup -> List Fixup
insertFixup f done =
    case done of
        [] ->
            [ f ]

        g :: rest ->
            if f.off <= g.off then
                f :: g :: rest

            else
                g :: insertFixup f rest


-- One walk over the bytes with the fixups sorted by offset: linear in the
-- function's size, with no per-byte dictionary lookup.
patch : Dict String Int -> List Int -> List Fixup -> List Int -> Int -> List Int
patch labels bytes fixups acc idx =
    case fixups of
        [] ->
            List.reverse acc ++ bytes

        f :: rest ->
            let
                skip =
                    f.off - idx

                ( head, tailBytes ) =
                    splitAt skip bytes

                ( _, afterField ) =
                    splitAt 4 tailBytes

                target =
                    case Dict.get f.label labels of
                        Just t ->
                            t

                        -- Unreachable: the IL's jumps name blocks of the same
                        -- function.  A wrong target would be a wrong jump, so
                        -- it lands on the block's own offset instead of 0.
                        Nothing ->
                            f.off

                disp =
                    target - (f.off + 4)

                acc1 =
                    List.reverse (le32 disp) ++ List.reverse head ++ acc
            in
            patch labels afterField rest acc1 (f.off + 4)


splitAt : Int -> List a -> ( List a, List a )
splitAt n xs =
    if n <= 0 then
        ( [], xs )

    else
        case xs of
            [] ->
                ( [], [] )

            x :: rest ->
                let
                    ( a, b ) =
                        splitAt (n - 1) rest
                in
                ( x :: a, b )


-- ============================ registers ============================


rax : Int
rax =
    0


rcx : Int
rcx =
    1


rdx : Int
rdx =
    2


rsp : Int
rsp =
    4


rbp : Int
rbp =
    5


rsi : Int
rsi =
    6


rdi : Int
rdi =
    7


r8 : Int
r8 =
    8


r9 : Int
r9 =
    9


r10 : Int
r10 =
    10


r11 : Int
r11 =
    11


-- REX, emitted only when it carries a bit: a bare 0x40 changes the meaning of
-- spl/bpl/sil/dil, which this backend never names.
rex : Bool -> Int -> Int -> List Int
rex wide r b =
    let
        v =
            0x40
                + (if wide then
                    8

                   else
                    0
                  )
                + (if r >= 8 then
                    4

                   else
                    0
                  )
                + (if b >= 8 then
                    1

                   else
                    0
                  )
    in
    if v == 0x40 then
        []

    else
        [ v ]


-- mod 11 (register direct)
modrmReg : Int -> Int -> Int
modrmReg r rm =
    0xC0 + (modBy 8 r * 8) + modBy 8 rm


-- [reg] (mod 00; `reg` may not be rbp/r13, which is why every slot access goes
-- through memRb instead)
memInd : Int -> Int -> List Int
memInd r rm =
    rex False r rm ++ [ (modBy 8 r * 8) + modBy 8 rm ]


-- [reg + k]
memIndOff : Int -> Int -> Int -> List Int
memIndOff r rm k =
    if k == 0 then
        memInd r rm

    else if k <= 127 then
        rex False r rm ++ [ 0x40 + (modBy 8 r * 8) + modBy 8 rm, k ]

    else
        rex False r rm ++ [ 0x80 + (modBy 8 r * 8) + modBy 8 rm ] ++ le32 k


-- [rbp + disp]
memRb : Int -> Int -> List Int
memRb r disp =
    if disp >= -128 && disp <= 127 then
        [ 0x45 + modBy 8 r * 8, modBy 256 disp ]

    else
        [ 0x85 + modBy 8 r * 8 ] ++ le32 disp


movSlotReg : Int -> Ty -> Int -> List Int
movSlotReg reg ty disp =
    rex (ty /= W) reg rbp ++ [ 0x8B ] ++ memRb reg disp


movSlotStore : Int -> Ty -> Int -> List Int
movSlotStore reg ty disp =
    rex (ty /= W) reg rbp ++ [ 0x89 ] ++ memRb reg disp


movImm : Int -> Ty -> Int -> List Int
movImm reg ty n =
    if ty == W then
        rex False 0 reg ++ [ 0xB8 + modBy 8 reg ] ++ le32 n

    else if n >= -2147483648 && n <= 2147483647 then
        rex True 0 reg ++ [ 0xC7, modrmReg 0 reg ] ++ le32 n

    else
        rex True 0 reg ++ [ 0xB8 + modBy 8 reg ] ++ le64 n


leaRb : Int -> Int -> List Int
leaRb reg disp =
    rex True reg rbp ++ [ 0x8D ] ++ memRb reg disp


-- lea sym(%rip), %reg
leaSym : Int -> List Int
leaSym reg =
    rex True reg 0 ++ [ 0x8D, (modBy 8 reg * 8) + 5 ] ++ le32 0


-- ============================ byte helpers ============================


strBytes : String -> List Int
strBytes s =
    List.map Char.toCode (String.toList s)


le32 : Int -> List Int
le32 n =
    [ modBy 256 n
    , modBy 256 (n // 256)
    , modBy 256 (n // 65536)
    , modBy 256 (n // 16777216)
    ]


-- See Mid.Qbe.Obj's le64: the high word is the FLOOR of n / 2^32 so a
-- negative displacement or immediate gets its upper bytes sign-filled.
le64 : Int -> List Int
le64 n =
    let
        rem =
            modBy 4294967296 n
    in
    le32 rem ++ le32 ((n - rem) // 4294967296)


alignTo : Int -> Int -> Int
alignTo n v =
    let
        r =
            modBy n v
    in
    if r == 0 then
        v

    else
        v + (n - r)


pad : Int -> Int -> List Int
pad from to =
    List.repeat (to - from) 0
