#!/usr/bin/env bash
# RETIRED AT O4 (the Zig-host deletion): this probe's subject — the
# QBE_MIDHOST=0 escape arm, i.e. the ZIG effect host as a differential
# against the Mid one — no longer exists.  src/effectloop.zig,
# vendor/osier-rt/src/rt/{prims,execplan}.zig and Rt.main's Zig arm are
# deleted; run.js's QBE_MIDHOST flag and splice are retired.  There is
# nothing left to probe; exit 0 so the probe enumeration stays uniform.
echo "probe-midgc-midhost0: RETIRED at O4 (the Zig effect host is deleted; the Mid host is the only host)"
exit 0
