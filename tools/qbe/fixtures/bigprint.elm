module BigPrint exposing (build)

-- print-buffer fixture: the RESULT is a 2000-cons list whose printed form
-- ([cons 2000 . [cons 1999 . ...]]) exceeds the runners' 16384-byte print
-- buffers, so native and VM must agree at a size the old fixed buffer
-- rejected.  Shape is exactly the churn fixture's (the slice supports `::`).

build n acc =
    if n == 0 then
        acc

    else
        build (n - 1) (n :: acc)
