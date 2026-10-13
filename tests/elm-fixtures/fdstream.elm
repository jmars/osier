module Fdstream exposing (main)

{-| THE STRING-STREAM ARMS OF THE COMPILED fd PRIMS (zigretire stage 3 GROUP 1)
— the focused, failure-is-the-route-being-wrong instrument for the Mid
`open`/`read-byte`/`close` bodies over the Vm-owned string-stream registry.
`main` is 1 iff every probe holds; a wrong registry seat, is_string packing,
or ENOENT detection makes at least one probe fail.

WHAT IT COVERS (the arms no existing worker fixture executes):
  * open "in" on a MISSING path -> ENOENT -> a STRING stream of the PATH bytes
    (the C quirk, streams.zig valStringStreamIn); read-byte walks the path
    bytes; close frees the slot (idempotent, slot index stays consumed).
  * open "in" on an EXISTING path -> a FILE stream (O_RDONLY); read-byte reads
    the file's first byte; close closes the fd.

The string-stream path is the one that must go RED if the route is wrong: it
touches `__errno_location` (ENOENT == 2), the `rt_ss_in` registry seat, the
packed is_input/is_string word, and `rt_ss_readbyte`/`rt_ss_close`.
-}


stringStreamProbe : Int
stringStreamProbe =
    let
        s =
            open "fdstream-no-such-file.txt" "in"

        b0 =
            readByte s

        b1 =
            readByte s

        _ =
            close s
    in
    if b0 == 102 && b1 == 100 then
        -- 'f' = 102, 'd' = 100 (the path's first two bytes)
        1

    else
        0


fileInProbe : Int
fileInProbe =
    let
        s =
            open "tests/elm-fixtures/input/hello.txt" "in"

        b =
            readByte s

        _ =
            close s
    in
    if b == 104 then
        -- 'h' = 104 (hello.txt's first byte)
        1

    else
        0


main : Int
main =
    if stringStreamProbe == 1 && fileInProbe == 1 then
        1

    else
        0
