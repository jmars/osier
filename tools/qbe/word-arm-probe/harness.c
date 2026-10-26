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
 *   Rt.allocRaw                   THE CONTRACT runtime.mid STATES (Blocker 1):
 *                                 gcAlloc writes the header at cursor-2/-1
 *                                 words and returns mknum(cursor), so the seat
 *                                 returns the BODY ADDRESS with the 2-word
 *                                 header `heapHeaderBytes` BEFORE it.  The
 *                                 earlier stub returned a calloc BASE with the
 *                                 header at +0 — the EMITTER's side of the
 *                                 contract — which made the probe measure
 *                                 emitter-internal consistency instead of
 *                                 agreement with the runtime.  That is exactly
 *                                 why it passed the bugs it should have caught.
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
    long body_words = (nbytes + 7) / 8;
    long *base = calloc(1, (size_t)(2 + body_words) * 8);
    long *body = base + 2;                    /* header is 2 words BEFORE it */
    /* the header word 0 the allocator writes: class 512, code 1, scan 0 */
    base[0] = (long)((512L * 4L) + (1L << 24));
    base[1] = body_words;
    g_last_body = body;
    struct Val v;
    v.w = (int64_t)((uintptr_t)body) << 3;     /* mknum(body) */
    return v;
}

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
#endif
    printf("%d checks\n", g_checks);
    printf("%s\n", g_fail ? "WORD-ARM HEAP PROBE: FAIL" : "WORD-ARM HEAP PROBE: PASS");
    return g_fail;
}
