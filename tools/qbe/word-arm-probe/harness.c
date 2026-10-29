/* harness.c — RUN the word arm's emitted heap code, and GATE on it.
 *
 * WHY THIS IS IN THE TREE (perf VR3b3 FIX F2).  Under QBE_VALREP=word no
 * program compiled through run.js can run: the runtime is always injected, so
 * the emitted set always reaches Rt.main and the runtime's first call stops the
 * arm at AREA 6.  That leaves the emitter's heap side — tag writes, payload
 * reads, kind tests, the string cell — with NO executable oracle on the arm it
 * targets, and text pins cannot replace one: on this arm a text pin asserts the
 * SHAPE THE AUTHOR WROTE, so it cannot see a wrong shape one instruction away.
 * MEASURED: five such bugs shipped past every pin in VR3b3's first commit, and
 * a sixth (a boolean tagis fold) past the second.  This file is the instrument
 * that caught all six; it must keep running.
 *
 * WHAT IS REAL AND WHAT IS STUBBED.  Real: the module `node run.js` emits for
 * QBE_WORDARM_PROBE=<name> (the SAME Mid.Qbe.WordArmProbe defun TestMain pins),
 * vendor/qbe, cc, and every assertion about what the code DID.  Stubbed: the
 * four runtime seats the probe module calls —
 *
 *   Rt.frame-enter / frame-leave  a pooled frame: VR3c twinned it to
 *                                 `8 * nslots`, zeroed — the stub does that.
 *   Rt.allocRaw                   THE CONTRACT runtime.mid STATES (Blocker 1,
 *                                 and perf word-arm-rawroot item 1 for the
 *                                 return): a word-arm byte buffer IS a string
 *                                 cell whose bytes are INLINE, so the seat
 *                                 reserves `2 + ceil(bytes/8)` body words with
 *                                 the 2-word header `heapHeaderBytes` BEFORE
 *                                 the body, writes body unit 0 = the cell's own
 *                                 byte base, and returns `mknum(body + 2
 *                                 units)` — the BYTE BASE, which is what every
 *                                 `allocraw(...)` caller fills and what `mkstr`
 *                                 turns into the value word.  The first stub
 *                                 returned a calloc BASE with the header at +0
 *                                 — the EMITTER's side of the contract — which
 *                                 made the probe measure emitter-internal
 *                                 consistency instead of agreement with the
 *                                 runtime.  That is exactly why it passed the
 *                                 bugs it should have caught.
 *   Rt.die                        records the message and sets a flag.
 *
 * THE ABI IS READ FROM Mid/RtLayout, NOT GUESSED — and since AREA 6 there is
 * one answer on both arms: a probe defun takes its value parameters as `l`
 * REGISTERS (on the word arm the register IS the one-word Value; on the value
 * arm it is a pointer to the caller's 40-byte slot) and returns `:val`.  At 8
 * bytes `:val` is REGISTER class, so the return arrives in %rax as the word
 * itself — no sret block, no `:ret` kind word.  MEASURED (probe agg8.ssa): an
 * 8-byte aggregate return puts the VALUE in the register, and `ret %s0` still
 * means "the value AT %s0".
 *
 * ONE MODULE PER BINARY: every emitted module exports the same preamble
 * (qbe_meta, rt_glob, rt_call0..16), so two cannot be linked together.  The
 * runner builds one binary per probe and gates on each EXIT CODE: a wrong
 * offset fails as SIGSEGV/SIGABRT (139/134) with no FAIL line, so the exit
 * status is part of the assertion, not a convenience.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <signal.h>
#include <setjmp.h>

/* ---- Mid.RtLayout's numbers, spelled once here ---- */
#define HEAP_HEADER_BYTES 16
#define HEAP_PTR_TAG 1
#define UNTAG_MASK (-8L)

struct Val { int64_t w; };

/* ---- the seats the emitted module calls (stubs, per runtime.mid's contract) ---- */
static long *g_frame;
long *q_Rt_x2eframe_x2denter(long nslots)
{
    size_t n = (size_t)nslots * 8;
    g_frame = calloc(1, n + 64);
    return g_frame;
}
void q_Rt_x2eframe_x2dleave(void) { }

/* AREA 4 (perf word-arm-area4): THE BOXING SEAT, STUBBED AS A CONTROL.
 *
 * The emitter's fixnum writer now branches on a round trip (`w << 3 >> 3 == w`)
 * and calls `Rt.boxInt` when the word does not fit i61 — so every probe whose
 * defun closes with a DYNAMIC `mknum` (veclen's `mknum(veclen(v))`, rec's
 * `mknum(veclen(rec) - 1)`, str's) references the seat and the module would not
 * LINK without a definition here.  It is defined UNCONDITIONALLY, outside the
 * PROBE_* blocks, for exactly that reason.
 *
 * IT MUST NEVER BE REACHED, and that is an assertion rather than a hope: every
 * value these probes box is a COUNT (2, 3, 4), which fits i61 with room to
 * spare, so the round trip HOLDS and the fixnum branch is taken.  A stub that
 * answered a plausible value would hide a regression that started boxing them —
 * a `mknum` of a length is exactly the case that must stay inline — so this one
 * says so and exits.  Same discipline as the frame stubs: it exists so the probe
 * can LINK, and it is loud so it cannot silently become part of the answer.
 *
 * THE RETURN SHAPE is `:val` = `align 8 { l }`: one eightbyte, INTEGER class, so
 * SysV returns it in RAX and this C `struct Val` matches QBE's own lowering. */
