// M0 bootstrap → M3 → batch: node wrapper for the elm-compiler.
//
// Single-fixture CLI (preserved):
//   node run.js <input1.elm> [input2.elm ...] <output.csexp>
// ALL inputs are compiled TOGETHER as one multi-module program (cross-module
// references resolve through the merged global table).  src/Prelude.elm is
// ALWAYS appended last — it is compiled by the compiler itself (plan §6/§8
// M3), so user modules get List/String/Basics conveniences without importing
// anything.  The source list travels to Main.elm as a JSON array string.
//
// Batch CLI (S8):
//   node run.js --batch <manifest.json>
// manifest = { "groups": [ { "sources": ["/abs/a.elm", ...], "output": "/abs/x.csexp" }, ... ] }
// The fixed corpus (Prelude + Runtime + the eight core-libs) is read ONCE and
// every group is compiled in this one process; Main.elm emits a JSON ARRAY of
// per-group bundle strings ("<bundle>" or "err <msg>" per group), which are
// written to each group's output file.  This pays for the corpus
// parse+typecheck+lower exactly once instead of once per fixture.
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
// `elm make src/Main.elm`).  The UI-flavoured libs (Tea, Key, Draw, ...) were
// parked in fx-ui in withe-split Phase 3 and are no longer part of the corpus.
const CORPUS = [
  fs.readFileSync(path.join(__dirname, 'src', 'Prelude.elm'), 'utf8'),
  fs.readFileSync(path.join(__dirname, 'src', 'Runtime.elm'), 'utf8'),
  ...[ 'Dict.elm', 'Set.elm', 'Maybe.elm', 'Result.elm',
       'Tuple.elm', 'JsArray.elm', 'Array.elm', 'Str.elm' ]
    .map((f) => fs.readFileSync(path.join(__dirname, 'core-libs', f), 'utf8')),
];

// MIDTIER=1 compiles through the middle tier (Mid.Ir: Mid.FromAst ->
// Mid.ToZinc); unset / MIDTIER=0 is the direct AST-to-ZINC path, which is the
// byte-identity anchor.  Stage 1 carries ZERO optimization passes, so the two
// modes must produce IDENTICAL bytes for every input (tools/midtier-diff.sh).
const MIDTIER = process.env.MIDTIER === '1';

// MIDTIER_TRACE=1 makes the compiler report which path it took on stderr.  It
// exists so a differential cannot pass vacuously when the switch fails to
// engage (an unsubscribed port is simply dropped otherwise).
const MIDTIER_TRACE = process.env.MIDTIER_TRACE === '1';

// V8's stack limit CANNOT be raised once node has started, and the MIDTIER=1
// path over the compiler's own 58 sources (the selfhost group, whose
// Char.Extra.unicodeIsAlphaNumOrUnderscoreFast compiles to ~11k instructions in
// ONE defun) runs closer to the limit than MIDTIER=0 does under the default
// optimizing JIT.  MEASURED (tools/midtier-diff.sh step 4 records it): with the
// JIT the two modes' minimum stacks differ by ~25% for that group, while with
// --no-opt they are within 50 KB of each other and the emitted bytes are
// IDENTICAL either way — so it is a V8 tiering/frame-size artifact, not a
// difference in the instruction stream.  MIDTIER_STACK=<KB> re-executes this
// driver once with --stack-size=<KB> so a caller that needs the headroom
// (`MIDTIER=1 MIDTIER_STACK=2400 tools/selfhost-compile.sh`) still uses the
// ordinary entry points.  Unset => no re-exec, no behaviour change.
if (process.env.MIDTIER_STACK && !process.env.MIDTIER_STACK_DONE) {
  const res = require('child_process').spawnSync(
    process.execPath,
    ['--stack-size=' + process.env.MIDTIER_STACK].concat(process.argv.slice(1)),
    { stdio: 'inherit', env: Object.assign({}, process.env, { MIDTIER_STACK_DONE: '1' }) }
  );
  process.exit(res.status === null ? 1 : res.status);
}

const { Elm } = require('./compiler.js');

// Compile `groups` (array of { sources: [String], output: String }) in ONE
// process.  Each group's bundle (or "err <msg>") lands in its output file.
function compileGroups(groups) {
  const app = Elm.Main.init({
    flags: {
      corpusSourcesJson: JSON.stringify(CORPUS),
      groupsJson: JSON.stringify(groups.map((g) => g.sources)),
      midtier: MIDTIER,
    },
  });

  // The runtime delivers a Cmd.batch in an order of its own (the mode report
  // arrives AFTER the emit payload), so with MIDTIER_TRACE=1 we wait for both
  // before exiting.  If the report never arrives, the safety-net timeout below
  // exits nonzero: the trace is the differential's proof that the switch
  // ENGAGED, and a missing proof must not look like a pass.
  let emitted = false;
  let modeSeen = !MIDTIER_TRACE;

  function finish() {
    if (emitted && modeSeen) process.exit(0);
  }

  app.ports.modeReport.subscribe((mode) => {
    modeSeen = true;
    process.stderr.write(`midtier-trace: ${mode}\n`);
    finish();
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
        `run.js: expected ${groups.length} bundles, got ` +
        `${Array.isArray(bundles) ? bundles.length : 'non-array'}`
      );
      process.exit(1);
    }
    for (let i = 0; i < groups.length; i++) {
      fs.writeFileSync(groups[i].output, bundles[i]);
    }
    emitted = true;
    finish();
  });

  // Safety net: if Main.elm never emits, don't hang forever.  Generous for
  // the batch mode (all fixtures in one process).
  setTimeout(() => {
    console.error(
      MIDTIER_TRACE && !modeSeen
        ? 'run.js: timed out waiting for the mode report port (MIDTIER_TRACE=1)'
        : 'run.js: timed out waiting for emit port'
    );
    process.exit(1);
  }, 120000);
}

function usage() {
  console.error(
    'usage: node run.js <input1.elm> [input2.elm ...] <output.csexp>\n' +
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
    }));
    compileGroups(groups);
    return;
  }

  if (argv.length < 2) usage();
  const output = argv[argv.length - 1];
  const inputs = argv.slice(0, -1);
  compileGroups([{ sources: inputs.map((p) => fs.readFileSync(p, 'utf8')), output }]);
}

main();
