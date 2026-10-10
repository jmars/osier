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

**154 registered checks.** Run from the repo root, the gate prints
`PASS=154 FAIL=0` on the frozen artifact. `docs/research/osier-paper.md`
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
| 29 | `patterns` | `run` | `main` | `1151` | — | — | `patterns.elm` |
| 30 | `boolcase` | `run` | `main` | `0` | — | — | `boolcase.elm` |
| 31 | `records` | `run` | `main` | `40` | — | — | `records.elm` |
| 32 | `shortcircuit` | `run` | `main` | `1` | — | — | `shortcircuit.elm` |
| 33 | `biglist` | `run` | `main` | `2003000` | — | — | `biglist.elm` |
| 34 | `strings` | `run` | `main` | `"6:5:x, y, z"` | — | — | `strings.elm` |
| 35 | `multimod` | `run2` | `main` | `42` | — | — | `multimod.elm` |
| 36 | `floatlit` | `run` | `main` | `2.0` | — | — | `floatlit.elm` |
| 37 | `floatarith` | `run` | `main` | `4.0` | — | — | `floatarith.elm` |
| 38 | `floatdiv` | `run` | `main` | `3.5` | — | — | `floatdiv.elm` |
| 39 | `floatmix` | `run` | `main` | `3.5` | — | — | `floatmix.elm` |
| 40 | `floatcmp` | `run` | `main` | `true` | — | — | `floatcmp.elm` |
| 41 | `floatfun` | `run` | `area` | `12.0` | `2.0` | — | `floatfun.elm` |
| 42 | `floatpartial` | `run` | `main` | `3.5` | — | — | `floatpartial.elm` |
| 43 | `floatineq` | `run` | `main` | `true` | — | — | `floatineq.elm` |
| 44 | `mxint` | `run` | `main` | `175` | — | — | `mxint.elm` |
| 45 | `mxstring` | `run` | `main` | `"2:Ann, Bo\|Hi Ann!"` | — | — | `mxstring.elm` |
| 46 | `iofile` | `run_io` | `main` | `"echo:hello\n"` | — | `hello.txt` | `iofile.elm` |
| 47 | `iofile` | `out_cmp` | — | — | — | — | — |
| 48 | `ioecho` | `run_io` | `main` | `hello\nworld\n2` | — | `echo.txt` | `ioecho.elm` |
| 49 | `taskpure` | `run` | `main` | `42` | — | — | `taskpure.elm` |
| 50 | `taskseq` | `run` | `main` | `6` | — | — | `taskseq.elm` |
| 51 | `taskattempt` | `run` | `main` | `"boom"` | — | — | `taskattempt.elm` |
| 52 | `execpipe` | `run` | `main` | `"0\|ho\|"` | — | — | `execpipe.elm` |
| 53 | `execenv` | `run` | `main` | `"hello\|1\|/tmp"` | — | — | `execenv.elm` |
| 54 | `execglob` | `run` | `main` | `"execenv.txt,execglob.txt,execpipe.txt"` | — | — | `execglob.elm` |
| 55 | `asyncorder` | `run` | `main` | `"file,ran"` | — | — | `asyncorder.elm` |
| 56 | `fastexec` | `run` | `main` | `"0\|hi\n\|"` | — | — | `fastexec.elm` |
| 57 | `asyncpure` | `run` | `main` | `"abc"` | — | — | `asyncpure.elm` |
| 58 | `signaldeath` | `sigdeath` | `main` | `"137\|\|"` | — | — | `signaldeath.elm` |
| 59 | `signaldeathasync` | `sigdeath` | `main` | `"137\|\|"` | — | — | `signaldeathasync.elm` |
| 60 | `dup` | `compile_error` | — | `duplicate top-level definition in Dup: f` | — | — | `dup.elm` |
| 61 | `shadowerr` | `compile_error` | — | `is both a top-level definition and imported via` | — | — | `shadowerr.elm` |
| 62 | `shadowtyperr` | `compile_error` | — | `is both a top-level definition and imported via` | — | — | `shadowtyperr.elm` |
| 63 | `ambimperr` | `compile_error` | — | `from two different modules` | — | — | `ambimperr.elm` |
| 64 | `cmporder` | `run` | `main` | `"LT GT EQ LT EQ LT GT EQ LT EQ LT EQ GT LT EQ LT LT EQ"` | — | — | `cmporder.elm` |
| 65 | `resultmaybe` | `run` | `main` | `"42 7 12 N 1 0 7 N 123 O42 E 9 5 O42 E E4 77 N O8 E 1 0 O6"` | — | — | `resultmaybe.elm` |
| 66 | `dictbasic` | `run` | `main` | `-1956` | — | — | `dictbasic.elm` |
| 67 | `setops` | `run` | `main` | `168` | — | — | `setops.elm` |
| 68 | `dictstress` | `run` | `main` | `1533354` | — | — | `dictstress.elm` |
| 69 | `bitwise` | `run` | `main` | `446` | — | — | `bitwise.elm` |
| 70 | `arraybasic` | `run` | `main` | `20799` | — | — | `arraybasic.elm` |
| 71 | `arraystress` | `run` | `main` | `7947531` | — | — | `arraystress.elm` |
| 72 | `strunit` | `run` | `main` | `"1111111111111111111111111111111111111111111111111\|42.5\|2.0\|  一"` | — | — | `strunit.elm` |
| 73 | `p2pad` | `run` | `main` | `"11111111111111\|========================================\|    ab\|ab    "` | — | — | `p2pad.elm` |
| 74 | `nowunit` | `run` | `main` | `"now-ok order-ok"` | — | — | `nowunit.elm` |
| 75 | `dirunit` | `run` | `main` | `"alpha.txt,beta.txt,gamma/"` | — | — | `dirunit.elm` |
| 76 | `statunit` | `run` | `main` | `"s12-ok nd-ok reg-ok treg-ok mtime-ok s8-ok dir-ok nfile-ok tdir-ok miss-ok"` | — | — | `statunit.elm` |
| 77 | `rowpoly` | `run` | `main` | `34` | — | — | `rowpoly.elm` |
| 78 | `extrec` | `run` | `main` | `29` | — | — | `extrec.elm` |
| 79 | `insrec` | `run` | `main` | `105` | — | — | `insrec.elm` |
| 80 | `remrec` | `run` | `main` | `8` | — | — | `remrec.elm` |
| 81 | `scopedup` | `run` | `main` | `17` | — | — | `scopedup.elm` |
| 82 | `recalias` | `run` | `main` | `33` | — | — | `recalias.elm` |
| 83 | `appendres` | `run` | `main` | `5` | — | — | `appendres.elm` |
| 84 | `tyerr_update_missing_field` | `compile_error` | — | `does not have field` | — | — | `tyerr_update_missing_field.elm` |
| 85 | `tyerr_ambiguous_append` | `compile_error` | — | `ambiguous` | — | — | `tyerr_ambiguous_append.elm` |
| 86 | `tyerr_numstr` | `compile_error` | — | `unify number with String` | — | — | `tyerr_numstr.elm` |
| 87 | `tyerr_arity` | `compile_error` | — | `apply non-function` | — | — | `tyerr_arity.elm` |
| 88 | `tyerr_remove_absent` | `compile_error` | — | `does not have field` | — | — | `tyerr_remove_absent.elm` |
| 89 | `rowgadt_select` | `compile_clean` | — | — | — | — | `rowgadt_select.elm` |
| 90 | `rowgadt_setx` | `compile_clean` | — | — | — | — | `rowgadt_setx.elm` |
| 91 | `rowgadt_absentfield` | `compile_error` | — | `is rigid` | — | — | `rowgadt_absentfield.elm` |
| 92 | `rowgadt_escape` | `compile_error` | — | `escaping row equation` | — | — | `rowgadt_escape.elm` |
| 93 | `rowgadt_eval` | `run` | `main` | `[cons 1 . true]` | — | — | `rowgadt_eval.elm` |
| 94 | `rowgadt_evalbad` | `compile_error` | — | `escaping row equation` | — | — | `rowgadt_evalbad.elm` |
| 95 | `rowgadt_het` | `run` | `main` | `"hi3"` | — | — | `rowgadt_het.elm` |
| 96 | `rowgadt_noescape` | `compile_error` | — | `is rigid` | — | — | `rowgadt_noescape.elm` |
| 97 | `rowgadt_l3i` | `run` | `main` | `"3"` | — | — | `rowgadt_l3i.elm` |
| 98 | `rowgadt_l3ii` | `compile_error` | — | `cannot unify {k:a\| b} with {\| a}` | — | — | `rowgadt_l3ii.elm` |
| 99 | `rowgadt_l3iii` | `run` | `main` | `1` | — | — | `rowgadt_l3iii.elm` |
| 100 | `rowgadt_hget` | `compile_clean` | — | — | — | — | `rowgadt_hget.elm` |
| 101 | `rowgadt_hget_bare` | `compile_clean` | — | — | — | — | `rowgadt_hget_bare.elm` |
| 102 | `rowgadt_hget_escape` | `compile_error` | — | `escaping row equation` | — | — | `rowgadt_hget_escape.elm` |
| 103 | `rowgadt_hget_badhead` | `compile_error` | — | `is rigid` | — | — | `rowgadt_hget_badhead.elm` |
| 104 | `rowgadt_escape_launder` | `compile_error` | — | `escaping row equation` | — | — | `rowgadt_escape_launder.elm` |
| 105 | `rowgadt_escape_wildcard` | `compile_error` | — | `escaping row equation` | — | — | `rowgadt_escape_wildcard.elm` |
| 106 | `rowgadt_ce1_prealias` | `compile_error` | — | `escaping row equation` | — | — | `rowgadt_ce1_prealias.elm` |
| 107 | `rowgadt_shape_rebuild` | `compile_clean` | — | — | — | — | `rowgadt_shape_rebuild.elm` |
| 108 | `rowgadt_dup_rebuild` | `compile_clean` | — | — | — | — | `rowgadt_dup_rebuild.elm` |
| 109 | `rowgadt_dup_fewer` | `compile_error` | — | `cannot unify a with {x:Int\|` | — | — | `rowgadt_dup_fewer.elm` |
| 110 | `rowgadt_fsm` | `run` | `main` | `"open:42"` | — | — | `rowgadt_fsm.elm` |
| 111 | `rowgadt_fsm_bad` | `compile_error` | — | `missing field closed` | — | — | `rowgadt_fsm_bad.elm` |
| 112 | `rowgadt_fsm_narrow` | `compile_error` | — | `cannot be unified with {broken:a\| b}` | — | — | `rowgadt_fsm_narrow.elm` |
| 113 | `rowgadt_fsm_nested` | `run` | `main` | `"open:42"` | — | — | `rowgadt_fsm_nested.elm` |
| 114 | `rowgadt_fsm_nested_bad` | `compile_error` | — | `cannot be unified with {broken:a\| b}` | — | — | `rowgadt_fsm_nested_bad.elm` |
| 115 | `adtgaps` | `compile_error` | — | `non-exhaustive case` | — | — | `adtgaps.elm` |
| 116 | `refutneg` | `compile_error` | — | `non-exhaustive case` | — | — | `refutneg.elm` |
| 117 | `refutpos` | `run` | `main` | `5` | — | — | `refutpos.elm` |
| 118 | `refutbare` | `compile_error` | — | `non-exhaustive case` | — | — | `refutbare.elm` |
| 119 | `rowgadt_ce2_barevar` | `compile_error` | — | `cannot unify Int with String` | — | — | `rowgadt_ce2_barevar.elm` |
| 120 | `rowgadt_ce2_plain` | `compile_error` | — | `cannot unify RowgadtCe2Plain.Expr with String` | — | — | `rowgadt_ce2_plain.elm` |
| 121 | `rowgadt_ce3_fieldalias` | `compile_error` | — | `type variable a is rigid` | — | — | `rowgadt_ce3_fieldalias.elm` |
| 122 | `rowgadt_ce3a_tuple` | `compile_error` | — | `infinite type` | — | — | `rowgadt_ce3a_tuple.elm` |
| 123 | `rowgadt_ce3b_prealias` | `compile_error` | — | `infinite type` | — | — | `rowgadt_ce3b_prealias.elm` |
| 124 | `rowgadt_ce3c_let` | `compile_error` | — | `infinite type` | — | — | `rowgadt_ce3c_let.elm` |
| 125 | `liftself` | `run` | `main` | `515` | — | — | `liftself.elm` |
| 126 | `liftmutual` | `run` | `main` | `42` | — | — | `liftmutual.elm` |
| 127 | `liftfirstclass` | `run` | `main` | `100` | — | — | `liftfirstclass.elm` |
| 128 | `liftshadow` | `run` | `main` | `13` | — | — | `liftshadow.elm` |
| 129 | `liftfwd` | `run` | `main` | `6` | — | — | `liftfwd.elm` |
| 130 | `liftfwdmix` | `run` | `main` | `11` | — | — | `liftfwdmix.elm` |
| 131 | `liftnested` | `run` | `main` | `1002` | — | — | `liftnested.elm` |
| 132 | `liftnestedtuple` | `run` | `main` | `1003` | — | — | `liftnestedtuple.elm` |
| 133 | `liftnestedfinal` | `run` | `main` | `1002` | — | — | `liftnestedfinal.elm` |
| 134 | `liftnestedrec` | `run` | `main` | `100` | — | — | `liftnestedrec.elm` |
| 135 | `liftdelegate` | `run` | `main` | `5` | — | — | `liftdelegate.elm` |
| 136 | `liftdelegmut` | `run` | `main` | `0` | — | — | `liftdelegmut.elm` |
| 137 | `liftprelude` | `run` | `main` | `7` | — | — | `liftprelude.elm` |
| 138 | `liftenclosing` | `run` | `main` | `100` | — | — | `liftenclosing.elm` |
| 139 | `liftseqcap` | `run` | `main` | `2` | — | — | `liftseqcap.elm` |
| 140 | `liftfwdback` | `run` | `main` | `6` | — | — | `liftfwdback.elm` |
| 141 | `liftcapconfl` | `run` | `main` | `51` | — | — | `liftcapconfl.elm` |
| 142 | `liftcapconfl2` | `run` | `main` | `51` | — | — | `liftcapconfl2.elm` |
| 143 | `liftmodfwd` | `run` | `main` | `999` | — | — | `liftmodfwd.elm` |
| 144 | `liftpreludefwd` | `run` | `main` | `2` | — | — | `liftpreludefwd.elm` |
| 145 | `liftprelfwdfn` | `run` | `main` | `1000` | — | — | `liftprelfwdfn.elm` |
| 146 | `liftstaycall` | `run` | `main` | `702` | — | — | `liftstaycall.elm` |
| 147 | `liftdisjoint` | `run` | `main` | `35` | — | — | `liftdisjoint.elm` |
| 148 | `liftvaluecycle` | `compile_error` | — | `unknown name: v` | — | — | `liftvaluecycle.elm` |
| 149 | `liftrefuse` | `compile_error` | — | `unknown name: a` | — | — | `liftrefuse.elm` |
| 150 | `liftstayfwd` | `run` | `main` | `999` | — | — | `liftstayfwd.elm` |
| 151 | `liftcycshadows` | `run` | `main` | `0` | — | — | `liftcycshadows.elm` |
| 152 | `liftrelaxleak` | `run` | `main` | `999` | — | — | `liftrelaxleak.elm` |
| 153 | `liftdisjointshadow` | `run` | `main` | `3` | — | — | `liftdisjointshadow.elm` |
| 154 | `natcalloverflow` | `natdepth` | `main` | `500500` | `1000 20000 100000` | — | `natcalloverflow.elm` |

---
Generated from `tests/elm-fixtures/run-elm-gate.sh`; 154 checks.
