module M exposing (main)

-- CONSTRUCTOR VALUES AND TAG TESTS ACROSS COLLECTIONS, ON THE WORD ARM (perf
-- word-arm-frontier).  The collecting oracle for the `Con`/`MTagEq` pair, and
-- the only row in the tree that holds a RUNTIME-BUILT VECTOR with a
-- runtime-built STRING payload inside it across thousands of scavenges.
--
-- WHAT IT PINS THAT NO OTHER ROW CAN.  A word-arm constructor value is one
-- code-10 block whose body is `[tag_symbol, arg_0 .. arg_{n-1}]` — the ctor tag
-- is a REAL Value (a code-2 symbol cell, `Rt.allocSym`) and the arguments are
-- INLINE body words the collector traces.  Three things can go wrong there and
-- every one of them needs a collection to show:
--   * the tag symbol cell (allocated by the emitter's `storeWordSymbolLiteral`
--     seat) reclaimed while the vector is being built — the vector's body word 0
--     would then name whatever reused the block, and the TAG TEST would answer
--     the wrong alternative rather than crash;
--   * the vector block itself reclaimed between `Rt.con`'s `allocKind` and its
--     `Rt.conFill` — the arguments land in a block the collector has handed out
--     twice;
--   * an argument string reclaimed because the staged argument block (a FRAME
--     region, passed to `Rt.con` as `mknum(cbase)`) was not rooted.
--
-- WHY THE CHECK IS A PATTERN MATCH *AND* A WHOLE-VALUE `==`.  The match is the
-- MTagEq path: `payload(body, 0)` (the tag symbol) compared through `Rt.=`'s
-- symbol arm, then the element binds through `fieldBase`/`IdxStep`.  The `==` is
-- `Rt.deepEq` over the code-10 body, so it walks every argument.  A defect in
-- either one prints a wrong number instead of dying, which is exactly the class
-- this row exists to catch — the val arm is the oracle, the expected count is
-- deliberately not spelled here.
--
-- OUTPUT is `examined/matched/mismatched`; expected 6000/6000/0 at every heap
-- size, on both arms.

type Payload
    = Loaded String Int
    | Blank


mk i =
    Loaded (String.fromInt i) i


buildAll i acc =
    if i == 0 then
        acc

    else
        buildAll (i - 1) (mk i :: acc)


check xs i examined matched mismatched =
    case xs of
        [] ->
            String.append (String.fromInt examined)
                (String.append "/"
                    (String.append (String.fromInt matched) (String.append "/" (String.fromInt mismatched)))
                )

        p :: rest ->
            case p of
                Loaded s n ->
                    if (s == String.fromInt i) && (n == i) then
                        if p == mk i then
                            check rest (i + 1) (examined + 1) (matched + 1) mismatched

                        else
                            check rest (i + 1) (examined + 1) matched (mismatched + 1)

                    else
                        check rest (i + 1) (examined + 1) matched (mismatched + 1)

                Blank ->
                    check rest (i + 1) (examined + 1) matched (mismatched + 1)


main =
    check (buildAll 6000 []) 1 0 0 0
