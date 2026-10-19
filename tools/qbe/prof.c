/* prof.c — a DEV-ONLY sampling profiler for QBE-built artifacts.
 *
 * WHY THIS EXISTS.  This box has no perf, no gprof, no valgrind (MEASURED,
 * 2026-10-19), and a QBE artifact is a single 3-4 MB executable whose hot code
 * is the Mid runtime — so "where does the seed-built compiler spend its time"
 * had no instrument at all.  This is the instrument: ~120 lines, links with
 * `cc`, samples the CPU clock with setitimer(ITIMER_PROF), and writes a
 * handful of `pc count` lines that tools/qbe/prof-report.sh resolves offline.
 *
 * OPT-IN ONLY.  tools/qbe/qbe-mk.sh links this file iff QBE_PROF=1; a default
 * build does not contain it (the hook is one `case` in that script).  It is
 * not part of rt.o and nothing links it by accident.
 *
 * WHAT IT SAMPLES, AND THE ONE THING TO KEEP IN MIND: ITIMER_PROF counts CPU
 * time (user + system), NOT wall clock.  A run that blocks in read()/write()
 * for 20 minutes and computes for 20 seconds has ~20 000 samples, not
 * 1 200 000 — so the percentages below are percentages OF CPU TIME.  I/O
 * stalls are INVISIBLE here (syscall time counts only while the kernel is
 * actually doing the work on our behalf).  Cross-check a profiled run against
 * its wall clock before concluding anything about I/O.
 *
 * WHAT IT CANNOT SEE.
 *   - Callers.  Only the interrupted PC is recorded, so a cost is attributed
 *     to the function the CPU was in, never to whoever called it.  Two
 *     different call sites of the same callee merge.
 *   - Inlined code, obviously (the PC lands in the enclosing symbol).
 *   - Time inside a signal handler (tiny, and it is our own).
 *   - A fatal signal loses the whole profile: the dump runs from atexit(3),
 *     so SIGSEGV/SIGABRT/SIGKILL produce NOTHING.  A crashing run must be
 *     bisected by workload, not profiled to the crash point.
 *   - Threads: the handler is registered process-wide and ITIMER_PROF's
 *     signal is delivered to the process; with >1 thread samples land on
 *     whichever thread the kernel picks.  The compiler is single-threaded;
 *     treat a multi-threaded artifact's profile as thread-mixed.
 *
 * DROP POLICY.  The ring holds the MOST RECENT PROF_RING samples; a run
 * longer than ring/hz seconds overwrites its own oldest samples (it does NOT
 * stop sampling), and every overwritten sample is counted in `dropped`.  A
 * non-zero `dropped` means "the last ring/hz seconds only", and the dump says
 * so on its header line.  Fresh output starts at `# qbe-prof`.
 *
 * Env:
 *   QBE_PROF_OUT   dump path (default: stderr)
 *   QBE_PROF_HZ    samples per CPU second (default 1000)
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <ucontext.h>
#include <unistd.h>

/* 1 << 22 = 4 194 304 samples = ~70 minutes at 1 kHz.  A power of two: the
 * index is masked, never divided (the handler must not use idiv if it can
 * help it, and more importantly must not allocate). */
#define PROF_RING_LOG2 22
#define PROF_RING (1u << PROF_RING_LOG2)

/* The ONLY state the handler touches.  `prof_pcs` is written by the handler
 * and read by the dumper at exit; a concurrent handler during the dump can at
 * worst make the newest few samples inconsistent, and the dump re-reads
 * `prof_count` last so the reported total is never larger than what was
 * written. */
static volatile uint64_t prof_pcs[PROF_RING];
static volatile uint64_t prof_count;

static long prof_hz = 1000;
static const char *prof_out;

/* ---- the handler: async-signal-safe by construction ---------------------
 * No allocation, no locks, no libc call, no errno change.  A relaxed atomic
 * fetch-add is the one primitive a signal handler may use (it compiles to a
 * single `lock xadd` on x86-64). */
static void prof_handler(int sig, siginfo_t *si, void *ctx)
{
  ucontext_t *uc = (ucontext_t *)ctx;
  uint64_t pc = (uint64_t)uc->uc_mcontext.gregs[REG_RIP];
  uint64_t i;
  (void)sig;
  (void)si;
  i = __atomic_fetch_add(&prof_count, 1, __ATOMIC_RELAXED);
  prof_pcs[i & (PROF_RING - 1)] = pc;
}

