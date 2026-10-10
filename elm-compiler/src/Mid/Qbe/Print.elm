module Mid.Qbe.Print exposing (print)

-- Mid.Qbe.Print — Qbe.Il -> QBE IL text.
--
-- This printer is the ONLY text surface of the native backend: whatever it
-- prints is what `vendor/qbe/qbe` parses, so its correctness is checkable by
-- construction against the real binary (the driver script pipes its output
-- straight into qbe and reads the exit code).  The syntax implemented here
-- is documented in vendor/qbe/doc/il.txt; the two spots where the doc could
-- be misread were verified against the VENDORED SOURCE instead:
--   * blit argument order is (src, dst) — sysv.c:130-131 lowers the sret
--     copy as `emit(Oblit0, ..., r0, fn->retr)`, i.e. arg[0] is the source;
--   * there are NO addressing-mode offsets in the IL: `%p 8` is a parse
--     error; field access is explicit `add` (MEASURED: qbe rejects
--     `storel %n, %p 8`).
--
-- MANGLED NAMES: QBE identifiers are [a-zA-Z_$][a-zA-Z0-9_$]*; a Mid global
-- key like "Fib.fib" is mangled by Mid.Qbe.Lower (the module that GENERATES
-- names) with hex escapes for every non-[a-zA-Z0-9] byte — stable across
-- runs, which is what the .ssa->asm->link path needs (the runtime never
-- parses these names back; symbols the RUNTIME looks up, like $qbe_meta, are
-- plain ASCII by construction).

import Char
import Mid.Qbe.Il exposing (Module, Func, Block, Inst(..), Jump(..), Arg(..), Ty(..), AbiTy(..), BinOp(..), CmpOp(..), LoadOp(..), StoreTy(..), CallArg(..), TypeDef, DataDef, DataItem(..), descType, retType, valType)


print : Module -> String
print m =
    String.join "\n"
        (List.map printType (valType :: retType :: m.types ++ [ descType ])
            ++ [ "" ]
            ++ List.map printData m.datas
            ++ [ "" ]
            ++ intersperse "" (List.map printFunc m.funcs)
        )


printType : TypeDef -> String
printType t =
    "type :"
        ++ t.name
        ++ (case t.align of
                Just a ->
                    " = align " ++ String.fromInt a ++ " { "

                Nothing ->
                    " = { "
           )
        ++ String.join ", " t.fields
        ++ " }"


printData : DataDef -> String
printData d =
    (if d.export_ then
        "export "

     else
        ""
    )
        ++ "data $"
        ++ d.name
        ++ (case d.align of
                Just a ->
                    " = align " ++ String.fromInt a ++ " { "

                Nothing ->
                    " = { "
           )
        ++ String.join ", " (List.map printItem d.items)
        ++ " }"


printItem : DataItem -> String
printItem item =
    case item of
        DByte n ->
            "b " ++ String.fromInt n

        DWord n ->
            "w " ++ String.fromInt n

        DLong n ->
            "l " ++ String.fromInt n

        DDouble f ->
            -- `d` here is the DATAITEM's extended type (8 bytes); the CONST
            -- itself carries the `d_` sigil (doc/il.txt CONST :175-179:
            -- `'d_' FP`).  Emitting `d 0.0` puts a decimal where the data
            -- lexer expects a field letter, and QBE answers
            -- `unknown keyword .0`.
            "d d_" ++ printFloat f

        DStr s ->
            "b \"" ++ escapeStr s ++ "\""

        DZero n ->
            "z " ++ String.fromInt n

        DRef name ->
            "l $" ++ name


-- Doubles print in a form QBE parses and JS round-trips: shortest
-- round-trip decimal (Elm/JS String.fromFloat guarantees the round trip),
-- with an explicit ".0"/exponent so the token stays a float literal.
--
-- NON-FINITE IS ALREADY A FLOAT TOKEN, SO IT GETS NO ".0": String.fromFloat
-- renders an overflowed literal as "Infinity" (and a NaN as "NaN"), and
-- appending the suffix produced `d_Infinity.0`.  QBE's data lexer runs C's
-- `fscanf("_%lf")` (vendor/qbe/parse.c:266), i.e. strtod, which reads
-- INF/INFINITY/NAN but STOPS AT THE '.' — leaving ".0" for the lexer, which
-- answers `unknown keyword .0` and kills a build that has nothing to do with
-- the float arithmetic.  MEASURED on `1.0e400`: `d d_Infinity.0` ->
-- `qbe: ...ssa:5: unknown keyword .0`.
printFloat : Float -> String
printFloat f =
    let
        s =
            String.fromFloat f
    in
    if String.any (\c -> c == '.' || c == 'e' || c == 'E') s then
        s

    else if s == "Infinity" || s == "-Infinity" || s == "NaN" then
        s

    else
        s ++ ".0"


