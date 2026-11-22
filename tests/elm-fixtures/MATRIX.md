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

The dump it is rendered from (no elm/node/jq needed in that mode):

```sh
ELM_GATE_MATRIX=/tmp/matrix.tsv tests/elm-fixtures/run-elm-gate.sh
```

**196 registered checks.** Run from the repo root, the gate prints
`PASS=196 FAIL=0` on the frozen artifact. `docs/research/osier-paper.md`
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
| `entry point` | the function the gate calls; `<Module>.<fn>` is resolved from the fixture's `module` header |
| `expected` | what must be observed: a single-line printed value, an escaped multi-line value (`\n`), or a substring the compile error must contain |
| `args` | argv passed to the entry point |
| `stdin` | file under `input/` redirected into the compiled binary |
| `fixture` | the fixture source |

| `kind` (registered by) | dispatcher kind | what it asserts |
|---|---|---|
| `run` | `natrun` | the fixture builds through the QBE backend (elm `->` .ssa `->` vendored qbe `->` cc + rt.o) and the binary must print `expected` — the gate's execution model since the interpreter retired at P8 |
| `run2` | `natrun2` | multi-module: `fixture` compiled *with* its aux module, then as `run` |
| `run_io` | `natio` | as `run`, with stdin redirected from `input/<stdin>` |
| `run_pipe` | `natpipe` | stage 7C: as `run`, but stdin is a PIPE fed by a slow producer (`he`, 50 ms, `llo`), so the fixture's `readFile` SUSPENDS on EAGAIN and the host's fd table (`rebuildPollfds` -> `poll` -> `drainReady`) is the only way the value completes — the one row that reaches the poll machinery |
| `compile_clean` | `ok` | compilation must yield a real output, not an `err …` payload (no value check — the fixture's value cannot be driven from argv) |
| `compile_error` | `err` | compilation must emit `err <message>` containing `expected` |
| `out_cmp` | `cmp` | the raw file an earlier run wrote must equal its `expected/*.txt` bytes |
| `runhost` | `nathost` | stage 7D: as `run`, but for a `Platform.program` fixture that drives `TaskExec` through the EFFECT HOST (every pre-existing `exec*` row is a `Platform.worker`, which runs the plan SYNCHRONOUSLY through the `exec-plan` prim and never reaches the leaf). `exechost` covers the async arm (out accumulator growth past 64 KiB, non-empty captured stderr, a non-zero exit code from `WIFEXITED`); `execfallback` covers the plan-shape predicate's negative arm (a pipeline must take the synchronous fallback). Both build their own binary |
| `sigdeath` | `natsig` | a child that dies BY SIGNAL must be reported as `128+signum` (builds its own binary; `expected` = the `<code>|<out>|<err>` tuple): `sh -c 'kill -9 $$'` is reaped WIFSIGNALED, so the code must be 137 — a decoder without `waitStatusCode`'s signal arm answers `EXITSTATUS(9) = 0` |
| `natdepth` | `natdepth` | deep NON-tail recursion past the C-stack budget must be LOUD (builds its own binary via `tools/qbe/qbe-mk.sh`; `args` = control-depth past-depth deep-depth): the control prints `expected` under the check's own 1 MiB `ulimit -s` (`QBE_NO_RLIMIT=1`); past the boundary the process exits non-zero with the `native stack depth exceeded` diagnostic on stderr and no value on stdout; deep-depth must still complete at the driver's r

## The registered checks

| # | check | kind | entry point | expected | args | stdin | fixture |
|---:|---|---|---|---|---|---|---|
| 1 | `fib` | `run` | `fib` | `55` | `10` | — | `fib.elm` |
| 2 | `rtl1` | `run` | `main` | `7` | — | — | `rtl1.elm` |
| 3 | `rtl2` | `run` | `main` | `-7` | — | — | `rtl2.elm` |
| 4 | `sub` | `run` | `sub` | `7` | `10 3` | — | `sub.elm` |
| 5 | `sub` | `run` | `sub` | `-7` | `3 10` | — | `sub.elm` |
| 6 | `div` | `run` | `main` | `14` | — | — | `div.elm` |
| 7 | `nested` | `run` | `main` | `7` | — | — | `nested.elm` |
| 8 | `closure` | `run` | `main` | `8` | — | — | `closure.elm` |
| 9 | `letread` | `run` | `main` | `-1` | — | — | `letread.elm` |
| 10 | `letclosure` | `run` | `main` | `18` | — | — | `letclosure.elm` |
| 11 | `letdeeprec` | `run` | `main` | `20000` | — | — | `letdeeprec.elm` |
| 12 | `lexselftail` | `run` | `main` | `500500` | — | — | `lexselftail.elm` |
| 13 | `applytwice` | `run` | `main` | `12` | — | — | `applytwice.elm` |
| 14 | `countdown` | `run` | `countdown` | `0` | `100000` | — | `countdown.elm` |
| 15 | `eqlist` | `run` | `main` | `true` | — | — | `eqlist.elm` |
| 16 | `const` | `run` | `answer` | `42` | — | — | `const.elm` |
| 17 | `partial` | `run` | `main` | `8` | — | — | `partial.elm` |
| 18 | `subpartial` | `run` | `main` | `2` | — | — | `subpartial.elm` |
| 19 | `overapply` | `run` | `main` | `10` | — | — | `overapply.elm` |
| 20 | `curry` | `run` | `main` | `3` | — | — | `curry.elm` |
| 21 | `opvalue` | `run` | `main` | `3` | — | — | `opvalue.elm` |
| 22 | `crossref` | `run` | `main` | `42` | — | — | `crossref.elm` |
| 23 | `selfqual` | `run` | `main` | `42` | — | — | `selfqual.elm` |
| 24 | `listcase` | `run` | `main` | `15` | — | — | `listcase.elm` |
| 25 | `adteval` | `run` | `main` | `20` | — | — | `adteval.elm` |
| 26 | `adtcase` | `run` | `main` | `13` | — | — | `adtcase.elm` |
| 27 | `letcase` | `run` | `main` | `4` | — | — | `letcase.elm` |
| 28 | `countcase` | `run` | `main` | `0` | — | — | `countcase.elm` |
| 29 | `symeq` | `run` | `main` | `1` | — | — | `symeq.elm` |
| 30 | `fdstream` | `run` | `main` | `1` | — | — | `fdstream.elm` |
| 31 | `patterns` | `run` | `main` | `1151` | — | — | `patterns.elm` |
| 32 | `boolcase` | `run` | `main` | `0` | — | — | `boolcase.elm` |
| 33 | `records` | `run` | `main` | `40` | — | — | `records.elm` |
| 34 | `shortcircuit` | `run` | `main` | `1` | — | — | `shortcircuit.elm` |
| 35 | `biglist` | `run` | `main` | `2003000` | — | — | `biglist.elm` |
| 36 | `strings` | `run` | `main` | `"6:5:x, y, z"` | — | — | `strings.elm` |
| 37 | `multimod` | `run2` | `main` | `42` | — | — | `multimod.elm` |
| 38 | `floatlit` | `run` | `main` | `2.0` | — | — | `floatlit.elm` |
| 39 | `floatarith` | `run` | `main` | `4.0` | — | — | `floatarith.elm` |
| 40 | `floatdiv` | `run` | `main` | `3.5` | — | — | `floatdiv.elm` |
| 41 | `floatmix` | `run` | `main` | `3.5` | — | — | `floatmix.elm` |
| 42 | `floatcmp` | `run` | `main` | `true` | — | — | `floatcmp.elm` |
| 43 | `floatfun` | `run` | `area` | `12.0` | `2.0` | — | `floatfun.elm` |
| 44 | `floatpartial` | `run` | `main` | `3.5` | — | — | `floatpartial.elm` |
| 45 | `floatineq` | `run` | `main` | `true` | — | — | `floatineq.elm` |
| 46 | `mxint` | `run` | `main` | `175` | — | — | `mxint.elm` |
| 47 | `mxstring` | `run` | `main` | `"2:Ann, Bo\|Hi Ann!"` | — | — | `mxstring.elm` |
| 48 | `iofile` | `run_io` | `main` | `"echo:hello\n"` | — | `hello.txt` | `iofile.elm` |
| 49 | `iofile` | `out_cmp` | — | — | — | — | — |
| 50 | `ioecho` | `run_io` | `main` | `hello\nworld\n2` | — | `echo.txt` | `ioecho.elm` |
| 51 | `readfile` | `run` | `main` | `runtime: cannot open file for read-file-as-string\n"hello=[hello\n] missing=[] empty=[] big=70000/tail-ok"` | — | — | `readfile.elm` |
| 52 | `taskpure` | `run` | `main` | `42` | — | — | `taskpure.elm` |
| 53 | `taskseq` | `run` | `main` | `6` | — | — | `taskseq.elm` |
| 54 | `taskattempt` | `run` | `main` | `"boom"` | — | — | `taskattempt.elm` |
| 55 | `execpipe` | `run` | `main` | `"0\|ho\|"` | — | — | `execpipe.elm` |
| 56 | `execenv` | `run` | `main` | `"hello\|1\|/tmp"` | — | — | `execenv.elm` |
| 57 | `execglob` | `run` | `main` | `"tests/elm-fixtures/globdir/?\|.\ntests/elm-fixtures/globdir/*\|.,..,x.txt\ntests/elm-fixtures/globdir/.*\|.,..\nexecbig.txt,execchain.txt,execenv.txt,execfallback.out.txt,execfallback.txt,execglob.txt,exechost.txt,execmal.txt,execnofile.txt,execpipe.txt,execsubchain.txt"` | — | — | `execglob.elm` |
| 58 | `asyncorder` | `run` | `main` | `"file,ran"` | — | — | `asyncorder.elm` |
| 59 | `fastexec` | `run` | `main` | `"0\|hi\n\|"` | — | — | `fastexec.elm` |
| 60 | `exechost` | `runhost` | `main` | `"3\|88894\|12345678910\|oops"` | — | — | `exechost.elm` |
| 61 | `execfallback` | `runhost` | `main` | `"ok"` | — | — | `execfallback.elm` |
| 62 | `execfallback` | `out_cmp` | — | — | — | — | — |
| 63 | `execmal` | `run` | `main` | `qbe-rt: qbe-rt: halt (a Mid prim reached its halt arm)` | — | — | `execmal.elm` |
| 64 | `execchain` | `run` | `main` | `"0\|start\nor-ran\nend\n\|"` | — | — | `execchain.elm` |
| 65 | `execsubchain` | `run` | `main` | `"0\|a\nb\n\|"` | — | — | `execsubchain.elm` |
| 66 | `execbig` | `run` | `main` | `"0\|168894\|0"` | — | — | `execbig.elm` |
| 67 | `execnofile` | `run` | `main` | `"1\|\|Input redirect file not found: no-such-file.txt\n"` | — | — | `execnofile.elm` |
| 68 | `asyncpure` | `run` | `main` | `"abc"` | — | — | `asyncpure.elm` |
| 69 | `signaldeath` | `sigdeath` | `main` | `"137\|\|"` | — | — | `signaldeath.elm` |
| 70 | `signaldeathasync` | `sigdeath` | `main` | `"137\|\|"` | — | — | `signaldeathasync.elm` |
| 71 | `dup` | `compile_error` | — | `duplicate top-level definition in Dup: f` | — | — | `dup.elm` |
| 72 | `shadowerr` | `compile_error` | — | `is both a top-level definition and imported via` | — | — | `shadowerr.elm` |
| 73 | `shadowtyperr` | `compile_error` | — | `is both a top-level definition and imported via` | — | — | `shadowtyperr.elm` |
| 74 | `ambimperr` | `compile_error` | — | `from two different modules` | — | — | `ambimperr.elm` |
| 75 | `cmporder` | `run` | `main` | `"LT GT EQ LT EQ LT GT EQ LT EQ LT EQ GT LT EQ LT LT EQ"` | — | — | `cmporder.elm` |
| 76 | `resultmaybe` | `run` | `main` | `"42 7 12 N 1 0 7 N 123 O42 E 9 5 O42 E E4 77 N O8 E 1 0 O6"` | — | — | `resultmaybe.elm` |
| 77 | `dictbasic` | `run` | `main` | `-1956` | — | — | `dictbasic.elm` |
| 78 | `setops` | `run` | `main` | `168` | — | — | `setops.elm` |
| 79 | `dictstress` | `run` | `main` | `1533354` | — | — | `dictstress.elm` |
| 80 | `bitwise` | `run` | `main` | `446` | — | — | `bitwise.elm` |
| 81 | `arraybasic` | `run` | `main` | `20799` | — | — | `arraybasic.elm` |
| 82 | `arraystress` | `run` | `main` | `7947531` | — | — | `arraystress.elm` |
| 83 | `strunit` | `run` | `main` | `"111111111111111111111111111111111111111111111111111\|42.5\|2.0\|  一"` | — | — | `strunit.elm` |
| 84 | `p2pad` | `run` | `main` | `"11111111111111\|========================================\|    ab\|ab    "` | — | — | `p2pad.elm` |
| 85 | `nowunit` | `run` | `main` | `"now-ok order-ok"` | — | — | `nowunit.elm` |
| 86 | `progio` | `run_hostio` | `main` | `echo:01234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789\n"01234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789\|set\|pid-ok\|/tmp"` | — | `progio.txt` | `progio.elm` |
| 87 | `progio` | `out_cmp` | — | — | — | — | — |
| 88 | `readpipe` | `run_pipe` | `main` | `"pipe=[hello] big=70000"` | — | — | `readpipe.elm` |
| 89 | `dirunit` | `run` | `main` | `"alpha.txt,beta.txt,gamma/"` | — | — | `dirunit.elm` |
| 90 | `statunit` | `run` | `main` | `"s12-ok nd-ok reg-ok treg-ok mtime-ok s8-ok dir-ok nfile-ok tdir-ok miss-ok"` | — | — | `statunit.elm` |
| 91 | `statplus` | `run` | `main` | `"statplus-ok"` | — | — | `statplus.elm` |
| 92 | `rowpoly` | `run` | `main` | `34` | — | — | `rowpoly.elm` |
| 93 | `extrec` | `run` | `main` | `29` | — | — | `extrec.elm` |
| 94 | `insrec` | `run` | `main` | `105` | — | — | `insrec.elm` |
| 95 | `remrec` | `run` | `main` | `8` | — | — | `remrec.elm` |
| 96 | `rmprobe` | `run` | `main` | `6` | — | — | `rmprobe.elm` |
| 97 | `scopedup` | `run` | `main` | `17` | — | — | `scopedup.elm` |
| 98 | `recalias` | `run` | `main` | `33` | — | — | `recalias.elm` |
| 99 | `appendres` | `run` | `main` | `5` | — | — | `appendres.elm` |
| 100 | `tyerr_update_missing_field` | `compile_error` | — | `does not have field` | — | — | `tyerr_update_missing_field.elm` |
| 101 | `tyerr_ambiguous_append` | `compile_error` | — | `ambiguous` | — | — | `tyerr_ambiguous_append.elm` |
| 102 | `tyerr_numstr` | `compile_error` | — | `unify number with String` | — | — | `tyerr_numstr.elm` |
| 103 | `tyerr_arity` | `compile_error` | — | `apply non-function` | — | — | `tyerr_arity.elm` |
| 104 | `tyerr_remove_absent` | `compile_error` | — | `does not have field` | — | — | `tyerr_remove_absent.elm` |
| 105 | `rowgadt_select` | `compile_clean` | — | — | — | — | `rowgadt_select.elm` |
| 106 | `rowgadt_setx` | `compile_clean` | — | — | — | — | `rowgadt_setx.elm` |
| 107 | `rowgadt_absentfield` | `compile_error` | — | `is rigid` | — | — | `rowgadt_absentfield.elm` |
| 108 | `rowgadt_escape` | `compile_error` | — | `escaping row equation` | — | — | `rowgadt_escape.elm` |
| 109 | `rowgadt_eval` | `run` | `main` | `[cons 1 . true]` | — | — | `rowgadt_eval.elm` |
| 110 | `rowgadt_evalbad` | `compile_error` | — | `escaping row equation` | — | — | `rowgadt_evalbad.elm` |
| 111 | `rowgadt_het` | `run` | `main` | `"hi3"` | — | — | `rowgadt_het.elm` |
| 112 | `rowgadt_noescape` | `compile_error` | — | `is rigid` | — | — | `rowgadt_noescape.elm` |
| 113 | `rowgadt_l3i` | `run` | `main` | `"3"` | — | — | `rowgadt_l3i.elm` |
| 114 | `rowgadt_l3ii` | `compile_error` | — | `cannot unify {k:a\| b} with {\| a}` | — | — | `rowgadt_l3ii.elm` |
| 115 | `rowgadt_l3iii` | `run` | `main` | `1` | — | — | `rowgadt_l3iii.elm` |
| 116 | `rowgadt_hget` | `compile_clean` | — | — | — | — | `rowgadt_hget.elm` |
| 117 | `rowgadt_hget_bare` | `compile_clean` | — | — | — | — | `rowgadt_hget_bare.elm` |
| 118 | `rowgadt_hget_escape` | `compile_error` | — | `escaping row equation` | — | — | `rowgadt_hget_escape.elm` |
| 119 | `rowgadt_hget_badhead` | `compile_error` | — | `is rigid` | — | — | `rowgadt_hget_badhead.elm` |
| 120 | `rowgadt_escape_launder` | `compile_error` | — | `escaping row equation` | — | — | `rowgadt_escape_launder.elm` |
| 121 | `rowgadt_escape_wildcard` | `compile_error` | — | `escaping row equation` | — | — | `rowgadt_escape_wildcard.elm` |
| 122 | `rowgadt_ce1_prealias` | `compile_error` | — | `escaping row equation` | — | — | `rowgadt_ce1_prealias.elm` |
| 123 | `rowgadt_shape_rebuild` | `compile_clean` | — | — | — | — | `rowgadt_shape_rebuild.elm` |
| 124 | `rowgadt_dup_rebuild` | `compile_clean` | — | — | — | — | `rowgadt_dup_rebuild.elm` |
| 125 | `rowgadt_dup_fewer` | `compile_error` | — | `cannot unify a with {x:Int\|` | — | — | `rowgadt_dup_fewer.elm` |
| 126 | `rowgadt_fsm` | `run` | `main` | `"open:42"` | — | — | `rowgadt_fsm.elm` |
| 127 | `rowgadt_fsm_bad` | `compile_error` | — | `missing field closed` | — | — | `rowgadt_fsm_bad.elm` |
| 128 | `rowgadt_fsm_narrow` | `compile_error` | — | `cannot be unified with {broken:a\| b}` | — | — | `rowgadt_fsm_narrow.elm` |
| 129 | `rowgadt_fsm_nested` | `run` | `main` | `"open:42"` | — | — | `rowgadt_fsm_nested.elm` |
| 130 | `rowgadt_fsm_nested_bad` | `compile_error` | — | `cannot be unified with {broken:a\| b}` | — | — | `rowgadt_fsm_nested_bad.elm` |
| 131 | `adtgaps` | `compile_error` | — | `non-exhaustive case` | — | — | `adtgaps.elm` |
| 132 | `refutneg` | `compile_error` | — | `non-exhaustive case` | — | — | `refutneg.elm` |
| 133 | `refutpos` | `run` | `main` | `5` | — | — | `refutpos.elm` |
| 134 | `refutbare` | `compile_error` | — | `non-exhaustive case` | — | — | `refutbare.elm` |
| 135 | `rowgadt_ce2_barevar` | `compile_error` | — | `cannot unify Int with String` | — | — | `rowgadt_ce2_barevar.elm` |
| 136 | `rowgadt_ce2_plain` | `compile_error` | — | `cannot unify RowgadtCe2Plain.Expr with String` | — | — | `rowgadt_ce2_plain.elm` |
| 137 | `rowgadt_ce3_fieldalias` | `compile_error` | — | `type variable a is rigid` | — | — | `rowgadt_ce3_fieldalias.elm` |
| 138 | `rowgadt_ce3a_tuple` | `compile_error` | — | `infinite type` | — | — | `rowgadt_ce3a_tuple.elm` |
| 139 | `rowgadt_ce3b_prealias` | `compile_error` | — | `infinite type` | — | — | `rowgadt_ce3b_prealias.elm` |
| 140 | `rowgadt_ce3c_let` | `compile_error` | — | `infinite type` | — | — | `rowgadt_ce3c_let.elm` |
| 141 | `liftself` | `run` | `main` | `515` | — | — | `liftself.elm` |
| 142 | `liftmutual` | `run` | `main` | `42` | — | — | `liftmutual.elm` |
| 143 | `liftfirstclass` | `run` | `main` | `100` | — | — | `liftfirstclass.elm` |
| 144 | `liftshadow` | `run` | `main` | `13` | — | — | `liftshadow.elm` |
| 145 | `liftfwd` | `run` | `main` | `6` | — | — | `liftfwd.elm` |
| 146 | `liftfwdmix` | `run` | `main` | `11` | — | — | `liftfwdmix.elm` |
| 147 | `liftnested` | `run` | `main` | `1002` | — | — | `liftnested.elm` |
| 148 | `liftnestedtuple` | `run` | `main` | `1003` | — | — | `liftnestedtuple.elm` |
| 149 | `liftnestedfinal` | `run` | `main` | `1002` | — | — | `liftnestedfinal.elm` |
| 150 | `liftnestedrec` | `run` | `main` | `100` | — | — | `liftnestedrec.elm` |
| 151 | `liftdelegate` | `run` | `main` | `5` | — | — | `liftdelegate.elm` |
| 152 | `liftdelegmut` | `run` | `main` | `0` | — | — | `liftdelegmut.elm` |
| 153 | `liftprelude` | `run` | `main` | `7` | — | — | `liftprelude.elm` |
| 154 | `liftenclosing` | `run` | `main` | `100` | — | — | `liftenclosing.elm` |
| 155 | `liftseqcap` | `run` | `main` | `2` | — | — | `liftseqcap.elm` |
| 156 | `liftfwdback` | `run` | `main` | `6` | — | — | `liftfwdback.elm` |
| 157 | `liftcapconfl` | `run` | `main` | `51` | — | — | `liftcapconfl.elm` |
| 158 | `liftcapconfl2` | `run` | `main` | `51` | — | — | `liftcapconfl2.elm` |
| 159 | `liftmodfwd` | `run` | `main` | `999` | — | — | `liftmodfwd.elm` |
| 160 | `liftpreludefwd` | `run` | `main` | `2` | — | — | `liftpreludefwd.elm` |
| 161 | `liftprelfwdfn` | `run` | `main` | `1000` | — | — | `liftprelfwdfn.elm` |
| 162 | `liftstaycall` | `run` | `main` | `702` | — | — | `liftstaycall.elm` |
| 163 | `liftdisjoint` | `run` | `main` | `35` | — | — | `liftdisjoint.elm` |
| 164 | `liftvaluecycle` | `compile_error` | — | `unknown name: v` | — | — | `liftvaluecycle.elm` |
| 165 | `liftrefuse` | `compile_error` | — | `unknown name: a` | — | — | `liftrefuse.elm` |
| 166 | `liftstayfwd` | `run` | `main` | `999` | — | — | `liftstayfwd.elm` |
| 167 | `liftcycshadows` | `run` | `main` | `0` | — | — | `liftcycshadows.elm` |
| 168 | `liftrelaxleak` | `run` | `main` | `999` | — | — | `liftrelaxleak.elm` |
| 169 | `liftdisjointshadow` | `run` | `main` | `3` | — | — | `liftdisjointshadow.elm` |
| 170 | `natcalloverflow` | `natdepth` | `main` | `500500` | `1000 20000 100000` | — | `natcalloverflow.elm` |
| 171 | `intcorner` | `intproc` | `wrapmul` | `0\|0\|` | `1` | — | `intcorner.elm` |
| 172 | `intcorner` | `intproc` | `truncdiv` | `0\|-3\|` | `7` | — | `intcorner.elm` |
| 173 | `intcorner` | `intproc` | `divzero` | `1\|\|qbe-rt: division by zero: `// 0` has no i64 value` | `0` | — | `intcorner.elm` |
| 174 | `intcorner` | `intproc` | `minbyneg` | `1\|\|qbe-rt: division overflow: `INT64_MIN // -1` is 2^63, which is not an i64` | `1` | — | `intcorner.elm` |
| 175 | `intbig` | `intproc` | `maxi64` | `0\|9223372036854775807\|` | — | — | `intbig.elm` |
| 176 | `intbig` | `intproc` | `mini64` | `0\|-9223372036854775808\|` | — | — | `intbig.elm` |
| 177 | `intbig` | `intproc` | `above53` | `0\|9007199254740993\|` | — | — | `intbig.elm` |
| 178 | `intbig` | `intproc` | `bigmul` | `0\|1152921504606846975\|` | — | — | `intbig.elm` |
| 179 | `intbig` | `intproc` | `bigdiff` | `0\|1152921504606846976\|` | — | — | `intbig.elm` |
| 180 | `intbig` | `intproc` | `hexmax` | `0\|9223372036854775807\|` | — | — | `intbig.elm` |
| 181 | `intbig` | `intproc` | `patmatch` | `0\|1\|` | `9223372036854775807` | — | `intbig.elm` |
| 182 | `intbig` | `intproc` | `patmatch` | `0\|0\|` | `5` | — | `intbig.elm` |
| 183 | `inttoobigparse` | `intreject` | — | `parse error at row 16 column 5: integer literal `99999999999999999999` is out of range: this language's Int is a signed 64-bit integer` | — | — | `inttoobigparse.elm` |
| 184 | `inttoobig` | `intreject` | — | `integer literal `9223372036854775808` is out of range: it is the magnitude of INT64_MIN` | — | — | `inttoobig.elm` |
| 185 | `inttoobighex` | `intreject` | — | `integer literal `9223372036854775808` is out of range: it is the magnitude of INT64_MIN` | — | — | `inttoobighex.elm` |
| 186 | `boxfloat` | `intproc` | `boxadd` | `0\|1152921504606847000.0\|` | — | — | `boxfloat.elm` |
| 187 | `boxfloat` | `intproc` | `boxaddrev` | `0\|1152921504606847000.0\|` | — | — | `boxfloat.elm` |
| 188 | `boxfloat` | `intproc` | `boxbigsum` | `0\|11152921504606847000.0\|` | — | — | `boxfloat.elm` |
| 189 | `boxfloat` | `intproc` | `boxaddint` | `0\|2305843009213693953\|` | — | — | `boxfloat.elm` |
| 190 | `boxfloat` | `intproc` | `boxnegint` | `0\|-2305843009213693952\|` | — | — | `boxfloat.elm` |
| 191 | `boxfloat` | `intproc` | `boxnegbox` | `0\|-2305843009213693954\|` | — | — | `boxfloat.elm` |
| 192 | `intpow` | `intproc` | `powsmall` | `0\|1024\|` | — | — | `intpow.elm` |
| 193 | `intpow` | `intproc` | `powzero` | `0\|1\|` | — | — | `intpow.elm` |
| 194 | `intpow` | `intproc` | `powwrap` | `0\|0\|` | — | — | `intpow.elm` |
| 195 | `intpow` | `intproc` | `powbig` | `0\|4052555153018976267\|` | — | — | `intpow.elm` |
| 196 | `intpow` | `intproc` | `powneg` | `1\|\|qbe-rt: negative exponent: `^` requires an exponent >= 0` | `1` | — | `intpow.elm` |

---
Generated from `tests/elm-fixtures/run-elm-gate.sh`; 196 checks.
