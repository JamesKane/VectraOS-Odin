// dbgdemo: what M4's exit test debugs (tests/qemu/dbg.ndb): dbg -c launches
// it, stops it at a breakpoint in leaf, prints its call stack and variables,
// and, given the argument "crash", sees it fault on its third call and opens
// the crash directory procfs leaves (05 §5, §7). Its functions are optnone,
// so it is the same program in every mode: a release build would inline
// middle and keep n in registers, which the index does not follow yet
// (docs/milestones.md, known gaps).

#include "../../lib/vx-rt/rt.c"

struct tally {
  int calls;
  long total;
  const char *label;
};
static struct tally tally = {0, 0, "demo"};
static volatile uintptr_t nowhere = 16; // nothing maps it; volatile, so the analyzer does not know it
static bool crash;

[[gnu::noinline, clang::optnone]] static long leaf(int n) {
  tally.calls++;
  tally.total += n;
  if (crash && n == 3) tally.total += *(volatile const long *)nowhere; // the fault
  return tally.total;
}

[[gnu::noinline, clang::optnone]] static long middle(int n) {
  long doubled = 2 * leaf(n);
  return doubled + 1;
}

const char *vx_main(void) {
  crash = vx_spawn.argc && vx_spawn.args[0].len == 5 && memcmp(vx_spawn.args[0].ptr, "crash", 5) == 0;
  long sum = 0;
  for (int i = 1; i <= 3; i++) sum += middle(i);
  vx_print(vx_cstr(tally.label)); // read, so its value is kept
  vx_print(VX_STR(": done\n"));
  return sum == 2 * (1 + 3 + 6) + 3 ? nullptr : "wrong sum";
}