escapeStr : String -> String
escapeStr s =
    String.join "" (List.map escapeChar (String.toList s))


escapeChar : Char -> String
escapeChar c =
    if c == '"' then
        "\\\""

    else if c == '\\' then
        "\\\\"

    else if isPrintableAscii c then
        String.fromChar c

    else if stringIsByteIndexed then
        -- BYTE-indexed runtime (the self-host compiler): `String.toList` yields
        -- one Char per BYTE, so `Char.toCode c` is already a raw UTF-8 byte.
        -- Emit its octal DIRECTLY — running it through `utf8Bytes` would
        -- re-encode the byte as a code point and double the width (the
        -- \342\200\224 vs \303\242\302\200\302\224 divergence).
        octalByte (Char.toCode c)

    else
        -- CODE-POINT-indexed runtime (stock elm on node): `String.toList` yields
        -- one Char per Unicode scalar; decode each scalar to its UTF-8 bytes.
        String.join "" (List.map octalByte (utf8Bytes c))


-- Probe which string semantics the runtime has, exactly like Zinc.Csexp:
-- byte-indexed (`String.length "é" == 2`) or code-point-indexed (`== 1`).
stringIsByteIndexed : Bool
stringIsByteIndexed =
    String.length "é" == 2


isPrintableAscii : Char -> Bool
isPrintableAscii c =
    let
        code =
            Char.toCode c
    in
    code >= 32 && code <= 126


octalByte : Int -> String
octalByte b =
    "\\" ++ pad3 (toOctal b)


