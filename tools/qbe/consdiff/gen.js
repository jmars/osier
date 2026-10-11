#!/usr/bin/env node
// gen.js — the DIFFERENTIAL VECTOR GENERATOR (handoff osier-consspike).
//
// Writes TWO artifacts of the SAME generated vectors:
//   <dir>/vectors.spec  — the line format the ZIG arm parses (one vector per
//                         line: "<car-spec> | <cdr-spec>")
//   <dir>/Fixture.elm   — the same vectors as SURFACE LITERALS, one
//                         `v<i> = <car> :: <cdr>` binding each, `all` the
//                         result list (the entry the compiled arm runs)
//
// so the two arms are driven by ONE generator and the comparison is over the
// same argument vectors, not hand-picked cases.  Deterministic: the seed is
// fixed unless --seed is passed, and the xorshift32 below is the whole
// randomness source.
//
// TYPE-DIRECTED, PER BATCH: surface `::` is TYPED — `car :: cdr` forces car's
// type to EQUAL the list's element type β, and the result list `all` is
// homogeneous in β — so ONE batch fixes β and every vector in it is
// well-typed.  consdiff.sh drives one batch per β (int/float/bool/string,
// each plain and 1-2 levels of nesting); the ZIG side needs no types at all
// (it builds Values from the spec directly), which is why the spec grammar
// stays kind-free.
//
// SPEC GRAMMAR (shared contract; keep in step with consdiff-zig.zig):
//   n:<int>      number        f:<float>   float       b:0|1   boolean
//   s:<bytes>    string        nil         the empty list value
//   l(S,S,...)   proper list (nested specs)
//
// RANGES: Int literals are bounded by the SURFACE parser (elm-syntax keeps
// JS-number precision): 9007199254740991 parses, 9999999999999999 does not
// (MEASURED) — the generator never exceeds 2^53-1.  String bytes are ASCII
// printable minus the spec delimiters ( , ) | and the elm-literal escapes
// " \ — no escaping layer anywhere, so the arms cannot disagree about a byte.
//
// Usage: node gen.js <dir> --kind=<int|float|bool|string> [--nest=0..2]
//                     [--n=200] [--seed=20261010]

'use strict';

const fs = require('fs');
const path = require('path');

const dir = process.argv[2];
if (!dir) { console.error('gen.js: usage: node gen.js <dir> --kind=... [--nest=D] [--n=N] [--seed=S]'); process.exit(2); }
let N = 200, SEED = 20261010, KIND = 'int', NEST = 0;
for (const a of process.argv.slice(3)) {
  const m = /^--(kind|nest|n|seed)=(.+)$/.exec(a);
  if (!m) { console.error(`gen.js: bad flag ${a}`); process.exit(2); }
  if (m[1] === 'kind') KIND = m[2];
  else if (m[1] === 'nest') NEST = parseInt(m[2], 10);
  else if (m[1] === 'n') N = parseInt(m[2], 10);
  else SEED = parseInt(m[2], 10);
}

// xorshift32 — deterministic, seedable, enough randomness for value shapes.
let st = SEED >>> 0;
function rnd() {
  st ^= st << 13; st >>>= 0;
  st ^= st >>> 17;
  st ^= st << 5; st >>>= 0;
  return st;
}
const ri = (lo, hi) => lo + (rnd() % (hi - lo + 1));

// String bytes: ASCII printable, EXCLUDING the spec delimiters ( , ) | and
// the elm-literal escapes " \.
const ALPHA = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .:;!@#$%^&*-_=+[]{}<>?/~'.split('');

function numSpec() {
  const shape = ri(0, 5);
  if (shape === 0) return { spec: 'n:0', elm: '0' };
  if (shape === 1) return { spec: 'n:-1', elm: '-1' };
  if (shape === 2) { const v = ri(1, 1000000); return { spec: `n:${-v}`, elm: `${-v}` }; }
  if (shape === 3) { const v = ri(1, 9007199254740991); return { spec: `n:${v}`, elm: `${v}` }; }
  if (shape === 4) { const v = ri(1, 94906265); return { spec: `n:${v * v}`, elm: `${v * v}` }; } // v^2 <= 2^53-1 (the surface ceiling, MEASURED)
  const v = ri(0, 999999); return { spec: `n:${v}`, elm: `${v}` };
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

// A β-VALUE (β = KIND nested NEST levels of List).
function elemSpec(depth) {
  if (depth >= NEST) {
    switch (KIND) {
      case 'int': return numSpec();
      case 'float': return floatSpec();
      case 'bool': return boolSpec();
      default: return strSpec();
    }
  }
  return listSpec(depth + 1);
}

function listSpec(depth) {
  // breadth 0 covers the empty list (= the nil VALUE as a list expression).
  const n = depth > NEST ? ri(0, 3) : (rnd() % 8 === 0 ? ri(20, 40) : ri(0, 8));
  const els = [];
  for (let i = 0; i < n; i++) els.push(elemSpec(depth));
  // `[ ` spaced form: this repo's parser rejects `[-1` (a negative literal
  // immediately after `[` — MEASURED: `1 :: [-1,-1]` parse-fails while
  // `1 :: [ -1,-1]` and `1 :: [0,-1]` parse); the space dodges the corner.
  return {
    spec: `l(${els.map((e) => e.spec).join(',')})`,
    elm: els.length === 0 ? '[]' : `[ ${els.map((e) => e.elm).join(',')} ]`,
  };
}

// car: a β-VALUE (typing forces it); cdr: nil or a β-list.  Both arms see
// the same shapes; the improper-pair half of cons's domain is the @p prim on
// the surface (identical Zig body — step 5 ports it) and is stated as not
// covered rather than approximated here.
const vectors = [];
for (let i = 0; i < N; i++) {
  vectors.push({
    car: elemSpec(0),
    cdr: ri(0, 2) === 0 ? { spec: 'nil', elm: '[]' } : listSpec(0),
  });
}

fs.mkdirSync(dir, { recursive: true });
fs.writeFileSync(path.join(dir, 'vectors.spec'),
  // No spaces around the separator: the bytes of an s: spec may contain
  // spaces (they are content), so the bar is the ONLY unambiguous split.
  `V ${N}\n` + vectors.map((v) => `${v.car.spec}|${v.cdr.spec}`).join('\n') + '\n');

let src = `module ConsDiff exposing (all)\n\n-- GENERATED by tools/qbe/consdiff/gen.js (kind ${KIND}, nest ${NEST}, seed ${SEED}, n ${N})\n-- — do not edit.  One binding per vector: <car> :: <cdr>, both of the\n-- batch's element type.  Compiled with QBE_MIDCONS=1, every :: here routes\n-- through the Mid-implemented Rt.cons.\n\n`;
vectors.forEach((v, i) => { src += `v${i} =\n    ${v.car.elm} :: ${v.cdr.elm}\n`; });
src += `\n\nall =\n    [ ${vectors.map((_, i) => `v${i}`).join('\n    , ')} ]\n`;
fs.writeFileSync(path.join(dir, 'Fixture.elm'), src);

console.log(`gen.js: ${N} vectors (kind ${KIND}, nest ${NEST}, seed ${SEED}) -> ${path.join(dir, 'vectors.spec')} + Fixture.elm`);
