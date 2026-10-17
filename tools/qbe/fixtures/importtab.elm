module ImportTab exposing (main)

-- M4NICE item 1: THE TOKEN-RULE MIRROR PIN.
--
-- The reader's `import` scan is a COLUMN-0 LINE SCAN, so a line at column 0
-- inside a block comment (or a string literal) is a candidate.  The separator
-- after the keyword is the CORE's whitespace — space/`\r` only
-- (ParserFast.elm:2852 takes exactly space, `\n`, `\r`) — so the TAB below is
-- NOT an import separator, and no `.mid` may be resolved from it:
--
--   run.js          /^import[ \r]+([A-Z][A-Za-z0-9_.]*)/
--   NativeMain.elm  keywordName "import" 6   (the same rule, mirrored)
--
-- The old loose rules disagreed here (run.js matched `\s+`/any-token, the
-- native lane required a literal space then a not-space/tab charset): this
-- BOTH lines made run.js resolve Tabimp.mid and REFUSE a legal program
-- with
-- "declares module Othername", while the native lane compiled it.  The
-- program must COMPILE and print 7, in both lanes.
{- 
import	Tabimp
import 	Tabimp
-}

main =
    7
