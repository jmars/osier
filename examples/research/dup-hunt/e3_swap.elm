module E3Swap exposing (main)
type HDup rho = HNil : HDup {} | HDupCons2 : String -> Int -> HDup rho -> HDup { x : String, x : Int | rho }
rebuild : type rho. HDup rho -> HDup rho
rebuild xs =
    case xs of
        HDupCons2 s i rest -> HDupCons2 s i rest
        _ -> xs
main : Int
main = 0
