module FfimMain exposing (main)

-- cffi U6 — the DRIVER for the width-typed-memory oracle.  Every load-bearing
-- line is in ffim-mem.mid; this module calls each arm and hands the numbers to
-- the runtime's printer as a LIST, so the golden is one line of MEASURED
-- numbers and a single wrong byte shows up as a different digit in a different
-- position.
--
-- What each element pins (see ffim-mem.mid's header for the header values and
-- the C measurements they came from):
--
--   9007203549808287  struct pollfd after poll(): fd=99999@0, events=1@4,
--                     revents=32@6 read back as ONE 8-byte word — the kernel
--                     wrote bytes 6..7, so no self-consistent wrong offset can
--                     produce it
--   14                poll() on a pipe's WRITE end with events=POLLOUT(4):
--                     revents(4) + 10*poll(1) — only reachable if the kernel
--                     READ our events store at byte 4
--   1122              struct timespec: tv_sec(11)@0, tv_nsec(22)@8
--   8589934593        struct stat word 3 = uid(2)<<32 | mode(1), so mode@24 and uid@28
--   17179869187       struct stat word 4 = pad0(4)<<32 | gid(3), so gid@32 and pad0@36
--   5                 struct stat word 5 = rdev@40 (the 8-byte alignment bump
--                     past pad0 — a no-padding rule lands rdev at 36)
--   48                struct stat word 6 = size@48
--   64                struct stat word 8 = blocks@64
--   -1                 i8  field 0xFF  read with loadsb  (loadub would give 255)
--   -2                 i16 field 0xFFFE read with loadsh (loaduh would give 65534)
--   -3                 i32 field 0xFFFFFFFD read with loadw (loaduw: 4294967293)
--   65535              u16 field read with loaduh
--   4294967295         u32 field read with loaduw
--   200                a u8 at byte 1 survived its i8 neighbour's store — a
--                     word-wide store for the 1-byte field would leave 255
main =
    [ FfimMem.pollfd 0
    , FfimMem.mask 0
    , FfimMem.ts 0
    , FfimMem.statW3 0
    , FfimMem.statW4 0
    , FfimMem.statW5 0
    , FfimMem.statW6 0
    , FfimMem.statW8 0
    , FfimMem.sign8 0
    , FfimMem.sign16 0
    , FfimMem.sign32 0
    , FfimMem.usign16 0
    , FfimMem.usign32 0
    , FfimMem.padByte 0
    ]