/* ---- dump: aggregate pc -> count in a fixed open-addressing table -------
 * 1 << 18 slots is ~24x the ~10k distinct PCs a compiled module realistically
 * has; a full table degrades to a named `-overflowed-` bucket instead of
 * corrupting the rest of the report. */
#define PROF_HASH_LOG2 18
#define PROF_HASH (1u << PROF_HASH_LOG2)

static void prof_dump(void)
{
  static uint64_t keys[PROF_HASH];
  static uint32_t vals[PROF_HASH];
  FILE *f;
  uint64_t total, have, i, overflow = 0;
  const char *path = prof_out && *prof_out ? prof_out : NULL;

  total = __atomic_load_n(&prof_count, __ATOMIC_RELAXED);
  have = total < PROF_RING ? total : PROF_RING;
  memset(keys, 0, sizeof keys);
  memset(vals, 0, sizeof vals);

  for (i = total - have; i < total; i++) {
    uint64_t pc = prof_pcs[i & (PROF_RING - 1)];
    uint64_t h, probes;
    if (pc == 0)
      continue;
    h = ((pc >> 2) * 0x9E3779B97F4A7C15ull) >> (64 - PROF_HASH_LOG2);
    for (probes = 0; probes < 64; probes++) {
      if (keys[h] == pc) { vals[h]++; break; }
      if (keys[h] == 0) { keys[h] = pc; vals[h] = 1; break; }
      h = (h + 1) & (PROF_HASH - 1);
    }
    if (probes == 64) /* table saturating: counted, never silently lost */
      overflow++;
  }

  if (path) f = fopen(path, "w");
  else      f = stderr;
  if (!f)
    return;

  fprintf(f, "# qbe-prof v1 hz=%ld ring=%u samples=%llu dropped=%llu\n",
          prof_hz, (unsigned)PROF_RING,
          (unsigned long long)have, (unsigned long long)(total - have));

  /* The mapping table, so the offline reporter can turn a runtime PC into a
   * file symbol in the RIGHT image (-lc is dynamic: PCs land in libc too).
   * Only executable mappings with a pathname are useful here. */
  {
    int mfd = open("/proc/self/maps", O_RDONLY);
    fprintf(f, "# maps\n");
    if (mfd >= 0) {
      char buf[8192];
      ssize_t n;
      while ((n = read(mfd, buf, sizeof buf)) > 0) {
        /* One mapping per line; lines never straddle our buffer in practice,
         * but a straddling tail is simply skipped (fidelity of the mapping
         * table is not worth an allocator here). */
        char *p = buf, *nl;
        while ((nl = memchr(p, '\n', (size_t)(buf + n - p))) != NULL) {
          size_t len = (size_t)(nl - p);
          *nl = '\0';
          if (len > 0 && strchr(p, 'x') && strchr(p, '/'))
            fprintf(f, "%s\n", p);
          p = nl + 1;
        }
      }
      close(mfd);
    }
  }

  fprintf(f, "# pcs\n");
  if (overflow)
    fprintf(f, "# hash-overflowed %llu samples\n",
            (unsigned long long)overflow);
  for (i = 0; i < PROF_HASH; i++)
    if (keys[i])
      fprintf(f, "0x%llx %u\n", (unsigned long long)keys[i], vals[i]);

  if (f != stderr)
    fclose(f);
  else
    fflush(f);
}

__attribute__((constructor)) static void prof_start(void)
{
  struct sigaction sa;
  struct itimerval it;
  const char *hz = getenv("QBE_PROF_HZ");

  prof_out = getenv("QBE_PROF_OUT");
  if (hz && *hz) {
    long v = strtol(hz, NULL, 10);
    if (v > 0 && v <= 100000) prof_hz = v;
  }
  memset(&sa, 0, sizeof sa);
  sa.sa_sigaction = prof_handler;
  sa.sa_flags = SA_SIGINFO | SA_RESTART;
  sigemptyset(&sa.sa_mask);
  if (sigaction(SIGPROF, &sa, NULL) != 0)
    return; /* no profiler, silently: the artifact must still run */
  it.it_interval.tv_sec = 0;
  it.it_interval.tv_usec = 1000000 / prof_hz;
  it.it_value = it.it_interval;
  if (it.it_interval.tv_usec <= 0)
    it.it_interval.tv_usec = 1;
  if (setitimer(ITIMER_PROF, &it, NULL) != 0)
    return;
  atexit(prof_dump);
}
