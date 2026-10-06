// lib/vx-rt/rt.c: a stand-in for upstream's C runtime of the same path,
// which this tree does not have and does not copy (ADR-0002). The debugger's
// fixtures include it, tests/user/dbgdemo.c and dbgthreads.c, kept
// byte-identical to upstream's because dbg prints their source lines
// (ADR-0007). This gives them exactly what they use of upstream's runtime,
// on musl (the POSIX personality), and nothing more (threads: at the end):
//
//   vx_str, VX_STR   a string as a pointer and a length
//   vx_cstr          a NUL-terminated string as a vx_str
//   vx_print         text to the console (standard output), unbuffered
//   vx_spawn         the program's arguments: argc and args[], without argv[0]
//   main             calls the program's vx_main, whose result ends it
//
// Upstream's vx_main returns the program's exit string (nullptr for
// success). musl's exit takes a number, so a failure here is its string on
// standard error and status 1; success is the same as upstream's, an empty
// exit string.

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

typedef struct vx_str {
  const char *ptr;
  size_t len;
} vx_str;

#define VX_STR(literal) ((vx_str){(literal), sizeof(literal) - 1})

[[maybe_unused]] static vx_str vx_cstr(const char *s) { return (vx_str){s, strlen(s)}; }

// Straight to the descriptor, so what the program prints goes out before a
// fault stops it, as upstream's console output does.
[[maybe_unused]] static void vx_print(vx_str s) {
  while (s.len > 0) {
    ssize_t n = write(STDOUT_FILENO, s.ptr, s.len);
    if (n <= 0) return;
    s.ptr += n;
    s.len -= (size_t)n;
  }
}

enum { VX_SHIM_MAX_ARGS = 64 };

static struct {
  vx_str args[VX_SHIM_MAX_ARGS];
  uint32_t argc;
} vx_spawn;

const char *vx_main(void);

int main(int argc, char **argv) {
  for (int i = 1; i < argc && vx_spawn.argc < VX_SHIM_MAX_ARGS; i++) vx_spawn.args[vx_spawn.argc++] = vx_cstr(argv[i]);
  const char *why = vx_main();
  if (!why) return 0;
  fprintf(stderr, "%s\n", why);
  return 1;
}

// dbgthreads's threads (upstream's M6 step 6d6a), after main so dbgdemo's
// lines stay where they were:
//
//   vx_status, VX_OK   a call's result, and success
//   vx_thread          a thread vx_thread_spawn made, for vx_thread_join:
//                      musl's pthread, with the stack size asked for
//   <stdatomic.h>      which upstream's runtime includes for its programs

#include <pthread.h>
#include <stdatomic.h>

typedef int32_t vx_status;
enum { VX_OK = 0, VX_ERR_NO_MEMORY = -6 }; // abi/vx/status.def's

typedef struct vx_thread {
  pthread_t thread;
  void (*fn)(void *);
  void *arg;
} vx_thread;

[[maybe_unused]] static void *vx_shim_thread(void *t) {
  ((vx_thread *)t)->fn(((vx_thread *)t)->arg);
  return nullptr;
}

// fn(arg) on a thread of its own, with a stack of stack bytes (0: musl's).
[[maybe_unused]] static vx_status vx_thread_spawn(vx_thread *t, void (*fn)(void *), void *arg, uint64_t stack) {
  pthread_attr_t a;
  pthread_attr_init(&a);
  if (stack) pthread_attr_setstacksize(&a, stack);
  t->fn = fn, t->arg = arg;
  int e = pthread_create(&t->thread, &a, vx_shim_thread, t);
  pthread_attr_destroy(&a);
  return e ? VX_ERR_NO_MEMORY : VX_OK;
}

[[maybe_unused]] static void vx_thread_join(vx_thread *t) { pthread_join(t->thread, nullptr); }
