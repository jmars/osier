module Mid.Qbe.Obj exposing
    ( Object
    , Reloc
    , RelocKind(..)
    , Sym
    , SymBind(..)
    , SymKind(..)
    , SymSec(..)
    , empty
    , relocType
    , serialize
    )

-- Mid.Qbe.Obj — the ELF64 container for the native backend's machine code
-- (handoff-osier-asm S1a; plan2's D-A route (c), the in-compiler encoder).
--
-- INPUT: bytes and symbol/relocation LISTS from Mid.Qbe.Encode.  This module
-- knows nothing about the IL: it lays out an ET_REL x86-64 object and writes
-- it.  TWO-PHASE BY CONSTRUCTION — Encode emits every byte with its relocs
-- naming SYMBOLS, and the symbol table is laid out HERE, after all the code
-- exists, so a forward reference costs nothing (no fixup chains).
--
-- SECTION LAYOUT is the one pass-1 MEASURED as GNU-acceptable
-- (handoff-osier-asm-plan): NULL, .text, .rela.text, .data, .rela.data,
-- .bss, .note.GNU-stack, .symtab, .strtab, .shstrtab.  Deviations from what
-- GNU as emits for the same input, both deliberate:
--   * no .note.gnu.property (as adds it for endbr64/IBT; ld accepts its
--     absence, and nothing in this backend emits endbr64);
--   * relocations always name a SYMBOL, never a section+addend (as resolves
--     local references at assembly time and names sections for the rest).
--     Both forms link identically; tools/qbe/obj-diff.sh normalizes the two
--     to the same target before comparing, and states that normalization.
--
-- .note.GNU-stack IS REQUIRED and is emitted empty: without it ld assumes the
-- object wants an executable stack (pass-1 finding, MEASURED there).
--
-- BYTES ARE EMITTED AS A STRING, which is byte-indexed in this tree's
-- selfhost runtime (Prelude's Char is one byte; see Mid.Qbe.Print's
-- `stringIsByteIndexed` probe).  Encode refuses to run on a code-point-indexed
-- runtime rather than silently UTF-8-expanding every byte >= 0x80.

import Char
import Dict exposing (Dict)


-- ============================ THE OBJECT ============================


type alias Object =
    { text : List Int -- .text bytes, in order
    , textRelocs : List Reloc -- by ascending offset
    , data : List Int -- .data bytes, in order
    , dataRelocs : List Reloc
    , bssSize : Int
    , syms : List Sym -- definitions (any order) then undefined externs
    }


type alias Reloc =
    { off : Int -- offset within the section
    , kind : RelocKind
    , sym : String -- the symbol this field resolves against
    , addend : Int
    }


type RelocKind
    = R64 -- R_X86_64_64: an absolute 8-byte data word
    | RPc32 -- R_X86_64_PC32: a rip-relative disp32
    | RPlt32 -- R_X86_64_PLT32: a call rel32
    | R32S -- R_X86_64_32S: a $sym immediate (reserved; no site emits one today)


relocType : RelocKind -> Int
relocType k =
    case k of
        R64 ->
            1

        RPc32 ->
            2

        RPlt32 ->
            4

        R32S ->
            11


type SymBind
    = Local
    | Global


type SymKind
    = SymFunc
    | SymObject
    | SymNoType


type SymSec
    = InText
    | InData
    | InBss
    | Undefined


type alias Sym =
    { name : String
    , bind : SymBind
    , kind : SymKind
    , sec : SymSec
    , value : Int
    , size : Int
    }


empty : Object
empty =
    { text = []
    , textRelocs = []
    , data = []
    , dataRelocs = []
    , bssSize = 0
    , syms = []
    }


-- ============================ SERIALIZE ============================


serialize : Object -> String
serialize obj =
    let
        -- the symbol table: null, then the two SECTION symbols the plan
        -- states (.text and .data), then locals, then globals+externs.
        defs =
            obj.syms

        ( locals, nonLocals ) =
            partitionLocals defs

        syms =
            nullSym :: textSecSym :: dataSecSym :: locals ++ nonLocals

        firstGlobal =
            3 + List.length locals

        strtab =
            stringTable syms

        symIndex =
            indexSyms syms

        -- sizes
        textSize =
            List.length obj.text

        dataSize =
            List.length obj.data

        relaTextSize =
            24 * List.length obj.textRelocs

        relaDataSize =
            24 * List.length obj.dataRelocs

        symtabSize =
            24 * List.length syms

        strtabSize =
            List.length strtab

        shstr =
            stringTableBytes
                [ ""
                , ".text"
                , ".rela.text"
                , ".data"
                , ".rela.data"
                , ".bss"
                , ".note.GNU-stack"
                , ".symtab"
                , ".strtab"
                , ".shstrtab"
                ]

        -- offsets: the header is 64 bytes, every section is aligned as the
        -- section header states.
        textOff =
            align 16 64

        relaTextOff =
            align 8 (textOff + textSize)

        dataOff =
            align 8 (relaTextOff + relaTextSize)

        relaDataOff =
            align 8 (dataOff + dataSize)

        bssOff =
            align 8 (relaDataOff + relaDataSize)

        noteOff =
            bssOff

        symtabOff =
            align 8 noteOff

        strtabOff =
            symtabOff + symtabSize

        shstrOff =
            strtabOff + strtabSize

        shOff =
            align 8 (shstrOff + List.length shstr)

        total =
            shOff + (64 * nSections)
    in
    bytesToString
        (elfHeader shOff
            ++ padTo 16 64 []
            ++ obj.text
            ++ padTo 8 (textOff + textSize) []
            ++ relocs obj.textRelocs symIndex
            ++ padTo 8 (relaTextOff + relaTextSize) []
            ++ obj.data
            ++ padTo 8 (dataOff + dataSize) []
            ++ relocs obj.dataRelocs symIndex
            ++ padTo 8 (relaDataOff + relaDataSize) []
            ++ padTo 8 noteOff []
            ++ symtab syms strtabOff
            ++ strtab
            ++ shstr
            ++ padTo 8 (shstrOff + List.length shstr) []
            ++ sectionHeaders
                { textOff = textOff
                , textSize = textSize
                , relaTextOff = relaTextOff
                , relaTextSize = relaTextSize
                , dataOff = dataOff
                , dataSize = dataSize
                , relaDataOff = relaDataOff
                , relaDataSize = relaDataSize
                , bssOff = bssOff
                , bssSize = obj.bssSize
                , noteOff = noteOff
                , symtabOff = symtabOff
                , symtabSize = symtabSize
                , firstGlobal = firstGlobal
                , strtabOff = strtabOff
                , strtabSize = strtabSize
                , shstrOff = shstrOff
                , shstrSize = List.length shstr
                , shOff = shOff
                }
            |> padTo 1 total
        )




-- ============================ SYMBOL TABLE ============================


nullSym : Sym
nullSym =
    { name = "", bind = Local, kind = SymNoType, sec = Undefined, value = 0, size = 0 }


textSecSym : Sym
textSecSym =
    { name = "", bind = Local, kind = SymNoType, sec = InText, value = 0, size = 0 }


dataSecSym : Sym
dataSecSym =
    { name = "", bind = Local, kind = SymNoType, sec = InData, value = 0, size = 0 }


-- Locals first (the ELF rule: sh_info is the index of the first non-local),
-- each group keeping the order Encode defined its symbols in.
partitionLocals : List Sym -> ( List Sym, List Sym )
partitionLocals syms =
    ( List.filter (\s -> s.bind == Local) syms
    , List.filter (\s -> s.bind /= Local) syms
    )


-- name -> symbol index, for relocation r_info.  Only NAMED symbols are
-- indexed: the null and section entries have the empty name and are never a
-- relocation target.  A duplicate name cannot happen — Encode defines each IL
-- name once and either defines or leaves undefined the rest.
indexSyms : List Sym -> Dict String Int
indexSyms syms =
    indexSymsHelp syms 0 Dict.empty


indexSymsHelp : List Sym -> Int -> Dict String Int -> Dict String Int
indexSymsHelp syms i acc =
    case syms of
        [] ->
            acc

        s :: rest ->
            indexSymsHelp rest (i + 1)
                (if s.name == "" then
                    acc

                 else
                    Dict.insert s.name i acc
                )


-- ============================ RELOCATIONS ============================


relocs : List Reloc -> Dict String Int -> List Int
relocs rs symIndex =
    List.concat (List.map (relocBytes symIndex) rs)


relocBytes : Dict String Int -> Reloc -> List Int
relocBytes symIndex r =
    let
        idx =
            case Dict.get r.sym symIndex of
                Just i ->
                    i

                -- Unreachable: Encode adds an undefined symbol for every name
                -- a reloc mentions.  Emitting a null-symbol reloc here would
                -- be a link-time surprise, so it stays index 0 (the null
                -- symbol) and shows up as a null relocation in readelf.
                Nothing ->
                    0
    in
    le64 r.off
        ++ le32 (relocType r.kind)
        ++ le32 idx
        ++ le64 r.addend


-- ============================ SYMTAB / STRTAB ============================


-- The string table: index 0 is the empty name; names in symtab order.
stringTable : List Sym -> List Int
stringTable syms =
    stringTableBytes (List.map .name syms)


stringTableBytes : List String -> List Int
stringTableBytes names =
    0 :: strtabGo names 1


strtabGo : List String -> Int -> List Int
strtabGo names off =
    case names of
        [] ->
            []

        n :: rest ->
            strBytes n ++ (0 :: strtabGo rest (off + 1 + String.length n))


-- name offsets, computed the same way `stringTable` lays them out.
nameOffsets : List String -> List ( String, Int )
nameOffsets names =
    offsetsGo names 1


offsetsGo : List String -> Int -> List ( String, Int )
offsetsGo names off =
    case names of
        [] ->
            []

        n :: rest ->
            ( n, off ) :: offsetsGo rest (off + 1 + String.length n)


symtab : List Sym -> Int -> List Int
symtab syms strtabOff =
    symtabGo syms (nameOffsets (List.map .name syms)) strtabOff


symtabGo : List Sym -> List ( String, Int ) -> Int -> List Int
symtabGo syms offsets strtabOff =
    case ( syms, offsets ) of
        ( s :: rest, ( _, off ) :: restOffsets ) ->
            le32 off
                ++ [ infoByte s.bind s.kind, 0 ]
                ++ le16 (sectionIndex s.sec)
                ++ le64 s.value
                ++ le64 s.size
                ++ symtabGo rest restOffsets strtabOff

        _ ->
            []


infoByte : SymBind -> SymKind -> Int
infoByte bind kind =
    (bindBits bind * 16) + kindBits kind


bindBits : SymBind -> Int
bindBits b =
    case b of
        Local ->
            0

        Global ->
            1


kindBits : SymKind -> Int
kindBits k =
    case k of
        SymNoType ->
            0

        SymObject ->
            1

        SymFunc ->
            2


sectionIndex : SymSec -> Int
sectionIndex sec =
    case sec of
        Undefined ->
            0

        InText ->
            iText

        InData ->
            iData

        InBss ->
            iBss


-- ============================ ELF HEADER ============================


nSections : Int
nSections =
    10


iText : Int
iText =
    1


iRelaText : Int
iRelaText =
    2


iData : Int
iData =
    3


iRelaData : Int
iRelaData =
    4


iBss : Int
iBss =
    5


iNote : Int
iNote =
    6


iSymtab : Int
iSymtab =
    7


iStrtab : Int
iStrtab =
    8


iShstrtab : Int
iShstrtab =
    9


elfHeader : Int -> List Int
elfHeader shOff =
    [ 0x7F, 0x45, 0x4C, 0x46 -- \x7f E L F
    , 2 -- ELFCLASS64
    , 1 -- ELFDATA2LSB
    , 1 -- EV_CURRENT
    , 0 -- ELFOSABI_NONE
    , 0, 0, 0, 0, 0, 0, 0, 0 -- EI_ABIVERSION + padding
    ]
        ++ le16 1 -- ET_REL
        ++ le16 62 -- EM_X86_64
        ++ le32 1 -- EV_CURRENT
        ++ le64 0 -- e_entry
        ++ le64 0 -- e_phoff
        ++ le64 shOff
        ++ le32 0 -- e_flags
        ++ le16 64 -- e_ehsize
        ++ le16 0 -- e_phentsize
        ++ le16 0 -- e_phnum
        ++ le16 64 -- e_shentsize
        ++ le16 nSections
        ++ le16 iShstrtab


sectionHeaders :
    { textOff : Int
    , textSize : Int
    , relaTextOff : Int
    , relaTextSize : Int
    , dataOff : Int
    , dataSize : Int
    , relaDataOff : Int
    , relaDataSize : Int
    , bssOff : Int
    , bssSize : Int
    , noteOff : Int
    , symtabOff : Int
    , symtabSize : Int
    , firstGlobal : Int
    , strtabOff : Int
    , strtabSize : Int
    , shstrOff : Int
    , shstrSize : Int
    , shOff : Int
    }
    -> List Int
sectionHeaders o =
    let
        names =
            nameOffsets
                [ ""
                , ".text"
                , ".rela.text"
                , ".data"
                , ".rela.data"
                , ".bss"
                , ".note.GNU-stack"
                , ".symtab"
                , ".strtab"
                , ".shstrtab"
                ]

        nameOf i =
            case List.drop i names of
                ( _, off ) :: _ ->
                    off

                [] ->
                    0
    in
    List.repeat 64 0
        ++ sectionHeader (nameOf iText) 1 0x6 o.textOff o.textSize 0 0 16 0
        ++ sectionHeader (nameOf iRelaText) 4 0 o.relaTextOff o.relaTextSize iSymtab iText 8 24
        ++ sectionHeader (nameOf iData) 1 0x3 o.dataOff o.dataSize 0 0 8 0
        ++ sectionHeader (nameOf iRelaData) 4 0 o.relaDataOff o.relaDataSize iSymtab iData 8 24
        ++ sectionHeader (nameOf iBss) 8 0x3 o.bssOff o.bssSize 0 0 8 0
        ++ sectionHeader (nameOf iNote) 1 0 o.noteOff 0 0 0 1 0
        ++ sectionHeader (nameOf iSymtab) 2 0 o.symtabOff o.symtabSize iStrtab o.firstGlobal 8 24
        ++ sectionHeader (nameOf iStrtab) 3 0 o.strtabOff o.strtabSize 0 0 1 0
        ++ sectionHeader (nameOf iShstrtab) 3 0 o.shstrOff o.shstrSize 0 0 1 0


sectionHeader : Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> List Int
sectionHeader name typ flags off size link info alignment entsize =
    le32 name
        ++ le32 typ
        ++ le64 flags
        ++ le64 0 -- sh_addr
        ++ le64 off
        ++ le64 size
        ++ le32 link
        ++ le32 info
        ++ le64 alignment
        ++ le64 entsize


-- ============================ BYTE HELPERS ============================


strBytes : String -> List Int
strBytes s =
    List.map Char.toCode (String.toList s)


le16 : Int -> List Int
le16 n =
    [ modBy 256 n, modBy 256 (n // 256) ]


le32 : Int -> List Int
le32 n =
    [ modBy 256 n
    , modBy 256 (n // 256)
    , modBy 256 (n // 65536)
    , modBy 256 (n // 16777216)
    ]


-- The high half is the FLOOR of n / 2^32, not the truncation: a negative
-- value (a PC32/PLT32 addend of -4 is the only one) needs its upper word
-- sign-filled, and Elm's `//` truncates toward zero.
le64 : Int -> List Int
le64 n =
    let
        rem =
            modBy 4294967296 n
    in
    le32 rem ++ le32 ((n - rem) // 4294967296)


align : Int -> Int -> Int
align n v =
    let
        r =
            modBy n v
    in
    if r == 0 then
        v

    else
        v + (n - r)


padTo : Int -> Int -> List Int -> List Int
padTo n current acc =
    List.repeat (align n current - current) 0 ++ acc
