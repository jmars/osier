module E4Let exposing (main)
type HDup rho = HNil : HDup {} | HOne : Int -> HDup rho -> HDup { x : Int | rho } | HDupCons : Int -> String -> HDup rho -> HDup { x : Int, x : String | rho }
rebuild : type rho. HDup rho -> HDup rho
rebuild xs =
    case xs of
        HDupCons i s rest ->
            let ys = rest in ys
        _ -> xs
main : Int
main = 0
