module Mid.Qbe.Il exposing
    ( Module
    , Func
    , Block
    , Inst(..)
    , Jump(..)
    , Arg(..)
    , Ty(..)
    , AbiTy(..)
    , BinOp(..)
    , CmpOp(..)
    , UnaryOp(..)
    , LoadOp(..)
    , StoreTy(..)
    , CallArg(..)
    , TypeDef
    , DataDef
    , DataItem(..)
    , descType
    , retType
    , valType
    )

import Mid.RtLayout as RtLayout

-- Mid.Qbe.Il — QBE's intermediate language as an ELM DATATYPE (native-backend
-- stage 1; handoff-qbe-lower).
--
-- DESIGN (settled, do not redesign): the native backend lowers Mid.Ir into
-- THIS representation, does what peephole work it wants on it here in Elm,
-- and prints it as QBE IL text (`Mid.Qbe.Print`); `vendor/qbe/qbe` then
-- compiles the text to assembly.  One IR, a printer that is trivially
-- testable, and NO modification to QBE.
--
-- NO SSA LAYER: QBE constructs SSA itself.  `vendor/qbe/doc/il.txt:1020`:
-- phi instructions are NOT necessary for a frontend and "Contrary to LLVM,
-- QBE is able to fixup programs not in SSA form"; `vendor/qbe/main.c:11`
-- wires `ssa(fn)`/`ssacheck(fn)` into the pipeline.  So this IR is ordinary
-- (non-SSA) three-address code over uniquely-named temporaries: a temporary
-- MAY be assigned more than once (the printer emits every assignment; QBE's
-- SSA construction renames them).  Non-SSA shapes are exercised on purpose
-- (branch joins, loop rebinding, nested) — see tools/qbe/fixtures.
--
-- COVERAGE: only the IL shapes this backend generates are representable.
-- The IR is a HONEST SUBSET of QBE's instruction set, kept small on purpose
-- (base types w/l, memory ops, blit, comparisons, call with `env`, alloc,
-- jnz/jmp/ret, data and type definitions).  Adding an instruction here means
-- adding it to the printer and to every consumer — there is no catch-all
-- escape hatch, so an unsupported construct cannot be silently misprinted.


-- ============================ MODULE ============================


type alias Module =
    { layout : RtLayout.ValLayout -- VR3a: the Value layout this module was emitted FOR (Lower seeds it from its state; Print/Encode read it, so no printer can describe a layout the emitter did not use)
    , types : List TypeDef
    , datas : List DataDef
    , funcs : List Func
    }


-- THE LAYOUT IS DEFINED ONCE, IN Mid.RtLayout (handoff-osier-zigretire-plan
-- STAGE 2); these three type definitions are DERIVED from it — the emitted
-- IL cannot describe a different layout from the one that module states.
--
-- `type :val = align 8 { w, l, l, l, l }` — the VM's 40-byte tagged Value
-- (gc/types.zig: Value = extern struct { tag: ValTag, payload: union }),
-- ABI-verified against the vendored qbe: aggregate params arrive as
-- POINTERS, aggregate returns go through sret.
-- VR3a: the ONE typedef that flips with the representation, so it is built
-- from the layout INSTANCE the module was emitted with.  `:ret`/`:desc` below
-- are NOT Values and stay constants (see Mid.RtLayout's TRAP-3 note; `:ret`'s
-- `retKindOffset` is the coupling VR3b must derive).
valType : RtLayout.ValLayout -> TypeDef
valType layout =
    { name = "val"
    , align = Just RtLayout.abiAlign
    , fields = layout.valQbeFields
    }


