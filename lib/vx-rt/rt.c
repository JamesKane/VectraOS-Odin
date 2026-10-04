// lib/vx-rt/rt.c: a stand-in for upstream's C runtime of the same path,
// which this tree does not have and does not copy (ADR-0002). One file
// includes it: tests/user/dbgdemo.c, the debugger's fixture, kept
// byte-identical to upstream's because dbg prints its source lines
// (ADR-0007). This gives that program exactly what it uses of upstream's
// runtime, on musl (the POSIX personality), and nothing more:
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
