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

**157 registered checks.** Run from the repo root, the gate prints
`PASS=157 FAIL=0` on the frozen artifact. `docs/research/osier-paper.md`
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
| `compile_clean` | `ok` | compilation must yield a real output, not an `err …` payload (no value check — the fixture's value cannot be driven from argv) |
| `compile_error` | `err` | compilation must emit `err <message>` containing `expected` |
| `out_cmp` | `cmp` | the raw file an earlier run wrote must equal its `expected/*.txt` bytes |
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
| 30 | `patterns` | `run` | `main` | `1151` | — | — | `patterns.elm` |
| 31 | `boolcase` | `run` | `main` | `0` | — | — | `boolcase.elm` |
| 32 | `records` | `run` | `main` | `40` | — | — | `records.elm` |
| 33 | `shortcircuit` | `run` | `main` | `1` | — | — | `shortcircuit.elm` |
| 34 | `biglist` | `run` | `main` | `2003000` | — | — | `biglist.elm` |
| 35 | `strings` | `run` | `main` | `"6:5:x, y, z"` | — | — | `strings.elm` |
| 36 | `multimod` | `run2` | `main` | `42` | — | — | `multimod.elm` |
| 37 | `floatlit` | `run` | `main` | `2.0` | — | — | `floatlit.elm` |
| 38 | `floatarith` | `run` | `main` | `4.0` | — | — | `floatarith.elm` |
| 39 | `floatdiv` | `run` | `main` | `3.5` | — | — | `floatdiv.elm` |
| 40 | `floatmix` | `run` | `main` | `3.5` | — | — | `floatmix.elm` |
| 41 | `floatcmp` | `run` | `main` | `true` | — | — | `floatcmp.elm` |
| 42 | `floatfun` | `run` | `area` | `12.0` | `2.0` | — | `floatfun.elm` |
| 43 | `floatpartial` | `run` | `main` | `3.5` | — | — | `floatpartial.elm` |
| 44 | `floatineq` | `run` | `main` | `true` | — | — | `floatineq.elm` |
| 45 | `mxint` | `run` | `main` | `175` | — | — | `mxint.elm` |
| 46 | `mxstring` | `run` | `main` | `"2:Ann, Bo\|Hi Ann!"` | — | — | `mxstring.elm` |
| 47 | `iofile` | `run_io` | `main` | `"echo:hello\n"` | — | `hello.txt` | `iofile.elm` |
| 48 | `iofile` | `out_cmp` | — | — | — | — | — |
| 49 | `ioecho` | `run_io` | `main` | `hello\nworld\n2` | — | `echo.txt` | `ioecho.elm` |
| 50 | `taskpure` | `run` | `main` | `42` | — | — | `taskpure.elm` |
| 51 | `taskseq` | `run` | `main` | `6` | — | — | `taskseq.elm` |
| 52 | `taskattempt` | `run` | `main` | `"boom"` | — | — | `taskattempt.elm` |
| 53 | `execpipe` | `run` | `main` | `"0\|ho\|"` | — | — | `execpipe.elm` |
| 54 | `execenv` | `run` | `main` | `"hello\|1\|/tmp"` | — | — | `execenv.elm` |
| 55 | `execglob` | `run` | `main` | `"execenv.txt,execglob.txt,execpipe.txt"` | — | — | `execglob.elm` |
| 56 | `asyncorder` | `run` | `main` | `"file,ran"` | — | — | `asyncorder.elm` |
| 57 | `fastexec` | `run` | `main` | `"0\|hi\n\|"` | — | — | `fastexec.elm` |
| 58 | `asyncpure` | `run` | `main` | `"abc"` | — | — | `asyncpure.elm` |
| 59 | `signaldeath` | `sigdeath` | `main` | `"137\|\|"` | — | — | `signaldeath.elm` |
| 60 | `signaldeathasync` | `sigdeath` | `main` | `"137\|\|"` | — | — | `signaldeathasync.elm` |
| 61 | `dup` | `compile_error` | — | `duplicate top-level definition in Dup: f` | — | — | `dup.elm` |
| 62 | `shadowerr` | `compile_error` | — | `is both a top-level definition and imported via` | — | — | `shadowerr.elm` |
| 63 | `shadowtyperr` | `compile_error` | — | `is both a top-level definition and imported via` | — | — | `shadowtyperr.elm` |
| 64 | `ambimperr` | `compile_error` | — | `from two different modules` | — | — | `ambimperr.elm` |
| 65 | `cmporder` | `run` | `main` | `"LT GT EQ LT EQ LT GT EQ LT EQ LT EQ GT LT EQ LT LT EQ"` | — | — | `cmporder.elm` |
| 66 | `resultmaybe` | `run` | `main` | `"42 7 12 N 1 0 7 N 123 O42 E 9 5 O42 E E4 77 N O8 E 1 0 O6"` | — | — | `resultmaybe.elm` |
| 67 | `dictbasic` | `run` | `main` | `-1956` | — | — | `dictbasic.elm` |
| 68 | `setops` | `run` | `main` | `168` | — | — | `setops.elm` |
| 69 | `dictstress` | `run` | `main` | `1533354` | — | — | `dictstress.elm` |
| 70 | `bitwise` | `run` | `main` | `446` | — | — | `bitwise.elm` |
| 71 | `arraybasic` | `run` | `main` | `20799` | — | — | `arraybasic.elm` |
| 72 | `arraystress` | `run` | `main` | `7947531` | — | — | `arraystress.elm` |
| 73 | `strunit` | `run` | `main` | `"1111111111111111111111111111111111111111111111111\|42.5\|2.0\|  一"` | — | — | `strunit.elm` |
| 74 | `p2pad` | `run` | `main` | `"11111111111111\|========================================\|    ab\|ab    "` | — | — | `p2pad.elm` |
| 75 | `nowunit` | `run` | `main` | `"now-ok order-ok"` | — | — | `nowunit.elm` |
| 76 | `dirunit` | `run` | `main` | `"alpha.txt,beta.txt,gamma/"` | — | — | `dirunit.elm` |
| 77 | `statunit` | `run` | `main` | `"s12-ok nd-ok reg-ok treg-ok mtime-ok s8-ok dir-ok nfile-ok tdir-ok miss-ok"` | — | — | `statunit.elm` |
| 78 | `statplus` | `run` | `main` | `"statplus-ok"` | — | — | `statplus.elm` |
| 79 | `rowpoly` | `run` | `main` | `34` | — | — | `rowpoly.elm` |
| 80 | `extrec` | `run` | `main` | `29` | — | — | `extrec.elm` |
| 81 | `insrec` | `run` | `main` | `105` | — | — | `insrec.elm` |
| 82 | `remrec` | `run` | `main` | `8` | — | — | `remrec.elm` |
| 83 | `rmprobe` | `run` | `main` | `6` | — | — | `rmprobe.elm` |
| 84 | `scopedup` | `run` | `main` | `17` | — | — | `scopedup.elm` |
| 85 | `recalias` | `run` | `main` | `33` | — | — | `recalias.elm` |
| 86 | `appendres` | `run` | `main` | `5` | — | — | `appendres.elm` |
| 87 | `tyerr_update_missing_field` | `compile_error` | — | `does not have field` | — | — | `tyerr_update_missing_field.elm` |
| 88 | `tyerr_ambiguous_append` | `compile_error` | — | `ambiguous` | — | — | `tyerr_ambiguous_append.elm` |
| 89 | `tyerr_numstr` | `compile_error` | — | `unify number with String` | — | — | `tyerr_numstr.elm` |
| 90 | `tyerr_arity` | `compile_error` | — | `apply non-function` | — | — | `tyerr_arity.elm` |
| 91 | `tyerr_remove_absent` | `compile_error` | — | `does not have field` | — | — | `tyerr_remove_absent.elm` |
| 92 | `rowgadt_select` | `compile_clean` | — | — | — | — | `rowgadt_select.elm` |
| 93 | `rowgadt_setx` | `compile_clean` | — | — | — | — | `rowgadt_setx.elm` |
| 94 | `rowgadt_absentfield` | `compile_error` | — | `is rigid` | — | — | `rowgadt_absentfield.elm` |
| 95 | `rowgadt_escape` | `compile_error` | — | `escaping row equation` | — | — | `rowgadt_escape.elm` |
| 96 | `rowgadt_eval` | `run` | `main` | `[cons 1 . true]` | — | — | `rowgadt_eval.elm` |
| 97 | `rowgadt_evalbad` | `compile_error` | — | `escaping row equation` | — | — | `rowgadt_evalbad.elm` |
| 98 | `rowgadt_het` | `run` | `main` | `"hi3"` | — | — | `rowgadt_het.elm` |
| 99 | `rowgadt_noescape` | `compile_error` | — | `is rigid` | — | — | `rowgadt_noescape.elm` |
| 100 | `rowgadt_l3i` | `run` | `main` | `"3"` | — | — | `rowgadt_l3i.elm` |
| 101 | `rowgadt_l3ii` | `compile_error` | — | `cannot unify {k:a\| b} with {\| a}` | — | — | `rowgadt_l3ii.elm` |
| 102 | `rowgadt_l3iii` | `run` | `main` | `1` | — | — | `rowgadt_l3iii.elm` |
| 103 | `rowgadt_hget` | `compile_clean` | — | — | — | — | `rowgadt_hget.elm` |
| 104 | `rowgadt_hget_bare` | `compile_clean` | — | — | — | — | `rowgadt_hget_bare.elm` |
| 105 | `rowgadt_hget_escape` | `compile_error` | — | `escaping row equation` | — | — | `rowgadt_hget_escape.elm` |
| 106 | `rowgadt_hget_badhead` | `compile_error` | — | `is rigid` | — | — | `rowgadt_hget_badhead.elm` |
| 107 | `rowgadt_escape_launder` | `compile_error` | — | `escaping row equation` | — | — | `rowgadt_escape_launder.elm` |
| 108 | `rowgadt_escape_wildcard` | `compile_error` | — | `escaping row equation` | — | — | `rowgadt_escape_wildcard.elm` |
| 109 | `rowgadt_ce1_prealias` | `compile_error` | — | `escaping row equation` | — | — | `rowgadt_ce1_prealias.elm` |
| 110 | `rowgadt_shape_rebuild` | `compile_clean` | — | — | — | — | `rowgadt_shape_rebuild.elm` |
| 111 | `rowgadt_dup_rebuild` | `compile_clean` | — | — | — | — | `rowgadt_dup_rebuild.elm` |
| 112 | `rowgadt_dup_fewer` | `compile_error` | — | `cannot unify a with {x:Int\|` | — | — | `rowgadt_dup_fewer.elm` |
| 113 | `rowgadt_fsm` | `run` | `main` | `"open:42"` | — | — | `rowgadt_fsm.elm` |
| 114 | `rowgadt_fsm_bad` | `compile_error` | — | `missing field closed` | — | — | `rowgadt_fsm_bad.elm` |
| 115 | `rowgadt_fsm_narrow` | `compile_error` | — | `cannot be unified with {broken:a\| b}` | — | — | `rowgadt_fsm_narrow.elm` |
| 116 | `rowgadt_fsm_nested` | `run` | `main` | `"open:42"` | — | — | `rowgadt_fsm_nested.elm` |
| 117 | `rowgadt_fsm_nested_bad` | `compile_error` | — | `cannot be unified with {broken:a\| b}` | — | — | `rowgadt_fsm_nested_bad.elm` |
| 118 | `adtgaps` | `compile_error` | — | `non-exhaustive case` | — | — | `adtgaps.elm` |
| 119 | `refutneg` | `compile_error` | — | `non-exhaustive case` | — | — | `refutneg.elm` |
| 120 | `refutpos` | `run` | `main` | `5` | — | — | `refutpos.elm` |
| 121 | `refutbare` | `compile_error` | — | `non-exhaustive case` | — | — | `refutbare.elm` |
| 122 | `rowgadt_ce2_barevar` | `compile_error` | — | `cannot unify Int with String` | — | — | `rowgadt_ce2_barevar.elm` |
| 123 | `rowgadt_ce2_plain` | `compile_error` | — | `cannot unify RowgadtCe2Plain.Expr with String` | — | — | `rowgadt_ce2_plain.elm` |
| 124 | `rowgadt_ce3_fieldalias` | `compile_error` | — | `type variable a is rigid` | — | — | `rowgadt_ce3_fieldalias.elm` |
| 125 | `rowgadt_ce3a_tuple` | `compile_error` | — | `infinite type` | — | — | `rowgadt_ce3a_tuple.elm` |
| 126 | `rowgadt_ce3b_prealias` | `compile_error` | — | `infinite type` | — | — | `rowgadt_ce3b_prealias.elm` |
| 127 | `rowgadt_ce3c_let` | `compile_error` | — | `infinite type` | — | — | `rowgadt_ce3c_let.elm` |
| 128 | `liftself` | `run` | `main` | `515` | — | — | `liftself.elm` |
| 129 | `liftmutual` | `run` | `main` | `42` | — | — | `liftmutual.elm` |
| 130 | `liftfirstclass` | `run` | `main` | `100` | — | — | `liftfirstclass.elm` |
| 131 | `liftshadow` | `run` | `main` | `13` | — | — | `liftshadow.elm` |
| 132 | `liftfwd` | `run` | `main` | `6` | — | — | `liftfwd.elm` |
| 133 | `liftfwdmix` | `run` | `main` | `11` | — | — | `liftfwdmix.elm` |
| 134 | `liftnested` | `run` | `main` | `1002` | — | — | `liftnested.elm` |
| 135 | `liftnestedtuple` | `run` | `main` | `1003` | — | — | `liftnestedtuple.elm` |
| 136 | `liftnestedfinal` | `run` | `main` | `1002` | — | — | `liftnestedfinal.elm` |
| 137 | `liftnestedrec` | `run` | `main` | `100` | — | — | `liftnestedrec.elm` |
| 138 | `liftdelegate` | `run` | `main` | `5` | — | — | `liftdelegate.elm` |
| 139 | `liftdelegmut` | `run` | `main` | `0` | — | — | `liftdelegmut.elm` |
| 140 | `liftprelude` | `run` | `main` | `7` | — | — | `liftprelude.elm` |
| 141 | `liftenclosing` | `run` | `main` | `100` | — | — | `liftenclosing.elm` |
| 142 | `liftseqcap` | `run` | `main` | `2` | — | — | `liftseqcap.elm` |
| 143 | `liftfwdback` | `run` | `main` | `6` | — | — | `liftfwdback.elm` |
| 144 | `liftcapconfl` | `run` | `main` | `51` | — | — | `liftcapconfl.elm` |
| 145 | `liftcapconfl2` | `run` | `main` | `51` | — | — | `liftcapconfl2.elm` |
| 146 | `liftmodfwd` | `run` | `main` | `999` | — | — | `liftmodfwd.elm` |
| 147 | `liftpreludefwd` | `run` | `main` | `2` | — | — | `liftpreludefwd.elm` |
| 148 | `liftprelfwdfn` | `run` | `main` | `1000` | — | — | `liftprelfwdfn.elm` |
| 149 | `liftstaycall` | `run` | `main` | `702` | — | — | `liftstaycall.elm` |
| 150 | `liftdisjoint` | `run` | `main` | `35` | — | — | `liftdisjoint.elm` |
| 151 | `liftvaluecycle` | `compile_error` | — | `unknown name: v` | — | — | `liftvaluecycle.elm` |
| 152 | `liftrefuse` | `compile_error` | — | `unknown name: a` | — | — | `liftrefuse.elm` |
| 153 | `liftstayfwd` | `run` | `main` | `999` | — | — | `liftstayfwd.elm` |
| 154 | `liftcycshadows` | `run` | `main` | `0` | — | — | `liftcycshadows.elm` |
| 155 | `liftrelaxleak` | `run` | `main` | `999` | — | — | `liftrelaxleak.elm` |
| 156 | `liftdisjointshadow` | `run` | `main` | `3` | — | — | `liftdisjointshadow.elm` |
| 157 | `natcalloverflow` | `natdepth` | `main` | `500500` | `1000 20000 100000` | — | `natcalloverflow.elm` |

---
Generated from `tests/elm-fixtures/run-elm-gate.sh`; 157 checks.