-- `type :ret = align 8 { :val, w, l, l, l, w }` — the call-result shape every
-- generated function returns (the bounce-loop convention, transcribed from
-- tools/aot/runtime.zig's `Ret = .done | .tail`).  80 bytes, ABI-matched by
-- tools/qbe/rt.zig `Ret`; the FIELD OFFSETS are stated once, in
-- Mid.RtLayout (`retValOffset`/`retKindOffset`/`retFOffset`/`retEOffset`/
-- `retArgsOffset`/`retArityOffset`), and rt.zig asserts its own `Ret` against
-- them at comptime.  `.tail` is built by the runtime (rt_tail_known /
-- rt_apply_tail) so its env and args survive the caller's rt_frame_leave, and
-- chased by rt_bounce — which is why deep tail chains no longer grow the
-- native stack.
-- MUST BE DEFINED AFTER `:val` (QBE requires a type to precede its uses).
retType : TypeDef
retType =
    { name = "ret"
    , align = Just RtLayout.abiAlign
    , fields = RtLayout.retQbeFields
    }


-- `type :desc = align 8 { l, w, w }` — a static function descriptor:
-- { code: *const fn, arity: i32, ncaps: i32 } (see tools/qbe/rt.zig Desc and
-- Mid.RtLayout's `descTotalBytes`/`desc*Offset`; the emitted descriptor DATA
-- carries one more word than this TYPE, the global-closure cache — see
-- Mid.RtLayout).
-- A closure Value's `code` field points at one of these; the GC passes
-- non-heap pointers through unchanged (collect.zig gcMove), so a static
-- descriptor is never moved or scanned.
descType : TypeDef
descType =
    { name = "desc"
    , align = Just RtLayout.abiAlign
    , fields = RtLayout.descQbeFields
    }


type alias TypeDef =
    { name : String
    , align : Maybe Int
    , fields : List String
    }


type alias DataDef =
    { name : String
    , align : Maybe Int
    , items : List DataItem
    , export_ : Bool -- `export data` — needed for symbols the runtime links against
    }


type DataItem
    = DByte Int -- b N  (one byte)
    | DWord Int -- w N
    | DLong Int -- l N
    | DDouble Float -- d F
    | DStr String -- b "..."  (bytes, no terminator added)
    | DZero Int -- z N
    | DRef String -- l $name  (a pointer to another data/function symbol)


-- ============================ FUNCTIONS ============================


type alias Func =
    { name : String
    , export_ : Bool
    , ret : AbiTy
    , envParam : Bool
    , params : List ( String, AbiTy )
    , blocks : List Block
    }


type alias Block =
    { label : String
    , body : List Inst
    , jump : Jump
    }


type Jump
    = Jmp String
    | Jnz Arg String String
    | Ret (Maybe Arg)
    | Hlt
    | Fallthrough -- no jump printed: control flows into the next block


-- ============================ TYPES / ARGS ============================
-- Ty is QBE's base-type letter; AbiTy adds the aggregate positions (call
-- params/returns and :val loads by pointer) that the C ABI lowers to memory.


type Ty
    = W
    | L
    | S
    | D


type AbiTy
    = Base Ty
    | Agg String


type Arg
    = Con Int
    | Tmp String
    | Sym String


-- ============================ INSTRUCTIONS ============================


type Inst
    = -- %r =ty op a b   (arithmetic, bitwise)
      Bin (Maybe String) Ty BinOp Arg Arg
    | -- %r =w c<op><oty> a b  (comparisons: result is w, the SUFFIX comes
      -- from the OPERAND type oty — ceqw/ceql/csltw/csltl/...)
      Cmp (Maybe String) Ty CmpOp Arg Arg
    | -- %r =ty loadOP a
      Load (Maybe String) Ty LoadOp Arg
    | -- storeST val, addr
      Store StoreTy Arg Arg
    | -- blit src, dst, N   (CONSTANT N; src/dst are addresses)
      Blit Arg Arg Int
    | -- %r =abity call target(args)
      Call (Maybe String) AbiTy Arg (List CallArg)
    | -- %r =l allocN bytes   (CONSTANT size)
      Alloc String Int
    | -- a pure marker kept for readability of the printed IL; prints as a
      -- comment and is ignored by every consumer.
      Cmt String
    | -- %r =ty uop a   (conversions: the result type is the DESTINATION, the
      -- operand carries its own type — extsw/extuw read `w`, sltof reads `l`,
      -- stosi reads `d` and lands at `w` per its dst)
      Unary (Maybe String) Ty UnaryOp Arg


