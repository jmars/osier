<!-- GENERATED FILE — DO NOT EDIT BY HAND.
     Regenerate with: tools/gen-fixture-matrix.sh
     Staleness check: tools/gen-fixture-matrix.sh --check -->

# The fixture-gate matrix (machine-readable counterpart of Appendix A)

Every check the language gate REGISTERS, in declaration order. Generated from
the gate's own registration calls, not copied by hand:

```sh
tools/gen-fixture-matrix.sh            # write this file
tools/gen-fixture-matrix.sh --check    # fail if this file is stale
tools/gen-fixture-matrix.sh --stdout   # print it
```

The dump it is rendered from (no elm/elmvm/node/jq needed in that mode):

```sh
ELM_GATE_MATRIX=/tmp/matrix.tsv tests/elm-fixtures/run-elm-gate.sh
```

**268 registered checks.** Run from the repo root, the gate prints
`PASS=268 FAIL=0` on the frozen artifact. `docs/research/osier-paper.md`
**Appendix A** is the paper's prose counterpart: the *designed* programs the
paper cites, with the claim each one pins. Appendix A is a selected subset;
this file is the complete registry. Where the two disagree, **this file and the
gate win** — the gate is the oracle, and `tools/gen-fixture-matrix.sh --check`
fails loudly rather than letting this listing go stale.

## How to read a row

| column | meaning |
|---|---|
| `check` | the name the gate prints (`PASS <name> …`) |
| `kind` | the gate function that registered it (see the mapping below) |
| `entry point` | the function the VM calls; `<Module>.<fn>` is resolved from the fixture's `module` header |
| `expected` | what must be observed: a single-line printed value, an escaped multi-line value (`\n`), or a substring the compile error must contain |
| `args` | argv passed to the entry point |
| `stdin` | file under `input/` redirected into the VM |
| `fixture` | the fixture source (or the committed `.csexp` bundle for `rawrun`) |

