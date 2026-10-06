// ctest: a C program against vectra-musl (M4 step 2d, tests/qemu/posix.ndb).
// It uses the C library as any port would, and checks what comes back: its
// arguments and environment, memory, floating point (aarch64's long double
// is compiler-rt's), stdio on files in its namespace, directories, stat, the
// working directory, errno, time, thread-local storage, setjmp, atexit, and
// its exit status.

#define _GNU_SOURCE // POSIX under -std=c23, and a ucontext's register names (REG_RIP and kin)

#include <dirent.h>
#include <errno.h>
#include <locale.h>
#include <fcntl.h>
#include <math.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <sched.h>
#include <setjmp.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/auxv.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/random.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/uio.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <uchar.h>
#include <unistd.h>
#include <wchar.h>

// Its own program, and where procfs saves crashes: what the scenario's
// manifest says (CTEST_SELF, CTEST_CRASH), else the posix scenario's. The
// fsd scenario runs it as /boot/bin/ctestfsd, with /tmp on fsd.
static const char *self = "/boot/bin/ctest", *self_name = "ctest", *crash_dir = "/tmp/crash";
// Its manifest, a file it knows: /boot/svc/NAME.ndb, which starts "# tests/user/NAME.ndb".
static char manifest[64], manifest_rel[64], manifest_head[64];
// The file server under /tmp keeps owners and checks permissions (fsd), as
// CTEST_OWNERS=kept says, rather than keeping none (tmpfs).
static bool owners_kept;
// Its files can be mapped shared (fsd, a pager: CTEST_MAPPED=shared), not only copied.
static bool maps_shared;

static void where_am_i(void) {
  const char *s = getenv("CTEST_SELF"), *c = getenv("CTEST_CRASH");
  if (s && *s) self = s, self_name = strrchr(s, '/') ? strrchr(s, '/') + 1 : s;
  if (c && *c) crash_dir = c;
  const char *o = getenv("CTEST_OWNERS");
  owners_kept = o && strcmp(o, "kept") == 0;
  const char *m = getenv("CTEST_MAPPED");
  maps_shared = m && strcmp(m, "shared") == 0;
  snprintf(manifest, sizeof manifest, "/boot/svc/%s.ndb", self_name);
  snprintf(manifest_rel, sizeof manifest_rel, "svc/../svc/%s.ndb", self_name);
  snprintf(manifest_head, sizeof manifest_head, "# tests/user/%s.ndb", self_name);
}

static int checks, failed;

