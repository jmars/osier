module ProbeA2 exposing (main)


-- Typed VM-value representation: the constructors the trusted bodies build
-- and observe, given honest types.  A symbol is a distinct leaf so `intern`
-- (the trusted lie: String-typed VM symbol) disappears.
type Value
    = VStr String
    | VNum Int
    | VSym String
    | VNil
    | VCons Value Value


tStr : String -> Value
tStr s =
    VStr s


tNum : Int -> Value
tNum n =
    VNum n


tSym : String -> Value
tSym x =
    VSym x


tNil : Value
tNil =
    VNil


tCons : Value -> Value -> Value
tCons h t =
    VCons h t


-- decodeNumber: the trusted body observes `_ :: n :: _` on a FLAT list; here
-- it is a case-match on the honest constructor.
decodeNumber : Value -> Int
decodeNumber v =
    case v of
        VNum n ->
            n

        _ ->
            0


-- decodeString
decodeString : Value -> String
decodeString v =
    case v of
        VStr s ->
            s

        _ ->
            ""


-- decodeStringList: the trusted body recurses over a FLAT tagged list of
-- [cons [string s1] [cons [string s2] [cons]]].  Honest form: a cons cell
-- whose head is a (cons (VStr s) VNil) pair and whose tail recurses.
decodeStringList : Value -> List String
decodeStringList v =
    case v of
        VCons (VCons (VStr s) VNil) rest ->
            s :: decodeStringList rest

        VNil ->
            []

        _ ->
            []


-- decodeExec: [cons [number code] [cons [string out] [cons [string err] [cons]]]]
decodeExec : Value -> ( Int, String, String )
decodeExec v =
    case v of
        VCons (VCons (VNum code) VNil) (VCons (VCons (VStr out) VNil) (VCons (VCons (VStr err) VNil) _)) ->
            ( code, out, err )

        _ ->
            ( 0, "", "" )


main : Int
main =
    let
        plan =
            tCons (tCons (tNum 0) tNil) (tCons (tCons (tStr "ok") tNil) (tCons (tCons (tStr "") tNil) tNil))

        ( code, out, _ ) =
            decodeExec plan
    in
    code
