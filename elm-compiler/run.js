// M0 bootstrap → M3 → batch: node wrapper for the elm-compiler.
//
// Single-fixture CLI:
//   QBE_ENTRY=<Mod>.<fn> node run.js <input1.elm> [input2.elm ...] <output.ssa>
// ALL inputs are compiled TOGETHER as one multi-module program (cross-module
// references resolve through the merged global table).  src/Prelude.elm is
// ALWAYS appended last — it is compiled by the compiler itself (plan §6/§8
// M3), so user modules get List/String/Basics conveniences without importing
// anything.  The source list travels to Main.elm as a JSON array string.
//
// Batch CLI (S8):
//   node run.js --batch <manifest.json>
// manifest = { "groups": [ { "sources": ["/abs/a.elm", ...], "output": "/abs/x.ssa", "entry": "Mod.fn" }, ... ] }
// The fixed corpus (Prelude + Runtime + the eight core-libs) is read ONCE and
// every group is compiled in this one process; Main.elm emits a JSON ARRAY of
// per-group strings (the QBE IL text, or "err <msg>" per group), which are
// written to each group's output file.  This pays for the corpus
// parse+typecheck+lower exactly once instead of once per fixture.  Each
// group's OWN `entry` names the defun the QBE backend roots reachability
// from (the single-fixture CLI's QBE_ENTRY, per group).
//
// P8 (osier-delete-zinc): this driver is QBE-ONLY.  The ZINC-csexp output
// paths (MIDTIER=0 direct lowering and the MIDTIER=1 middle-tier driver) are
// deleted with the interpreter; every compile emits QBE IL (.ssa).
//
// Main.elm emits synchronously inside init, but Elm's kernel delivers port
// Cmd messages asynchronously (on the next tick), so we wait for the emit
// callback and exit once it fires.

'use strict';

const fs = require('fs');
const path = require('path');

// The fixed corpus, in the order Main/run.js historically appended them:
// Prelude, Runtime, then the eight elm/core ports (Dict/Set/Maybe/Result/
// Tuple live in core-libs/ — NOT src/ — because elm's ambiguity check
// spans source-directories: a local src/Dict.elm collides with elm/core's
// Dict for every compiler module that imports it, breaking
// `elm make src/Main.elm`).  The UI-flavoured libs (Tea, Key, Draw, ...)
// were parked in fx-ui in osier split Phase 3 and are no longer part of the
// corpus.
const CORPUS = [
  fs.readFileSync(path.join(__dirname, 'src', 'Prelude.elm'), 'utf8'),
  fs.readFileSync(path.join(__dirname, 'src', 'Runtime.elm'), 'utf8'),
  ...[ 'Dict.elm', 'Set.elm', 'Maybe.elm', 'Result.elm',
       'Tuple.elm', 'JsArray.elm', 'Array.elm', 'Str.elm' ]
    .map((f) => fs.readFileSync(path.join(__dirname, 'core-libs', f), 'utf8')),
];

// QBE_NOFLATTEN=1 DISABLES the defun-local aggregate flattening pass.  It
// exists so the pass can be A/B'd on the SAME source: the structural gate in
// tools/qbe/qbe-check.sh compiles both ways and requires the aggregate prims
// to be GONE in one build and PRESENT in the other, and the selfhost
// wall-clock measurement needs the same switch.  Default ON.
const QBE_FLATTEN = process.env.QBE_NOFLATTEN !== '1';
// QBE_NOREP=1 DISABLES the S4/M1 representation pass (unboxed Int locals +
// Native i64 arithmetic on proven-Int operands in a monotype defun).  Same
// purpose as QBE_NOFLATTEN: it exists so the pass can be A/B'd on the SAME
// source — the structural gate compiles both ways and the counters must move
// with the clock.  Default ON.
const QBE_REP = process.env.QBE_NOREP !== '1';
// QBE_ENTRY: the defun key the QBE backend roots reachability from
// ("<Mod>.<fn>").  REQUIRED in the single-fixture CLI; the batch mode reads
// one entry PER GROUP from the manifest instead.
const QBE_ENTRY = process.env.QBE_ENTRY || '';

