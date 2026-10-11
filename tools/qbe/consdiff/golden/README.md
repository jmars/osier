# consdiff reference goldens

The FROZEN reference outputs of the 7 consdiff batches (2 modes each:
`default` + `churn-16`), captured at git `8f581b8` with `primCons` still in
`vendor/osier-rt/src/rt/prims.zig` (`--freeze-ref`; `MANIFEST.txt` records the
tree, n, seed and the batch list).

THE FLIP (handoff osier-flip) deleted the Zig cons handler, so there is no
live reference arm: `consdiff.sh` runs only the Mid arm and compares against
these bytes.  What they still falsify: any future change to `Rt.cons`.  What
they can no longer falsify: a live Zig-vs-Mid divergence — the reference is
frozen evidence, not a measurement.
