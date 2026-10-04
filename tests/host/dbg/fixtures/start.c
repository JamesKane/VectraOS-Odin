// start.c: what the fixtures link in place of musl's back end (ADR-0007),
// which a host test never runs: an entry that calls main, and a system call
// that does nothing. The fixtures are only read, by dbg's index, never run;
// this makes dbgdemo.o and musl's libc.a link as they will on VectraOS.

int main(int argc, char **argv);

long __vx_syscall(long n, long a1, long a2, long a3, long a4, long a5, long a6) {
  (void)n, (void)a1, (void)a2, (void)a3, (void)a4, (void)a5, (void)a6;
  return -38; // ENOSYS
}

[[noreturn]] void _start(void) {
  main(0, nullptr);
  for (;;) {
  }
}