// V8's stack limit CANNOT be raised once node has started, and the QBE
// backend's lowering runs non-tail-recursive passes (Peephole.forwardBlock)
// over per-block instruction lists.  The gate fixtures and the whole-compiler
// emit (rooted at NativeMain.main) stay comfortably inside the default, but a
// compile that roots reachability at an arbitrary deep defun (the per-file
// groups of tools/selfhost-audit.sh — e.g. Elm.Parser.Declarations.declaration,
// one enormous parser-combinator expression) can exceed it.  RUN_STACK_KB=<kb>
// re-executes this driver once with --stack-size=<kb> so such callers keep
// using the ordinary entry points.  Unset => no re-exec, no behaviour change.
// (This is the same mechanism the retired MIDTIER_STACK knob provided.)
if (process.env.RUN_STACK_KB && !process.env.RUN_STACK_KB_DONE) {
  const res = require('child_process').spawnSync(
    process.execPath,
    ['--stack-size=' + process.env.RUN_STACK_KB].concat(process.argv.slice(1)),
    { stdio: 'inherit', env: Object.assign({}, process.env, { RUN_STACK_KB_DONE: '1' }) }
  );
  process.exit(res.status === null ? 1 : res.status);
}

const { Elm } = require('./compiler.js');

// Compile `groups` (array of { sources: [String], output: String, entry:
// String }) in ONE process.  Each group's QBE IL text (or "err <msg>") lands
// in its output file.
function compileGroups(groups) {
  const app = Elm.Main.init({
    flags: {
      corpusSourcesJson: JSON.stringify(CORPUS),
      groupsJson: JSON.stringify(groups.map((g) => g.sources)),
      entriesJson: JSON.stringify(groups.map((g) => g.entry)),
      qbeFlatten: QBE_FLATTEN,
      qbeRep: QBE_REP,
    },
  });

  app.ports.emit.subscribe((msg) => {
    let bundles;
    try {
      bundles = JSON.parse(msg);
    } catch (e) {
      console.error('run.js: bad emit payload (not JSON)');
      process.exit(1);
    }
    if (!Array.isArray(bundles) || bundles.length !== groups.length) {
      console.error(
        `run.js: expected ${groups.length} outputs, got ` +
        `${Array.isArray(bundles) ? bundles.length : 'non-array'}`
      );
      process.exit(1);
    }
    for (let i = 0; i < groups.length; i++) {
      fs.writeFileSync(groups[i].output, bundles[i]);
    }
    process.exit(0);
  });

  // Safety net: if Main.elm never emits, don't hang forever.  Generous for
  // the batch mode (all fixtures in one process).
  setTimeout(() => {
    console.error('run.js: timed out waiting for emit port');
    process.exit(1);
  }, 120000);
}

function usage() {
  console.error(
    'usage: QBE_ENTRY=<Mod>.<fn> node run.js <input1.elm> [input2.elm ...] <output.ssa>\n' +
    '       node run.js --batch <manifest.json>'
  );
  process.exit(2);
}

function main() {
  const argv = process.argv.slice(2);

  if (argv[0] === '--batch') {
    if (argv.length !== 2) usage();
    const manifest = JSON.parse(fs.readFileSync(argv[1], 'utf8'));
    const groups = manifest.groups.map((g) => ({
      sources: g.sources.map((p) => fs.readFileSync(p, 'utf8')),
      output: g.output,
      entry: g.entry || '',
    }));
    for (const g of groups) {
      if (!g.entry) {
        console.error(`run.js: batch group missing "entry" for output ${g.output}`);
        process.exit(2);
      }
    }
    compileGroups(groups);
    return;
  }

  if (argv.length < 2) usage();
  if (!QBE_ENTRY) usage();
  const output = argv[argv.length - 1];
  const inputs = argv.slice(0, -1);
  compileGroups([{ sources: inputs.map((p) => fs.readFileSync(p, 'utf8')), output, entry: QBE_ENTRY }]);
}

main();
