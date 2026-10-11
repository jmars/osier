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
// The churn batches' long-string source: a few hundred bytes per vector, so
// `Str.repeat 500` allocates tens of KB PER VECTOR (the volume the fixed 8MB
// nursery actually needs to see).  Kept inside the spec grammar's byte range.
function longStrSpec() {
  const len = ri(60, 100);
  let bytes = '';
  for (let i = 0; i < len; i++) bytes += ALPHA[ri(0, ALPHA.length - 1)];
  return { spec: `s:${bytes}`, elm: JSON.stringify(bytes) };
}

// The churn-cons loop: a tail-recursive cons accumulator, so the list built by
// the Mid `cons` prim stays REACHABLE across every iteration (promotion churn
// and the moving collector's interior-pointer/rooting discipline) while the
// printed result stays a single number.
const CHURN_CONS_HELPER = `
churnbuild : Int -> Int -> List Int -> Int
churnbuild n m acc =
    if n == 0 then
        m

    else
        churnbuild (n - 1) m (n :: acc)
`;

// The eq-vec builder: a fully written vector of size 1, 2 or 3 (each slot
// addressed explicitly, so the elementwise walk reads only initialized
// elements on both arms).
const VEC_HELPERS = `
mkvec n x =
    case n of
        1 ->
            vectorSet (vectorMake 1) 0 x

        2 ->
            vectorSet (vectorSet (vectorMake 2) 0 x) 1 x

        _ ->
            vectorSet (vectorSet (vectorSet (vectorMake 3) 0 x) 1 x) 2 x
`;

function listIntSpec(depth) {
  const n = depth > 0 ? ri(0, 2) : (rnd() % 6 === 0 ? ri(4, 6) : ri(0, 4));
  const els = [];
  for (let i = 0; i < n; i++) els.push(depth > 0 ? listIntSpec(depth - 1) : numSpec());
  return {
    spec: `l(${els.map((e) => e.spec).join(',')})`,
    elm: els.length === 0 ? '[]' : `[ ${els.map((e) => e.elm).join(',')} ]`,
  };
}

// ---------------------------------------------------------------------
//  Blocker 2 helpers (step-5 review): the RECORD must reach the access in a
//  form the pipeline CANNOT constant-fold.
//
//  MEASURED (review): `v = (let r = { f = a, g = b } in r.f)` is folded by the
//  shape analysis — every v-defun in the assoc batches STORED the field value
//  directly, so the batch's .ssa held only q_Rt_x2econs/q_Rt_x2eemptylist and
//  the Mid arm never ran Rt.assoc/Rt.snd/Rt.assocGo: the comparison tested the
//  FOLDER against the Zig prim chain, not Mid against Zig.
//
//  The fix: build the record in a TOP-LEVEL function (Elm does not inline
//  those, and the call is not evaluable at compile time) and read the field
//  through ANOTHER top-level function's PARAMETER, whose shape is unknown at
//  the access.  The `.g` vectors are deliberate: assoc's FIRST-pair arm
//  returns before the recursion, so only a deferred key reaches Rt.assocGo
//  (and, through it, the symbol deepEq) — a head-only batch would leave both
//  with zero execution evidence.
// ---------------------------------------------------------------------
const REC_HELPERS_INT = `
mkrec : Int -> Int -> { f : Int, g : Int }
mkrec a b =
    { f = a, g = b }


getf : { f : Int, g : Int } -> Int
getf r =
    r.f


getg : { f : Int, g : Int } -> Int
getg r =
    r.g
`;

const REC_HELPERS_STR = `
mkrec : String -> String -> { f : String, g : String }
mkrec a b =
    { f = a, g = b }


getf : { f : String, g : String } -> String
getf r =
    r.f


getg : { f : String, g : String } -> String
getg r =
    r.g
`;

// The two PATTERN seats (blocker 1's second entry point): a record-field
// pattern binds through lowerPath's VField arm, and it does so on BOTH paths
// that reach it — a `let` destructure (VField in LetDestruct.binds) and a
// `case` alt (VField in Alt.binds).  Both spellings are in one batch so the
// census arms for both are exercised by one comparison.
const REC_HELPERS_PAT = `
mkrec : Int -> Int -> { f : Int, g : Int }
mkrec a b =
    { f = a, g = b }


patf : { f : Int, g : Int } -> Int
patf r =
    let
        { f } =
            r
    in
    f


patg : { f : Int, g : Int } -> Int
patg r =
    case r :: [] of
        { g } :: _ ->
            g

        [] ->
            0
`;