| `kind` (registered by) | dispatcher kind | what it asserts |
|---|---|---|
| `run` | `run` | compiles, runs the entry point through the VM, printed value == `expected` |
| `run2` | `run2` | multi-module: `fixture` compiled *with* its aux module, then as `run` |
| `run_io` | `io` | as `run`, with stdin redirected from `input/<stdin>` |
| `compile_clean` | `ok` | compilation must yield a real bundle, not an `err …` payload (no value check — the fixture's value cannot be driven from argv) |
| `compile_error` | `err` | compilation must emit `err <message>` containing `expected` |
| `out_cmp` | `cmp` | the raw file an earlier run wrote must equal its `expected/*.txt` bytes |
| `rawrun` | `rawrun` | runs a committed `.csexp` bundle no Elm source can produce (e.g. an unknown Task ctor) |
| `sigdeath` | `sigdeath` | a child that dies BY SIGNAL must be reported as `128+signum` (compiles its own bundle; `expected` = the `<code>|<out>|<err>` tuple): `sh -c 'kill -9 $$'` is reaped WIFSIGNALED, so the code must be 137 — a decoder without `waitStatusCode`'s signal arm answers `EXITSTATUS(9) = 0` |
| `depth` | `depth` | deep NON-tail recursion past `CALL_STACK_DEPTH` must be LOUD (compiles its own bundle; `args` = control-depth past-cap-margin): control depth and `CAP-1` print `expected`; past the cap the process exits non-zero with the `call stack depth exceeded` diagnostic on stderr and no value on stdout |
| `natrun` (registered by `run`) | `natrun` | P7 native twin of `run`: the same sources build through the QBE backend (elm `->` .ssa `->` vendored qbe `->` cc + rt.o) and the binary must print `expected` — the successor execution model; `ELM_GATE_NATIVE=0` registers none |
| `natrun2` (by `run2`) | `natrun2` | native twin of `run2` (aux module + fixture compiled together) |
| `natio` (by `run_io`) | `natio` | native twin of `run_io` (stdin redirected from `input/<stdin>`) |
| `natsig` (by `sigdeath`) | `natsig` | native twin of `sigdeath` (signal-death reap on the native effect loop) |
| `natdepth` | `natdepth` | the NATIVE twin of `depth`: deep NON-tail recursion past the C-stack budget must be LOUD (builds its own binary via `tools/qbe/qbe-mk.sh`; `args` = control-depth past-depth deep-depth): the control prints `expected` under the check's own 1 MiB `ulimit -s` (`QBE_NO_RLIMIT=1`); past the boundary the process exits non-zero with the `native stack depth exceeded` diagnostic on stderr and no value on stdout; deep-depth must still complete at the driver's raised 64 MiB limit |

## The registered checks

| # | check | kind | entry point | expected | args | stdin | fixture |
|---:|---|---|---|---|---|---|---|
| 1 | `fib` | `run` | `fib` | `55` | `10` | — | `fib.elm` |
| 2 | `fib` | `run` | `fib` | `55` | `10` | — | `fib.elm` |
| 3 | `rtl1` | `run` | `main` | `7` | — | — | `rtl1.elm` |
| 4 | `rtl1` | `run` | `main` | `7` | — | — | `rtl1.elm` |
| 5 | `rtl2` | `run` | `main` | `-7` | — | — | `rtl2.elm` |
| 6 | `rtl2` | `run` | `main` | `-7` | — | — | `rtl2.elm` |
| 7 | `sub` | `run` | `sub` | `7` | `10 3` | — | `sub.elm` |
| 8 | `sub` | `run` | `sub` | `7` | `10 3` | — | `sub.elm` |
| 9 | `sub` | `run` | `sub` | `-7` | `3 10` | — | `sub.elm` |
| 10 | `sub` | `run` | `sub` | `-7` | `3 10` | — | `sub.elm` |
| 11 | `div` | `run` | `main` | `14` | — | — | `div.elm` |
| 12 | `div` | `run` | `main` | `14` | — | — | `div.elm` |
| 13 | `nested` | `run` | `main` | `7` | — | — | `nested.elm` |
| 14 | `nested` | `run` | `main` | `7` | — | — | `nested.elm` |
| 15 | `closure` | `run` | `main` | `8` | — | — | `closure.elm` |
| 16 | `closure` | `run` | `main` | `8` | — | — | `closure.elm` |
| 17 | `letread` | `run` | `main` | `-1` | — | — | `letread.elm` |
| 18 | `letread` | `run` | `main` | `-1` | — | — | `letread.elm` |
| 19 | `letclosure` | `run` | `main` | `18` | — | — | `letclosure.elm` |
| 20 | `letclosure` | `run` | `main` | `18` | — | — | `letclosure.elm` |
| 21 | `letdeeprec` | `run` | `main` | `20000` | — | — | `letdeeprec.elm` |
| 22 | `letdeeprec` | `run` | `main` | `20000` | — | — | `letdeeprec.elm` |
| 23 | `lexselftail` | `run` | `main` | `500500` | — | — | `lexselftail.elm` |
| 24 | `lexselftail` | `run` | `main` | `500500` | — | — | `lexselftail.elm` |
| 25 | `applytwice` | `run` | `main` | `12` | — | — | `applytwice.elm` |
| 26 | `applytwice` | `run` | `main` | `12` | — | — | `applytwice.elm` |
| 27 | `countdown` | `run` | `countdown` | `0` | `100000` | — | `countdown.elm` |
| 28 | `countdown` | `run` | `countdown` | `0` | `100000` | — | `countdown.elm` |
| 29 | `eqlist` | `run` | `main` | `true` | — | — | `eqlist.elm` |
| 30 | `eqlist` | `run` | `main` | `true` | — | — | `eqlist.elm` |
| 31 | `const` | `run` | `answer` | `42` | — | — | `const.elm` |
| 32 | `const` | `run` | `answer` | `42` | — | — | `const.elm` |
| 33 | `partial` | `run` | `main` | `8` | — | — | `partial.elm` |
| 34 | `partial` | `run` | `main` | `8` | — | — | `partial.elm` |
| 35 | `subpartial` | `run` | `main` | `2` | — | — | `subpartial.elm` |
| 36 | `subpartial` | `run` | `main` | `2` | — | — | `subpartial.elm` |
| 37 | `overapply` | `run` | `main` | `10` | — | — | `overapply.elm` |
| 38 | `overapply` | `run` | `main` | `10` | — | — | `overapply.elm` |
| 39 | `curry` | `run` | `main` | `3` | — | — | `curry.elm` |
| 40 | `curry` | `run` | `main` | `3` | — | — | `curry.elm` |
| 41 | `opvalue` | `run` | `main` | `3` | — | — | `opvalue.elm` |
| 42 | `opvalue` | `run` | `main` | `3` | — | — | `opvalue.elm` |
| 43 | `crossref` | `run` | `main` | `42` | — | — | `crossref.elm` |
| 44 | `crossref` | `run` | `main` | `42` | — | — | `crossref.elm` |
| 45 | `selfqual` | `run` | `main` | `42` | — | — | `selfqual.elm` |
| 46 | `selfqual` | `run` | `main` | `42` | — | — | `selfqual.elm` |
| 47 | `listcase` | `run` | `main` | `15` | — | — | `listcase.elm` |
| 48 | `listcase` | `run` | `main` | `15` | — | — | `listcase.elm` |
| 49 | `adteval` | `run` | `main` | `20` | — | — | `adteval.elm` |
| 50 | `adteval` | `run` | `main` | `20` | — | — | `adteval.elm` |
| 51 | `adtcase` | `run` | `main` | `13` | — | — | `adtcase.elm` |
| 52 | `adtcase` | `run` | `main` | `13` | — | — | `adtcase.elm` |
| 53 | `letcase` | `run` | `main` | `4` | — | — | `letcase.elm` |
| 54 | `letcase` | `run` | `main` | `4` | — | — | `letcase.elm` |
| 55 | `countcase` | `run` | `main` | `0` | — | — | `countcase.elm` |
| 56 | `countcase` | `run` | `main` | `0` | — | — | `countcase.elm` |
| 57 | `patterns` | `run` | `main` | `1151` | — | — | `patterns.elm` |
| 58 | `patterns` | `run` | `main` | `1151` | — | — | `patterns.elm` |
| 59 | `boolcase` | `run` | `main` | `0` | — | — | `boolcase.elm` |
| 60 | `boolcase` | `run` | `main` | `0` | — | — | `boolcase.elm` |
| 61 | `records` | `run` | `main` | `40` | — | — | `records.elm` |
| 62 | `records` | `run` | `main` | `40` | — | — | `records.elm` |
| 63 | `shortcircuit` | `run` | `main` | `1` | — | — | `shortcircuit.elm` |
| 64 | `shortcircuit` | `run` | `main` | `1` | — | — | `shortcircuit.elm` |
| 65 | `biglist` | `run` | `main` | `2003000` | — | — | `biglist.elm` |
| 66 | `biglist` | `run` | `main` | `2003000` | — | — | `biglist.elm` |
| 67 | `strings` | `run` | `main` | `"6:5:x, y, z"` | — | — | `strings.elm` |
| 68 | `strings` | `run` | `main` | `"6:5:x, y, z"` | — | — | `strings.elm` |
| 69 | `multimod` | `run2` | `main` | `42` | — | — | `multimod.elm` |
| 70 | `multimod` | `run2` | `main` | `42` | — | — | `multimod.elm` |
| 71 | `floatlit` | `run` | `main` | `2.0` | — | — | `floatlit.elm` |
| 72 | `floatlit` | `run` | `main` | `2.0` | — | — | `floatlit.elm` |
| 73 | `floatarith` | `run` | `main` | `4.0` | — | — | `floatarith.elm` |
| 74 | `floatarith` | `run` | `main` | `4.0` | — | — | `floatarith.elm` |
| 75 | `floatdiv` | `run` | `main` | `3.5` | — | — | `floatdiv.elm` |
| 76 | `floatdiv` | `run` | `main` | `3.5` | — | — | `floatdiv.elm` |
| 77 | `floatmix` | `run` | `main` | `3.5` | — | — | `floatmix.elm` |
| 78 | `floatmix` | `run` | `main` | `3.5` | — | — | `floatmix.elm` |
| 79 | `floatcmp` | `run` | `main` | `true` | — | — | `floatcmp.elm` |
| 80 | `floatcmp` | `run` | `main` | `true` | — | — | `floatcmp.elm` |
| 81 | `floatfun` | `run` | `area` | `12.0` | `2.0` | — | `floatfun.elm` |
| 82 | `floatfun` | `run` | `area` | `12.0` | `2.0` | — | `floatfun.elm` |
| 83 | `floatpartial` | `run` | `main` | `3.5` | — | — | `floatpartial.elm` |
| 84 | `floatpartial` | `run` | `main` | `3.5` | — | — | `floatpartial.elm` |
| 85 | `floatineq` | `run` | `main` | `true` | — | — | `floatineq.elm` |
| 86 | `floatineq` | `run` | `main` | `true` | — | — | `floatineq.elm` |
| 87 | `mxint` | `run` | `main` | `175` | — | — | `mxint.elm` |
| 88 | `mxint` | `run` | `main` | `175` | — | — | `mxint.elm` |
| 89 | `mxstring` | `run` | `main` | `"2:Ann, Bo\|Hi Ann!"` | — | — | `mxstring.elm` |
| 90 | `mxstring` | `run` | `main` | `"2:Ann, Bo\|Hi Ann!"` | — | — | `mxstring.elm` |
| 91 | `iofile` | `run_io` | `main` | `"echo:hello\n"` | — | `hello.txt` | `iofile.elm` |
| 92 | `iofile` | `run_io` | `main` | `"echo:hello\n"` | — | `hello.txt` | `iofile.elm` |
| 93 | `iofile` | `out_cmp` | — | — | — | — | — |
| 94 | `ioecho` | `run_io` | `main` | `hello\nworld\n2` | — | `echo.txt` | `ioecho.elm` |
| 95 | `ioecho` | `run_io` | `main` | `hello\nworld\n2` | — | `echo.txt` | `ioecho.elm` |
| 96 | `taskpure` | `run` | `main` | `42` | — | — | `taskpure.elm` |
| 97 | `taskpure` | `run` | `main` | `42` | — | — | `taskpure.elm` |
| 98 | `taskseq` | `run` | `main` | `6` | — | — | `taskseq.elm` |
| 99 | `taskseq` | `run` | `main` | `6` | — | — | `taskseq.elm` |
| 100 | `taskattempt` | `run` | `main` | `"boom"` | — | — | `taskattempt.elm` |
| 101 | `taskattempt` | `run` | `main` | `"boom"` | — | — | `taskattempt.elm` |
| 102 | `execpipe` | `run` | `main` | `"0\|ho\|"` | — | — | `execpipe.elm` |
| 103 | `execpipe` | `run` | `main` | `"0\|ho\|"` | — | — | `execpipe.elm` |
| 104 | `execenv` | `run` | `main` | `"hello\|1\|/tmp"` | — | — | `execenv.elm` |
| 105 | `execenv` | `run` | `main` | `"hello\|1\|/tmp"` | — | — | `execenv.elm` |
| 106 | `execglob` | `run` | `main` | `"execenv.txt,execglob.txt,execpipe.txt"` | — | — | `execglob.elm` |
| 107 | `execglob` | `run` | `main` | `"execenv.txt,execglob.txt,execpipe.txt"` | — | — | `execglob.elm` |
| 108 | `asyncorder` | `run` | `main` | `"file,ran"` | — | — | `asyncorder.elm` |
| 109 | `asyncorder` | `run` | `main` | `"file,ran"` | — | — | `asyncorder.elm` |
| 110 | `fastexec` | `run` | `main` | `"0\|hi\n\|"` | — | — | `fastexec.elm` |
| 111 | `fastexec` | `run` | `main` | `"0\|hi\n\|"` | — | — | `fastexec.elm` |
| 112 | `asyncpure` | `run` | `main` | `"abc"` | — | — | `asyncpure.elm` |
| 113 | `asyncpure` | `run` | `main` | `"abc"` | — | — | `asyncpure.elm` |
| 114 | `signaldeath` | `sigdeath` | `main` | `"137\|\|"` | — | — | `signaldeath.elm` |
| 115 | `signaldeath` | `sigdeath` | `main` | `"137\|\|"` | — | — | `signaldeath.elm` |
| 116 | `signaldeathasync` | `sigdeath` | `main` | `"137\|\|"` | — | — | `signaldeathasync.elm` |
| 117 | `signaldeathasync` | `sigdeath` | `main` | `"137\|\|"` | — | — | `signaldeathasync.elm` |
| 118 | `dup` | `compile_error` | — | `duplicate top-level definition in Dup: f` | — | — | `dup.elm` |
| 119 | `shadowerr` | `compile_error` | — | `is both a top-level definition and imported via` | — | — | `shadowerr.elm` |
| 120 | `shadowtyperr` | `compile_error` | — | `is both a top-level definition and imported via` | — | — | `shadowtyperr.elm` |
| 121 | `ambimperr` | `compile_error` | — | `from two different modules` | — | — | `ambimperr.elm` |
| 122 | `unhandledtask` | `rawrun` | `main` | `elmvm: error: unhandled Task effect: TaskBogus\nerror: ShenError` | — | — | `unhandledtask.csexp` |
| 123 | `cmporder` | `run` | `main` | `"LT GT EQ LT EQ LT GT EQ LT EQ LT EQ GT LT EQ LT LT EQ"` | — | — | `cmporder.elm` |
| 124 | `cmporder` | `run` | `main` | `"LT GT EQ LT EQ LT GT EQ LT EQ LT EQ GT LT EQ LT LT EQ"` | — | — | `cmporder.elm` |
| 125 | `resultmaybe` | `run` | `main` | `"42 7 12 N 1 0 7 N 123 O42 E 9 5 O42 E E4 77 N O8 E 1 0 O6"` | — | — | `resultmaybe.elm` |
| 126 | `resultmaybe` | `run` | `main` | `"42 7 12 N 1 0 7 N 123 O42 E 9 5 O42 E E4 77 N O8 E 1 0 O6"` | — | — | `resultmaybe.elm` |
| 127 | `dictbasic` | `run` | `main` | `-1956` | — | — | `dictbasic.elm` |
| 128 | `dictbasic` | `run` | `main` | `-1956` | — | — | `dictbasic.elm` |
| 129 | `setops` | `run` | `main` | `168` | — | — | `setops.elm` |
| 130 | `setops` | `run` | `main` | `168` | — | — | `setops.elm` |
| 131 | `dictstress` | `run` | `main` | `1533354` | — | — | `dictstress.elm` |
| 132 | `dictstress` | `run` | `main` | `1533354` | — | — | `dictstress.elm` |
| 133 | `bitwise` | `run` | `main` | `446` | — | — | `bitwise.elm` |
| 134 | `bitwise` | `run` | `main` | `446` | — | — | `bitwise.elm` |
| 135 | `arraybasic` | `run` | `main` | `20799` | — | — | `arraybasic.elm` |
| 136 | `arraybasic` | `run` | `main` | `20799` | — | — | `arraybasic.elm` |
| 137 | `arraystress` | `run` | `main` | `7947531` | — | — | `arraystress.elm` |
| 138 | `arraystress` | `run` | `main` | `7947531` | — | — | `arraystress.elm` |
| 139 | `strunit` | `run` | `main` | `"1111111111111111111111111111111111111111111111111\|42.5\|2.0\|  一"` | — | — | `strunit.elm` |
| 140 | `strunit` | `run` | `main` | `"1111111111111111111111111111111111111111111111111\|42.5\|2.0\|  一"` | — | — | `strunit.elm` |
| 141 | `p2pad` | `run` | `main` | `"11111111111111\|========================================\|    ab\|ab    "` | — | — | `p2pad.elm` |
| 142 | `p2pad` | `run` | `main` | `"11111111111111\|========================================\|    ab\|ab    "` | — | — | `p2pad.elm` |
| 143 | `nowunit` | `run` | `main` | `"now-ok order-ok"` | — | — | `nowunit.elm` |
| 144 | `nowunit` | `run` | `main` | `"now-ok order-ok"` | — | — | `nowunit.elm` |
| 145 | `dirunit` | `run` | `main` | `"alpha.txt,beta.txt,gamma/"` | — | — | `dirunit.elm` |
| 146 | `dirunit` | `run` | `main` | `"alpha.txt,beta.txt,gamma/"` | — | — | `dirunit.elm` |
| 147 | `statunit` | `run` | `main` | `"s12-ok nd-ok reg-ok treg-ok mtime-ok s8-ok dir-ok nfile-ok tdir-ok miss-ok"` | — | — | `statunit.elm` |
| 148 | `statunit` | `run` | `main` | `"s12-ok nd-ok reg-ok treg-ok mtime-ok s8-ok dir-ok nfile-ok tdir-ok miss-ok"` | — | — | `statunit.elm` |
| 149 | `rowpoly` | `run` | `main` | `34` | — | — | `rowpoly.elm` |
| 150 | `rowpoly` | `run` | `main` | `34` | — | — | `rowpoly.elm` |
| 151 | `extrec` | `run` | `main` | `29` | — | — | `extrec.elm` |
| 152 | `extrec` | `run` | `main` | `29` | — | — | `extrec.elm` |
| 153 | `insrec` | `run` | `main` | `105` | — | — | `insrec.elm` |
| 154 | `insrec` | `run` | `main` | `105` | — | — | `insrec.elm` |
| 155 | `remrec` | `run` | `main` | `8` | — | — | `remrec.elm` |
| 156 | `remrec` | `run` | `main` | `8` | — | — | `remrec.elm` |
| 157 | `scopedup` | `run` | `main` | `17` | — | — | `scopedup.elm` |
| 158 | `scopedup` | `run` | `main` | `17` | — | — | `scopedup.elm` |
| 159 | `recalias` | `run` | `main` | `33` | — | — | `recalias.elm` |
| 160 | `recalias` | `run` | `main` | `33` | — | — | `recalias.elm` |
| 161 | `appendres` | `run` | `main` | `5` | — | — | `appendres.elm` |
| 162 | `appendres` | `run` | `main` | `5` | — | — | `appendres.elm` |
| 163 | `tyerr_update_missing_field` | `compile_error` | — | `does not have field` | — | — | `tyerr_update_missing_field.elm` |
| 164 | `tyerr_ambiguous_append` | `compile_error` | — | `ambiguous` | — | — | `tyerr_ambiguous_append.elm` |
| 165 | `tyerr_numstr` | `compile_error` | — | `unify number with String` | — | — | `tyerr_numstr.elm` |
| 166 | `tyerr_arity` | `compile_error` | — | `apply non-function` | — | — | `tyerr_arity.elm` |
| 167 | `tyerr_remove_absent` | `compile_error` | — | `does not have field` | — | — | `tyerr_remove_absent.elm` |
| 168 | `rowgadt_select` | `compile_clean` | — | — | — | — | `rowgadt_select.elm` |
| 169 | `rowgadt_setx` | `compile_clean` | — | — | — | — | `rowgadt_setx.elm` |
| 170 | `rowgadt_absentfield` | `compile_error` | — | `is rigid` | — | — | `rowgadt_absentfield.elm` |
| 171 | `rowgadt_escape` | `compile_error` | — | `escaping row equation` | — | — | `rowgadt_escape.elm` |
| 172 | `rowgadt_eval` | `run` | `main` | `[cons 1 . true]` | — | — | `rowgadt_eval.elm` |
| 173 | `rowgadt_eval` | `run` | `main` | `[cons 1 . true]` | — | — | `rowgadt_eval.elm` |
| 174 | `rowgadt_evalbad` | `compile_error` | — | `escaping row equation` | — | — | `rowgadt_evalbad.elm` |
| 175 | `rowgadt_het` | `run` | `main` | `"hi3"` | — | — | `rowgadt_het.elm` |
| 176 | `rowgadt_het` | `run` | `main` | `"hi3"` | — | — | `rowgadt_het.elm` |
| 177 | `rowgadt_noescape` | `compile_error` | — | `is rigid` | — | — | `rowgadt_noescape.elm` |
| 178 | `rowgadt_l3i` | `run` | `main` | `"3"` | — | — | `rowgadt_l3i.elm` |
| 179 | `rowgadt_l3i` | `run` | `main` | `"3"` | — | — | `rowgadt_l3i.elm` |
| 180 | `rowgadt_l3ii` | `compile_error` | — | `cannot unify {k:a\| b} with {\| a}` | — | — | `rowgadt_l3ii.elm` |
| 181 | `rowgadt_l3iii` | `run` | `main` | `1` | — | — | `rowgadt_l3iii.elm` |
| 182 | `rowgadt_l3iii` | `run` | `main` | `1` | — | — | `rowgadt_l3iii.elm` |
| 183 | `rowgadt_hget` | `compile_clean` | — | — | — | — | `rowgadt_hget.elm` |
| 184 | `rowgadt_hget_bare` | `compile_clean` | — | — | — | — | `rowgadt_hget_bare.elm` |
| 185 | `rowgadt_hget_escape` | `compile_error` | — | `escaping row equation` | — | — | `rowgadt_hget_escape.elm` |
| 186 | `rowgadt_hget_badhead` | `compile_error` | — | `is rigid` | — | — | `rowgadt_hget_badhead.elm` |
| 187 | `rowgadt_escape_launder` | `compile_error` | — | `escaping row equation` | — | — | `rowgadt_escape_launder.elm` |
| 188 | `rowgadt_escape_wildcard` | `compile_error` | — | `escaping row equation` | — | — | `rowgadt_escape_wildcard.elm` |
| 189 | `rowgadt_ce1_prealias` | `compile_error` | — | `escaping row equation` | — | — | `rowgadt_ce1_prealias.elm` |
| 190 | `rowgadt_shape_rebuild` | `compile_clean` | — | — | — | — | `rowgadt_shape_rebuild.elm` |
| 191 | `rowgadt_dup_rebuild` | `compile_clean` | — | — | — | — | `rowgadt_dup_rebuild.elm` |
| 192 | `rowgadt_dup_fewer` | `compile_error` | — | `cannot unify a with {x:Int\|` | — | — | `rowgadt_dup_fewer.elm` |
| 193 | `rowgadt_fsm` | `run` | `main` | `"open:42"` | — | — | `rowgadt_fsm.elm` |
| 194 | `rowgadt_fsm` | `run` | `main` | `"open:42"` | — | — | `rowgadt_fsm.elm` |
| 195 | `rowgadt_fsm_bad` | `compile_error` | — | `missing field closed` | — | — | `rowgadt_fsm_bad.elm` |
| 196 | `rowgadt_fsm_narrow` | `compile_error` | — | `cannot be unified with {broken:a\| b}` | — | — | `rowgadt_fsm_narrow.elm` |
| 197 | `rowgadt_fsm_nested` | `run` | `main` | `"open:42"` | — | — | `rowgadt_fsm_nested.elm` |
| 198 | `rowgadt_fsm_nested` | `run` | `main` | `"open:42"` | — | — | `rowgadt_fsm_nested.elm` |
| 199 | `rowgadt_fsm_nested_bad` | `compile_error` | — | `cannot be unified with {broken:a\| b}` | — | — | `rowgadt_fsm_nested_bad.elm` |
| 200 | `adtgaps` | `compile_error` | — | `non-exhaustive case` | — | — | `adtgaps.elm` |
| 201 | `refutneg` | `compile_error` | — | `non-exhaustive case` | — | — | `refutneg.elm` |
| 202 | `refutpos` | `run` | `main` | `5` | — | — | `refutpos.elm` |
| 203 | `refutpos` | `run` | `main` | `5` | — | — | `refutpos.elm` |
| 204 | `refutbare` | `compile_error` | — | `non-exhaustive case` | — | — | `refutbare.elm` |
| 205 | `rowgadt_ce2_barevar` | `compile_error` | — | `cannot unify Int with String` | — | — | `rowgadt_ce2_barevar.elm` |
| 206 | `rowgadt_ce2_plain` | `compile_error` | — | `cannot unify RowgadtCe2Plain.Expr with String` | — | — | `rowgadt_ce2_plain.elm` |
| 207 | `rowgadt_ce3_fieldalias` | `compile_error` | — | `type variable a is rigid` | — | — | `rowgadt_ce3_fieldalias.elm` |
| 208 | `rowgadt_ce3a_tuple` | `compile_error` | — | `infinite type` | — | — | `rowgadt_ce3a_tuple.elm` |
| 209 | `rowgadt_ce3b_prealias` | `compile_error` | — | `infinite type` | — | — | `rowgadt_ce3b_prealias.elm` |
| 210 | `rowgadt_ce3c_let` | `compile_error` | — | `infinite type` | — | — | `rowgadt_ce3c_let.elm` |
| 211 | `liftself` | `run` | `main` | `515` | — | — | `liftself.elm` |
| 212 | `liftself` | `run` | `main` | `515` | — | — | `liftself.elm` |
| 213 | `liftmutual` | `run` | `main` | `42` | — | — | `liftmutual.elm` |
| 214 | `liftmutual` | `run` | `main` | `42` | — | — | `liftmutual.elm` |
| 215 | `liftfirstclass` | `run` | `main` | `100` | — | — | `liftfirstclass.elm` |
| 216 | `liftfirstclass` | `run` | `main` | `100` | — | — | `liftfirstclass.elm` |
| 217 | `liftshadow` | `run` | `main` | `13` | — | — | `liftshadow.elm` |
| 218 | `liftshadow` | `run` | `main` | `13` | — | — | `liftshadow.elm` |
| 219 | `liftfwd` | `run` | `main` | `6` | — | — | `liftfwd.elm` |
| 220 | `liftfwd` | `run` | `main` | `6` | — | — | `liftfwd.elm` |
| 221 | `liftfwdmix` | `run` | `main` | `11` | — | — | `liftfwdmix.elm` |
| 222 | `liftfwdmix` | `run` | `main` | `11` | — | — | `liftfwdmix.elm` |
| 223 | `liftnested` | `run` | `main` | `1002` | — | — | `liftnested.elm` |
| 224 | `liftnested` | `run` | `main` | `1002` | — | — | `liftnested.elm` |
| 225 | `liftnestedtuple` | `run` | `main` | `1003` | — | — | `liftnestedtuple.elm` |
| 226 | `liftnestedtuple` | `run` | `main` | `1003` | — | — | `liftnestedtuple.elm` |
| 227 | `liftnestedfinal` | `run` | `main` | `1002` | — | — | `liftnestedfinal.elm` |
| 228 | `liftnestedfinal` | `run` | `main` | `1002` | — | — | `liftnestedfinal.elm` |
| 229 | `liftnestedrec` | `run` | `main` | `100` | — | — | `liftnestedrec.elm` |
| 230 | `liftnestedrec` | `run` | `main` | `100` | — | — | `liftnestedrec.elm` |
| 231 | `liftdelegate` | `run` | `main` | `5` | — | — | `liftdelegate.elm` |
| 232 | `liftdelegate` | `run` | `main` | `5` | — | — | `liftdelegate.elm` |
| 233 | `liftdelegmut` | `run` | `main` | `0` | — | — | `liftdelegmut.elm` |
| 234 | `liftdelegmut` | `run` | `main` | `0` | — | — | `liftdelegmut.elm` |
| 235 | `liftprelude` | `run` | `main` | `7` | — | — | `liftprelude.elm` |
| 236 | `liftprelude` | `run` | `main` | `7` | — | — | `liftprelude.elm` |
| 237 | `liftenclosing` | `run` | `main` | `100` | — | — | `liftenclosing.elm` |
| 238 | `liftenclosing` | `run` | `main` | `100` | — | — | `liftenclosing.elm` |
| 239 | `liftseqcap` | `run` | `main` | `2` | — | — | `liftseqcap.elm` |
| 240 | `liftseqcap` | `run` | `main` | `2` | — | — | `liftseqcap.elm` |
| 241 | `liftfwdback` | `run` | `main` | `6` | — | — | `liftfwdback.elm` |
| 242 | `liftfwdback` | `run` | `main` | `6` | — | — | `liftfwdback.elm` |
| 243 | `liftcapconfl` | `run` | `main` | `51` | — | — | `liftcapconfl.elm` |
| 244 | `liftcapconfl` | `run` | `main` | `51` | — | — | `liftcapconfl.elm` |
| 245 | `liftcapconfl2` | `run` | `main` | `51` | — | — | `liftcapconfl2.elm` |
| 246 | `liftcapconfl2` | `run` | `main` | `51` | — | — | `liftcapconfl2.elm` |
| 247 | `liftmodfwd` | `run` | `main` | `999` | — | — | `liftmodfwd.elm` |
| 248 | `liftmodfwd` | `run` | `main` | `999` | — | — | `liftmodfwd.elm` |
| 249 | `liftpreludefwd` | `run` | `main` | `2` | — | — | `liftpreludefwd.elm` |
| 250 | `liftpreludefwd` | `run` | `main` | `2` | — | — | `liftpreludefwd.elm` |
| 251 | `liftprelfwdfn` | `run` | `main` | `1000` | — | — | `liftprelfwdfn.elm` |
| 252 | `liftprelfwdfn` | `run` | `main` | `1000` | — | — | `liftprelfwdfn.elm` |
| 253 | `liftstaycall` | `run` | `main` | `702` | — | — | `liftstaycall.elm` |
| 254 | `liftstaycall` | `run` | `main` | `702` | — | — | `liftstaycall.elm` |
| 255 | `liftdisjoint` | `run` | `main` | `35` | — | — | `liftdisjoint.elm` |
| 256 | `liftdisjoint` | `run` | `main` | `35` | — | — | `liftdisjoint.elm` |
| 257 | `liftvaluecycle` | `compile_error` | — | `unknown name: v` | — | — | `liftvaluecycle.elm` |
| 258 | `liftrefuse` | `compile_error` | — | `unknown name: a` | — | — | `liftrefuse.elm` |
| 259 | `liftstayfwd` | `run` | `main` | `999` | — | — | `liftstayfwd.elm` |
| 260 | `liftstayfwd` | `run` | `main` | `999` | — | — | `liftstayfwd.elm` |
| 261 | `liftcycshadows` | `run` | `main` | `0` | — | — | `liftcycshadows.elm` |
| 262 | `liftcycshadows` | `run` | `main` | `0` | — | — | `liftcycshadows.elm` |
| 263 | `liftrelaxleak` | `run` | `main` | `999` | — | — | `liftrelaxleak.elm` |
| 264 | `liftrelaxleak` | `run` | `main` | `999` | — | — | `liftrelaxleak.elm` |
| 265 | `liftdisjointshadow` | `run` | `main` | `3` | — | — | `liftdisjointshadow.elm` |
| 266 | `liftdisjointshadow` | `run` | `main` | `3` | — | — | `liftdisjointshadow.elm` |
| 267 | `calloverflow` | `depth` | `main` | `500500` | `1000 5000` | — | `calloverflow.elm` |
| 268 | `natcalloverflow` | `natdepth` | `main` | `500500` | `1000 20000 100000` | — | `natcalloverflow.elm` |

---
Generated from `tests/elm-fixtures/run-elm-gate.sh`; 268 checks.
