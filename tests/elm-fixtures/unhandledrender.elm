module UnhandledRender exposing (main)

-- withe-split Phase 1b: the LANGUAGE host handles no renderer.  A program that
-- submits Io.renderFrame must FAIL LOUDLY AND FAST — the host throws
-- "unhandled UI effect: TaskRender" naming the effect — not silently complete
-- (a no-op host would make a rendering program appear to work while doing
-- nothing) and not silently drop (which would leave the continuation unresumed
-- and stall).  This is the falsifiable gate proof of edit 2: the expected
-- artifact names the effect, and elmvm can only produce it by TERMINATING.

type Msg
    = Got ()


main =
    Platform.program { init = init, update = update, subscriptions = \_ -> Sub.none }


init () =
    ( 0, Task.perform Got (Io.renderFrame (Draw.fromAnsi [ "hi" ])) )


update msg model =
    case msg of
        Got () ->
            ( model, Cmd.none )
