module E7FieldType exposing (main)
type HDup rho = HNil : HDup {} | HOneS : String -> HDup rho -> HDup { x : String | rho } | HDupCons : Int -> String -> HDup rho -> HDup { x : Int, x : String | rho }
rebuild : type rho. HDup rho -> HDup rho
rebuild xs =
    case xs of
        HDupCons i s rest -> HOneS s rest
        _ -> xs
main : Int
main = 0