struct Val q_Rt_x2eboxInt(long n)
{
    fflush(stdout);
    fprintf(stderr,
            "word-arm-probe: Rt.boxInt REACHED with %ld - the probe's word must fit i61, so the ROUND-TRIP CHECK is boxing a count (a regression)\n",
            n);
    exit(1);
}

/* The last block the seat handed out, and its BODY address — the harness
 * compares the emitter's untagged value against this, which is the one
 * NON-VACUOUS check of the seat convention (the emitter never writes a header,
 * so asserting header bits here would only assert this stub). */
static long *g_last_body;

struct Val q_Rt_x2eallocRaw(long *a, long *b, long *c, int n)
{
    (void)b; (void)c; (void)n;
    /* the lean ABI passes POINTERS to Value slots plus an arity word, so the
     * byte count is `payload(a[0], 0)`: a fixnum, i.e. the word shifted down. */
    long nbytes = a[0] >> 3;
    long byte_words = (nbytes + 7) / 8;
    /* THE CELL'S TWO UNITS ARE RESERVED WITH THE BYTES (perf word-arm-rawroot
     * item 1): a word-arm byte buffer IS a string cell whose bytes are inline,
     * so the count is `2 + ceil(bytes/8)` and the seat returns the BYTE BASE
     * (body + 2 units), not the body.  `mkstr` allocates nothing and tags the
     * block the caller filled; unit 0 is the cell's own byte base, which the
     * real collector re-derives on promotion. */
    long body_words = 2 + byte_words;
    long *base = calloc(1, (size_t)(2 + body_words) * 8);
    long *body = base + 2;                    /* header is 2 words BEFORE it */
    /* the header word 0 the allocator writes: class 512, code 1, scan 0 */
    base[0] = (long)((512L * 4L) + (1L << 24));
    base[1] = body_words;
    body[0] = (long)(uintptr_t)(body + 2);    /* unit 0 = the cell's own bytes */
    body[1] = 0;                              /* the length: the caller writes it */
    g_last_body = body;
    struct Val v;
    v.w = (int64_t)((uintptr_t)(body + 2)) << 3;   /* mknum(BYTE BASE) */
    return v;
}

#if defined(PROBE_SYM)
/* THE SYMBOL SEAT'S STUB, to the contract `runtime.mid` states: `Rt.allocSym`
 * passes the BODY WORD COUNT, and `gcAlloc` writes the 2-word header INCLUDING
 * the KIND CODE (2 = symbol) plus the scan bit `kindHdr` derives from it, then
 * returns `mknum(body)`.  The header is written here from the SAME rule the
 * runtime states, because the check below READS it: a cell allocated with the
 * wrong code is indistinguishable from a string to `tagis(v, 2)`, which is the
 * whole hazard this probe exists to see. */
struct Val q_Rt_x2eallocSym(long *a, long *b, long *c, int n)
{
    (void)b; (void)c; (void)n;
    long body_words = a[0] >> 3;              /* payload(count, 0) */
    long *base = calloc(1, (size_t)(2 + body_words) * 8);
    long *body = base + 2;
    base[0] = (long)((512L * 4L) + (0L << 1) + (2L << 24));  /* class, scan 0, code 2 */
    base[1] = body_words;
    g_last_body = body;
    struct Val v;
    v.w = (int64_t)((uintptr_t)body) << 3;    /* mknum(body) */
    return v;
}
#endif

#if defined(PROBE_REC)
/* THE RECORD SEAT'S STUB, to the contract `runtime.mid` states: `Rt.allocRecord`
 * takes the DATA field count and allocates `count + 1` body words (the names
 * word is the last one), with the KIND CODE 14 and — because `heapKindScanned 14`
 * — the scan bit SET, so the collector traces the body.  The `+ 1` is asserted
 * below through the header's count word: a seat that allocated `count` words
 * would make the names store land one word past the block. */
struct Val q_Rt_x2eallocRecord(long *a, long *b, long *c, int n)
{
    (void)b; (void)c; (void)n;
    long body_words = (a[0] >> 3) + 1;
    long *base = calloc(1, (size_t)(2 + body_words) * 8);
    long *body = base + 2;
    base[0] = (long)((512L * 4L) + (1L << 1) + (14L << 24));  /* class, SCAN 1, code 14 */
    base[1] = body_words;
    g_last_body = body;
    struct Val v;
    v.w = (int64_t)((uintptr_t)body) << 3;    /* mknum(body) */
    return v;
}

