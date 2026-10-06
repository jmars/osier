module E6DiffLabel exposing (main)
type HDup rho = HNil : HDup {} | HOther : Bool -> HDup rho -> HDup { y : Bool | rho } | HDupCons : Int -> String -> HDup rho -> HDup { x : Int, x : String | rho }
rebuild : type rho. HDup rho -> HDup rho
rebuild xs =
    case xs of
        HDupCons i s rest -> HOther True rest
        _ -> xs
main : Int
main = 0
