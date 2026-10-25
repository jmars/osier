/* tcall_main.c — the driver for tools/qbe/tcall.ssa (the `tcall` fixture).
 *
 * Every expectation below is the SAME arithmetic written independently in C,
 * so a wrong tail call shows up as a wrong number rather than as a golden the
 * author copied out of the emitter's own output.
 *
 * It prints one PASS/FAIL line per check and exits non-zero if any FAILed.
 * tools/qbe/tcall-probe.sh gates on the exit code AND on the exact PASS count:
 * a wrong sret pointer or a frame read after the teardown corrupts a value, it
 * does not crash, and only the value check sees it.
 *
 * The 1e7-hop probe is the one whose ASSERTION IS THE STACK: it is run under
 * `ulimit -s 8192`, and the runner also runs the same fixture with `tcall`
 * hand-mutated to `call`, which must die. See tcall-probe.sh.
 */
#include <stdio.h>

long even(long);
long odd(long);

struct big { long a, b, c; };
struct big sretA(long);

long indirect(long, long);
long envcall(long);
long pressure(long, long);

static int fails;

static void
ck(const char *what, long got, long want)
{
	if (got == want)
		printf("PASS %s (%ld)\n", what, got);
	else {
		printf("FAIL %s: got %ld want %ld\n", what, got, want);
		fails++;
	}
}

/* $pressure's body, in C: 12 chained values, 6 products, and $sink6. */
static long
want_pressure(long a, long b)
{
	long p[12], s[6];
	int i;

	p[0] = a + b;
	for (i = 1; i < 12; i++)
		p[i] = p[i-1] + i;
	s[0] = p[11] * p[0];
	s[1] = p[10] * p[1];
	s[2] = p[9] * p[2];
	s[3] = p[8] * p[3];
	s[4] = p[7] * p[4];
	s[5] = p[6] * p[5];
	/* $pressure adds $sink1(%a) to %s0 before the tail call */
	s[0] += a + 1;
	return (s[0] + s[1]) + (s[2] + s[3]) + (s[4] + s[5]);
}

int
main(void)
{
	struct big b;

	/* (a)+(b) 1e7 mutual tail hops. the value proves the chain ran; the
	 * STACK CAP proves it ran in constant stack. */
	ck("mutual-even-1e7", even(10000000), 1);
	ck("mutual-odd-1e7", odd(10000000), 0);
	ck("mutual-small", even(1) * 10 + odd(1), 1);

	/* (c) sret forwarded through two tail hops: k*3, then +1, written by the
	 * leaf into the ORIGINAL caller's buffer. */
	b = sretA(7);
	ck("sret-forward-a", b.a, 7 * 3 + 1);
	ck("sret-forward-b", b.b, 7 * 3 + 1 + 100);
	ck("sret-forward-c", b.c, 7 * 3 + 1 + 1000);

	/* (c2) indirect tail through a function pointer, 1e5 deep. */
	ck("indirect-tail", indirect(100000, (long)indirect), 0);

	/* (d) env (rax) survives the teardown. */
	ck("env-tail", envcall(37), 37 + 5 + 37);

	/* (e) spilled arguments read from the frame before the teardown. */
	ck("pressure", pressure(3, 5), want_pressure(3, 5));

	if (fails) {
		printf("tcall_main: %d FAILED\n", fails);
		return 1;
	}
	printf("tcall_main: all checks passed\n");
	return 0;
}
