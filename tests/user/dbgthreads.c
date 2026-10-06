// dbgthreads: what the debugger's thread test debugs (M6 step 6d6a,
// tests/qemu/dbgthreads.ndb): 32 threads beside the first, each calling
// marked as it starts and then counting; the eighth calls hit_me once every
// one is past marked and the count past a million, and the program ends when hit_me returns. dbg
// stops each thread at marked in turn (more than the 16 procfs followed),
// then at hit_me, with every other thread stopped, and looks at another's
// stack and registers. Its functions are optnone, as dbgdemo's are.

#include "../../lib/vx-rt/rt.c"

static constexpr int WORKERS = 32;
static _Atomic uint64_t total;
static _Atomic bool done;
static _Atomic uint32_t arrived; // workers past marked

[[gnu::noinline, clang::optnone]] static void marked(int i) { (void)i; }

[[gnu::noinline, clang::optnone]] static void hit_me(void) { atomic_store(&done, true); }

[[gnu::noinline, clang::optnone]] static void count(int i) {
  while (!atomic_load(&done)) {
    uint64_t t = atomic_fetch_add(&total, 1);
    if (i == 7 && t > 1'000'000 && atomic_load(&arrived) == WORKERS) hit_me();
  }
}

static void worker(void *arg) {
  int i = (int)(intptr_t)arg;
  marked(i);
  atomic_fetch_add(&arrived, 1);
  count(i);
}

const char *vx_main(void) {
  static vx_thread t[WORKERS];
  for (int i = 0; i < WORKERS; i++)
    if (vx_thread_spawn(&t[i], worker, (void *)(intptr_t)i, 64ull * 1024) != VX_OK) return "no thread";
  for (int i = 0; i < WORKERS; i++) vx_thread_join(&t[i]);
  vx_print(VX_STR("dbgthreads: done\n"));
  return nullptr;
}