/* `Rt.vecStorePlain(vec, i, val)` — the word arm's ONE-WORD element store at
 * `vec + i * 8`, `val` being the ADDRESS of the value's slot. */
long q_Rt_x2evecStorePlain(long vec, long i, long *val)
{
    ((long *)(uintptr_t)vec)[i] = val[0];
    return 0;
}
#endif

static int g_died;
static char g_die_msg[512];
long q_Rt_x2edie(const char *msg)
{
    g_died = 1;
    snprintf(g_die_msg, sizeof g_die_msg, "%s", msg);
    return 0;
}

/* The refusal path ends in QBE `hlt`, which the assembler spells `ud2` — an
 * EXPECTED death arrives as SIGILL.  Catch it and carry on: a refusal that
 * cannot be observed is not a test.  SIGSEGV/SIGABRT are NOT caught: those are
 * real failures and the runner gates on the exit code. */
static sigjmp_buf g_jb;
static void on_ill(int sig) { (void)sig; siglongjmp(g_jb, 1); }

static int g_fail;
static int g_checks;
static void ok(int cond, const char *what)
{
    g_checks++;
    printf("%s %s\n", cond ? "PASS" : "FAIL", what);
    if (!cond) g_fail = 1;
}
static long *mk_block(int code, int scan, long w0, long w1)
{
    long *base = calloc(1, 4 * 8);
    base[0] = (long)((512L * 4L) + ((long)scan << 1) + ((long)code << 24));
    base[1] = 2;
    base[2] = w0;
    base[3] = w1;
    return base;
}
/* a block with THREE body words — what the vector probe needs (a code-10 block
 * whose body IS its elements, so index 1 and 2 measure the STRIDE as well as
 * the base).  The header's word 1 is the COUNT, which is where a word-arm
 * vector's length lives. */
static long *mk_block3(int code, int scan, long w0, long w1, long w2)
{
    long *base = calloc(1, 5 * 8);
    base[0] = (long)((512L * 4L) + ((long)scan << 1) + ((long)code << 24));
    base[1] = 3;
    base[2] = w0;
    base[3] = w1;
    base[4] = w2;
    return base;
}
/* the tagged Value word for a block whose BODY is base+2 */
static long tagged(long *base) { return (long)((uintptr_t)(base + 2)) | HEAP_PTR_TAG; }
static long *body_of(long *base) { return base + 2; }

/* THE AREA 6 ABI: one `l` in, one `l` out.  A probe defun is a surface defun
 * under the word arm, so its parameter IS the value word and its `:val` result
 * IS the returned word (8 bytes = register class). */
#if defined(PROBE_STR)
long q_St_x2ef(long x);
#elif defined(PROBE_PAY)
long q_Pl_x2ef(long x);
#elif defined(PROBE_LEN)
long q_Ln_x2ef(long x);
#elif defined(PROBE_TAGHEAP)
long q_Tg_x2ef(long v);
#elif defined(PROBE_TAGNIL)
long q_Nt_x2ef(long v);
#elif defined(PROBE_TAGBOOL)
long q_Bt_x2ef(long v);
#elif defined(PROBE_CALL)
long q_Ca_x2ef(long v);
#elif defined(PROBE_VEC)
long q_Vc_x2ef(long v, long i);
#elif defined(PROBE_VECLEN)
long q_Vl_x2ef(long v);
#elif defined(PROBE_SYM)
long q_Sy_x2ef(long x);           /* the entry: returns the emitted symbol cell */
long q_Sy_x2eg(long v);           /* mkbool(tagis(v, tagSymbol)) — the READER */
#elif defined(PROBE_REC)
long q_Rc_x2ef(long v, long i);   /* the entry: evaluates every read */
long q_Rc_x2en(long v);           /* mknum(veclen(v) - 1)      — reclen      */
long q_Rc_x2ee(long v, long i);   /* vecload(vecbody(v), i)    — data[i]     */
long q_Rc_x2eb(long v);           /* mknum(wload(body, n))     — namesBase   */
long q_Rc_x2ek(long v, long i);   /* mknum(wload(namesBase, i)) — name_i     */
long q_Rc_x2el(long x);           /* { x = 1, y = "hi" } BUILT by the emitter */
#endif

#if defined(PROBE_REC)
/* THE PRINTER'S FORMAT, re-spelled for the ONE block shape this probe builds.
 * `Rt.pvRec` walks `i < reclen` calling `pvV` per element between `[record`
 * and `]`; `pvV` renders a fixnum through `numText` (decimal) and a string as
 * `"` bytes `"`.  Both formats are copied EXACTLY, because the check below is a
 * BYTE comparison against the val arm's own render — the printer itself cannot
 * run in a probe module (it needs the byte-stream seat and numText).  A tag
 * this probe does not build renders as `<?>`, which then FAILS the comparison
 * loudly rather than passing something unrecognisable.
 */