-- QBE's conversion mnemonics this backend builds (Mid.Qbe.Lower's Rt
-- raw-word lowering).  `extsw`/`extuw` widen w->l signed/zero (the i32
-- Bitwise results re-entering i64 land); `sltof` widens an i64 payload to
-- f64 (the M4 numeric promote); `stosi` narrows a double to a signed int at
-- the DESTINATION type (`w` = ToInt32, truncating toward zero).
type UnaryOp
    = Extsw
    | Extuw
    | Sltof
    | Dtosi


-- `Div` is the only op whose QBE spelling is not shared between the integer
-- and the float forms: `Bin dst L Add` prints `%r =l add` (QBE's `add` at type
-- `l`) and `Bin dst D Add` prints `%r =d add` (QBE's `add` at type `d`, i.e.
-- `addd` in QBE's internal op table) — the MNEMONIC is the same and the type
-- letter selects the float one.  Integer `div` never reaches this backend
-- (Elm's `//` goes to `rt_prim`), so `Div` is only ever built at `D`.
type BinOp
    = Add
    | Sub
    | Mul
    | Div
    | And
    | Or
    | Xor
    | -- the SHIFT family (QBE `shl`/`sar`/`shr`): both operands and the
      -- result share one type.  Built only by the Rt raw-word lowering
      -- (Mid.Qbe.Lower's RawBin), which applies the JS/Elm-Bitwise contract
      -- (w-typed operand, mask the count to 5 bits, sign- or zero-extend the
      -- result) before these ever print.
      Shl
    | Sar
    | Shr


-- Ceq/Cne/Cslt/Csle/Csgt/Csge are the SIGNED INTEGER family: with the operand
-- type appended they spell `ceqw`/`ceql`/`csltw`/`csltl`/... .  The `*d`
-- variants below are a DIFFERENT QBE instruction family — the float compares,
-- which drop the `s` (`cltd`, `cged`) and, at type `d`, are the only ones QBE
-- accepts: `cslt` + `d` is `csltd`, which is NOT in QBE's op table
-- (vendor/qbe/doc/il.txt:1126-1163) and is a parse error, not a retag — so a
-- float compare cannot be expressed by reusing Cslt.
--
-- The operand type still supplies the suffix (Mid.Qbe.Print), so these carry
-- the type `d` in every use this backend builds; at `s` they would spell
-- `ceqs`/`clts`/... which QBE also accepts.  A `w`/`l` operand type with one
-- of these is misprinted into a mnemonic QBE does not know — loud, not silent.
type CmpOp
    = Ceq
    | Cne
    | Cslt
    | Csle
    | Csgt
    | Csge
    | Ceqd
    | Cned
    | Cltd
    | Cled
    | Cgtd
    | Cged


type LoadOp
    = LoadW -- loadw (32-bit SIGN-extending; MEASURED: `%r =l loadw %p` gives -1 for 0xFFFFFFFF)
    | LoadL -- loadl (64-bit payloads)
    | LoadD -- loadd (float payloads, from static data)
    | LoadUb -- loadub (8-bit, ZERO-extended; the string-byte read)
    | -- (cffi U6) THE SUB-WORD LOAD FAMILY.  `doc/il.txt:715-745` gives
      -- `loaduw`/`loaduh`/`loadub` as the ZERO-extending variants and
      -- `loadsw`/`loadsh`/`loadsb` as the SIGN-extending ones, each `I(mm)`:
      -- the result may be `w` OR `l`, and the extension is the OP's own —
      -- MEASURED on the vendored qbe (`%r =l loadsh %p` of 0xFFFE gives -2;
      -- `%r =l loaduh %p` gives 65534; `%r =l loadsb %p` of 0xC8 gives -56)
      -- so a widening load needs NO separate `exts*` after it.  `loadw` is
      -- QBE's sugar for `loadsw` and stays the signed 32-bit form.
      LoadUw -- loaduw (32-bit, ZERO-extended)
    | LoadUh -- loaduh (16-bit, ZERO-extended)
    | LoadSh -- loadsh (16-bit, SIGN-extended)
    | LoadSb -- loadsb (8-bit, SIGN-extended)


type StoreTy
    = StoreW
    | StoreL
    | StoreD -- stored (64-bit float payloads; the load/store mirror of LoadD)
    | StoreB -- storeb (the string-byte write)
    | -- (cffi U6) storeh — 2 bytes.  `doc/il.txt:715-730`: byte and halfword
      -- stores take a WORD (`(w,m)`), and QBE's Subtyping rule ("any value of
      -- type `l` can be used in a `w` context") means an `l` temp is legal in
      -- that slot — MEASURED: `storeh %l, %addr` stores the low 16 bits.
      StoreH


type CallArg
    = ArgVal AbiTy Arg
    | ArgEnv Arg
    | -- (cffi U4) THE VARIADIC BOUNDARY MARKER — a literal `...` in QBE's IL,
      -- printed between the fixed and the variadic arguments (`doc/il.txt:925,
      -- 961-962`).  It carries NO operand: everything QBE needs beyond the
      -- position is the argument count it can already see, and it derives the
      -- vector-register count (`%al`) itself from the `d`-class arguments after
      -- the marker (MEASURED: `movl $1, %eax` after `call $printf(l $fmt,
      -- ..., d %d, w 42)`; `movl $0, %eax` with no float among them — plan §5).
      -- Nothing in this backend ever needs to compute `%al`.
      ArgEllipsis


-- ============================ HELPERS ============================


tmpName : Arg -> Maybe String
tmpName arg =
    case arg of
        Tmp t ->
            Just t

        _ ->
            Nothing


-- All temporaries READ by an instruction (not exposed; used by peephole
-- consumers inside this module's orbit via Print/Peephole re-derivation).
readsTmps : Inst -> List String
readsTmps inst =
    case inst of
        Bin _ _ _ a b ->
            List.filterMap tmpName [ a, b ]

        Cmp _ _ _ a b ->
            List.filterMap tmpName [ a, b ]

        Load _ _ _ a ->
            List.filterMap tmpName [ a ]

        Unary _ _ _ a ->
            List.filterMap tmpName [ a ]

        Store _ v addr ->
            List.filterMap tmpName [ v, addr ]

        Blit src dst _ ->
            List.filterMap tmpName [ src, dst ]

        Call _ _ target args ->
            List.filterMap tmpName (target :: List.filterMap callArgArg args)

        Alloc _ _ ->
            []

        Cmt _ ->
            []


callArgArg : CallArg -> Maybe Arg
callArgArg carg =
    case carg of
        ArgVal _ a ->
            Just a

        ArgEnv a ->
            Just a

        -- (cffi U4) the `...` marker carries NO operand — it is a position,
        -- not a value, so it contributes no temporary to the liveness walk.
        ArgEllipsis ->
            Nothing


{-| Temporaries an instruction DEFINES (used by the peephole's liveness; kept
here so the IL is the single authority on its own shape).
-}
defsTmp : Inst -> Maybe String
defsTmp inst =
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


{-| True when the instruction can start a GC (a call into the runtime or any
generated function).  The peephole must treat these as memory barriers: a
rooted frame slot's store/load pair may not be forwarded across one.
-}
isSafepoint : Inst -> Bool
isSafepoint inst =
    case inst of
        Call _ _ _ _ ->
            True

        _ ->
            False