// ---------------------------------------------------------------------
//  OPAQUE OPERANDS (blocker 2, the OPERATOR family — same defect class as the
//  assoc batches, MEASURED here): Lower's inline fast path is gated by a
//  deny-by-default VALUE proof (`isIntKnown`/`isFloatKnown`: a literal, an
//  Int/Float-typed parameter, or a + - * node over those), so `(3) + (4)` is
//  emitted as a raw i64 add and the Mid prim is NEVER CALLED.  MEASURED on
//  the committed spelling: add-int/sub-int/mul-int/add-float/fdiv-float/
//  lt-int/le-int/gt-int/ge-float and eq-int/eq-mixed/eq-bool produced NO
//  `call $q_Rt_<op>` from any vector defun — the batch compared the INLINE
//  path against Zig, not the Mid implementation (and the header claimed the
//  latter).
//
//  `idn`/`idf`/`idb` are top-level identities: Elm does not inline top-level
//  functions (MEASURED: `getf (mkrec 1 2)` survives), so the operand is an
//  `App`, which the proof DENIES — the site then routes to the prim.
//
//  The batches ALTERNATE the two spellings by vector index, so ONE batch
//  compares BOTH paths against the reference, and the `require` list below
//  makes "the routed path is present" a checked claim (a batch that goes back
//  to folding FAILS instead of silently passing).
// ---------------------------------------------------------------------
const OP_HELPERS = `
idn : Int -> Int
idn x =
    x


idx : number -> number
idx x =
    x


idf : Float -> Float
idf x =
    x


idb : Bool -> Bool
idb x =
    x
`;

function opq(v) {
  const w = v.spec.startsWith('f:') ? 'idf' : v.spec.startsWith('b:') ? 'idb' : 'idn';
  return `(${w} (${v.elm}))`;
}

// even vectors: the PROVEN-operand spelling (Lower inlines it)
// odd  vectors: every operand wrapped, so the proof denies and the prim runs
function alt(proven, opaque) {
  return (v, i) => (i % 2 === 0 ? proven(v) : opaque(v));
}

