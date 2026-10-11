#!/usr/bin/env node
// gen.js — the GENERALIZED differential vector generator (handoff
// osier-midprims, step 5): the cons spike's shape extended to every ported
// prim family.  ONE generator, ONE fixed seed, THREE artifacts of the SAME
// vectors:
//   <dir>/vectors.spec  — what the ZIG arm parses: "V <n>" then n lines
//                         "<op>|<argspec>|<argspec>..." (op = the batch's
//                         operation; argspec = the cons spike's kind-free
//                         grammar, kept verbatim)
//   <dir>/Fixture.elm   — the same vectors as SURFACE spellings, one
//                         `v<i> = <spelling>` binding each, `all` the list
//                         the compiled Mid arm prints (the driver's
//                         printValue is the canonical form on both sides)
// so the two arms are driven by ONE generator and the comparison is over
// the same argument vectors, not hand-picked cases.
//
// OPS (the surface spelling each one compiles to; QBE_MIDCONS=1 routes the
// prim under it to its Mid implementation):
//   binary arithmetic/comparison/eq: a OP b       (+ - * / f/ < <= > >= ==)
//   bitwise:  Bitwise.and|or|xor a b, complement a, shiftLeftBy|RightBy|
//             RightZfBy c v      (ZINC RTL: count FIRST, value SECOND —
//                                 the spec arg order is (count, value))
//   predicates: isNumber/isString/isCons/isNil a
//   strings: String.append a b; String.length s; Str.repeat n s;
//            String.sliceLen st ln s; charCode s i
//   bytes:   strToBytes s  (prints as the byte list);
//            bytesToString (byte list)
//   vectors: vectorGet (vectorSet (vectorMake n) i x) i   (op `vec`)
//   tuples:  (a, b)                                        (op `atp`)
//   records: let r = { f = a, g = b } in r.f               (op `assoc`)
//   cons:    a :: xs                                       (op `cons`)
//   emptylist: []                                          (op `nil`)
//
// RANGES carried over from the cons spike (MEASURED there): Int literals
// bounded by 2^53-1 (the surface parser's ceiling); string bytes ASCII
// printable minus the spec delimiters and the elm-literal escapes; div
// batches never emit a 0 divisor (BOTH arms crash on x/0 — SIGFPE parity,
// untestable in a same-process comparison); shift counts include -1 and 64
// (the mod-32 mask).
//
// Usage: node gen.js <dir> --op=<op> [--n=200] [--seed=20261011]

'use strict';

const fs = require('fs');
const path = require('path');

const dir = process.argv[2];
if (!dir) { console.error('gen.js: usage: node gen.js <dir> --op=<op> [--n=N] [--seed=S]'); process.exit(2); }
let N = 200, SEED = 20261011, OP = 'add-int';
for (const a of process.argv.slice(3)) {
  const m = /^--(op|n|seed)=(.+)$/.exec(a);
  if (!m) { console.error(`gen.js: bad flag ${a}`); process.exit(2); }
  if (m[1] === 'op') OP = m[2];
  else if (m[1] === 'n') N = parseInt(m[2], 10);
  else SEED = parseInt(m[2], 10);
}

let st = SEED >>> 0;
function rnd() {
  st ^= st << 13; st >>>= 0;
  st ^= st >>> 17;
  st ^= st << 5; st >>>= 0;
  return st;
}
const ri = (lo, hi) => lo + (rnd() % (hi - lo + 1));
const pick = (xs) => xs[ri(0, xs.length - 1)];

const ALPHA = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .:;!@#$%^&*-_=+[]{}<>?/~'.split('-').join('-').split('');

function numSpec() {
  const shape = ri(0, 6);
  if (shape === 0) return { spec: 'n:0', elm: '0' };
  if (shape === 1) return { spec: 'n:-1', elm: '-1' };
  if (shape === 2) { const v = ri(1, 1000000); return { spec: `n:${-v}`, elm: `${-v}` }; }
  if (shape === 3) { const v = ri(1, 9007199254740991); return { spec: `n:${v}`, elm: `${v}` }; }
  if (shape === 4) { const v = ri(1, 94906265); return { spec: `n:${v * v}`, elm: `${v * v}` }; } // v^2 <= 2^53-1 (the surface ceiling, MEASURED in the cons spike)
  if (shape === 5) return { spec: `n:${2147483647}`, elm: '2147483647' };
  const v = ri(0, 999999); return { spec: `n:${v}`, elm: `${v}` };
}
function i32Spec() {
  // operands that stay inside i32 (the Bitwise family's honest domain)
  const v = ri(-2147483648, 2147483647);
  return { spec: `n:${v}`, elm: `${v}` };
}
function shiftSpec() {
  const v = pick([0, 1, -1, 31, 32, 64, -64, ri(-100, 100)]);
  return { spec: `n:${v}`, elm: `${v}` };
}
function floatSpec() {
  const i = ri(-100000, 100000);
  const f = ri(0, 999999);
  const s = `${i}.${String(f).padStart(6, '0')}`;
  return { spec: `f:${s}`, elm: s };
}
function boolSpec() {
  const b = ri(0, 1);
  return { spec: `b:${b}`, elm: b ? 'True' : 'False' };
}
function strSpec() {
  const len = ri(0, 12);
  let bytes = '';
  for (let i = 0; i < len; i++) bytes += ALPHA[ri(0, ALPHA.length - 1)];
  return { spec: `s:${bytes}`, elm: JSON.stringify(bytes) };
}
function listIntSpec(depth) {
  const n = depth > 0 ? ri(0, 2) : (rnd() % 6 === 0 ? ri(4, 6) : ri(0, 4));
  const els = [];
  for (let i = 0; i < n; i++) els.push(depth > 0 ? listIntSpec(depth - 1) : numSpec());
  return {
    spec: `l(${els.map((e) => e.spec).join(',')})`,
    elm: els.length === 0 ? '[]' : `[ ${els.map((e) => e.elm).join(',')} ]`,
  };
}