static int render_elem(char *out, size_t cap, long w)
{
    if ((w & 7) == 0) {                     /* a fixnum: numText's decimal */
        return snprintf(out, cap, "%ld", w >> 3);
    }
    if ((w & 7) == HEAP_PTR_TAG) {
        long *body = (long *)(uintptr_t)(w & UNTAG_MASK);
        long code = (body[-2] >> 24) & 15;  /* header word 0's KIND CODE */
        if (code == 1) {                    /* a raw body: bytes, then length */
            const char *bytes = (const char *)(uintptr_t)body[0];
            long len = body[1];
            return snprintf(out, cap, "\"%.*s\"", (int)len, bytes);
        }
    }
    return snprintf(out, cap, "<?>");
}
#endif

int main(void)
{
    signal(SIGILL, on_ill);

#if defined(PROBE_STR)
    /* ===== AREA A + D: the string literal's cell, against the REAL seat convention ===== */
    {
        long x = 0;
        long w = q_St_x2ef(x);
        ok((w & 7) == HEAP_PTR_TAG,
           "A: a word-arm string literal is ONE tagged heap pointer (...001)");
        /* THE SEAT CONVENTION: the untagged value must be the BODY the seat
         * returned, not a block base.
         *
         * WHAT THIS ROW CAN AND CANNOT CATCH (measured by the VR3b3
         * re-review, which grafted this probe onto the PRE-FIX emitter).  The
         * probe as a whole fails there — 5 of 6 probes — but NOT through this
         * assertion: on the paired-error emitter the old `+16` (consuming the
         * seat's return) and the old `-16` (building the value word) CANCEL,
         * so the stored word is still `body|1` and this check PASSES.  The
         * load-bearing probes are the OTHER FIVE (str/payload/len/tagheap/
         * tagbool), which fail on the out-of-bounds body writes, the wrong
         * body word and the boolean fold.  This row catches the HALF-fixed
         * state a later author can produce (a writer that keeps `-16` while
         * the seat path drops `+16`, or the reverse) — a cancelling pair of
         * errors looks exactly like a passing check, so do NOT treat the five
         * behavioural probes as redundant with this arithmetic identity. */
        ok((long *)(uintptr_t)(w & UNTAG_MASK) == g_last_body,
           "A/SEAT: the untagged value word IS the body address the seat returned (header 16 B before it)");
        long *body = g_last_body;
        ok(strcmp((char *)body[0], "hi") == 0,
           "A: body unit 0 is the static byte pointer");
        ok(body[1] == 2,
           "D: body unit lenFieldWord (1) is the LENGTH (2)");
        /* AREA 6: the defun returns `:val` at 8 bytes, so there IS no `:ret`
         * kind word to be untouched — the old row here asserted one, and the
         * type it belonged to is deleted (the value arm's row is the same
         * absence).  The load-bearing checks above are unchanged. */
    }
#elif defined(PROBE_PAY)
    /* ===== AREA B: payload reads, all three shapes ===== */
    {
        long fix = 5L << 3;
        ok(q_Pl_x2ef(fix) == (5L << 3), "B: payload(fixnum 5, 0) == 5, re-boxed as mknum(5)");

        long *base = mk_block(4, 1, 0xDEAD, 0xBEEF);
        long cell = tagged(base);
        ok(q_Pl_x2ef(cell) == (0xDEADL << 3), "B: payload(heap cons, 0) == body unit 0 (untag is the body)");

        /* NIL IS ZERO, NOT A REFUSAL (perf word-arm-area3rt).  The val arm's
         * `payload(nil, 0)` reads an UNWRITTEN payload word — the slot is
         * zeroed at frame entry and `mknil` writes only the tag — so the
         * faithful word-arm answer is 0.  Runtime sites lean on it
         * (`Rt.main`'s `payload(prc, 0) != 0`), and MEASURED: refusing here made
         * `main = 7` die at that read.
         *
         * ERROR still refuses, and that is the half of the row that keeps it
         * fail-able: a val-arm error's payload word 0 is a REAL message pointer,
         * so a word-arm immediate has no equivalent read and must not invent
         * one. */
        long nil = 2;
        ok(q_Pl_x2ef(nil) == 0, "B: payload(nil, 0) == 0 (the val arm's unwritten payload word, ported)");

        g_died = 0;
        long err = 5; /* ...101, the error immediate */
        if (sigsetjmp(g_jb, 1) == 0) {
            (void)q_Pl_x2ef(err);
            ok(0, "B: payload(error, 0) must REFUSE - it returned instead");
        }
        ok(g_died == 1 && strstr(g_die_msg, "neither a fixnum") != NULL,
           "B: payload(error, 0) REFUSES and names the reason (its payload word 0 is a real pointer on the val arm)");
    }
#elif defined(PROBE_LEN)
    /* ===== AREA D: the length is body unit lenFieldWord ===== */
    {
        long *base = mk_block(1, 0, 0, 0);
        ((long *)body_of(base))[0] = (long)(uintptr_t)"abcdef";
        ((long *)body_of(base))[1] = 6;
        long cell = tagged(base);
        ok(q_Ln_x2ef(cell) == (6L << 3), "D: payload32(str, lenFieldWord) == 6, re-boxed as mknum(6)");

        long fix = 9L << 3;
        g_died = 0;
        if (sigsetjmp(g_jb, 1) == 0) {
            (void)q_Ln_x2ef(fix);
            ok(0, "D: payload32(fixnum, 1) must REFUSE - a fixnum has no body unit 1");
        }
        ok(g_died == 1, "D: payload32(fixnum, 1) REFUSES (no body unit 1 of a number)");
    }
#elif defined(PROBE_TAGHEAP)
    /* ===== AREA C: tagis on a heap object ===== */
    {
        long *cons = mk_block(4, 1, 0, 0);
        long c = tagged(cons);
        ok(q_Tg_x2ef(c) == 3, "C: tagis(cons, 4) is TRUE (immediate ...011)");

        long *vec = mk_block(10, 1, 0, 0);
        long v = tagged(vec);
        ok(q_Tg_x2ef(v) == 4, "C: tagis(vector, 4) is FALSE (immediate ...100) - the CODE was read, not the tag");

        long fix = 7L << 3;
        g_died = 0;
        ok(g_died == 0 && q_Tg_x2ef(fix) == 4,
           "C: tagis(fixnum, 4) is FALSE and reads NO header (untagging a fixnum is a small int - an unconditional load would fault)");

        long *nocode = mk_block(0, 0, 0, 0);
        long n = tagged(nocode);
        g_died = 0;
        if (sigsetjmp(g_jb, 1) == 0) {
            (void)q_Tg_x2ef(n);
            ok(0, "C: a code-0 header must REFUSE - it returned instead");
        }
        ok(g_died == 1,
           "C: a header whose KIND CODE is 0 REFUSES BY NAME (code 0 means NO CODE - a val-arm header)");
        ok(strstr(g_die_msg, "KIND CODE 0") != NULL, "C: the code-0 refusal says what it is");
    }
#elif defined(PROBE_TAGNIL)
    /* ===== AREA C: the VALTAG vs the WORD IMMEDIATE ===== */
    {
        long nil = 2;
        ok(q_Nt_x2ef(nil) == 3, "C: tagis(nil, 5) is TRUE - valtag 5 IS the word immediate 2");
        long t = 3;
        ok(q_Nt_x2ef(t) == 4, "C: tagis(true, 5) is FALSE");
        long *cons = mk_block(4, 1, 0, 0);
        long c = tagged(cons);
        ok(q_Nt_x2ef(c) == 4, "C: tagis(cons, 5) is FALSE (a heap object is not the nil immediate)");
    }
#elif defined(PROBE_TAGBOOL)
    /* ===== AREA C: THE TWO-IMMEDIATE FOLD (the probe BLOCKER 2 needed) ===== */
    {
        long t = 3;  /* true  = ...011 */
        ok(q_Bt_x2ef(t) == 3, "C/BOOL: tagis(true, tagBoolean) is TRUE");
        long f = 4;  /* false = ...100 */
        ok(q_Bt_x2ef(f) == 3,
           "C/BOOL: tagis(false, tagBoolean) is TRUE - BOTH immediates answer (the shipped fold answered FALSE here)");
        long nil = 2;
        ok(q_Bt_x2ef(nil) == 4, "C/BOOL: tagis(nil, tagBoolean) is FALSE");
        long fix = 5L << 3;
        ok(q_Bt_x2ef(fix) == 4, "C/BOOL: tagis(fixnum, tagBoolean) is FALSE");
    }
#elif defined(PROBE_CALL)
    /* ===== AREA 6: THE CALL ABI, EXECUTED ===== */
    {
        /* The probe is `\x -> Ca.g(Ca.g(x))` and `Ca.g` is `\x -> x`, so the
         * WHOLE chain is an identity — through one ORDINARY call (its argument
         * crosses in a register and its `:val` result is blitted into a slot)
         * and one TAIL call (the same ABI, C4-checked for class equality).
         *
         * WHAT EACH CHECK CATCHES, all of it measured-shape rather than
         * author-shape:
         *   * a POINTER-passed argument (the val arm's form) would make the
         *     callee store the ADDRESS of the caller's slot, and the identity
         *     would come back as a stack address — not `n * 8`, not even a
         *     fixnum, so check 1 goes red;
         *   * a 40-byte or sret-shaped return would leave the register holding
         *     an address rather than the word (check 2 on a heap-tagged word
         *     is the one that makes that visible, because the low 3 bits of a
         *     stack address are 0);
         *   * a lost argument (a slot number off by one, the U3b drift) breaks
         *     the identity for at least one of the three inputs. */
        ok(q_Ca_x2ef(7L << 3) == (7L << 3),
           "6/CALL: an identity through a CALL returns the same value word (the argument crossed in a register, not as a pointer)");
        ok(q_Ca_x2ef(0) == 0, "6/CALL: the fixnum ZERO round-trips (a leaked slot address cannot be 0)");
        long *blk = mk_block(4, 1, 0x1111, 0x2222);
        long cell = tagged(blk);
        ok(q_Ca_x2ef(cell) == cell,
           "6/CALL: a TAGGED HEAP WORD round-trips bit-exact (a sret/40-byte return or a pointer pass moves the low tag bits)");
        ok((q_Ca_x2ef(cell) & 7) == HEAP_PTR_TAG,
           "6/CALL: the returned word still carries the heap tag (...001) - the call did not retype it");
    }
#elif defined(PROBE_VEC)
    /* ===== AREA 3: THE ELEMENT BASE, THROUGH `vecbody` =====
     *
     * THE INSTRUMENT THE DIFF ROW CANNOT BE.  `word-arm-diff` runs whole
     * programs, and under the word arm no program can BUILD a heap vector yet
     * (an arg-taking entry needs a `Lam`, refused on the surface lane), so it
     * never reaches an element read.  MEASURED by the review: flipping
     * `wordVecBody`'s heap arm to `heapHeaderOffset` — a 32-byte-wrong base for
     * every heap object — left both the diff row and this probe set GREEN.
     *
     * So this probe hand-builds a code-10 block (exactly as probe B hand-builds
     * a cons) and reads elements THROUGH the emitter's own `vecbody`.  Index 0
     * catches a wrong BASE (with the flipped sign it reads the block's HEADER
     * word instead of element 0); indices 1 and 2 catch a wrong STRIDE (a
     * 40-byte stride reads past the 3-word body).
     */
    {
        long *base = mk_block3(10, 1, (5L << 3), (7L << 3), (9L << 3));
        long v = tagged(base);
        ok(q_Vc_x2ef(v, 0L << 3) == (5L << 3),
           "V: vecload(vecbody(code-10 block), 0) is element 0 - the BASE is the BODY (a header-relative base would read the header word)");
        ok(q_Vc_x2ef(v, 1L << 3) == (7L << 3),
           "V: ... index 1 is element 1 - the STRIDE is one word");
        ok(q_Vc_x2ef(v, 2L << 3) == (9L << 3),
           "V: ... index 2 is element 2");
        /* A FIXNUM IS NOT A VECTOR: `vecbody` of one is its payload word (a
         * `mknum(ptr)` carrier), so index 0 of mknum(0) is 0 — the loud die
         * belongs to the IMMEDIATES, not to the numbers. */
        g_died = 0;
        long nil = 2;
        if (sigsetjmp(g_jb, 1) == 0) {
            (void)q_Vc_x2ef(nil, 0L << 3);
            ok(0, "V: vecbody(nil) must REFUSE - it returned instead");
        }
        ok(g_died == 1 && strstr(g_die_msg, "element base") != NULL,
           "V: vecbody(nil) REFUSES and names the reason (an immediate names no elements)");
    }
#elif defined(PROBE_VECLEN)
    /* ===== AREA 3: THE ELEMENT COUNT, FROM THE HEADER (review BLOCKER 2) =====
     *
     * `veclen` is what makes a word-arm vector's length correct at all: the
     * count is not in the body (the body IS the elements), it is the GC header's
     * count word.  A reader that answered from the BODY would return element 0
     * — which is why the block below is built with count 3 and DIFFERENT element
     * values, so body-read and header-read cannot agree by accident.
     */
    {
        long *base = mk_block3(10, 1, (5L << 3), (7L << 3), (9L << 3));
        long v = tagged(base);
        ok(q_Vl_x2ef(v) == (3L << 3),
           "VL: veclen(code-10 block) == 3, the HEADER's count word - not element 0 (a body read would answer 5)");

        g_died = 0;
        long fix = 9L << 3;
        if (sigsetjmp(g_jb, 1) == 0) {
            (void)q_Vl_x2ef(fix);
            ok(0, "VL: veclen(fixnum) must REFUSE - it returned instead");
        }
        ok(g_died == 1 && strstr(g_die_msg, "element count") != NULL,
           "VL: veclen(fixnum) REFUSES and names the reason (a number has no elements)");
    }
#elif defined(PROBE_REC)
    /* ===== THE RECORD LAYOUT, HAND-BUILT (perf word-arm-records R0) =====
     *
     * THE FALSIFIABLE FIRST STEP, and it is taken BEFORE a line of record
     * lowering exists.  A word-arm record is ONE code-14 block whose body is
     * `[data_0 .. data_{n-1} | namesBase]` with header count n+1; the harness
     * builds exactly that by hand and drives the emitter's four reads against
     * it.  If the layout is wrong the probe prints a wrong element count, a
     * garbage names word, or dies on the kind test — with no compiler code to
     * blame, which is the point: this is the cheap place to lose the argument.
     */
    {
        /* THE VAL ARM'S RENDER of `{ x = 1, y = "hi" }` — MEASURED by running
         * that program on the val arm (QBE=1 run.js -> qbe -> cc -> run), not
         * guessed.  This is the byte string the last check compares against. */
        static const char *want = "[record 1 \"hi\"]";

        /* THE FIELD-NAMES ARRAY a word-arm record points at: a STATIC array of
         * name-byte pointers (DRef words).  It is 8-aligned, so each element
         * reads as a fixnum-tagged (`000`) word — the R3-risk, and the reason
         * the length reader must be `reclen` and not a bare `veclen`. */
        static const char *names_blob[2] = { "x", "y" };

        long *hi = mk_block(1, 0, 0, 0);          /* the string cell: code 1 */
        body_of(hi)[0] = (long)(uintptr_t)"hi";
        body_of(hi)[1] = 2;
        long hicell = tagged(hi);

        /* ONE code-14 block, count 3 = two data words PLUS the names word. */
        long *rec = mk_block3(14, 1, (1L << 3), hicell, (long)(uintptr_t)names_blob);
        long r = tagged(rec);
        long nb;
        char *n0;
        char *n1;

        ok(q_Rc_x2en(r) == (2L << 3),
           "R/LEN: reclen(record) == 2 for a two-field record - the header count is 3 and the names word is NOT a field (a bare veclen bound reads it as a value)");

        ok(q_Rc_x2ee(r, 0L << 3) == (1L << 3),
           "R/DATA: element 0 is the fixnum 1 - vecload(vecbody(rec), 0) IS data[0] on BOTH arms (names-last is what makes that true)");
        ok(q_Rc_x2ee(r, 1L << 3) == hicell,
           "R/DATA: element 1 is the string cell - one-word stride, and the names word did not move the data");

        nb = q_Rc_x2eb(r) >> 3;
        ok(nb == (long)(uintptr_t)names_blob,
           "R/NAMES: the names base is the body word at index reclen - the LAST body word, and the static blob verbatim");

        n0 = (char *)(uintptr_t)(q_Rc_x2ek(r, 0L << 3) >> 3);
        n1 = (char *)(uintptr_t)(q_Rc_x2ek(r, 1L << 3) >> 3);
        ok(strcmp(n0, "x") == 0,
           "R/NAMES: name 0 is \"x\" - a RAW char* word read as wload(namesBase, 0), boxed with mknum (the wrap symEq's payload(.,0) reads back)");
        ok(strcmp(n1, "y") == 0, "R/NAMES: name 1 is \"y\"");

        ok((body_of(rec)[2] & 7) == 0,
           "R/HAZARD: the names word AS A VALUE is fixnum-tagged (...000) - which is why `reclen` is the only record-length reader: a walk bounded by bare veclen copies/prints a pointer as a number");

        /* THE KILL NUMBER.  The element COUNT comes from the probe's own
         * reclen read and each element from its own element read, so a wrong
         * length prints the wrong NUMBER of elements and a wrong stride prints
         * the wrong element — the two failures this layout could have. */
        {
            char got[256];
            int len = snprintf(got, sizeof got, "[record");
            long cnt = q_Rc_x2en(r) >> 3;
            long k;
            for (k = 0; k < cnt; k++) {
                len += snprintf(got + len, sizeof got - (size_t)len, " ");
                len += render_elem(got + len, sizeof got - (size_t)len, q_Rc_x2ee(r, k << 3));
            }
            snprintf(got + len, sizeof got - (size_t)len, "]");
            if (strcmp(got, want) != 0)
                printf("    rendered [%s] want [%s]\n", got, want);
            ok(strcmp(got, want) == 0,
               "R/PRINT: the hand-built record RENDERS byte-identically to the val arm's `{ x = 1, y = \"hi\" }` -> [record 1 \"hi\"]");
        }

        /* ===== THE BUILT RECORD (perf word-arm-records R2) =====
         *
         * The block above is the harness's; this one is the EMITTER's, through
         * `lowerRecordLitPos`'s word fork and the `Rt.allocRecord` seat.  A
         * program-level diff row can only see the record's PRINT, and the print
         * walks `veclen - 1` elements — it cannot see the names word, the
         * header's count, or the kind code, which are exactly what a wrong
         * build gets wrong.
         */
        {
            long b = q_Rc_x2el(0);
            long *bb = (long *)(uintptr_t)(b & UNTAG_MASK);

            ok((b & 7) == HEAP_PTR_TAG,
               "R/BUILD: the built record is ONE tagged heap pointer (...001)");

            ok(bb[-1] == 3,
               "R/BUILD: the header's COUNT is n + 1 (3 for two fields) - the names word is a body word, so `veclen - 1` is the length (a seat that allocated n would put the names store past the block)");
            ok(((bb[-2] >> 24) & 15) == 14,
               "R/BUILD: the header's KIND CODE is 14 (tagRecord) - the module CONSTANT, not the instance field (on this arm `layout.tagRecord` is the heap shape tag 1, which is the STRING code)");
            ok((bb[-2] & 2) != 0,
               "R/BUILD: the header's SCAN bit is SET - a record body is Values (`heapKindScanned 14`), so the collector must trace data_0..data_{n-1}");

            ok(q_Rc_x2ee(b, 0L << 3) == (1L << 3),
               "R/BUILD: data[0] is the fixnum 1 - `vecload(vecbody(rec), i)` is data[i] on BOTH arms, which is why the positional read needs no fork");
            {
                long e1 = q_Rc_x2ee(b, 1L << 3);
                long *sb = (long *)(uintptr_t)(e1 & UNTAG_MASK);
                ok((e1 & 7) == HEAP_PTR_TAG && ((sb[-2] >> 24) & 15) == 1
                        && strcmp((char *)(uintptr_t)sb[0], "hi") == 0,
                   "R/BUILD: data[1] is the string cell the emitter built (code 1, bytes \"hi\") - a heap element in the data run, not a pointer to one");
            }

            ok(q_Rc_x2en(b) == (2L << 3),
               "R/BUILD: reclen(built record) == 2 - the layout's off-by-one answered by the one accessor that owns it");

            {
                long nb2 = q_Rc_x2eb(b) >> 3;
                const char *n0 = nb2 ? *(const char **)(uintptr_t)nb2 : 0;
                const char *n1 = nb2 ? *((const char **)(uintptr_t)nb2 + 1) : 0;
                ok(n0 && n1 && strcmp(n0, "x") == 0 && strcmp(n1, "y") == 0,
                   "R/BUILD: the names base is the body's LAST word and points at the static DRef-word blob, in canonical (sorted) order: x, y");
                /* TWO builds of the same row share ONE names array: the blob is
                 * a content-keyed static data def, not a per-record allocation.
                 * (It cannot be compared against THIS harness's blob — that is
                 * a different object in a different module.) */
                ok(q_Rc_x2eb(q_Rc_x2el(0)) >> 3 == nb2,
                   "R/BUILD: the names array is the SAME static blob for a second build of the same row - content-keyed, not per-record");
            }

            {
                char got[256];
                int len = snprintf(got, sizeof got, "[record");
                long cnt = q_Rc_x2en(b) >> 3;
                long k;
                for (k = 0; k < cnt; k++) {
                    len += snprintf(got + len, sizeof got - (size_t)len, " ");
                    len += render_elem(got + len, sizeof got - (size_t)len, q_Rc_x2ee(b, k << 3));
                }
                snprintf(got + len, sizeof got - (size_t)len, "]");
                ok(strcmp(got, want) == 0,
                   "R/BUILD: the BUILT record renders byte-identically to the val arm's");
            }
        }
    }
#elif defined(PROBE_SYM)
    /* ===== THE SYMBOL CELL (perf word-arm-records R1) =====
     *
     * The record family's dependency: a record's field NAMES are symbols.  A
     * word-arm symbol is a HEAP BLOCK (a symbol Value cannot live in `.data`),
     * so the record's names array holds raw name pointers and a symbol cell is
     * materialised only in a Value position.  This probe EMITS the cell through
     * the emitter's own writer and inspects it — the construction is the unit.
     */
    {
        long sym = q_Sy_x2ef(0);
        long *body;

        ok((sym & 7) == HEAP_PTR_TAG,
           "SYM: a word-arm symbol literal is ONE tagged heap pointer (...001)");

        body = (long *)(uintptr_t)(sym & UNTAG_MASK);
        ok(((body[-2] >> 24) & 15) == 2,
           "SYM: the header's KIND CODE is 2 (tagSymbol) - the code IS the constructor on this arm, and it is what tagis(v, 2) reads");
        ok((body[-2] & 2) == 0,
           "SYM: the header's SCAN bit is 0 - a symbol body is RAW (bytes, length), so the collector must not trace it as Values");

        ok(body[-1] == 1,
           "SYM: the header's COUNT is 1 - the body is the name pointer ONLY, the shape `Rt.intern` already builds; a two-word literal beside a one-word interned symbol would make any future length reader an OVERRUN on the interned one");
        ok(strcmp((char *)(uintptr_t)body[0], "x") == 0,
           "SYM: body unit 0 is the static byte pointer - the printer's pvZ(payload(v, 0)) walks exactly these bytes, so the render is the name with no length reader needed");

        ok(q_Sy_x2eg(sym) == 3,
           "SYM/TAGIS: the emitter's own tagis(v, tagSymbol) answers TRUE for the cell it built");

        /* THE DECOYS: the CODE is the only thing separating a symbol from a
         * string on this arm, so a "symbol" written through the string's seat
         * (code 1) has to answer FALSE - and so does a record. */
        {
            long *str = mk_block(1, 0, 0, 0);
            long sc;
            body_of(str)[0] = (long)(uintptr_t)"x";
            body_of(str)[1] = 1;
            sc = tagged(str);
            ok(q_Sy_x2eg(sc) == 4,
               "SYM/TAGIS: a code-1 cell with the SAME body words is NOT a symbol - the code, not the shape, is the constructor");
        }
        {
            long *rec = mk_block3(14, 1, (1L << 3), 0, 0);
            ok(q_Sy_x2eg(tagged(rec)) == 4,
               "SYM/TAGIS: a code-14 record block is NOT a symbol");
        }
    }
#endif
    printf("%d checks\n", g_checks);
    printf("%s\n", g_fail ? "WORD-ARM HEAP PROBE: FAIL" : "WORD-ARM HEAP PROBE: PASS");
    return g_fail;
}