// arg buildes per batch: [ [specFn, ...], ... ] — one entry per ARG.
// `helpers` (optional) is emitted verbatim into Fixture.elm.  `require` is
// the list of Rt symbols primsdiff.sh asserts the Mid arm's own (non-Rt)
// defuns actually CALL — a batch that names a prim it never exercises fails,
// which is what turns "COVERAGE" from a comment into a check.
// `churn: true` marks a batch whose vectors allocate enough to make the
// collector run; primsdiff.sh asserts the GC counters moved for those.
const OPS = {
  'add-int': { args: [numSpec, numSpec], line: alt(([a, b]) => `(${a.elm}) + (${b.elm})`, ([a, b]) => `${opq(a)} + ${opq(b)}`), zig: '+', helpers: OP_HELPERS, require: ['q_Rt_x2e_x2b'] },
  'add-float': { args: [floatSpec, floatSpec], line: alt(([a, b]) => `(${a.elm}) + (${b.elm})`, ([a, b]) => `${opq(a)} + ${opq(b)}`), zig: '+', helpers: OP_HELPERS, require: ['q_Rt_x2e_x2b'] },
  'sub-int': { args: [numSpec, numSpec], line: alt(([a, b]) => `(${a.elm}) - (${b.elm})`, ([a, b]) => `${opq(a)} - ${opq(b)}`), zig: '-', helpers: OP_HELPERS, require: ['q_Rt_x2e_x2d'] },
  'mul-int': { args: [numSpec, numSpec], line: alt(([a, b]) => `(${a.elm}) * (${b.elm})`, ([a, b]) => `${opq(a)} * ${opq(b)}`), zig: '*', helpers: OP_HELPERS, require: ['q_Rt_x2e_x2a'] },
  // the GUARD is on the SECOND arg (the divisor): x/0 SIGFPEs BOTH arms —
  // parity by crash, untestable same-process (see the header's stated gaps)
  'div-int': { args: [numSpec, () => { const d = numSpec(); if (d.spec === 'n:0') return { spec: 'n:3', elm: '3' }; return d; }], line: ([a, b]) => `(${a.elm}) // (${b.elm})`, zig: '/', require: ['q_Rt_x2e_x2f'] },
  'fdiv-float': { args: [floatSpec, floatSpec], line: alt(([a, b]) => `(${a.elm}) / (${b.elm})`, ([a, b]) => `${opq(a)} / ${opq(b)}`), zig: 'f/', helpers: OP_HELPERS, require: ['q_Rt_x2ef_x2f'] },
  'lt-int': { args: [numSpec, numSpec], line: alt(([a, b]) => `(${a.elm}) < (${b.elm})`, ([a, b]) => `${opq(a)} < ${opq(b)}`), zig: '<', helpers: OP_HELPERS, require: ['q_Rt_x2e_x3c'] },
  'le-int': { args: [numSpec, numSpec], line: alt(([a, b]) => `(${a.elm}) <= (${b.elm})`, ([a, b]) => `${opq(a)} <= ${opq(b)}`), zig: '<=', helpers: OP_HELPERS, require: ['q_Rt_x2e_x3c_x3d'] },
  'gt-int': { args: [numSpec, numSpec], line: alt(([a, b]) => `(${a.elm}) > (${b.elm})`, ([a, b]) => `${opq(a)} > ${opq(b)}`), zig: '>', helpers: OP_HELPERS, require: ['q_Rt_x2e_x3e'] },
  'ge-float': { args: [floatSpec, floatSpec], line: alt(([a, b]) => `(${a.elm}) >= (${b.elm})`, ([a, b]) => `${opq(a)} >= ${opq(b)}`), zig: '>=', helpers: OP_HELPERS, require: ['q_Rt_x2e_x3e_x3d'] },
  'eq-int': { args: [numSpec, numSpec], line: alt(([a, b]) => `(${a.elm}) == (${b.elm})`, ([a, b]) => `${opq(a)} == ${opq(b)}`), zig: '=', helpers: OP_HELPERS, require: ['q_Rt_x2e_x3d'] },
  'eq-mixed': { args: [() => (rnd() % 2 ? numSpec() : floatSpec()), () => (rnd() % 2 ? numSpec() : floatSpec())], line: alt(([a, b]) => `(${a.elm}) == (${b.elm})`, ([a, b]) => `(idx (${a.elm})) == (idx (${b.elm}))`), zig: '=', helpers: OP_HELPERS, require: ['q_Rt_x2e_x3d'] },
  // eq-string's operands are INDEPENDENT random strings, so the `=` TRUE path
  // (bytesEqGo's i>=len walk on equal strings) was never reached: see the
  // eq-string-same batch below.
  'eq-string': { args: [strSpec, strSpec], line: ([a, b]) => `(${a.elm}) == (${b.elm})`, zig: '=', require: ['q_Rt_x2e_x3d'] },
  'eq-bool': { args: [boolSpec, boolSpec], line: alt(([a, b]) => `(${a.elm}) == (${b.elm})`, ([a, b]) => `${opq(a)} == ${opq(b)}`), zig: '=', helpers: OP_HELPERS, require: ['q_Rt_x2e_x3d'] },
  'eq-list': { args: [() => listIntSpec(0), () => listIntSpec(0)], line: ([a, b]) => `(${a.elm}) == (${b.elm})`, zig: '=', require: ['q_Rt_x2e_x3d'] },
  // (capture item 1) EQUAL-STRING true path: both sides are the SAME runtime
  // expression, so the byte walks agree to the end and `=` must answer True
  // (the eq-string batch's two independent draws almost never match).
  'eq-string-same': { args: [strSpec, strSpec], line: ([a, b]) => `(String.append (${a.elm}) (${b.elm})) == (String.append (${a.elm}) (${b.elm}))`, zig: 'eq-cn-same', require: ['q_Rt_x2e_x3d'] },
  // (capture item 2) vecEq's ELEMENTWISE walk on EQUAL-LENGTH vectors — the
  // vec batch only writes-then-reads, so only `=`'s length-mismatch
  // short-circuit had any vector coverage.  Alternating equal/differing
  // element values, so the walk is exercised on BOTH its match and its
  // mismatch arm; every slot is written (an uninitialized element would be
  // read by BOTH arms and make the comparison meaningless).
  'eq-vec': {
    args: () => {
      const n = ri(1, 3);
      const x1 = numSpec();
      let x2 = x1;
      if (rnd() % 2) {
        x2 = numSpec();
        if (x2.spec === x1.spec) x2 = { spec: 'n:1', elm: '1' };
      }
      return [{ spec: `n:${n}`, elm: `${n}` }, x1, x2];
    },
    line: ([n, x1, x2]) => `(mkvec (${n.elm}) (${x1.elm})) == (mkvec (${n.elm}) (${x2.elm}))`,
    zig: 'vec-eq',
    helpers: VEC_HELPERS,
    require: ['q_Rt_x2e_x3d'],
  },
  'and-int': { args: [i32Spec, i32Spec], line: ([a, b]) => `Bitwise.and (${a.elm}) (${b.elm})`, zig: 'bitwise-and', require: ['q_Rt_x2ebitwise_x2dand'] },
  'or-int': { args: [i32Spec, i32Spec], line: ([a, b]) => `Bitwise.or (${a.elm}) (${b.elm})`, zig: 'bitwise-or', require: ['q_Rt_x2ebitwise_x2dor'] },
  'xor-int': { args: [i32Spec, i32Spec], line: ([a, b]) => `Bitwise.xor (${a.elm}) (${b.elm})`, zig: 'bitwise-xor', require: ['q_Rt_x2ebitwise_x2dxor'] },
  'not-int': { args: [i32Spec], line: ([a]) => `Bitwise.complement (${a.elm})`, zig: 'bitwise-not', require: ['q_Rt_x2ebitwise_x2dnot'] },
  'shl-int': { args: [shiftSpec, i32Spec], line: ([c, v]) => `Bitwise.shiftLeftBy (${c.elm}) (${v.elm})`, zig: 'bitwise-shift-left', require: ['q_Rt_x2ebitwise_x2dshift_x2dleft'] },
  'shr-int': { args: [shiftSpec, i32Spec], line: ([c, v]) => `Bitwise.shiftRightBy (${c.elm}) (${v.elm})`, zig: 'bitwise-shift-right', require: ['q_Rt_x2ebitwise_x2dshift_x2dright'] },
  'shrzf-int': { args: [shiftSpec, i32Spec], line: ([c, v]) => `Bitwise.shiftRightZfBy (${c.elm}) (${v.elm})`, zig: 'bitwise-shift-right-zf', require: ['q_Rt_x2ebitwise_x2dshift_x2dright_x2dzf'] },
  'isnum': { args: [() => (rnd() % 3 === 0 ? floatSpec() : numSpec())], line: ([a]) => `isNumber (${a.elm})`, zig: 'number?', require: ['q_Rt_x2enumber_x3f'] },
  'isstr': { args: [() => (rnd() % 2 ? strSpec() : numSpec())], line: ([a]) => `isString (${a.elm})`, zig: 'string?', require: ['q_Rt_x2estring_x3f'] },
  'iscons': { args: [() => listIntSpec(0)], line: ([a]) => `isCons (${a.elm})`, zig: 'cons?', require: ['q_Rt_x2econs_x3f'] },
  'isnil': { args: [() => listIntSpec(0)], line: ([a]) => `isNil (${a.elm})`, zig: 'empty?', require: ['q_Rt_x2eempty_x3f'] },
  'cn-str': { args: [strSpec, strSpec], line: ([a, b]) => `String.append (${a.elm}) (${b.elm})`, zig: 'cn', require: ['q_Rt_x2ecn'] },
  'cn-num': { args: [numSpec, strSpec], line: ([a, b]) => `String.append (String.fromInt (${a.elm})) (${b.elm})`, zig: 'cn', require: ['q_Rt_x2ecn'] },
  'strlen': { args: [strSpec], line: ([a]) => `String.length (${a.elm})`, zig: 'c-strlen', require: ['q_Rt_x2ec_x2dstrlen'] },
  'repeat-str': { args: [() => { const v = ri(0, 6); return { spec: `n:${v}`, elm: `${v}` }; }, strSpec], line: ([n, s]) => `Str.repeat (${n.elm}) (${s.elm})`, zig: 'repeat', require: ['q_Rt_x2erepeat'] },
  'substring-str': { args: [strSpec, () => { const v = ri(-2, 10); return { spec: `n:${v}`, elm: `${v}` }; }, () => { const v = ri(-2, 10); return { spec: `n:${v}`, elm: `${v}` }; }], line: ([s, a, b]) => `String.sliceLen (${a.elm}) (${b.elm}) (${s.elm})`, zig: 'substring', require: ['q_Rt_x2esubstring'] },
  'charcode-str': { args: [strSpec, () => { const v = ri(-2, 12); return { spec: `n:${v}`, elm: `${v}` }; }], line: ([s, i]) => `charCode (${s.elm}) (${i.elm})`, zig: 'char-code', require: ['q_Rt_x2echar_x2dcode'] },
  'strbytes': { args: [strSpec], line: ([a]) => `strToBytes (${a.elm})`, zig: 'shen.str->bytes', require: ['q_Rt_x2eshen_x2estr_x2d_x3ebytes'] },
  'bytestr': { args: [() => listIntSpec(0)], line: ([a]) => `bytesToString (${a.elm})`, zig: 'shen.bytes->string', require: ['q_Rt_x2eshen_x2ebytes_x2d_x3estring'] },
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
    require: ['q_Rt_x2eabsvector', 'q_Rt_x2eaddress_x2d_x3e', 'q_Rt_x2e_x3c_x2daddress'],
  },
  // a surface TUPLE is buildTuple — a cons chain, NOT the `@p` prim (measured)
  'atp': { args: [numSpec, strSpec], line: ([a, b]) => `( (${a.elm}), (${b.elm}) )`, zig: '@p', require: ['q_Rt_x2econs'] },
  'assoc-int': {
    args: [numSpec, numSpec],
    line: ([a, b], i) => `${i % 2 === 0 ? 'getf' : 'getg'} (mkrec (${a.elm}) (${b.elm}))`,
    zig: (i) => (i % 2 === 0 ? 'assoc' : 'assoc-g'),
    helpers: REC_HELPERS_INT,
    require: ['q_Rt_x2eassoc', 'q_Rt_x2esnd'],
  },
  'assoc-str': {
    args: [strSpec, strSpec],
    line: ([a, b], i) => `${i % 2 === 0 ? 'getf' : 'getg'} (mkrec (${a.elm}) (${b.elm}))`,
    zig: (i) => (i % 2 === 0 ? 'assoc' : 'assoc-g'),
    helpers: REC_HELPERS_STR,
    require: ['q_Rt_x2eassoc', 'q_Rt_x2esnd'],
  },
  // the SECOND entry point of the census (Lower.elm's VField seat): field
  // PATTERNS through both paths that reach lowerPath — a let destructure and a
  // case alt.  Same reference op ('assoc') on the Zig side.
  'assoc-pat': {
    args: [numSpec, numSpec],
    line: ([a, b], i) => `${i % 2 === 0 ? 'patf' : 'patg'} (mkrec (${a.elm}) (${b.elm}))`,
    zig: (i) => (i % 2 === 0 ? 'assoc' : 'assoc-g'),
    helpers: REC_HELPERS_PAT,
    require: ['q_Rt_x2eassoc', 'q_Rt_x2esnd'],
  },
  'cons-int': { args: [numSpec, () => listIntSpec(0)], line: ([a, b]) => `(${a.elm}) :: (${b.elm})`, zig: 'cons', require: ['q_Rt_x2econs'] },
  // [] as a literal: ListLit [] -> the `emptylist 0` desugar
  'nil': { args: [], line: () => `[]`, zig: 'emptylist', require: ['q_Rt_x2eemptylist'] },

  // ---------------------------------------------------------------------
  //  THE CHURN BATCHES (should-fix 3).  The committed churn mode was INERT:
  //  MEASURED with QBE_GC_STATS, every one of the 40 batches showed
  //  scavenges=0 full_collects=0 — the nursery is a FIXED 8MB
  //  (vendor/osier-rt/src/gc/heap.zig:53; QBE_HEAP_MB scales the TOTAL heap,
  //  rt.zig:1244, not the nursery) and 200 small vectors allocate < 1MB.  So
  //  `churn-16` was a plain rerun and the GC/rooting dimension had ZERO
  //  exercise.  The lever that actually works is ALLOCATION VOLUME: each
  //  vector below allocates tens of KB and keeps the printed result SMALL
  //  (a length / one element), so the collector genuinely churns without
  //  40MB of stdout.  primsdiff.sh ASSERTS the collection happened (its
  //  churn rows fail when the counters stay at 0) rather than claiming it.
  //
  //  MEASURED at n=200, QBE_HEAP_MB=16, MID arm: churn-str 334 scavenges /
  //  144 full collects; churn-cons 8 scavenges; churn-vec 0 scavenges / 11
  //  full collects (a multi-KB array is old-gen-allocated, so the vector
  //  family CHURNS THE OLD GENERATION, not the nursery — stated per batch,
  //  not papered over).
  // ---------------------------------------------------------------------
  'churn-str': {
    args: [() => ({ spec: 'n:500', elm: '500' }), longStrSpec],
    line: ([n, s]) => `String.length (Str.repeat (${n.elm}) (${s.elm}))`,
    zig: 'churn-str',
    churn: true,
    require: ['q_Rt_x2erepeat', 'q_Rt_x2ec_x2dstrlen'],
  },
  'churn-cons': {
    args: [() => { const v = ri(2500, 3500); return { spec: `n:${v}`, elm: `${v}` }; }],
    line: ([n]) => `churnbuild (${n.elm}) (${n.elm}) []`,
    zig: 'churn-cons',
    churn: 2,
    helpers: CHURN_CONS_HELPER,
    require: ['q_Rt_x2econs'],
  },
  'churn-vec': {
    args: () => {
      const n = ri(5000, 7000);
      const i = ri(0, 9);
      const x = numSpec();
      return [{ spec: `n:${n}`, elm: `${n}` }, { spec: `n:${i}`, elm: `${i}` }, x];
    },
    line: ([n, i, x]) => `vectorGet (vectorSet (vectorMake (${n.elm})) (${i.elm}) (${x.elm})) (${i.elm})`,
    zig: 'vec',
    churn: true,
    require: ['q_Rt_x2eabsvector'],
  },
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
  `V ${N}\n` + vectors.map((v, i) => `${typeof op.zig === 'function' ? op.zig(i) : op.zig}|${v.map((a) => a.spec).join('|')}`).join('\n') + '\n');