// arg buildes per batch: [ [specFn, ...], ... ] — one entry per ARG.
const OPS = {
  'add-int': { args: [numSpec, numSpec], line: ([a, b]) => `(${a.elm}) + (${b.elm})`, zig: '+' },
  'add-float': { args: [floatSpec, floatSpec], line: ([a, b]) => `(${a.elm}) + (${b.elm})`, zig: '+' },
  'sub-int': { args: [numSpec, numSpec], line: ([a, b]) => `(${a.elm}) - (${b.elm})`, zig: '-' },
  'mul-int': { args: [numSpec, numSpec], line: ([a, b]) => `(${a.elm}) * (${b.elm})`, zig: '*' },
  // the GUARD is on the SECOND arg (the divisor): x/0 SIGFPEs BOTH arms —
  // parity by crash, untestable same-process (see the header's stated gaps)
  'div-int': { args: [numSpec, () => { const d = numSpec(); if (d.spec === 'n:0') return { spec: 'n:3', elm: '3' }; return d; }], line: ([a, b]) => `(${a.elm}) // (${b.elm})`, zig: '/' },
  'fdiv-float': { args: [floatSpec, floatSpec], line: ([a, b]) => `(${a.elm}) / (${b.elm})`, zig: 'f/' },
  'lt-int': { args: [numSpec, numSpec], line: ([a, b]) => `(${a.elm}) < (${b.elm})`, zig: '<' },
  'le-int': { args: [numSpec, numSpec], line: ([a, b]) => `(${a.elm}) <= (${b.elm})`, zig: '<=' },
  'gt-int': { args: [numSpec, numSpec], line: ([a, b]) => `(${a.elm}) > (${b.elm})`, zig: '>' },
  'ge-float': { args: [floatSpec, floatSpec], line: ([a, b]) => `(${a.elm}) >= (${b.elm})`, zig: '>=' },
  'eq-int': { args: [numSpec, numSpec], line: ([a, b]) => `(${a.elm}) == (${b.elm})`, zig: '=' },
  'eq-mixed': { args: [() => (rnd() % 2 ? numSpec() : floatSpec()), () => (rnd() % 2 ? numSpec() : floatSpec())], line: ([a, b]) => `(${a.elm}) == (${b.elm})`, zig: '=' },
  'eq-string': { args: [strSpec, strSpec], line: ([a, b]) => `(${a.elm}) == (${b.elm})`, zig: '=' },
  'eq-bool': { args: [boolSpec, boolSpec], line: ([a, b]) => `(${a.elm}) == (${b.elm})`, zig: '=' },
  'eq-list': { args: [() => listIntSpec(0), () => listIntSpec(0)], line: ([a, b]) => `(${a.elm}) == (${b.elm})`, zig: '=' },
  'and-int': { args: [i32Spec, i32Spec], line: ([a, b]) => `Bitwise.and (${a.elm}) (${b.elm})`, zig: 'bitwise-and' },
  'or-int': { args: [i32Spec, i32Spec], line: ([a, b]) => `Bitwise.or (${a.elm}) (${b.elm})`, zig: 'bitwise-or' },
  'xor-int': { args: [i32Spec, i32Spec], line: ([a, b]) => `Bitwise.xor (${a.elm}) (${b.elm})`, zig: 'bitwise-xor' },
  'not-int': { args: [i32Spec], line: ([a]) => `Bitwise.complement (${a.elm})`, zig: 'bitwise-not' },
  'shl-int': { args: [shiftSpec, i32Spec], line: ([c, v]) => `Bitwise.shiftLeftBy (${c.elm}) (${v.elm})`, zig: 'bitwise-shift-left' },
  'shr-int': { args: [shiftSpec, i32Spec], line: ([c, v]) => `Bitwise.shiftRightBy (${c.elm}) (${v.elm})`, zig: 'bitwise-shift-right' },
  'shrzf-int': { args: [shiftSpec, i32Spec], line: ([c, v]) => `Bitwise.shiftRightZfBy (${c.elm}) (${v.elm})`, zig: 'bitwise-shift-right-zf' },
  'isnum': { args: [() => (rnd() % 3 === 0 ? floatSpec() : numSpec())], line: ([a]) => `isNumber (${a.elm})`, zig: 'number?' },
  'isstr': { args: [() => (rnd() % 2 ? strSpec() : numSpec())], line: ([a]) => `isString (${a.elm})`, zig: 'string?' },
  'iscons': { args: [() => listIntSpec(0)], line: ([a]) => `isCons (${a.elm})`, zig: 'cons?' },
  'isnil': { args: [() => listIntSpec(0)], line: ([a]) => `isNil (${a.elm})`, zig: 'empty?' },
  'cn-str': { args: [strSpec, strSpec], line: ([a, b]) => `String.append (${a.elm}) (${b.elm})`, zig: 'cn' },
  'cn-num': { args: [numSpec, strSpec], line: ([a, b]) => `String.append (String.fromInt (${a.elm})) (${b.elm})`, zig: 'cn' },
  'strlen': { args: [strSpec], line: ([a]) => `String.length (${a.elm})`, zig: 'c-strlen' },
  'repeat-str': { args: [() => { const v = ri(0, 6); return { spec: `n:${v}`, elm: `${v}` }; }, strSpec], line: ([n, s]) => `Str.repeat (${n.elm}) (${s.elm})`, zig: 'repeat' },
  'substring-str': { args: [strSpec, () => { const v = ri(-2, 10); return { spec: `n:${v}`, elm: `${v}` }; }, () => { const v = ri(-2, 10); return { spec: `n:${v}`, elm: `${v}` }; }], line: ([s, a, b]) => `String.sliceLen (${a.elm}) (${b.elm}) (${s.elm})`, zig: 'substring' },
  'charcode-str': { args: [strSpec, () => { const v = ri(-2, 12); return { spec: `n:${v}`, elm: `${v}` }; }], line: ([s, i]) => `charCode (${s.elm}) (${i.elm})`, zig: 'char-code' },
  'strbytes': { args: [strSpec], line: ([a]) => `strToBytes (${a.elm})`, zig: 'shen.str->bytes' },
  'bytestr': { args: [() => listIntSpec(0)], line: ([a]) => `bytesToString (${a.elm})`, zig: 'shen.bytes->string' },
  'vec': {
    // i < n GUARANTEED (both arms fault on <-address beyond the end —
    // parity crash, untestable same-process; the generator excludes it)
    args: () => {
      const n = ri(1, 5);
      const i = ri(0, n - 1);
      const x = numSpec();
      return [{ spec: `n:${n}`, elm: `${n}` }, { spec: `n:${i}`, elm: `${i}` }, x];
    },
    line: ([n, i, x]) => `vectorGet (vectorSet (vectorMake (${n.elm})) (${i.elm}) (${x.elm})) (${i.elm})`,
    zig: 'vec',
  },
  'atp': { args: [numSpec, strSpec], line: ([a, b]) => `( (${a.elm}), (${b.elm}) )`, zig: '@p' },
  'assoc-int': { args: [numSpec, numSpec], line: ([a, b]) => `(let r = { f = (${a.elm}), g = (${b.elm}) } in r.f)`, zig: 'assoc' },
  'assoc-str': { args: [strSpec, strSpec], line: ([a, b]) => `(let r = { f = (${a.elm}), g = (${b.elm}) } in r.f)`, zig: 'assoc' },
  'cons-int': { args: [numSpec, () => listIntSpec(0)], line: ([a, b]) => `(${a.elm}) :: (${b.elm})`, zig: 'cons' },
  // [] as a literal: ListLit [] -> the `emptylist 0` desugar
  'nil': { args: [], line: () => `[]`, zig: 'emptylist' },
};

