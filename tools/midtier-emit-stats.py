#!/usr/bin/env python3
"""midtier-emit-stats.py — emitted-size / instruction-count delta for the
middle tier (`Mid.Simplify`): the cheap half of every pass's measurement.

    tools/midtier-emit-stats.py <dir|file> [<dir|file> ...]

Each argument is a `.csexp` bundle or a directory of them; the tool prints, per
argument, the bundle count, total bytes, total VM instructions and the opcode
histogram, and — when two or more are given — the head-to-head DELTA
(instructions and bytes, absolute and percent).  Intended usage is two
directories of artifacts produced by the SAME manifest under different MIDTIER
flags:

    <compile manifest under MIDTIER=0 into out0/ and MIDTIER=1 into out1/>
    tools/midtier-emit-stats.py out0 out1

WHY THIS FILE EXISTS: the project's other oracle is byte identity, and the
middle tier BREAKS it by design (plan decision D5) — a pass needs a measurement
that does not depend on the bytes being equal.  Instruction count is what the
VM dispatches, it is comparable across modes, and it cannot be gamed by
re-ordering the same work.

BUT INSTRUCTION COUNT IS NOT A PROXY FOR RUNTIME HERE, and it must not be the
acceptance criterion for a pass.  These passes target RUNTIME cost on a closure
VM, and a representation transform can ADD instructions while REMOVING an
allocation or a call — the dominant cost in this VM (docs/vm-perf-plan.md):
a full-arity call allocates a fresh env array and pushes a frame; a partial
application copies the whole closure body's instruction array; an over-applied
call runs a nested vmExecEnv that allocates a fresh ~3 MB frame stack.  The
pass series proved the trap concretely: Inline is +11.6% instructions on the
inline probe yet -14% wall-clock (it removes the per-call frame/env alloc), and
Arity's two representation repairs each add ~38 instructions while removing a
per-call allocation.  Judge representation transforms by RUNTIME, measured with
tools/midtier-runtime.sh; report the instruction delta alongside as information,
never as the verdict.

PARSING NOTE: the bundle format is `[len:type]value` atoms with BARE one-letter
opcodes (Zinc/Emit.elm's `instrText`: `m`, `p`, `t`, `r`, `v`, `e`, `d`, `a`,
`g`, `f`, `j`, `n`, `F`, `s`, `S`, `b`, `P`, `A`, `K`, `Q`, `R`, `V`, `c`) —
the OPCODE is not an atom, only its operands are.  Counting `[1:s]<letter>`
atoms (the obvious first guess) counts almost nothing.
"""

import glob
import os
import sys
from collections import Counter

# Zinc/Emit.elm's flattened opcode set.
OPCODES = set("mptrvedagfjnFsSbPAKQRV")
MEANING = {
    "m": "pushmark", "p": "apply", "t": "appterm", "r": "grab", "v": "return",
    "e": "let", "d": "endlet", "a": "access", "g": "global", "f": "jmpf",
    "j": "jmp", "n": "number", "F": "float", "s": "symbol", "S": "string",
    "b": "boolean", "P": "prim", "A": "access+prim", "K": "const+prim",
    "Q": "global+apply", "R": "global+appterm", "V": "prim+return",
    "c": "closure",
}


def tokens(data):
    i, n = 0, len(data)
    while i < n:
        c = data[i:i + 1]
        if c == b'[':
            j = data.index(b']', i)
            length = int(data[i + 1:j].split(b':')[0])
            yield ('atom', data[j - 1:j], data[j + 1:j + 1 + length])
            i = j + 1 + length
        elif c in b'() \n\t':
            i += 1
        else:
            k = i
            while k < n and data[k:k + 1] not in b'() \n\t[':
                k += 1
            yield ('bare', b'', data[i:k])
            i = k


def bundle_stats(path):
    data = open(path, 'rb').read()
    hist = Counter()
    for kind, _t, value in tokens(data):
        if kind == 'bare' and len(value) == 1 and chr(value[0]) in OPCODES:
            hist[chr(value[0])] += 1
    return len(data), sum(hist.values()), hist


def collect(target):
    if os.path.isdir(target):
        paths = sorted(glob.glob(os.path.join(target, '*.csexp')))
    else:
        paths = [target]
    nbytes = ninstr = 0
    hist = Counter()
    for p in paths:
        b, i, h = bundle_stats(p)
        nbytes += b
        ninstr += i
        hist += h
    return len(paths), nbytes, ninstr, hist


def main(argv):
    targets = argv[1:]
    if not targets:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    rows = []
    for t in targets:
        count, nbytes, ninstr, hist = collect(t)
        rows.append((t, count, nbytes, ninstr, hist))
        print("%-28s bundles=%-4d bytes=%12d instrs=%9d" % (t, count, nbytes, ninstr))
    for label, _c, _b, _i, hist in rows:
        top = " ".join("%s=%d" % (MEANING.get(k, k), v) for k, v in hist.most_common(8))
        print("    %-24s %s" % (label, top))
    if len(rows) >= 2:
        _lt, _lc, lb, li, lh = rows[0]
        for label, _c, b, i, hist in rows[1:]:
            db, di = b - lb, i - li
            print("DELTA %s -> %s: instrs %+d (%.3f%%)  bytes %+d (%.3f%%)"
                  % (rows[0][0], label, di, 100.0 * di / li if li else 0.0,
                     db, 100.0 * db / lb if lb else 0.0))
            if i:
                for k, v in (hist - lh).most_common(8):
                    if v:
                        print("    %-14s %+d (mode - baseline)" % (MEANING.get(k, k), v))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