let src = `module PrimDiff exposing (all)\n\n-- GENERATED by tools/qbe/primsdiff/gen.js (op ${OP}, seed ${SEED}, n ${N})\n-- — do not edit.  One binding per vector; compiled with QBE_MIDCONS=1,\n-- every prim under each spelling routes to its Mid implementation.\n\n`;
if (op.helpers) src += op.helpers.replace(/^\n/, '') + '\n\n';
vectors.forEach((v, i) => { src += `v${i} =\n    ${op.line(v, i)}\n`; });
src += `\n\nall =\n    [ ${vectors.map((_, i) => `v${i}`).join('\n    , ')} ]\n`;
fs.writeFileSync(path.join(dir, 'Fixture.elm'), src);

// The batch's INSTRUMENTATION CONTRACT: the Rt symbols the Mid arm's .ssa must
// actually CALL.  primsdiff.sh fails the batch when one is absent — that is
// what makes "this batch EXERCISES the prim" a checked claim instead of a
// comment (blocker 2: the assoc batches carried neither call and the harness
// could not tell).
fs.writeFileSync(path.join(dir, 'require.txt'), (op.require || []).join('\n') + '\n');
// Whether this batch's vectors allocate enough for the collector to run: the
// harness ASSERTS the GC counters moved for these (and does not claim churn
// for the rest).
// 0 = not a churn batch; 1 = the collector must RUN on both arms; 2 = nursery
// SCAVENGES must be positive on both arms (see primsdiff.sh's assertion).
fs.writeFileSync(path.join(dir, 'churn.txt'), (op.churn === 2 ? '2' : op.churn ? '1' : '0') + '\n');

console.log(`gen.js: ${N} vectors (op ${OP}, seed ${SEED}) -> ${path.join(dir, 'vectors.spec')} + Fixture.elm`);