const op = OPS[OP];
if (!op) { console.error(`gen.js: unknown op ${OP}`); process.exit(2); }

const vectors = [];
for (let i = 0; i < N; i++) {
  const args = typeof op.args === 'function' ? op.args() : op.args.map((f) => f());
  vectors.push(args);
}

fs.mkdirSync(dir, { recursive: true });
fs.writeFileSync(path.join(dir, 'vectors.spec'),
  `V ${N}\n` + vectors.map((v) => `${op.zig}|${v.map((a) => a.spec).join('|')}`).join('\n') + '\n');

let src = `module PrimDiff exposing (all)\n\n-- GENERATED by tools/qbe/primsdiff/gen.js (op ${OP}, seed ${SEED}, n ${N})\n-- — do not edit.  One binding per vector; compiled with QBE_MIDCONS=1,\n-- every prim under each spelling routes to its Mid implementation.\n\n`;
vectors.forEach((v, i) => { src += `v${i} =\n    ${op.line(v)}\n`; });
src += `\n\nall =\n    [ ${vectors.map((_, i) => `v${i}`).join('\n    , ')} ]\n`;
fs.writeFileSync(path.join(dir, 'Fixture.elm'), src);

console.log(`gen.js: ${N} vectors (op ${OP}, seed ${SEED}) -> ${path.join(dir, 'vectors.spec')} + Fixture.elm`);