#define CHECK(cond)                                                                                          \
  do {                                                                                                       \
    checks++;                                                                                                \
    if (!(cond)) {                                                                                           \
      failed++;                                                                                              \
      printf("ctest: FAILED line %d: %s\n", __LINE__, #cond);                                                \
    }                                                                                                        \
  } while (0)

static _Thread_local int tls_counter = 41;
static jmp_buf jump;

static void at_exit(void) { printf("ctest: atexit ran\n"); }

static void jump_back(int value) { longjmp(jump, value); }

static int by_int(const void *a, const void *b) { return *(const int *)a - *(const int *)b; }

static double seconds(const struct timespec *t) { return (double)t->tv_sec + (double)t->tv_nsec / 1e9; }

// ctest run by ctest: argv[1] says what to check, argv[2] is the parent's
// pid, and the exit status says what it found.

static volatile sig_atomic_t signals[65]; // how many of each signal a handler saw
static volatile pid_t last_sender;
static sigjmp_buf fault_jump;
static void *volatile fault_address;

// An address nothing is mapped at, for the faults the tests make on purpose:
// made at run time, which keeps the static analyzer from flagging them.
static volatile int *nowhere_at(void) { return (volatile int *)(uintptr_t)strtoul("16", nullptr, 10); }

static void on_signal(int sig) { signals[sig]++; }

static void on_signal_info(int sig, siginfo_t *info, void *uc) {
  (void)uc;
  signals[sig]++;
  last_sender = info->si_pid;
}

static void on_fault(int sig, siginfo_t *info, void *uc) {
  (void)uc;
  signals[sig]++;
  fault_address = info->si_addr;
  siglongjmp(fault_jump, 1);
}

static int child_main(char **argv) {
  // default: the end, as SIGSEGV; before the parent's check, as dbg runs it too (tests/qemu/dbgmusl.ndb)
  if (strcmp(argv[1], "segv") == 0) return *nowhere_at();
  pid_t parent = (pid_t)strtol(argv[2], nullptr, 10);
  if (getppid() != parent || getpid() == parent || getsid(0) != getsid(parent)) return 1;
  if (strcmp(argv[1], "exit") == 0) return argv[3] ? (int)strtol(argv[3], nullptr, 10) : 7;
  if (strcmp(argv[1], "same") == 0) // run by execve: still the process it was (task_exec, ADR-0012)
    return argv[3] && getpid() == (pid_t)strtol(argv[3], nullptr, 10) ? 15 : 2;
  if (strcmp(argv[1], "group") == 0) return getpgrp() == getpid() ? 9 : 2; // POSIX_SPAWN_SETPGROUP, 0
  if (strcmp(argv[1], "sleep") == 0) {
    nanosleep(&(struct timespec){.tv_nsec = 100'000'000}, nullptr);
    return 3;
  }
  if (strcmp(argv[1], "echo") == 0) { // its standard output, a pipe the parent reads
    printf("echo from child\n");
    return 8;
  }
  if (strcmp(argv[1], "fds") == 0) { // descriptors and the working directory, as the parent left them
    char b[3] = {}, cwd[64];
    bool ok = read(3, b, 2) == 2 && memcmp(b, "te", 2) == 0; // inherited at offset 2
    ok = ok && fcntl(4, F_GETFD) == -1 && errno == EBADF;    // FD_CLOEXEC: not inherited
    ok = ok && read(5, b, 1) == 1 && b[0] == '#';            // posix_spawn_file_actions_addopen
    ok = ok && getcwd(cwd, sizeof cwd) && strcmp(cwd, "/boot") == 0;
    return ok ? 10 : 2;
  }
  if (strcmp(argv[1], "signal") == 0) return kill(parent, SIGUSR1) == 0 ? 12 : 2;
  if (strcmp(argv[1], "socket") == 0) { // descriptor 3, a TCP socket the parent connected
    struct stat st;
    int type = 0;
    socklen_t len = sizeof type;
    bool ok = fstat(3, &st) == 0 && S_ISSOCK(st.st_mode);
    ok = ok && getsockopt(3, SOL_SOCKET, SO_TYPE, &type, &len) == 0 && type == SOCK_STREAM;
    return ok && write(3, "spawned", 7) == 7 ? 16 : 2;
  }
  if (strcmp(argv[1], "late") == 0) { // a signal to the parent while it sleeps
    nanosleep(&(struct timespec){.tv_nsec = 50'000'000}, nullptr);
    return kill(parent, SIGUSR1) == 0 ? 14 : 2;
  }
  if (strcmp(argv[1], "pause") == 0) { // ready (on its standard output), then waits for SIGUSR2
    struct sigaction sa = {.sa_handler = on_signal};
    sigset_t usr2, none;
    sigemptyset(&usr2);
    sigaddset(&usr2, SIGUSR2);
    sigemptyset(&none);
    sigprocmask(SIG_BLOCK, &usr2, nullptr); // so it cannot come between "ready" and the wait
    sigaction(SIGUSR2, &sa, nullptr);
    write(1, "ready", 5);
    bool interrupted = sigsuspend(&none) == -1 && errno == EINTR;
    return interrupted && signals[SIGUSR2] == 1 ? 13 : 2;
  }
  if (strcmp(argv[1], "kept") == 0) { // what its parent ignored and blocked, kept through posix_spawn
    struct sigaction now;
    sigset_t mask;
    bool ok = sigaction(SIGUSR2, nullptr, &now) == 0 && now.sa_handler == SIG_IGN;
    ok = ok && sigprocmask(SIG_SETMASK, nullptr, &mask) == 0 && sigismember(&mask, SIGUSR1);
    ok = ok && sigaction(SIGHUP, nullptr, &now) == 0 && now.sa_handler == SIG_DFL; // POSIX_SPAWN_SETSIGDEF
    return ok ? 23 : 2;
  }
  if (strcmp(argv[1], "env") == 0) {
    const char *greeting = getenv("GREETING");
    return greeting && strcmp(greeting, "hello") == 0 ? 4 : 2;
  }
  return 2;
}

static int spawn_wait(const char *path, bool search, const char *what, const posix_spawnattr_t *attr) {
  char parent[24];
  snprintf(parent, sizeof parent, "%d", (int)getpid());
  char *args[] = {"ctest", (char *)what, parent, "7", nullptr};
  pid_t child = 0;
  int err = search ? posix_spawnp(&child, path, nullptr, attr, args, environ)
                   : posix_spawn(&child, path, nullptr, attr, args, environ);
  if (err != 0) return -err;
  int status = 0;
  if (waitpid(child, &status, 0) != child || !WIFEXITED(status)) return -1000;
  return WEXITSTATUS(status);
}

// pids, groups and sessions through /proc (ADR-0011); posix_spawn and wait.
static void test_processes(void) {
  pid_t me = getpid();
  CHECK(me >= 2 && getppid() == 1); // registered by svcd: a session of its own
  CHECK(getsid(0) == me && getpgrp() == me);
  errno = 0;
  CHECK(setsid() == -1 && errno == EPERM); // a group leader already
  int status;
  errno = 0;
  CHECK(waitpid(-1, &status, 0) == -1 && errno == ECHILD);

  CHECK(spawn_wait(self, false, "exit", nullptr) == 7);
  CHECK(spawn_wait(self, false, "env", nullptr) == 4);
  CHECK(spawn_wait(self_name, true, "exit", nullptr) == 7); // posix_spawnp, through PATH
  posix_spawnattr_t attr;
  posix_spawnattr_init(&attr);
  posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
  posix_spawnattr_setpgroup(&attr, 0);
  CHECK(spawn_wait(self, false, "group", &attr) == 9);
  posix_spawnattr_destroy(&attr);
  CHECK(spawn_wait("/boot/bin/no-such-program", false, "exit", nullptr) == -ENOENT);

  // A child still running: WNOHANG finds nothing, then a wait finds it.
  char parent[24];
  snprintf(parent, sizeof parent, "%d", (int)me);
  char *args[] = {"ctest", "sleep", parent, nullptr};
  pid_t child = 0;
  CHECK(posix_spawn(&child, self, nullptr, nullptr, args, environ) == 0 && child > me);
  CHECK(getpgid(child) == me && getsid(child) == me);
  CHECK(waitpid(child, &status, WNOHANG) == 0);
  CHECK(waitpid(-1, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 3);
  errno = 0;
  CHECK(getpgid(child) == -1 && errno == ESRCH); // reaped
}

// Reads a pipe to its end.
static size_t read_all(int fd, char *buf, size_t cap) {
  size_t n = 0;
  for (ssize_t r; n < cap && (r = read(fd, buf + n, cap - n)) > 0;) n += (size_t)r;
  return n;
}

// fork, execve and pipes; descriptors given to children.
static void test_fork_exec_pipes(void) {
  char buf[64] = {}, parent[24];
  pid_t me = getpid();
  snprintf(parent, sizeof parent, "%d", (int)me);
  int p[2], status = 0;
  CHECK(pipe(p) == 0);
  CHECK(write(p[1], "hello", 5) == 5 && read(p[0], buf, sizeof buf) == 5 && memcmp(buf, "hello", 5) == 0);
  int q[2];
  CHECK(pipe2(q, O_NONBLOCK) == 0);
  errno = 0;
  CHECK(read(q[0], buf, 1) == -1 && errno == EAGAIN);
  close(q[0]);
  close(q[1]);

  // fork: the child has memory and descriptors as they were, and its own
  // from then on; it reports through the pipe and its status.
  static int marker = 1;
  int file = open(manifest, O_RDONLY);
  CHECK(file >= 0 && lseek(file, 2, SEEK_SET) == 2);
  if (file < 0) return; // the rest needs it
  pid_t child = fork();
  if (child == 0) {
    char b[3] = {};
    bool ok = marker == 1 && getppid() == me && getpid() != me;
    ok = ok && read(file, b, 2) == 2 && memcmp(b, "te", 2) == 0;
    marker = 2;
    const char *say = ok ? "child ok" : "child bad";
    ok = write(p[1], say, strlen(say)) == (ssize_t)strlen(say) && ok;
    _exit(ok ? 5 : 1);
  }
  CHECK(child > me);
  close(p[1]); // the child's end is the last writer: the read ends when it exits
  memset(buf, 0, sizeof buf);
  CHECK(read_all(p[0], buf, sizeof buf - 1) == 8 && strcmp(buf, "child ok") == 0);
  close(p[0]);
  CHECK(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 5);
  CHECK(marker == 1);
  char b[3] = {};
  CHECK(read(file, b, 2) == 2 && memcmp(b, "te", 2) == 0); // the offset is not shared yet (M4 step 4)

  // fork, then execve: the program goes on as the same process.
  child = fork();
  if (child == 0) {
    char *args[] = {"ctest", "exit", parent, "6", nullptr};
    execv(self, args);
    _exit(1);
  }
  CHECK(child > me && waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 6);
  child = fork();
  if (child == 0) { // its pid before and after
    char pid[16];
    snprintf(pid, sizeof pid, "%d", (int)getpid());
    char *args[] = {"ctest", "same", parent, pid, nullptr};
    execv(self, args);
    _exit(1);
  }
  CHECK(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 15);
  child = fork();
  if (child == 0) {
    char *args[] = {"none", nullptr};
    _exit(execv("/boot/bin/no-such-program", args) == -1 && errno == ENOENT ? 11 : 1);
  }
  CHECK(waitpid(child, &status, 0) == child && WEXITSTATUS(status) == 11);

  // posix_spawn's file actions: the child's standard output into a pipe.
  CHECK(pipe(p) == 0);
  posix_spawn_file_actions_t fa;
  posix_spawn_file_actions_init(&fa);
  posix_spawn_file_actions_adddup2(&fa, p[1], 1);
  posix_spawn_file_actions_addclose(&fa, p[0]);
  posix_spawn_file_actions_addclose(&fa, p[1]);
  char *echo[] = {"ctest", "echo", parent, nullptr};
  CHECK(posix_spawn(&child, self, &fa, nullptr, echo, environ) == 0);
  posix_spawn_file_actions_destroy(&fa);
  close(p[1]);
  memset(buf, 0, sizeof buf);
  CHECK(read_all(p[0], buf, sizeof buf - 1) == 16 && strcmp(buf, "echo from child\n") == 0);
  close(p[0]);
  CHECK(waitpid(child, &status, 0) == child && WEXITSTATUS(status) == 8);

  // Inherited: a file at its offset, not one marked FD_CLOEXEC, one opened
  // by a file action, and the working directory.
  int keep = open(manifest, O_RDONLY | O_CLOEXEC);
  CHECK(keep >= 0 && dup3(keep, 4, O_CLOEXEC) == 4);
  posix_spawn_file_actions_init(&fa);
  posix_spawn_file_actions_adddup2(&fa, file, 3);
  posix_spawn_file_actions_addopen(&fa, 5, manifest, O_RDONLY, 0);
  CHECK(lseek(file, 2, SEEK_SET) == 2 && chdir("/boot") == 0);
  char *fds[] = {"ctest", "fds", parent, nullptr};
  CHECK(posix_spawn(&child, self, &fa, nullptr, fds, environ) == 0);
  CHECK(chdir("/") == 0);
  posix_spawn_file_actions_destroy(&fa);
  CHECK(waitpid(child, &status, 0) == child && WEXITSTATUS(status) == 10);
  close(4);
  close(keep);
  close(file);
}

static int spawn_child(const char *what, posix_spawn_file_actions_t *fa, pid_t *child) {
  char parent[24];
  snprintf(parent, sizeof parent, "%d", (int)getpid());
  char *args[] = {"ctest", (char *)what, parent, nullptr};
  return posix_spawn(child, self, fa, nullptr, args, environ);
}

static double now_seconds(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return seconds(&t);
}

// Signals: to itself, blocked and pending, ignored, between processes;
// faults; default actions; SIGCHLD; interrupted and restarted calls.
static void test_signals(void) {
  struct sigaction sa = {.sa_handler = on_signal},
                   info = {.sa_sigaction = on_signal_info, .sa_flags = SA_SIGINFO};
  CHECK(sigaction(SIGUSR1, &sa, nullptr) == 0);
  CHECK(raise(SIGUSR1) == 0 && signals[SIGUSR1] == 1); // delivered before raise returns
  sigset_t usr1, pending;
  sigemptyset(&usr1);
  sigaddset(&usr1, SIGUSR1);
  CHECK(sigprocmask(SIG_BLOCK, &usr1, nullptr) == 0);
  CHECK(raise(SIGUSR1) == 0 && signals[SIGUSR1] == 1); // blocked: pending
  CHECK(sigpending(&pending) == 0 && sigismember(&pending, SIGUSR1));
  CHECK(sigprocmask(SIG_UNBLOCK, &usr1, nullptr) == 0 && signals[SIGUSR1] == 2);
  CHECK(signal(SIGUSR2, SIG_IGN) != SIG_ERR && raise(SIGUSR2) == 0 && signals[SIGUSR2] == 0);
  signal(SIGUSR2, SIG_DFL);
  errno = 0;
  CHECK(sigaction(SIGKILL, &sa, nullptr) == -1 && errno == EINVAL);

  // From another process, with its pid; the wait it interrupts goes on (SA_RESTART).
  info.sa_flags |= SA_RESTART;
  CHECK(sigaction(SIGUSR1, &info, nullptr) == 0);
  pid_t child = 0;
  int status = 0;
  CHECK(spawn_child("signal", nullptr, &child) == 0);
  CHECK(waitpid(child, &status, 0) == child && WEXITSTATUS(status) == 12);
  for (double end = now_seconds() + 1; signals[SIGUSR1] < 3 && now_seconds() < end;) sched_yield();
  CHECK(signals[SIGUSR1] == 3 && last_sender == child);

  // To a child that waits for it.
  int p[2];
  CHECK(pipe(p) == 0);
  posix_spawn_file_actions_t fa;
  posix_spawn_file_actions_init(&fa);
  posix_spawn_file_actions_adddup2(&fa, p[1], 1);
  posix_spawn_file_actions_addclose(&fa, p[0]);
  CHECK(spawn_child("pause", &fa, &child) == 0);
  posix_spawn_file_actions_destroy(&fa);
  close(p[1]);
  char ready[8] = {};
  CHECK(read(p[0], ready, 5) == 5 && strcmp(ready, "ready") == 0);
  close(p[0]);
  CHECK(kill(child, SIGUSR2) == 0);
  CHECK(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 13);

  // Default actions: the end, with the signal in the wait status.
  CHECK(spawn_child("sleep", nullptr, &child) == 0 && kill(child, SIGTERM) == 0);
  CHECK(waitpid(child, &status, 0) == child && WIFSIGNALED(status) && WTERMSIG(status) == SIGTERM);
  CHECK(spawn_child("sleep", nullptr, &child) == 0 && kill(child, SIGKILL) == 0);
  CHECK(waitpid(child, &status, 0) == child && WIFSIGNALED(status) && WTERMSIG(status) == SIGKILL);
  CHECK(spawn_child("segv", nullptr, &child) == 0);
  CHECK(waitpid(child, &status, 0) == child && WIFSIGNALED(status) && WTERMSIG(status) == SIGSEGV);
  { // and its crash directory (05 §5), its note the fault in Plan 9's words
    char path[64], note[96] = {};
    snprintf(path, sizeof path, "%s/%s.%d/note", crash_dir, self_name, (int)child);
    int fd = open(path, O_RDONLY);
    CHECK(fd >= 0 && read(fd, note, sizeof note - 1) > 0 &&
          strncmp(note, "sys: trap: fault read addr=0x10", 31) == 0);
    if (fd >= 0) close(fd);
    snprintf(path, sizeof path, "%s/%s.%d/threads/1/regs.ndb", crash_dir, self_name, (int)child);
    struct stat cst;
    CHECK(stat(path, &cst) == 0 && cst.st_size > 0);
  }
  errno = 0;
  CHECK(kill(99999, SIGTERM) == -1 && errno == ESRCH);

  // A fault caught, and left by siglongjmp.
  struct sigaction fault = {.sa_sigaction = on_fault, .sa_flags = SA_SIGINFO};
  CHECK(sigaction(SIGSEGV, &fault, nullptr) == 0);
  if (sigsetjmp(fault_jump, 1) == 0) (void)*nowhere_at();
  CHECK(signals[SIGSEGV] == 1 && fault_address == (void *)nowhere_at());
  signal(SIGSEGV, SIG_DFL);

  // SIGCHLD, after the wait's answer.
  CHECK(sigaction(SIGCHLD, &(struct sigaction){.sa_handler = on_signal, .sa_flags = SA_RESTART}, nullptr) ==
        0);
  // An earlier child's may still be on its way: this one's adds at least one.
  int before = signals[SIGCHLD];
  CHECK(spawn_child("exit", nullptr, &child) == 0);
  CHECK(waitpid(child, &status, 0) == child);
  for (double end = now_seconds() + 1; signals[SIGCHLD] <= before && now_seconds() < end;) sched_yield();
  CHECK(signals[SIGCHLD] > before);
  signal(SIGCHLD, SIG_DFL);

  // A sleep a handler interrupts ends with EINTR and what was left; one that
  // an ignored signal (SIGCHLD by default) interrupts goes on to its end.
  CHECK(sigaction(SIGUSR1, &sa, nullptr) == 0); // not SA_RESTART
  CHECK(spawn_child("late", nullptr, &child) == 0);
  struct timespec rem = {};
  double t0 = now_seconds();
  CHECK(nanosleep(&(struct timespec){.tv_sec = 2}, &rem) == -1 && errno == EINTR && rem.tv_sec >= 1);
  CHECK(now_seconds() - t0 < 1.5);
  CHECK(waitpid(child, &status, 0) == child && WEXITSTATUS(status) == 14);
  CHECK(spawn_child("exit", nullptr, &child) == 0); // its SIGCHLD comes during the sleep
  t0 = now_seconds();
  CHECK(nanosleep(&(struct timespec){.tv_nsec = 300'000'000}, nullptr) == 0 && now_seconds() - t0 >= 0.3);
  CHECK(waitpid(child, &status, 0) == child);

  // A blocked signal ends no call: the sleep goes on, and the handler runs
  // once it is let through.
  int had = signals[SIGUSR1];
  CHECK(sigprocmask(SIG_BLOCK, &usr1, nullptr) == 0 && spawn_child("late", nullptr, &child) == 0);
  t0 = now_seconds();
  CHECK(nanosleep(&(struct timespec){.tv_nsec = 300'000'000}, nullptr) == 0 && now_seconds() - t0 >= 0.3);
  CHECK(signals[SIGUSR1] == had && sigpending(&pending) == 0 && sigismember(&pending, SIGUSR1));

  // A forked child has none of its parent's pending signals.
  child = fork();
  if (child == 0) _exit(sigpending(&pending) == 0 && !sigismember(&pending, SIGUSR1) ? 0 : 1);
  CHECK(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0);
  CHECK(sigprocmask(SIG_UNBLOCK, &usr1, nullptr) == 0 && signals[SIGUSR1] == had + 1);
  CHECK(waitpid(-1, &status, 0) > 0); // the late child

  // posix_spawn keeps what is ignored and the mask, but what SETSIGDEF names.
  CHECK(signal(SIGUSR2, SIG_IGN) != SIG_ERR && signal(SIGHUP, SIG_IGN) != SIG_ERR);
  CHECK(sigprocmask(SIG_BLOCK, &usr1, nullptr) == 0);
  posix_spawnattr_t defaults;
  sigset_t hup;
  sigemptyset(&hup);
  sigaddset(&hup, SIGHUP);
  posix_spawnattr_init(&defaults);
  posix_spawnattr_setflags(&defaults, POSIX_SPAWN_SETSIGDEF);
  posix_spawnattr_setsigdefault(&defaults, &hup);
  CHECK(spawn_wait(self, false, "kept", &defaults) == 23);
  posix_spawnattr_destroy(&defaults);
  CHECK(sigprocmask(SIG_UNBLOCK, &usr1, nullptr) == 0);
  signal(SIGUSR2, SIG_DFL);
  signal(SIGHUP, SIG_DFL);
  signal(SIGUSR1, SIG_DFL);

  // A timeout that is not one.
  errno = 0;
  CHECK(pselect(0, nullptr, nullptr, nullptr, &(struct timespec){.tv_nsec = 2'000'000'000}, nullptr) == -1 &&
        errno == EINVAL);
}

// Text is UTF-8 (ADR-0013): a program that asks for the environment's locale
// gets C.UTF-8, one that does not keeps POSIX's byte-based "C", and a name
// that is not UTF-8, or holds a control character, is refused (EILSEQ).
static void test_utf8(void) {
  CHECK(MB_CUR_MAX == 1); // "C", until setlocale
  const char *name = setlocale(LC_CTYPE, "");
  CHECK(name && strcmp(name, "C.UTF-8") == 0 && MB_CUR_MAX == 4);
  wchar_t w = 0;
  mbstate_t st = {};
  CHECK(mbrtowc(&w, "\xc3\xa9", 2, &st) == 2 && w == 0xe9);
  char32_t c = 0;
  st = (mbstate_t){};
  CHECK(mbrtoc32(&c, "\xe2\x82\xac", 3, &st) == 3 && c == 0x20ac);
  st = (mbstate_t){};
  errno = 0;
  CHECK(mbrtowc(&w, "\xc0\x80", 2, &st) == (size_t)-1 && errno == EILSEQ); // overlong
  errno = 0;
  CHECK(open("/tmp/bad\nname", O_WRONLY | O_CREAT, 0644) == -1 && errno == EILSEQ);
  errno = 0;
  CHECK(mkdir("/tmp/\xc3", 0755) == -1 && errno == EILSEQ);
  int fd = open("/tmp/caf\xc3\xa9", O_WRONLY | O_CREAT, 0644); // UTF-8 names are fine
  CHECK(fd >= 0 && close(fd) == 0 && unlink("/tmp/caf\xc3\xa9") == 0);
  // A name that exists is EEXIST, even where the server refuses to create
  // (bootfs, read-only, holds the /tmp mount point).
  errno = 0;
  CHECK(mkdir("/tmp", 0755) == -1 && errno == EEXIST);
  errno = 0;
  CHECK(open("/tmp", O_WRONLY | O_CREAT | O_EXCL, 0644) == -1 && errno == EEXIST);
  setlocale(LC_CTYPE, "C");
}

// Sockets over /net (01 §9), on netd's loopback: TCP's connect, accept and
// data both ways, a forked child writing on the socket it inherited, the end
// of the stream after shutdown, a refused connection; UDP's sendto and
// recvfrom with addresses, and connect.
static struct sockaddr_in loopback(uint16_t port) {
  return (struct sockaddr_in){
      .sin_family = AF_INET, .sin_port = htons(port), .sin_addr = {htonl(INADDR_LOOPBACK)}};
}

static uint16_t port_of(int fd) {
  struct sockaddr_in a = {};
  socklen_t len = sizeof a;
  if (fd < 0) return 0;
  return getsockname(fd, (struct sockaddr *)&a, &len) == 0 && len == sizeof a ? ntohs(a.sin_port) : 0;
}

static void test_sockets(void) {
  int l = -1;
  for (int tries = 0; tries < 50; tries++) { // netd may not have its driver yet
    l = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (l >= 0 || errno != ENETDOWN) break;
    nanosleep(&(struct timespec){.tv_nsec = 100'000'000}, nullptr);
  }
  CHECK(l >= 0);
  if (l < 0) return;
  int one = 1;
  struct sockaddr_in any = loopback(0);
  CHECK(setsockopt(l, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one) == 0);
  CHECK(bind(l, (struct sockaddr *)&any, sizeof any) == 0 && listen(l, 4) == 0);
  uint16_t port = port_of(l);
  CHECK(port != 0);
  int c = socket(AF_INET, SOCK_STREAM, 0);
  struct sockaddr_in to = loopback(port);
  CHECK(c >= 0 && connect(c, (struct sockaddr *)&to, sizeof to) == 0);
  struct sockaddr_in peer = {};
  socklen_t plen = sizeof peer;
  int a = accept(l, (struct sockaddr *)&peer, &plen);
  CHECK(a >= 0 && plen == sizeof peer && peer.sin_addr.s_addr == htonl(INADDR_LOOPBACK) &&
        ntohs(peer.sin_port) == port_of(c));
  if (c < 0 || a < 0) return;
  plen = sizeof peer;
  CHECK(getpeername(c, (struct sockaddr *)&peer, &plen) == 0 && ntohs(peer.sin_port) == port);
  char buf[64] = {};
  CHECK(write(c, "hello", 5) == 5 && read(a, buf, sizeof buf) == 5 && memcmp(buf, "hello", 5) == 0);
  CHECK(send(a, "back", 4, 0) == 4 && recv(c, buf, sizeof buf, 0) == 4 && memcmp(buf, "back", 4) == 0);
  struct stat st;
  int type = 0;
  socklen_t tlen = sizeof type;
  CHECK(fstat(c, &st) == 0 && S_ISSOCK(st.st_mode) && lseek(c, 0, SEEK_SET) == -1 && errno == ESPIPE);
  CHECK(getsockopt(c, SOL_SOCKET, SO_TYPE, &type, &tlen) == 0 && type == SOCK_STREAM);
  pid_t pid = fork(); // the child's socket is the same conversation, opened again
  if (pid == 0) _exit(write(c, "child", 5) == 5 ? 0 : 1);
  int status = 0;
  CHECK(pid > 0 && waitpid(pid, &status, 0) == pid && WIFEXITED(status) && WEXITSTATUS(status) == 0);
  CHECK(recv(a, buf, 5, MSG_WAITALL) == 5 && memcmp(buf, "child", 5) == 0);
  posix_spawn_file_actions_t fa; // and a spawned one's, by exec's descriptor records
  posix_spawn_file_actions_init(&fa);
  posix_spawn_file_actions_adddup2(&fa, c, 3);
  CHECK(spawn_child("socket", &fa, &pid) == 0 && waitpid(pid, &status, 0) == pid && WIFEXITED(status) &&
        WEXITSTATUS(status) == 16);
  posix_spawn_file_actions_destroy(&fa);
  CHECK(recv(a, buf, 7, MSG_WAITALL) == 7 && memcmp(buf, "spawned", 7) == 0);
  CHECK(shutdown(c, SHUT_WR) == 0 && read(a, buf, sizeof buf) == 0); // the end of the stream
  CHECK(close(a) == 0 && close(c) == 0 && close(l) == 0);
  c = socket(AF_INET, SOCK_STREAM, 0);
  CHECK(c >= 0);
  if (c < 0) return;
  to = loopback(1); // nobody listens
  CHECK(connect(c, (struct sockaddr *)&to, sizeof to) == -1 && errno == ECONNREFUSED);
  close(c);

  int u1 = socket(AF_INET, SOCK_DGRAM, 0), u2 = socket(AF_INET, SOCK_DGRAM, 0);
  CHECK(u1 >= 0 && u2 >= 0);
  if (u1 < 0 || u2 < 0) return;
  CHECK(bind(u1, (struct sockaddr *)&any, sizeof any) == 0);
  uint16_t p1 = port_of(u1);
  to = loopback(p1);
  CHECK(p1 != 0 && sendto(u2, "ping", 4, 0, (struct sockaddr *)&to, sizeof to) == 4);
  struct sockaddr_in from = {};
  socklen_t flen = sizeof from;
  CHECK(recvfrom(u1, buf, sizeof buf, 0, (struct sockaddr *)&from, &flen) == 4 &&
        memcmp(buf, "ping", 4) == 0);
  CHECK(from.sin_addr.s_addr == htonl(INADDR_LOOPBACK) && ntohs(from.sin_port) == port_of(u2));
  CHECK(sendto(u1, "pong", 4, 0, (struct sockaddr *)&from, flen) == 4 && recv(u2, buf, sizeof buf, 0) == 4 &&
        memcmp(buf, "pong", 4) == 0);
  CHECK(connect(u2, (struct sockaddr *)&to, sizeof to) == 0 && send(u2, "conn", 4, 0) == 4 &&
        read(u1, buf, sizeof buf) == 4 && memcmp(buf, "conn", 4) == 0);
  CHECK(close(u1) == 0 && close(u2) == 0);
  CHECK(socket(AF_INET6, SOCK_STREAM, 0) == -1 && errno == EAFNOSUPPORT);
}

// Sockets that do not wait (4h2): accept and connect without waiting, poll
// and select on sockets, MSG_DONTWAIT and MSG_PEEK, a writer that fills
// netd's buffer and waits for POLLOUT, a refused connect seen through
// SO_ERROR, a wait a signal ends (EINTR), and SIGPIPE.
static short poll_one(int fd, short events, int ms) {
  struct pollfd p = {.fd = fd, .events = events};
  return poll(&p, 1, ms) == 1 ? p.revents : 0;
}

static void test_sockets_waiting(void) {
  int l = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
  struct sockaddr_in any = loopback(0);
  CHECK(l >= 0 && bind(l, (struct sockaddr *)&any, sizeof any) == 0 && listen(l, 4) == 0);
  if (l < 0) return;
  CHECK(accept(l, nullptr, nullptr) == -1 && errno == EAGAIN && poll_one(l, POLLIN, 0) == 0);
  struct sockaddr_in to = loopback(port_of(l));
  int c = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
  CHECK(c >= 0 && connect(c, (struct sockaddr *)&to, sizeof to) == -1 && errno == EINPROGRESS);
  if (c < 0) return;
  int err = -1;
  socklen_t elen = sizeof err;
  CHECK((poll_one(c, POLLOUT, 2000) & POLLOUT) && getsockopt(c, SOL_SOCKET, SO_ERROR, &err, &elen) == 0 &&
        err == 0);
  CHECK(poll_one(l, POLLIN, 2000) & POLLIN);
  int a = accept4(l, nullptr, nullptr, SOCK_NONBLOCK);
  CHECK(a >= 0);
  if (a < 0) return;
  char buf[256];
  CHECK(recv(a, buf, sizeof buf, MSG_DONTWAIT) == -1 && errno == EAGAIN && poll_one(a, POLLIN, 0) == 0);
  CHECK(send(c, "xy", 2, 0) == 2 && (poll_one(a, POLLIN, 2000) & POLLIN));
  CHECK(recv(a, buf, 1, MSG_PEEK) == 1 && buf[0] == 'x' && recv(a, buf, sizeof buf, 0) == 2 && buf[1] == 'y');
  fd_set rd;
  FD_ZERO(&rd);
  FD_SET(a, &rd);
  CHECK(send(c, "z", 1, 0) == 1 &&
        select(a + 1, &rd, nullptr, nullptr, &(struct timeval){.tv_sec = 2}) == 1 && FD_ISSET(a, &rd) &&
        read(a, buf, sizeof buf) == 1);

  // A writer that does not wait fills netd's buffers, and is writable again
  // once the reader has taken it all.
  static char chunk[4096];
  memset(chunk, 'w', sizeof chunk);
  size_t sent = 0;
  for (int i = 0; i < 4096; i++) {
    ssize_t w = send(c, chunk, sizeof chunk, 0);
    if (w < 0) break;
    sent += (size_t)w;
  }
  CHECK(errno == EAGAIN && sent > 0 && poll_one(c, POLLOUT, 0) == 0);
  size_t got = 0;
  bool same = true;
  while (got < sent && (poll_one(a, POLLIN, 2000) & POLLIN)) {
    ssize_t r = read(a, buf, sizeof buf);
    if (r <= 0) break;
    for (ssize_t i = 0; i < r; i++) same = same && buf[i] == 'w';
    got += (size_t)r;
  }
  CHECK(got == sent && same && (poll_one(c, POLLOUT, 2000) & POLLOUT));

  // A read that waits, and a signal (no SA_RESTART): EINTR; then the data.
  CHECK(sigaction(SIGUSR1, &(struct sigaction){.sa_handler = on_signal}, nullptr) == 0);
  int flags = fcntl(a, F_GETFL);
  CHECK(fcntl(a, F_SETFL, flags & ~O_NONBLOCK) == 0);
  pid_t child;
  int status = 0;
  CHECK(spawn_child("late", nullptr, &child) == 0);
  CHECK(read(a, buf, sizeof buf) == -1 && errno == EINTR);
  CHECK(waitpid(child, &status, 0) == child && WEXITSTATUS(status) == 14);
  CHECK(send(c, "after", 5, 0) == 5 && recv(a, buf, 5, MSG_WAITALL) == 5 && memcmp(buf, "after", 5) == 0);
  signal(SIGUSR1, SIG_DFL);

  // SIGPIPE: a write after shutdown raises it, unless MSG_NOSIGNAL; a pipe's too.
  CHECK(sigaction(SIGPIPE, &(struct sigaction){.sa_handler = on_signal}, nullptr) == 0);
  int before = signals[SIGPIPE];
  CHECK(shutdown(c, SHUT_WR) == 0);
  CHECK(poll_one(c, POLLOUT, 2000) & POLLOUT); // what was written behind has gone
  CHECK(send(c, "x", 1, MSG_NOSIGNAL) == -1 && errno == EPIPE && signals[SIGPIPE] == before);
  CHECK(write(c, "x", 1) == -1 && errno == EPIPE && signals[SIGPIPE] == before + 1);
  int p[2];
  CHECK(pipe(p) == 0 && close(p[0]) == 0 && write(p[1], "x", 1) == -1 && errno == EPIPE &&
        signals[SIGPIPE] == before + 2 && close(p[1]) == 0);
  signal(SIGPIPE, SIG_DFL);
  CHECK(close(a) == 0 && close(c) == 0 && close(l) == 0);

  // A refused connect that did not wait: POLLERR, and the reason in SO_ERROR.
  c = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
  to = loopback(1);
  CHECK(c >= 0 && connect(c, (struct sockaddr *)&to, sizeof to) == -1 && errno == EINPROGRESS);
  CHECK((poll_one(c, POLLOUT, 2000) & POLLERR) && getsockopt(c, SOL_SOCKET, SO_ERROR, &err, &elen) == 0 &&
        err == ECONNREFUSED);
  close(c);
}

static bool all_zero(const unsigned char *p, size_t n) {
  for (size_t i = 0; i < n; i++)
    if (p[i]) return false;
  return true;
}

static bool write_file(const char *path, const char *text) {
  FILE *f = fopen(path, "w");
  bool ok = f && fputs(text, f) >= 0;
  return f && fclose(f) == 0 && ok;
}

static bool file_is(const char *path, const char *text) {
  char buf[64] = {};
  FILE *f = fopen(path, "r");
  size_t n = f ? fread(buf, 1, sizeof buf - 1, f) : 0;
  if (f) fclose(f);
  return f && n == strlen(text) && memcmp(buf, text, n) == 0;
}

// /tmp (tmpfs), /dev's null, zero and urandom (nullfs), getrandom.
static void test_tmp_and_devices(void) {
  char buf[64] = {};
  errno = 0;
  CHECK(mkdir("/tmp/d", 0755) == 0);
  CHECK(mkdir("/tmp/d", 0755) == -1 && errno == EEXIST); // made already
  FILE *f = fopen("/tmp/d/a.txt", "w");
  CHECK(f && fputs("hello tmp\n", f) >= 0 && fclose(f) == 0);
  struct stat st;
  CHECK(stat("/tmp/d/a.txt", &st) == 0 && S_ISREG(st.st_mode) && st.st_size == 10);
  f = fopen("/tmp/d/a.txt", "a");
  CHECK(f && fputs("more\n", f) >= 0 && fclose(f) == 0);
  f = fopen("/tmp/d/a.txt", "r");
  CHECK(f && fread(buf, 1, sizeof buf - 1, f) == 15 && strcmp(buf, "hello tmp\nmore\n") == 0);
  if (f) fclose(f);
  DIR *d = opendir("/tmp/d");
  struct dirent *e = d ? readdir(d) : nullptr;
  CHECK(e && strcmp(e->d_name, "a.txt") == 0 && !readdir(d));
  if (d) closedir(d);

  // Removed while open: gone from its directory, still readable.
  int fd = open("/tmp/d/a.txt", O_RDONLY);
  CHECK(fd >= 0 && unlink("/tmp/d/a.txt") == 0);
  errno = 0;
  CHECK(stat("/tmp/d/a.txt", &st) == -1 && errno == ENOENT);
  memset(buf, 0, sizeof buf);
  CHECK(read(fd, buf, 5) == 5 && memcmp(buf, "hello", 5) == 0);
  close(fd);

  // O_EXCL refuses a name that exists without touching the file, even with
  // O_TRUNC; without O_EXCL, O_CREAT opens it.
  CHECK(write_file("/tmp/d/keep", "kept"));
  errno = 0;
  CHECK(open("/tmp/d/keep", O_RDWR | O_CREAT | O_EXCL | O_TRUNC, 0644) == -1 && errno == EEXIST);
  CHECK(file_is("/tmp/d/keep", "kept"));
  fd = open("/tmp/d/keep", O_RDWR | O_CREAT, 0644);
  CHECK(fd >= 0 && read(fd, buf, 4) == 4 && memcmp(buf, "kept", 4) == 0);
  close(fd);
  fd = open("/tmp/d/new", O_RDWR | O_CREAT | O_EXCL, 0644);
  CHECK(fd >= 0 && write(fd, "x", 1) == 1);
  close(fd);
  CHECK(unlink("/tmp/d/keep") == 0 && unlink("/tmp/d/new") == 0);

  // A hole reads as zeros; truncation; a directory goes only when empty.
  fd = open("/tmp/d/hole", O_RDWR | O_CREAT, 0644);
  CHECK(fd >= 0 && pwrite(fd, "x", 1, 100) == 1);
  if (fd < 0) return; // the rest needs it
  unsigned char c = 0xff;
  CHECK(pread(fd, &c, 1, 50) == 1 && c == 0 && fstat(fd, &st) == 0 && st.st_size == 101);
  close(fd);
  CHECK(rmdir("/tmp/d") == -1); // not empty
  fd = open("/tmp/d/hole", O_WRONLY | O_TRUNC);
  CHECK(fd >= 0 && fstat(fd, &st) == 0 && st.st_size == 0);
  close(fd);
  CHECK(unlink("/tmp/d/hole") == 0 && rmdir("/tmp/d") == 0);
  errno = 0;
  CHECK(opendir("/tmp/d") == nullptr && errno == ENOENT);

  // /dev.
  fd = open("/dev/null", O_RDWR);
  CHECK(fd >= 0 && write(fd, "gone", 4) == 4 && read(fd, buf, sizeof buf) == 0);
  close(fd);
  unsigned char zeros[16], r1[32] = {}, r2[32] = {};
  memset(zeros, 0xff, sizeof zeros);
  fd = open("/dev/zero", O_RDONLY);
  CHECK(fd >= 0 && read(fd, zeros, sizeof zeros) == 16 && all_zero(zeros, sizeof zeros));
  close(fd);
  fd = open("/dev/urandom", O_RDONLY);
  CHECK(fd >= 0 && read(fd, r1, sizeof r1) == 32 && read(fd, r2, sizeof r2) == 32);
  CHECK(!all_zero(r1, sizeof r1) && memcmp(r1, r2, sizeof r1) != 0);
  close(fd);
  CHECK(getrandom(r1, sizeof r1, 0) == 32 && memcmp(r1, r2, sizeof r1) != 0 && !all_zero(r1, sizeof r1));
  CHECK(getauxval(AT_RANDOM) != 0);
}

// The posix and xattr extensions, through tmpfs: rename, symbolic links,
// chmod, truncate, utimensat, fsync.
static void test_names_and_attributes(void) {
  struct stat st;
  char buf[64] = {};
  CHECK(write_file("/tmp/r1", "renamed") && mkdir("/tmp/rd", 0755) == 0);
  CHECK(rename("/tmp/r1", "/tmp/r2") == 0 && stat("/tmp/r1", &st) == -1 && file_is("/tmp/r2", "renamed"));
  CHECK(rename("/tmp/r2", "/tmp/rd/r3") == 0 && file_is("/tmp/rd/r3", "renamed")); // across directories
  CHECK(write_file("/tmp/other", "replaced") && rename("/tmp/other", "/tmp/rd/r3") == 0);
  CHECK(file_is("/tmp/rd/r3", "replaced") && stat("/tmp/other", &st) == -1);
  errno = 0;
  CHECK(rename("/tmp/rd", "/tmp/rd/inside") == -1 && errno == EINVAL);
  errno = 0;
  CHECK(rename("/tmp/rd/r3", "/boot/r3") == -1 && errno == EXDEV); // another server

  // Symbolic links: read, followed (at the end and on the way), or not.
  CHECK(symlink("rd/r3", "/tmp/ln") == 0);
  ssize_t n = readlink("/tmp/ln", buf, sizeof buf);
  CHECK(n == 5 && memcmp(buf, "rd/r3", 5) == 0);
  CHECK(lstat("/tmp/ln", &st) == 0 && S_ISLNK(st.st_mode));
  CHECK(stat("/tmp/ln", &st) == 0 && S_ISREG(st.st_mode) && st.st_size == 8 &&
        file_is("/tmp/ln", "replaced"));
  CHECK(symlink("/tmp/rd", "/tmp/dl") == 0 && file_is("/tmp/dl/r3", "replaced"));
  bool saw_link = false;
  DIR *d = opendir("/tmp");
  for (struct dirent *e; d && (e = readdir(d));)
    if (strcmp(e->d_name, "ln") == 0) saw_link = e->d_type == DT_LNK;
  if (d) closedir(d);
  CHECK(saw_link);
  CHECK(symlink("/tmp/nothing", "/tmp/dangling") == 0 && lstat("/tmp/dangling", &st) == 0);
  errno = 0;
  CHECK(stat("/tmp/dangling", &st) == -1 && errno == ENOENT);
  errno = 0; // O_EXCL doesn't follow it: the name is taken, and its target isn't made
  CHECK(open("/tmp/dangling", O_WRONLY | O_CREAT | O_EXCL, 0644) == -1 && errno == EEXIST &&
        stat("/tmp/nothing", &st) == -1);
  CHECK(symlink("/tmp/loop", "/tmp/loop") == 0);
  errno = 0;
  CHECK(open("/tmp/loop", O_RDONLY) == -1 && errno == ELOOP);
  errno = 0;
  CHECK(open("/tmp/ln", O_RDONLY | O_NOFOLLOW) == -1 && errno == ELOOP);
  CHECK(unlink("/tmp/ln") == 0 && lstat("/tmp/ln", &st) == -1 &&
        stat("/tmp/rd/r3", &st) == 0); // the link only
  errno = 0;
  CHECK(readlink("/tmp/rd/r3", buf, sizeof buf) == -1 && errno == EINVAL); // not a link

  // Attributes.
  CHECK(chmod("/tmp/rd/r3", 0600) == 0 && stat("/tmp/rd/r3", &st) == 0 && (st.st_mode & 0777) == 0600);
  int fd = open("/tmp/rd/r3", O_RDWR);
  CHECK(fd >= 0);
  if (fd < 0) return; // the rest needs it
  CHECK(fchmod(fd, 0640) == 0 && fstat(fd, &st) == 0 && (st.st_mode & 0777) == 0640);
  CHECK(truncate("/tmp/rd/r3", 3) == 0 && stat("/tmp/rd/r3", &st) == 0 && st.st_size == 3);
  CHECK(ftruncate(fd, 10) == 0 && fstat(fd, &st) == 0 && st.st_size == 10);
  unsigned char tail[7];
  memset(tail, 0xff, sizeof tail);
  CHECK(pread(fd, tail, sizeof tail, 3) == 7 && all_zero(tail, sizeof tail)); // grown with zeros
  CHECK(fsync(fd) == 0 && fdatasync(fd) == 0);
  CHECK(utimensat(AT_FDCWD, "/tmp/rd/r3", (struct timespec[]){{.tv_nsec = UTIME_OMIT}, {.tv_sec = 1000}},
                  0) == 0);
  CHECK(stat("/tmp/rd/r3", &st) == 0 && st.st_mtime == 1000);
  CHECK(futimens(fd, nullptr) == 0 && fstat(fd, &st) == 0 && st.st_mtime != 1000); // now
  // tmpfs keeps no owners, so any change succeeds; fsd's are adm's to give,
  // and the user ctestfsd runs as is in adm (host/vxfs mkfs's /adm/users).
  CHECK(chown("/tmp/rd/r3", 0, 0) == 0);
  errno = 0;
  CHECK(link("/tmp/rd/r3", "/tmp/hard") == -1 && errno == EPERM);
  close(fd);
  CHECK(unlink("/tmp/dl") == 0 && unlink("/tmp/dangling") == 0 && unlink("/tmp/loop") == 0);
  CHECK(unlink("/tmp/rd/r3") == 0 && rmdir("/tmp/rd") == 0);
}

// Permissions, where the server keeps them: a directory without w takes no
// new entries, a file without w opens for no writing, and the owner may
// change both back.
// mmap of files: on fsd, its page cache, shared by every mapping; elsewhere
// MAP_SHARED is refused and MAP_PRIVATE is a copy.
static void test_mmap(void) {
  int fd = open("/tmp/mapped", O_RDWR | O_CREAT | O_TRUNC, 0644);
  CHECK(fd >= 0);
  if (fd < 0) return;
  char page[4096];
  for (int i = 0; i < 3; i++) {
    memset(page, 'a' + i, sizeof page);
    CHECK(write(fd, page, sizeof page) == (ssize_t)sizeof page);
  }
  CHECK(write(fd, "tail", 4) == 4); // 3 pages and 4 bytes
  errno = 0;
  char *p = mmap(nullptr, 16384, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  if (!maps_shared) {
    CHECK(p == MAP_FAILED && errno == ENODEV);
    p = mmap(nullptr, 16384, PROT_READ, MAP_PRIVATE, fd, 4096); // a copy
    CHECK(p != MAP_FAILED && p[0] == 'b' && p[8192] == 't' && p[8196] == 0);
    if (p != MAP_FAILED) munmap(p, 16384);
    close(fd);
    unlink("/tmp/mapped");
    return;
  }
  CHECK(p != MAP_FAILED);
  if (p == MAP_FAILED) return;
  CHECK(p[0] == 'a' && p[4095] == 'a' && p[4096] == 'b' && p[12288] == 't' && p[12292] == 0);
  // Written through the mapping, read with read(); written with write(), seen in the mapping.
  p[5000] = 'Z';
  char c = 0;
  CHECK(pread(fd, &c, 1, 5000) == 1 && c == 'Z');
  CHECK(pwrite(fd, "Y", 1, 6000) == 1 && p[6000] == 'Y');
  // A forked child shares the mapping: what it writes, its parent sees.
  pid_t pid = fork();
  if (pid == 0) {
    p[100] = 'C';
    _exit(0);
  }
  int status = -1;
  CHECK(pid > 0 && waitpid(pid, &status, 0) == pid && status == 0 && p[100] == 'C');
  // A second mapping, read-only and private, is the same pages, not a copy.
  char *q = mmap(nullptr, 8192, PROT_READ, MAP_PRIVATE, fd, 4096);
  CHECK(q != MAP_FAILED);
  if (q != MAP_FAILED) {
    CHECK(q[5000 - 4096] == 'Z');
    p[7000] = 'W';
    CHECK(q[7000 - 4096] == 'W');
    munmap(q, 8192);
  }
  CHECK(msync(p, 16384, MS_SYNC) == 0 && fsync(fd) == 0);
  // Truncated: past the end, zeros, in the mapping and in the file grown again.
  CHECK(ftruncate(fd, 4106) == 0 && p[4100] == 'b' && p[5000] == 0);
  CHECK(ftruncate(fd, 8192) == 0 && pread(fd, &c, 1, 5000) == 1 && c == 0);
  CHECK(munmap(p, 16384) == 0);
  // What the descriptor allows: a shared writable mapping needs O_RDWR.
  int ro = open("/tmp/mapped", O_RDONLY);
  errno = 0;
  CHECK(mmap(nullptr, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, ro, 0) == MAP_FAILED && errno == EACCES);
  p = mmap(nullptr, 4096, PROT_READ, MAP_SHARED, ro, 0);
  CHECK(p != MAP_FAILED && p[100] == 'C');
  if (p != MAP_FAILED) munmap(p, 4096);
  close(ro);
  // Removed while mapped: its pages still come, until the mapping goes.
  p = mmap(nullptr, 8192, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  close(fd);
  CHECK(p != MAP_FAILED && unlink("/tmp/mapped") == 0);
  if (p != MAP_FAILED) {
    CHECK(p[4100] == 'b' && p[0] == 'a');
    munmap(p, 8192);
  }
  CHECK(access("/tmp/mapped", F_OK) == -1);

  // Written in many places through a mapping (more dirty ranges than one
  // DIRTY call answers), unmapped at once: every write reaches the file.
  static constexpr size_t PAGES = 160;
  fd = open("/tmp/many", O_RDWR | O_CREAT | O_TRUNC, 0644);
  CHECK(fd >= 0 && ftruncate(fd, (off_t)(PAGES * 4096)) == 0);
  p = mmap(nullptr, PAGES * 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  CHECK(p != MAP_FAILED);
  if (p != MAP_FAILED) {
    for (size_t i = 0; i < PAGES; i += 2) p[i * 4096 + 7] = (char)('A' + i % 26);
    CHECK(munmap(p, PAGES * 4096) == 0);
  }
  size_t right = 0;
  for (size_t i = 0; i < PAGES; i += 2)
    right += pread(fd, &c, 1, (off_t)(i * 4096 + 7)) == 1 && c == (char)('A' + i % 26);
  CHECK(right == PAGES / 2);
  // Mapped past the file's end: the file's pages there, the rest not.
  CHECK(ftruncate(fd, 100) == 0);
  p = mmap(nullptr, 3ul * 4096, PROT_READ, MAP_SHARED, fd, 0);
  CHECK(p != MAP_FAILED && p[7] == 'A' && p[100] == 0);
  if (p != MAP_FAILED) munmap(p, 3ul * 4096);
  close(fd);
  unlink("/tmp/many");

  // Renamed over while open: the open file is still the old one.
  int old = open("/tmp/r-old", O_RDWR | O_CREAT | O_TRUNC, 0644);
  CHECK(old >= 0 && write(old, "old", 3) == 3);
  int fresh = open("/tmp/r-new", O_RDWR | O_CREAT | O_TRUNC, 0644);
  CHECK(fresh >= 0 && write(fresh, "new", 3) == 3 && close(fresh) == 0);
  CHECK(rename("/tmp/r-new", "/tmp/r-old") == 0);
  char got[4] = {};
  CHECK(pread(old, got, 3, 0) == 3 && memcmp(got, "old", 3) == 0);
  CHECK(close(old) == 0);
  fresh = open("/tmp/r-old", O_RDONLY);
  CHECK(fresh >= 0 && read(fresh, got, 3) == 3 && memcmp(got, "new", 3) == 0);
  close(fresh);
  unlink("/tmp/r-old");
}

static void test_permissions(void) {
  if (!owners_kept) return;
  // Owners are adm's to give (vectra is a member); but through an ordinary
  // attach an adm member gets no more than anyone else, so a group the
  // file's new owner's rules do not allow is refused (gefs: only the
  // permissive attach bypasses them).
  int given = open("/tmp/given", O_RDWR | O_CREAT | O_TRUNC, 0644);
  CHECK(given >= 0);
  if (given < 0) return;
  CHECK(fchown(given, 0, (gid_t)-1) == 0);
  errno = 0;
  CHECK(fchown(given, (uid_t)-1, 0) == -1 && errno == EPERM);
  close(given);
  unlink("/tmp/given");
  CHECK(mkdir("/tmp/locked", 0755) == 0 && chmod("/tmp/locked", 0555) == 0);
  errno = 0;
  CHECK(open("/tmp/locked/x", O_WRONLY | O_CREAT, 0644) == -1 && errno == EACCES);
  errno = 0;
  CHECK(mkdir("/tmp/locked/d", 0755) == -1 && errno == EACCES);
  CHECK(chmod("/tmp/locked", 0755) == 0);
  int fd = open("/tmp/locked/x", O_WRONLY | O_CREAT, 0644);
  CHECK(fd >= 0 && write(fd, "x", 1) == 1 && close(fd) == 0);
  CHECK(chmod("/tmp/locked/x", 0444) == 0);
  errno = 0;
  CHECK(open("/tmp/locked/x", O_WRONLY) == -1 && errno == EACCES);
  fd = open("/tmp/locked/x", O_RDONLY);
  CHECK(fd >= 0 && close(fd) == 0);
  CHECK(chmod("/tmp/locked/x", 0644) == 0 && unlink("/tmp/locked/x") == 0 && rmdir("/tmp/locked") == 0);
}

// The posix extension's open files, kept by the server: a child's writes
// move its parent's offset; O_APPEND is the server's; locks between
// processes.
static void test_shared_offsets_and_locks(void) {
  struct stat st;
  int status = 0;
  int fd = open("/tmp/shared", O_RDWR | O_CREAT | O_TRUNC, 0644);
  CHECK(fd >= 0);
  if (fd < 0) return;
  CHECK(write(fd, "ab", 2) == 2);
  pid_t child = fork();
  if (child == 0) _exit(write(fd, "cd", 2) == 2 ? 0 : 1); // at the offset it shares
  CHECK(child > 0 && waitpid(child, &status, 0) == child && WEXITSTATUS(status) == 0);
  CHECK(lseek(fd, 0, SEEK_CUR) == 4 && write(fd, "ef", 2) == 2 && file_is("/tmp/shared", "abcdef"));
  CHECK(lseek(fd, -1, SEEK_END) == 5);

  // A child's standard output, twice, then the parent's: in that order.
  int out = open("/tmp/sequence", O_WRONLY | O_CREAT | O_TRUNC, 0644);
  CHECK(out >= 0);
  posix_spawn_file_actions_t fa;
  posix_spawn_file_actions_init(&fa);
  posix_spawn_file_actions_adddup2(&fa, out, 1);
  for (int i = 0; i < 2; i++) {
    CHECK(spawn_child("echo", &fa, &child) == 0);
    CHECK(waitpid(child, &status, 0) == child && WEXITSTATUS(status) == 8);
  }
  posix_spawn_file_actions_destroy(&fa);
  CHECK(write(out, "parent\n", 7) == 7);
  close(out);
  CHECK(file_is("/tmp/sequence", "echo from child\necho from child\nparent\n"));

  // O_APPEND through two opens of one file: each write at the end.
  int a = open("/tmp/shared", O_WRONLY | O_APPEND), b = open("/tmp/shared", O_WRONLY | O_APPEND);
  CHECK(a >= 0 && b >= 0 && write(a, "1", 1) == 1 && write(b, "2", 1) == 1 && write(a, "3", 1) == 1);
  CHECK(file_is("/tmp/shared", "abcdef123"));
  close(a);
  close(b);

  // Locks: a child cannot take what the parent holds, and sees who holds it.
  struct flock whole = {.l_type = F_WRLCK, .l_whence = SEEK_SET}, first = {.l_type = F_WRLCK, .l_len = 4};
  CHECK(fcntl(fd, F_SETLK, &first) == 0);
  pid_t me = getpid();
  int ready[2];
  CHECK(pipe(ready) == 0);
  child = fork();
  if (child == 0) {
    struct flock probe = whole, other = {.l_type = F_WRLCK, .l_start = 4, .l_len = 4};
    bool ok = fcntl(fd, F_SETLK, &(struct flock){.l_type = F_WRLCK}) == -1 && errno == EAGAIN;
    ok = ok && fcntl(fd, F_GETLK, &probe) == 0 && probe.l_type == F_WRLCK && probe.l_pid == me;
    ok = ok && probe.l_start == 0 && probe.l_len == 4;
    ok = ok && fcntl(fd, F_SETLK, &other) == 0; // the bytes after: free
    ok = write(ready[1], "r", 1) == 1 && ok;    // checked while the parent holds it, however slow the machine
    ok = ok && fcntl(fd, F_SETLKW, &(struct flock){.l_type = F_RDLCK, .l_len = 4}) == 0; // once let go
    _exit(ok ? 0 : 1);
  }
  char r;
  CHECK(read(ready[0], &r, 1) == 1); // not a sleep: under load the child may start late
  close(ready[0]);
  close(ready[1]);
  CHECK(fcntl(fd, F_SETLK, &(struct flock){.l_type = F_UNLCK, .l_len = 4}) == 0); // the child's wait ends
  CHECK(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0);
  CHECK(fcntl(fd, F_SETLK, &whole) == 0); // the child's went with it
  close(fd);

  // A file removed while open: a forked child still has it, offset and all.
  fd = open("/tmp/gone", O_RDWR | O_CREAT | O_TRUNC, 0644);
  CHECK(fd >= 0 && write(fd, "kept", 4) == 4 && unlink("/tmp/gone") == 0);
  if (fd < 0) return;
  child = fork();
  if (child == 0) {
    char kept[4];
    struct stat gone;
    bool ok = fstat(fd, &gone) == 0 && gone.st_size == 4 && write(fd, "!", 1) == 1;
    ok = ok && pread(fd, kept, 4, 0) == 4 && memcmp(kept, "kept", 4) == 0;
    _exit(ok ? 0 : 1);
  }
  CHECK(child > 0 && waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0);
  CHECK(lseek(fd, 0, SEEK_CUR) == 5); // the child's write moved the offset they share
  close(fd);

  // iovecs that add up past what a write can return: EINVAL, nothing written.
  char one = 'x';
  struct iovec huge[2] = {{&one, SIZE_MAX}, {&one, 2}};
  CHECK(writev(1, huge, 2) == -1 && errno == EINVAL);
  CHECK(stat("/tmp/shared", &st) == 0 && unlink("/tmp/shared") == 0 && unlink("/tmp/sequence") == 0);
}

// Reads what the master has now: the slave's output and echo.
static size_t master_read(int m, char *buf, size_t cap) {
  ssize_t n = read(m, buf, cap - 1);
  buf[n > 0 ? n : 0] = 0;
  return n > 0 ? (size_t)n : 0;
}

// ptyd's terminals and job control.
static void test_terminals(void) {
  char buf[64];
  int m = posix_openpt(O_RDWR | O_NOCTTY);
  CHECK(m >= 0 && grantpt(m) == 0 && unlockpt(m) == 0);
  if (m < 0) return;
  const char *name = ptsname(m);
  CHECK(name && strcmp(name, "/dev/pts/0") == 0);
  int s = open(name ? name : "/dev/pts/0", O_RDWR | O_NOCTTY);
  CHECK(s >= 0);
  if (s < 0) return;
  struct stat st;
  CHECK(isatty(s) && isatty(m) && fstat(s, &st) == 0 && S_ISCHR(st.st_mode));
  int plain = open(manifest, O_RDONLY);
  CHECK(plain >= 0);
  if (plain >= 0) {
    CHECK(!isatty(plain));
    close(plain);
  }
  struct termios t;
  CHECK(tcgetattr(s, &t) == 0 && (t.c_lflag & ICANON) && (t.c_lflag & ECHO) && cfgetospeed(&t) == B38400);

  // Cooked input: CR made NL, echoed (as CR NL), one line a read; erase.
  CHECK(write(m, "hello\r", 6) == 6 && read(s, buf, sizeof buf) == 6 && memcmp(buf, "hello\n", 6) == 0);
  CHECK(master_read(m, buf, sizeof buf) == 7 && strcmp(buf, "hello\r\n") == 0);
  CHECK(write(m,
              "ab\x7f"
              "c\n",
              5) == 5 &&
        read(s, buf, sizeof buf) == 3 && memcmp(buf, "ac\n", 3) == 0);
  master_read(m, buf, sizeof buf);
  // IUTF8, on by default: erase takes back a whole rune (ADR-0013), é's two bytes.
  CHECK(write(m, "a\xc3\xa9\x7f\n", 5) == 5 && read(s, buf, sizeof buf) == 2 && memcmp(buf, "a\n", 2) == 0);
  master_read(m, buf, sizeof buf);
  CHECK(write(s, "out\n", 4) == 4 && master_read(m, buf, sizeof buf) == 5 && strcmp(buf, "out\r\n") == 0);
  CHECK(write(m, "\x04", 1) == 1 && read(s, buf, sizeof buf) == 0); // ^D on an empty line
  // ^D after some of a line sends it as it is, alone; a NUL typed is a byte.
  CHECK(write(m, "ab\x04", 3) == 3 && read(s, buf, sizeof buf) == 2 && memcmp(buf, "ab", 2) == 0);
  CHECK(write(m, "cd\n", 3) == 3 && read(s, buf, sizeof buf) == 3 && memcmp(buf, "cd\n", 3) == 0);
  CHECK(write(m, "\x04\0z\n", 4) == 4 && read(s, buf, sizeof buf) == 0 && read(s, buf, sizeof buf) == 3 &&
        memcmp(buf, "\0z\n", 3) == 0);
  master_read(m, buf, sizeof buf);

  // Output past what ptyd holds waits for the master to read it: none lost.
  // A child's copy of the master closed leaves the terminal as it was.
  pid_t writer = fork();
  if (writer == 0) {
    close(m);
    static char lots[10000];
    memset(lots, 'x', sizeof lots);
    size_t put = 0;
    for (ssize_t w; put < sizeof lots && (w = write(s, lots + put, sizeof lots - put)) > 0;) put += (size_t)w;
    _exit(put == sizeof lots ? 0 : 1);
  }
  size_t got = 0;
  static char drain[4096];
  for (ssize_t r; got < 10000 && (r = read(m, drain, sizeof drain)) > 0;) got += (size_t)r;
  int wstatus = 0;
  CHECK(got == 10000 && waitpid(writer, &wstatus, 0) == writer && WIFEXITED(wstatus) &&
        WEXITSTATUS(wstatus) == 0);
  CHECK(write(s, "still\n", 6) == 6 && master_read(m, buf, sizeof buf) == 7);

  // Raw input, a byte at a time and not echoed; then cooked again.
  struct termios raw = t;
  raw.c_lflag &= ~(tcflag_t)(ICANON | ECHO);
  CHECK(tcsetattr(s, TCSANOW, &raw) == 0 && tcgetattr(s, &raw) == 0 && !(raw.c_lflag & ICANON));
  CHECK(write(m, "xy", 2) == 2 && read(s, buf, 1) == 1 && buf[0] == 'x' && read(s, buf, 8) == 1 &&
        buf[0] == 'y');
  CHECK(tcsetattr(s, TCSAFLUSH, &t) == 0);

  // The window's size, set at the master, read at the slave.
  CHECK(ioctl(m, TIOCSWINSZ, &(struct winsize){.ws_row = 30, .ws_col = 100}) == 0);
  struct winsize w = {};
  CHECK(ioctl(s, TIOCGWINSZ, &w) == 0 && w.ws_row == 30 && w.ws_col == 100);

  // ^C: SIGINT to the foreground group, which ends a read waiting for input.
  CHECK(tcsetpgrp(s, getpgrp()) == 0 && tcgetpgrp(s) == getpgrp());
  CHECK(sigaction(SIGINT, &(struct sigaction){.sa_handler = on_signal}, nullptr) == 0); // not SA_RESTART
  int before = signals[SIGINT], status = 0;
  pid_t child = fork();
  if (child == 0) _exit(read(s, buf, sizeof buf) == -1 && errno == EINTR ? 21 : 1);
  nanosleep(&(struct timespec){.tv_nsec = 100'000'000}, nullptr);
  CHECK(write(m, "\x03", 1) == 1);
  CHECK(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 21);
  for (double end = now_seconds() + 1; signals[SIGINT] <= before && now_seconds() < end;) sched_yield();
  CHECK(signals[SIGINT] > before); // the parent is in the group too
  signal(SIGINT, SIG_DFL);
  master_read(m, buf, sizeof buf); // the ^C's echo

  // Job control: SIGSTOP, then SIGCONT, as waitpid reports them; a stopping
  // signal's default stops.
  child = fork();
  if (child == 0)
    for (;;) pause();
  CHECK(kill(child, SIGSTOP) == 0);
  CHECK(waitpid(child, &status, WUNTRACED) == child && WIFSTOPPED(status) && WSTOPSIG(status) == SIGSTOP);
  CHECK(kill(child, SIGCONT) == 0);
  CHECK(waitpid(child, &status, WCONTINUED) == child && WIFCONTINUED(status));
  CHECK(kill(child, SIGTERM) == 0);
  CHECK(waitpid(child, &status, 0) == child && WIFSIGNALED(status) && WTERMSIG(status) == SIGTERM);
  child = fork();
  if (child == 0) _exit(raise(SIGTSTP) == 0 ? 22 : 1);
  CHECK(waitpid(child, &status, WUNTRACED) == child && WIFSTOPPED(status) && WSTOPSIG(status) == SIGTSTP);
  CHECK(kill(child, SIGCONT) == 0);
  CHECK(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 22);

  // The master gone, the slave reads the end of its file.
  close(m);
  CHECK(read(s, buf, sizeof buf) == 0);
  close(s);
}

// poll and select, over pipes, files and terminals.
static void test_poll(void) {
  int p[2], status = 0;
  CHECK(pipe(p) == 0);
  struct pollfd fds[2] = {{.fd = p[0], .events = POLLIN}, {.fd = p[1], .events = POLLOUT}};
  CHECK(poll(fds, 2, 0) == 1 && fds[0].revents == 0 && (fds[1].revents & POLLOUT)); // nothing to read yet
  double t0 = now_seconds();
  CHECK(poll(fds, 1, 50) == 0 && now_seconds() - t0 >= 0.05); // its timeout
  CHECK(write(p[1], "x", 1) == 1 && poll(fds, 1, -1) == 1 && (fds[0].revents & POLLIN));
  char c;
  CHECK(read(p[0], &c, 1) == 1 && poll(fds, 1, 0) == 0);

  // A wait that a child's write ends; then the writers gone: hang-up.
  pid_t child = fork();
  if (child == 0) {
    nanosleep(&(struct timespec){.tv_nsec = 50'000'000}, nullptr);
    _exit(write(p[1], "y", 1) == 1 ? 0 : 1);
  }
  t0 = now_seconds();
  CHECK(poll(fds, 1, 5000) == 1 && (fds[0].revents & POLLIN) && now_seconds() - t0 < 4);
  CHECK(read(p[0], &c, 1) == 1 && c == 'y');
  CHECK(waitpid(child, &status, 0) == child);
  close(p[1]);
  CHECK(poll(fds, 1, 1000) == 1 && (fds[0].revents & POLLHUP));
  close(p[0]);

  // A file is always ready; a closed descriptor is not valid.
  int f = open(manifest, O_RDONLY);
  struct pollfd ff[2] = {{.fd = f, .events = POLLIN | POLLOUT}, {.fd = 60, .events = POLLIN}};
  CHECK(poll(ff, 2, 0) == 2 && (ff[0].revents & POLLIN) && ff[1].revents == POLLNVAL);
  fd_set rd;
  FD_ZERO(&rd);
  FD_SET(f, &rd);
  CHECK(select(f + 1, &rd, nullptr, nullptr, &(struct timeval){0}) == 1 && FD_ISSET(f, &rd));
  close(f);

  // A terminal: readable once a line is typed, through a read kept outstanding.
  int m = posix_openpt(O_RDWR | O_NOCTTY);
  CHECK(m >= 0 && unlockpt(m) == 0);
  if (m < 0) return;
  int s = open(ptsname(m), O_RDWR | O_NOCTTY);
  CHECK(s >= 0);
  if (s < 0) return;
  struct pollfd tf = {.fd = s, .events = POLLIN};
  CHECK(poll(&tf, 1, 0) == 0);
  CHECK(write(m, "line\n", 5) == 5 && poll(&tf, 1, 2000) == 1 && (tf.revents & POLLIN));
  char buf[16] = {};
  CHECK(read(s, buf, sizeof buf) == 5 && memcmp(buf, "line\n", 5) == 0);
  struct pollfd mf = {.fd = m, .events = POLLIN};
  CHECK(poll(&mf, 1, 1000) == 1 && read(m, buf, sizeof buf) > 0); // the echo
  // pselect, waiting with SIGUSR1 blocked but for the wait: a handler ends it.
  sigset_t usr1, none;
  sigemptyset(&usr1);
  sigaddset(&usr1, SIGUSR1);
  sigemptyset(&none);
  CHECK(sigaction(SIGUSR1, &(struct sigaction){.sa_handler = on_signal, .sa_flags = SA_RESTART}, nullptr) ==
        0);
  sigprocmask(SIG_BLOCK, &usr1, nullptr);
  CHECK(spawn_child("late", nullptr, &child) == 0);
  FD_ZERO(&rd);
  FD_SET(s, &rd);
  errno = 0;
  CHECK(pselect(s + 1, &rd, nullptr, nullptr, &(struct timespec){.tv_sec = 5}, &none) == -1 &&
        errno == EINTR);
  sigprocmask(SIG_UNBLOCK, &usr1, nullptr);
  CHECK(waitpid(child, &status, 0) == child && WEXITSTATUS(status) == 14);
  signal(SIGUSR1, SIG_DFL);
  close(s);
  close(m);
}

// --- Threads (M6 step 6d2a) ---

static pthread_mutex_t t_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t t_cond = PTHREAD_COND_INITIALIZER;
static long t_count;
static int t_turn;
static thread_local int t_mine = 7;
static _Atomic pthread_t t_selves[4];
static _Atomic bool t_detached_ran;
static _Atomic pthread_t t_signalled; // whose handler ran
static thread_local bool t_got;       // on this thread
static _Atomic bool t_waiting;

// Its own thread_local copy, a shared count under a mutex, its own identity.
static void *t_counter(void *arg) {
  long i = (long)arg;
  bool fresh = t_mine == 7;
  t_mine = (int)i;
  for (int k = 0; k < 20000; k++) {
    pthread_mutex_lock(&t_lock);
    t_count++;
    pthread_mutex_unlock(&t_lock);
  }
  t_selves[i] = pthread_self();
  return (void *)(intptr_t)(fresh && t_mine == i ? i * 10 : -1);
}

// A condition handed back and forth.
static void *t_ponger(void *arg) {
  (void)arg;
  pthread_mutex_lock(&t_lock);
  while (t_turn != 1) pthread_cond_wait(&t_cond, &t_lock);
  t_turn = 2;
  pthread_cond_broadcast(&t_cond);
  pthread_mutex_unlock(&t_lock);
  return nullptr;
}

static void *t_detached(void *arg) {
  (void)arg;
  t_detached_ran = true;
  return nullptr; // its stack goes as it ends (musl's __unmapself)
}

static void t_on_xcpu(int sig) {
  (void)sig;
  t_got = true;
  t_signalled = pthread_self();
}

// Waits in a sleep for a signal aimed at it.
static void *t_target(void *arg) {
  (void)arg;
  t_waiting = true;
  for (int i = 0; i < 2000 && !t_got; i++) nanosleep(&(struct timespec){.tv_nsec = 1'000'000}, nullptr);
  return nullptr;
}

// fork from a thread that is not the first: the child is that thread alone,
// and can make threads of its own.
static void *t_forker(void *arg) {
  (void)arg;
  pid_t pid = fork();
  if (pid == 0) {
    pthread_t c;
    void *r = nullptr;
    bool ok = pthread_create(&c, nullptr, t_detached, nullptr) == 0 && pthread_join(c, &r) == 0;
    _exit(ok ? 3 : 4);
  }
  int status = 0;
  bool ok = pid > 0 && waitpid(pid, &status, 0) == pid && WIFEXITED(status) && WEXITSTATUS(status) == 3;
  return (void *)(intptr_t)ok;
}

// --- Signal stacks and contexts (M6 step 6d2b) ---

static sigjmp_buf t_overflow_jump;
static char *t_alt;
static _Atomic bool t_handler_on_alt;
static _Atomic uintptr_t t_overflow_addr;

static void t_on_overflow(int sig, siginfo_t *info, void *uc) {
  (void)sig, (void)uc;
  char here;
  t_handler_on_alt = &here > t_alt && &here < t_alt + SIGSTKSZ;
  t_overflow_addr = (uintptr_t)info->si_addr;
  siglongjmp(t_overflow_jump, 1);
}

static _Atomic int t_depth_limit = 1 << 30; // far past any stack: the fault comes first

// NOLINTNEXTLINE(misc-no-recursion): running off the stack is the point
[[gnu::noinline]] static int t_recurse(int n) {
  volatile char pad[1024];
  pad[0] = (char)n;
  return n < t_depth_limit ? t_recurse(n + 1) + pad[0] : pad[0];
}

// On a small stack, without end: the fault on its guard has only the
// alternate stack to run on.
static void *t_overflower(void *arg) {
  (void)arg;
  t_alt = malloc(SIGSTKSZ);
  stack_t ss = {.ss_sp = t_alt, .ss_size = SIGSTKSZ}, old = {}, small = {.ss_sp = t_alt, .ss_size = 64};
  bool ok = sigaltstack(&small, nullptr) == -1 && errno == ENOMEM; // under MINSIGSTKSZ
  ok = ok && sigaltstack(&ss, &old) == 0 && (old.ss_flags & SS_DISABLE);
  if (sigsetjmp(t_overflow_jump, 1) == 0) t_recurse(0);
  stack_t now = {};
  ok = ok && sigaltstack(nullptr, &now) == 0 && now.ss_sp == t_alt && !(now.ss_flags & SS_ONSTACK);
  stack_t off = {.ss_flags = SS_DISABLE};
  ok = ok && sigaltstack(&off, nullptr) == 0;
  free(t_alt);
  return (void *)(intptr_t)ok;
}

static long t_good = 0x5eed;
static _Atomic uintptr_t t_ctx_fault, t_ctx_reg;
static _Atomic bool t_ctx_fp;

// The load's pointer register, read and pointed at t_good: the load is made
// again, and works.
static void t_on_bad_load(int sig, siginfo_t *info, void *ucv) {
  (void)sig;
  ucontext_t *uc = ucv;
#ifdef __x86_64__
  t_ctx_reg = (uintptr_t)uc->uc_mcontext.gregs[REG_RDI];
  t_ctx_fault = (uintptr_t)uc->uc_mcontext.gregs[REG_CR2];
  t_ctx_fp = uc->uc_mcontext.fpregs && uc->uc_mcontext.fpregs->mxcsr != 0;
  uc->uc_mcontext.gregs[REG_RDI] = (greg_t)&t_good;
#else
  t_ctx_reg = (uintptr_t)uc->uc_mcontext.regs[9];
  t_ctx_fault = (uintptr_t)uc->uc_mcontext.fault_address;
  t_ctx_fp = ((const struct _aarch64_ctx *)uc->uc_mcontext.__reserved)->magic == FPSIMD_MAGIC;
  uc->uc_mcontext.regs[9] = (unsigned long)&t_good;
#endif
  (void)info;
}

static long t_load(const long *p) {
  long v;
#ifdef __x86_64__
  __asm__ volatile("movq (%%rdi), %0" : "=r"(v) : "D"(p) : "memory");
#else
  register const long *x9 __asm__("x9") = p;
  __asm__ volatile("ldr %0, [x9]" : "=r"(v) : "r"(x9) : "memory");
#endif
  return v;
}

static _Atomic pthread_t t_usr2_on;
static _Atomic bool t_usr2_ready;

static void t_on_usr2(int sig) {
  (void)sig;
  t_usr2_on = pthread_self();
}

// A long sleep that only the signal, passed on to this thread, cuts short.
static bool t_woken_early(void) {
  struct timespec a, b;
  clock_gettime(CLOCK_MONOTONIC, &a);
  int r = nanosleep(&(struct timespec){.tv_sec = 5}, nullptr);
  clock_gettime(CLOCK_MONOTONIC, &b);
  return r == -1 && errno == EINTR && b.tv_sec - a.tv_sec < 4;
}

static _Atomic bool t_taker_early;

static void *t_usr2_taker(void *arg) {
  (void)arg;
  t_usr2_ready = true;
  t_taker_early = t_woken_early();
  return nullptr;
}

// The mirror: it blocks the signal and stays, the first thread does not.
static _Atomic bool t_blocker_done;

static void *t_usr2_blocker(void *arg) {
  (void)arg;
  sigset_t block;
  sigemptyset(&block);
  sigaddset(&block, SIGUSR2);
  pthread_sigmask(SIG_BLOCK, &block, nullptr);
  t_usr2_ready = true;
  while (!t_blocker_done) nanosleep(&(struct timespec){.tv_nsec = 1'000'000}, nullptr);
  return nullptr;
}

static void t_usr2_from_child(void) {
  pid_t pid = fork();
  if (pid == 0) _exit(kill(getppid(), SIGUSR2) == 0 ? 0 : 1);
  int status = 0;
  CHECK(waitpid(pid, &status, 0) == pid && WIFEXITED(status) && WEXITSTATUS(status) == 0);
}

static void test_signal_contexts(void) {
  // The registers a fault came with, changed by the handler.
  struct sigaction sa = {.sa_sigaction = t_on_bad_load, .sa_flags = SA_SIGINFO}, was;
  sigaction(SIGSEGV, &sa, &was);
  const long *bad = (const long *)(uintptr_t)0x10;
  CHECK(t_load(bad) == 0x5eed);
  CHECK(t_ctx_reg == 0x10 && t_ctx_fault == 0x10 && t_ctx_fp);
  sigaction(SIGSEGV, &was, nullptr);

  // A stack overflow caught on the alternate stack.
  struct sigaction ov = {.sa_sigaction = t_on_overflow, .sa_flags = SA_SIGINFO | SA_ONSTACK};
  sigaction(SIGSEGV, &ov, &was);
  pthread_attr_t attr;
  pthread_attr_init(&attr);
  pthread_attr_setstacksize(&attr, 64ul * 1024);
  pthread_t o;
  void *ok = nullptr;
  CHECK(pthread_create(&o, &attr, t_overflower, nullptr) == 0 && pthread_join(o, &ok) == 0 && ok);
  CHECK(t_handler_on_alt && t_overflow_addr != 0);
  sigaction(SIGSEGV, &was, nullptr);

  // A signal from another process that this thread blocks: the thread that
  // does not takes it.
  signal(SIGUSR2, t_on_usr2);
  sigset_t block, old;
  sigemptyset(&block);
  sigaddset(&block, SIGUSR2);
  pthread_t g;
  CHECK(pthread_create(&g, nullptr, t_usr2_taker, nullptr) == 0); // first: it would start with the mask
  while (!t_usr2_ready) nanosleep(&(struct timespec){.tv_nsec = 1'000'000}, nullptr);
  pthread_sigmask(SIG_BLOCK, &block, &old);
  t_usr2_from_child();
  CHECK(pthread_join(g, nullptr) == 0 && pthread_equal(t_usr2_on, g) && t_taker_early);
  t_usr2_on = 0;
  pthread_sigmask(SIG_SETMASK, &old, nullptr); // nothing left pending here
  CHECK(!t_usr2_on);
  // And the other way round: whichever thread the kernel gives the note to,
  // one of the two cases has it passed on.
  t_usr2_ready = false;
  CHECK(pthread_create(&g, nullptr, t_usr2_blocker, nullptr) == 0);
  while (!t_usr2_ready) nanosleep(&(struct timespec){.tv_nsec = 1'000'000}, nullptr);
  pid_t pid = fork(); // the sender waits a little, for this thread to be asleep
  if (pid == 0) {
    nanosleep(&(struct timespec){.tv_nsec = 100'000'000}, nullptr);
    _exit(kill(getppid(), SIGUSR2) == 0 ? 0 : 1);
  }
  bool early = t_woken_early();
  int status = 0;
  CHECK(waitpid(pid, &status, 0) == pid && WIFEXITED(status) && WEXITSTATUS(status) == 0);
  t_blocker_done = true;
  CHECK(pthread_join(g, nullptr) == 0 && pthread_equal(t_usr2_on, pthread_self()) && early);
  signal(SIGUSR2, SIG_DFL);
}

static void test_threads(void) {
  pthread_t t[4];
  t_mine = 1000;
  for (long i = 0; i < 4; i++) CHECK(pthread_create(&t[i], nullptr, t_counter, (void *)i) == 0);
  for (long i = 0; i < 4; i++) {
    void *r = nullptr;
    CHECK(pthread_join(t[i], &r) == 0 && (intptr_t)r == i * 10);
  }
  CHECK(t_count == 4L * 20000 && t_mine == 1000); // whole, and the first thread's own copy untouched
  CHECK(pthread_equal(t_selves[0], t[0]) && !pthread_equal(t_selves[0], t_selves[1]) &&
        !pthread_equal(t_selves[0], pthread_self()));

  pthread_t p;
  CHECK(pthread_create(&p, nullptr, t_ponger, nullptr) == 0);
  pthread_mutex_lock(&t_lock);
  t_turn = 1;
  pthread_cond_broadcast(&t_cond);
  while (t_turn != 2) pthread_cond_wait(&t_cond, &t_lock);
  pthread_mutex_unlock(&t_lock);
  CHECK(pthread_join(p, nullptr) == 0);

  pthread_attr_t attr;
  pthread_attr_init(&attr);
  pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
  pthread_t d;
  CHECK(pthread_create(&d, &attr, t_detached, nullptr) == 0);
  for (int i = 0; i < 1000 && !t_detached_ran; i++)
    nanosleep(&(struct timespec){.tv_nsec = 1'000'000}, nullptr);
  CHECK(t_detached_ran);

  pthread_t f;
  void *forked = nullptr;
  CHECK(pthread_create(&f, nullptr, t_forker, nullptr) == 0 && pthread_join(f, &forked) == 0 && forked);

  // pthread_kill: the handler runs on the thread it was aimed at (SIGXCPU,
  // which nothing else here sends).
  signal(SIGXCPU, t_on_xcpu);
  pthread_t g;
  CHECK(pthread_create(&g, nullptr, t_target, nullptr) == 0);
  while (!t_waiting) nanosleep(&(struct timespec){.tv_nsec = 1'000'000}, nullptr);
  CHECK(pthread_kill(g, SIGXCPU) == 0);
  CHECK(pthread_join(g, nullptr) == 0);
  CHECK(pthread_equal(t_signalled, g) && !t_got);
  signal(SIGXCPU, SIG_DFL);
}

int main(int argc, char **argv) {
  where_am_i();
  if (argc >= 3 && strcmp(argv[1], "one") != 0) return child_main(argv);
  printf("ctest: hello from musl\n");
  const char *file = getenv("CTEST_FILE"); // one a scenario put there, to show it is there
  if (file) {
    char text[128] = {};
    FILE *f = fopen(file, "r");
    CHECK(f && fgets(text, sizeof text, f) != nullptr);
    if (f) fclose(f);
    printf("ctest: %s: %s", file, text);
  }
  // The spawn message's arguments, after the program's name, and environment.
  bool args = argc == 3 && argv[0] && argv[1] && argv[2];
  CHECK(args && strcmp(argv[0], self_name) == 0);
  if (args) printf("ctest: argv %s|%s\n", argv[1], argv[2]);
  CHECK(args && strcmp(argv[2], "two words") == 0);
  const char *greeting = getenv("GREETING");
  CHECK(greeting && strcmp(greeting, "hello") == 0);
  CHECK(getenv("NOT_SET") == nullptr);

  // Memory: small allocations from musl's heap, a large one mapped alone.
  char *small = malloc(100);
  CHECK(small != nullptr);
  strcpy(small, "small");
  char *big = calloc(1, 4u << 20);
  CHECK(big != nullptr && big[0] == 0 && big[(4u << 20) - 1] == 0);
  if (big) {
    big[123456] = 7;
    char *bigger = realloc(big, 8u << 20);
    CHECK(bigger != nullptr && bigger[123456] == 7);
    free(bigger ? bigger : big);
  }
  CHECK(strcmp(small, "small") == 0);
  free(small);

  // Floating point, formatted and parsed; long double too.
  char buf[128];
  snprintf(buf, sizeof buf, "%.6f %g %.3e", sqrt(2.0), 1.0 / 3.0, 6.02214076e23);
  CHECK(strcmp(buf, "1.414214 0.333333 6.022e+23") == 0);
  long double third = 1.0L / 3.0L;
  snprintf(buf, sizeof buf, "%.12Lf", third);
  CHECK(strcmp(buf, "0.333333333333") == 0);
  CHECK(strtod("2.5e3", nullptr) == 2500.0 && strtold("0.25", nullptr) == 0.25L);
  CHECK(fabs(sin(M_PI / 6) - 0.5) < 1e-12 && pow(2.0, 10.0) == 1024.0);

  // Text: integers, sorting, the C locale's classes.
  CHECK(strtol("-0x7f", nullptr, 16) == -127 && strtol("  42", nullptr, 10) == 42);
  int numbers[] = {5, 3, 9, 1, 7};
  qsort(numbers, 5, sizeof numbers[0], by_int);
  CHECK(numbers[0] == 1 && numbers[4] == 9);

  // Files in the namespace: its own manifest, by absolute and relative paths.
  FILE *f = fopen(manifest, "r");
  CHECK(f != nullptr);
  if (f) {
    CHECK(fgets(buf, sizeof buf, f) && strncmp(buf, manifest_head, strlen(manifest_head)) == 0);
    CHECK(fseek(f, 0, SEEK_END) == 0);
    CHECK(fseek(f, 0, SEEK_SET) == 0 && fgetc(f) == '#');
    fclose(f);
  }
  struct stat st;
  CHECK(stat(manifest, &st) == 0 && S_ISREG(st.st_mode) && st.st_size > 100);
  CHECK(stat("/boot/bin", &st) == 0 && S_ISDIR(st.st_mode));
  CHECK(getcwd(buf, sizeof buf) && strcmp(buf, "/") == 0);
  CHECK(chdir("/boot") == 0 && getcwd(buf, sizeof buf) && strcmp(buf, "/boot") == 0);
  f = fopen(manifest_rel, "r");
  CHECK(f != nullptr);
  if (f) fclose(f);
  CHECK(chdir(manifest) == -1 && errno == ENOTDIR);

  // A directory, read whole.
  DIR *d = opendir("/boot/bin");
  CHECK(d != nullptr);
  int entries = 0;
  bool found = false;
  for (struct dirent *e; d && (e = readdir(d));) {
    entries++;
    if (strcmp(e->d_name, self_name) == 0) found = e->d_type == DT_REG;
  }
  if (d) closedir(d);
  CHECK(found && entries > 5);

  // Errors come back as errno, and are worded.
  errno = 0;
  FILE *none = fopen("/no/such/file", "r");
  CHECK(none == nullptr && errno == ENOENT);
  if (none) fclose(none);
  CHECK(strcmp(strerror(ENOENT), "No such file or directory") == 0);
  CHECK(open("/boot/bin", O_WRONLY) == -1);

  // Time: the clock moves, and a sleep lasts as long as asked.
  struct timespec t0, t1;
  CHECK(clock_gettime(CLOCK_MONOTONIC, &t0) == 0);
  CHECK(nanosleep(&(struct timespec){.tv_nsec = 20'000'000}, nullptr) == 0);
  CHECK(clock_gettime(CLOCK_MONOTONIC, &t1) == 0 && seconds(&t1) - seconds(&t0) >= 0.02);

  // Thread-local storage (errno is too), setjmp, and the system's name.
  CHECK(++tls_counter == 42);
  int jumped = setjmp(jump);
  if (!jumped) jump_back(5);
  CHECK(jumped == 5);
  struct utsname u;
  CHECK(uname(&u) == 0 && strcmp(u.sysname, "VectraOS") == 0);

  test_processes();
  test_fork_exec_pipes();
  test_signals();
  test_tmp_and_devices();
  test_names_and_attributes();
  test_shared_offsets_and_locks();
  test_permissions();
  test_mmap();
  test_terminals();
  test_poll();
  test_utf8();
  test_sockets();
  test_sockets_waiting();

  test_threads();
  test_signal_contexts();

  atexit(at_exit);
  fprintf(stderr, "ctest: to stderr\n");
  printf("ctest: %d checks, %d failed\n", checks, failed);
  return failed ? 1 : 0;
}
