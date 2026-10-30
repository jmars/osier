module M exposing (main)

-- THE Task.andThen CONTINUATION UNDER COLLECTION (perf andthen-clobber).
--
-- THE DEFECT THIS ROW PINS, and it was NOT inside any allocation seat: the
-- host blob's 33031-slot array — the ONLY root for every Value the host lane
-- holds — was registered by `Rt.hostInit`, and `Rt.hostInit` is classified
-- ALLOCATING on the word arm (the `mknum(blob)` that closes it is a boxing
-- seat), so it has a frame.  A root pushed between `frame-enter` and
-- `frame-leave` is truncated by that frame's OWN leave
-- (`Rt.frame-leave` -> `rootPopTo(hdr->wm)`), so the registration was dropped
-- the moment `hostInit` returned and the whole host lane ran unrooted.
--
-- THE SHAPE THAT SHOWS IT, and why nothing in the tree did before: the
-- continuation closure lives ONLY in a blob slot.  `Rt.hostDispatch` stages it
-- into SCR_TMP and `Rt.hostPushFrame` copies it into `slot[base + 2 + n]`;
-- nothing else references it.  So the first scavenge reclaims it, the churn's
-- next string allocation is handed the same memory, and `Rt.apply-at` then
-- reads a "closure" whose body word 0 is string text.  MEASURED before the
-- fix, word arm, at QBE_HEAP_MB=1/2/4/64: rc=1 "a heap header carries KIND
-- CODE 0"; at QBE_HEAP_MB=512 (no collection) rc=0.  The val arm passed
-- throughout — NOT because it roots better, but because `hostInit` is
-- frame-free there, so the root was never truncated: the asymmetry was the
-- FRAME CLASS, exactly the class this arc has now met three times.
--
-- THE CHURN MUST BE IN THE CONTINUATION, not in `init` and not in `update`:
-- measured, a `Task.succeed "OK"` continuation passes on both arms, and the
-- same churn in `update` passes too (the model is then also reachable through
-- the compiled frame, so a lost slot does not matter).  A continuation whose
-- allocation crosses a scavenge is the one shape that puts a live Value in a
-- blob slot and nothing else anywhere.
--
-- THE CHECK WALKS THE BYTES.  `String.length` alone would pass on a reclaimed
-- or wrongly-strided cell (the length can survive while the bytes do not), so
-- the value that comes back through `Done` is REBUILT from the step count with
-- `String.repeat` and compared.  Output is `len/ok|bad`, and the val arm is
-- the oracle: no expected count is spelled here, because a hard-coded number
-- would be a second thing to keep in step and a wrong one would bless a wrong
-- answer on both arms at once.

type Msg
    = Done String


main =
    Runtime.program
        { init = init
        , update = update
        , subscriptions = \_ -> ()
        }


init () =
    ( "start", Task.perform Done (Task.andThen start (Task.succeed ())) )


-- THE CONTINUATION: this is the closure `hostPushFrame` stages into the blob.
start _ =
    Task.succeed (churn 2000)


churn : Int -> String
churn n =
    build n ""


build : Int -> String -> String
build n acc =
    if n <= 0 then
        acc

    else
        build (n - 1) (String.append acc "1800x179")


-- THE EXPECTATION IS REBUILT THROUGH A DIFFERENT CODE PATH (prepend instead of
-- append) so the comparison is not one function twice: the chunks are all
-- identical, so the bytes must match.
want : String
want =
    buildLeft 2000 ""


buildLeft : Int -> String -> String
buildLeft n acc =
    if n <= 0 then
        acc

    else
        buildLeft (n - 1) (String.append "1800x179" acc)


update msg model =
    case msg of
        Done s ->
            ( String.fromInt (String.length s)
                ++ (if s == want then
                        "/ok"

                    else
                        "/bad"
                   )
            , Cmd.none
            )
