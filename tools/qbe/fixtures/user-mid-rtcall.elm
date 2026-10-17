module UserMidRtCall exposing (main)

-- M3-rtcall: the EXPORTED-runtime-key call, end to end.  This Osier module
-- calls the user .mid defun `RtCall.read` (user-mid-rtcall.mid), passing the
-- path "rtcall-input.txt"; that defun `call`s the EXPORTED runtime key
-- `Rt.read-file-as-string` and returns its result unchanged.  Before this
-- unit the call passed J2 (the key IS exported) but the callee was never
-- SEEDED into the emitted Rt subset, so the binary failed to LINK on
-- `q_Rt_x2eread_x2dfile_x2das_x2dstring` — the exported-key allowance was a
-- trap.  The run row creates rtcall-input.txt in the run dir and expects the
-- file's content as the golden, so the printed value is load-bearing on the
-- seeded call (emit it wrong, or not at all, and the row moves).
main =
    RtCall.read "rtcall-input.txt"
