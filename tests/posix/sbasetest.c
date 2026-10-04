// sbasetest: sbase's commands in the POSIX userland (M4 step 5b, ADR-0016).
// There is no /bin/sh yet, so this runs each command itself, as a shell
// would: posix_spawnp by PATH (/bin, where sbase's are bound before the
// native ones), standard input from a pipe it writes, standard output to a
// pipe it reads, and the exit status. Each case checks what came out.

#include <errno.h>
#include <fcntl.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ; // POSIX's, which <unistd.h> declares only for _GNU_SOURCE

static int checks, failed;

// Runs argv with `in` on its standard input; its standard output into out
// (cap bytes, NUL-terminated). Returns its exit status, or -1.
static int run(char *const argv[], const char *in, char *out, size_t cap) {
  int to[2], from[2];
  if (pipe(to) != 0 || pipe(from) != 0) return -1;
  posix_spawn_file_actions_t fa;
  posix_spawn_file_actions_init(&fa);
  posix_spawn_file_actions_adddup2(&fa, to[0], 0);
  posix_spawn_file_actions_adddup2(&fa, from[1], 1);
  posix_spawn_file_actions_addclose(&fa, to[1]);
  posix_spawn_file_actions_addclose(&fa, from[0]);
  pid_t pid;
  int err = posix_spawnp(&pid, argv[0], &fa, nullptr, argv, environ);
  posix_spawn_file_actions_destroy(&fa);
  close(to[0]);
  close(from[1]);
  if (err) {
    close(to[1]);
    close(from[0]);
    return -1;
  }
  size_t len = in ? strlen(in) : 0;
  if (len && write(to[1], in, len) != (ssize_t)len) printf("sbasetest: %s: a short write\n", argv[0]);
  close(to[1]);
  size_t got = 0;
  ssize_t n;
  while (got + 1 < cap && (n = read(from[0], out + got, cap - 1 - got)) > 0) got += (size_t)n;
  out[got] = 0;
  close(from[0]);
  int status = 0;
  if (waitpid(pid, &status, 0) != pid) return -1;
  return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

// One case: argv (nullptr-ended), its input, the output and status expected.
static void expect(const char *in, const char *want, int status, char *const argv[]) {
  static char out[8192];
  int st = run(argv, in, out, sizeof out);
  checks++;
  if (st == status && (!want || strcmp(out, want) == 0)) return;
  failed++;
  printf("sbasetest: FAILED %s: status %d (wanted %d), output [%s] (wanted [%s])\n", argv[0], st, status, out,
         want ? want : "anything");
}

#define CMD(...) ((char *const[]){__VA_ARGS__, nullptr})

int main(void) {
  printf("sbasetest: running sbase's commands\n");
  // Text.
  expect(nullptr, "hello world\n", 0, CMD("echo", "hello", "world"));
  expect(nullptr, "3 x 0x1f\n", 0, CMD("printf", "%d %s %#x\\n", "3", "x", "31"));
  expect(nullptr, "1\n2\n3\n", 0, CMD("seq", "3"));
  expect("b\na\nc\na\n", "a\na\nb\nc\n", 0, CMD("sort"));
  expect("a\na\nb\n", "      2 a\n      1 b\n", 0, CMD("uniq", "-c")); // sbase's widths
  expect("one two\nthree\n", "2 3 14\n", 0, CMD("wc"));
  expect("hello\n", "HELLO\n", 0, CMD("tr", "a-z", "A-Z"));
  expect("a:b:c\n", "b\n", 0, CMD("cut", "-d:", "-f2"));
  expect("cat\ndog\ncow\n", "cat\ncow\n", 0, CMD("grep", "^c"));
  expect("cat\n", "", 1, CMD("grep", "dog"));
  expect("hello world\n", "hello there\n", 0, CMD("sed", "s/world/there/"));
  expect("1\n2\n3\n4\n", "1\n2\n", 0, CMD("head", "-n", "2"));
  expect("1\n2\n3\n4\n", "4\n", 0, CMD("tail", "-n", "1"));
  // Not rev, nor tail -m: sbase's are broken upstream (ADR-0016, known issues).
  expect("a\n", "0000000 141  12\n0000002\n", 0, CMD("od", "-b"));
  expect("caf\xc3\xa9\n", "6\n", 0, CMD("wc", "-c")); // é is two bytes, and one character (ADR-0013)
  expect("caf\xc3\xa9\n", "5\n", 0, CMD("wc", "-m"));
  expect(nullptr, "c\n", 0, CMD("basename", "/a/b/c"));
  expect(nullptr, "/a/b\n", 0, CMD("dirname", "/a/b/c"));
  expect(nullptr, "7\n", 0, CMD("expr", "3", "+", "4"));
  expect("2^10\n", "1024\n", 0, CMD("bc"));
  expect(nullptr, "", 0, CMD("test", "-d", "/tmp"));
  expect(nullptr, "", 1, CMD("[", "-f", "/tmp", "]"));
  expect(nullptr, "", 0, CMD("true"));
  expect(nullptr, "", 1, CMD("false"));
  expect("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  <stdin>\n", 0,
         CMD("sha256sum"));
  expect("a b c\n", "a\nb\nc\n", 0, CMD("xargs", "-n", "1", "echo"));

  // Files, in /tmp.
  expect(nullptr, "", 0, CMD("mkdir", "-p", "/tmp/sb/sub"));
  expect("data\n", "data\n", 0, CMD("tee", "/tmp/sb/f"));
  expect(nullptr, "", 0, CMD("cp", "/tmp/sb/f", "/tmp/sb/sub/g"));
  expect(nullptr, "", 0, CMD("mv", "/tmp/sb/sub/g", "/tmp/sb/h"));
  expect(nullptr, "data\ndata\n", 0, CMD("cat", "/tmp/sb/f", "/tmp/sb/h"));
  expect(nullptr, "f\nh\nsub\n", 0, CMD("ls", "/tmp/sb"));
  expect(nullptr, "/tmp/sb/sub\n", 0, CMD("find", "/tmp/sb", "-type", "d", "-name", "sub"));
  expect(nullptr, "", 0, CMD("ln", "-s", "/tmp/sb/f", "/tmp/sb/link"));
  expect(nullptr, "/tmp/sb/f\n", 0, CMD("readlink", "/tmp/sb/link"));
  expect(nullptr, "", 0, CMD("touch", "/tmp/sb/empty"));
  expect(nullptr, "", 0, CMD("chmod", "600", "/tmp/sb/empty"));
  struct stat st;
  checks++;
  if (stat("/tmp/sb/empty", &st) != 0 || (st.st_mode & 0777) != 0600 || st.st_size != 0) {
    failed++;
    printf("sbasetest: FAILED chmod and touch\n");
  }
  expect(nullptr, "", 0, CMD("rm", "-r", "/tmp/sb"));
  checks++;
  if (access("/tmp/sb", F_OK) == 0 || errno != ENOENT) {
    failed++;
    printf("sbasetest: FAILED rm -r\n");
  }
  // The environment, and a command that is not there.
  expect(nullptr, "hello\n", 0, CMD("printenv", "GREETING"));
  expect(nullptr, nullptr, -1, CMD("no-such-command"));

  printf("sbasetest: %d checks, %d failed\n", checks, failed);
  return failed ? 1 : 0;
}