-- One code point -> its UTF-8 byte sequence (each byte 0..255).  Elm
-- String.toList yields one Char per Unicode scalar (no surrogate pairs), so
-- Char.toCode is the full code point and the four UTF-8 widths below cover it.
utf8Bytes : Char -> List Int
utf8Bytes c =
    let
        code =
            Char.toCode c
    in
    if code <= 0x7F then
        [ code ]

    else if code <= 0x7FF then
        [ 0xC0 + (code // 64), 0x80 + modBy 64 code ]

    else if code <= 0xFFFF then
        [ 0xE0 + (code // 4096), 0x80 + modBy 4096 code // 64, 0x80 + modBy 64 code ]

    else
        [ 0xF0 + (code // 262144), 0x80 + modBy 262144 code // 4096, 0x80 + modBy 4096 code // 64, 0x80 + modBy 64 code ]


pad3 : String -> String
pad3 s =
    String.join "" (List.repeat (3 - String.length s) "0") ++ s


toOctal : Int -> String
toOctal n =
    if n < 8 then
        String.fromInt n

    else
        toOctal (n // 8) ++ String.fromInt (modBy 8 n)


printFunc : Func -> String
printFunc f =
    (if f.export_ then
        "export "

     else
        ""
    )
        ++ "function "
        ++ printAbi f.ret
        ++ " $"
        ++ f.name
        ++ "("
        ++ String.join ", "
            ((if f.envParam then
                [ "env %env" ]

              else
                []
             )
                ++ List.map (\( n, t ) -> printAbi t ++ " %" ++ n) f.params
            )
        ++ ") {\n"
        ++ String.join "\n" (List.map printBlock f.blocks)
        ++ "\n}"


printBlock : Block -> String
printBlock b =
    "@"
        ++ b.label
        ++ (if List.isEmpty b.body then
                ""

            else
                "\n" ++ String.join "\n" (List.map printInst b.body)
           )
        ++ "\n\t"
        ++ printJump b.jump


printJump : Jump -> String
printJump j =
    case j of
        Fallthrough ->
            "# (fallthrough)"

        Jmp l ->
            "jmp @" ++ l

        Jnz c t e ->
            "jnz " ++ printArg c ++ ", @" ++ t ++ ", @" ++ e

        Ret Nothing ->
            "ret"

        Ret (Just a) ->
            "ret " ++ printArg a

        Hlt ->
            "hlt"


printInst : Inst -> String
printInst inst =
    case inst of
        Cmt s ->
            "\t# " ++ s

        Bin dst ty op a b ->
            tab dst ty (opName op ++ " " ++ printArg a ++ ", " ++ printArg b)

        Cmp dst oty op a b ->
            tab dst W (cmpName op ++ printTy oty ++ " " ++ printArg a ++ ", " ++ printArg b)

        Load dst ty op a ->
            tab dst ty (loadName op ++ " " ++ printArg a)

        Store st v addr ->
            "\t" ++ storeName st ++ " " ++ printArg v ++ ", " ++ printArg addr

        Blit src dst n ->
            "\tblit " ++ printArg src ++ ", " ++ printArg dst ++ ", " ++ String.fromInt n

        Call dst ty target args ->
            (case dst of
                Just r ->
                    "\t%" ++ r ++ " =" ++ printAbi ty ++ " "

                Nothing ->
                    "\t"
            )
                ++ "call "
                ++ printArg target
                ++ "("
                ++ String.join ", " (List.map printCallArg args)
                ++ ")"

        Alloc r n ->
            "\t%" ++ r ++ " =l alloc8 " ++ String.fromInt n


tab : Maybe String -> Ty -> String -> String
tab dst ty rest =
    (case dst of
        Just r ->
            "\t%" ++ r ++ " =" ++ printTy ty ++ " "

        Nothing ->
            "\t"
    )
        ++ rest


printCallArg : CallArg -> String
printCallArg carg =
    case carg of
        ArgVal t a ->
            printAbi t ++ " " ++ printArg a

        ArgEnv a ->
            "env " ++ printArg a


printAbi : AbiTy -> String
printAbi t =
    case t of
        Base b ->
            printTy b

        Agg name ->
            ":" ++ name


printTy : Ty -> String
printTy ty =
    case ty of
        W ->
            "w"

        L ->
            "l"

        S ->
            "s"

        D ->
            "d"


printArg : Arg -> String
printArg arg =
    case arg of
        Con n ->
            String.fromInt n

        Tmp t ->
            "%" ++ t

        Sym s ->
            "$" ++ s


opName : BinOp -> String
opName op =
    case op of
        Add ->
            "add"

        Sub ->
            "sub"

        Mul ->
            "mul"

        Div ->
            "div"

        And ->
            "and"

        Or ->
            "or"

        Xor ->
            "xor"


cmpName : CmpOp -> String
cmpName op =
    case op of
        Ceq ->
            "ceq"

        Cne ->
            "cne"

        Cslt ->
            "cslt"

        Csle ->
            "csle"

        Csgt ->
            "csgt"

        Csge ->
            "csge"

        -- the FLOAT family: the mnemonic drops the `s` and `printTy oty`
        -- supplies the operand-type suffix, so at oty = D these print
        -- `ceqd`/`cned`/`cltd`/`cled`/`cgtd`/`cged`.
        Ceqd ->
            "ceq"

        Cned ->
            "cne"

        Cltd ->
            "clt"

        Cled ->
            "cle"

        Cgtd ->
            "cgt"

        Cged ->
            "cge"


loadName : LoadOp -> String
loadName op =
    case op of
        LoadW ->
            "loadw"

        LoadL ->
            "loadl"

        LoadD ->
            "loadd"


storeName : StoreTy -> String
storeName st =
    case st of
        StoreW ->
            "storew"

        StoreL ->
            "storel"

        StoreD ->
            "stored"


-- List.intersperse, local: the selfhost alias table has no `List.intersperse`
-- row, and this is the only call site.  Semantics match elm/core exactly:
-- `intersperse sep [a, b, c] = [a, sep, b, sep, c]`.
intersperse : a -> List a -> List a
intersperse sep xs =
    case xs of
        [] ->
            []

        [ x ] ->
            [ x ]

        x :: rest ->
            x :: sep :: intersperse sep rest
