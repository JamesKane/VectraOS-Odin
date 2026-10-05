// powercut: M5's power-cut exit test (step 11; tests/qemu/powercut.ndb).
// Two boots on one volume. The first writes FILES files of known bytes,
// syncs them, leaves a marker and syncs again, says so, then writes and
// commits under load until QEMU is killed (as a power cut). It says so just
// before a commit of 4 MiB begins, so the kill most likely lands inside it. The second finds the marker: fsd has mounted at once, every
// file synced is there with its bytes, and fsd's check is clean. Run as
// vectra (in adm's group), with home on /tmp and adm on /adm.

#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int checks, failed;

#define CHECK(c) check((c), #c, __LINE__)

static void check(bool ok, const char *what, int line) {
  checks++;
  if (ok) return;
  failed++;
  printf("powercut: FAILED line %d: %s\n", line, what);
}

static constexpr int FILES = 32;
static constexpr size_t SIZE = 20000, LOAD = 4 << 20;

static uint8_t byte_of(int file, size_t at) { return (uint8_t)((size_t)file * 31 + at * 7 + (at >> 9)); }

static bool ctl(const char *cmd) {
  int fd = open("/adm/ctl", O_WRONLY);
  if (fd < 0) return false;
  bool ok = write(fd, cmd, strlen(cmd)) == (ssize_t)strlen(cmd);
  return close(fd) == 0 && ok;
}

static bool write_all(int fd, const void *p, size_t n) {
  for (size_t at = 0; at < n;) {
    ssize_t w = write(fd, (const char *)p + at, n - at);
    if (w <= 0) return false;
    at += (size_t)w;
  }
  return true;
}

static size_t read_all(int fd, void *p, size_t cap) {
  size_t got = 0;
  for (ssize_t n; got < cap && (n = read(fd, (char *)p + got, cap - got)) > 0;) got += (size_t)n;
  return got;
}

static void path_of(char *out, int i) { snprintf(out, 32, "/tmp/pc/f%02d", i); }

static int first_boot(void) {
  static uint8_t buf[SIZE];
  CHECK(mkdir("/tmp/pc", 0755) == 0);
  for (int i = 0; i < FILES; i++) {
    char p[32];
    path_of(p, i);
    for (size_t k = 0; k < SIZE; k++) buf[k] = byte_of(i, k);
    int fd = open(p, O_CREAT | O_WRONLY | O_TRUNC, 0644);
    CHECK(fd >= 0 && write_all(fd, buf, SIZE) && close(fd) == 0);
  }
  CHECK(ctl("sync"));
  int m = open("/tmp/pc/marker", O_CREAT | O_WRONLY | O_TRUNC, 0644);
  CHECK(m >= 0 && write_all(m, "synced\n", 7) && close(m) == 0);
  CHECK(ctl("sync"));
  if (failed) {
    printf("powercut: %d checks, %d failed\n", checks, failed);
    return 1;
  }
  printf("powercut: %d files synced\n", FILES);
  fflush(stdout);
  // Load until the cut: a large file rewritten and committed, over and over.
  static uint8_t load[LOAD];
  for (uint32_t round = 0;; round++) {
    memset(load, (int)(round & 0xff), sizeof load);
    int fd = open("/tmp/pc/load.bin", O_CREAT | O_WRONLY | O_TRUNC, 0644);
    bool ok = fd >= 0 && write_all(fd, load, sizeof load) && close(fd) == 0;
    if (ok && round == 3) printf("powercut: under load, committing\n"), fflush(stdout);
    if (!ok || !ctl("sync")) {
      printf("powercut: FAILED under load, round %u\n", round);
      return 1;
    }
  }
}

static int second_boot(void) {
  printf("powercut: after the cut\n");
  static uint8_t buf[SIZE + 1];
  for (int i = 0; i < FILES; i++) {
    char p[32];
    path_of(p, i);
    int fd = open(p, O_RDONLY);
    size_t n = fd >= 0 ? read_all(fd, buf, sizeof buf) : 0;
    bool same = n == SIZE;
    for (size_t k = 0; same && k < SIZE; k++) same = buf[k] == byte_of(i, k);
    CHECK(fd >= 0 && same);
    if (fd >= 0) close(fd);
  }
  CHECK(ctl("check"));
  static char st[1024];
  int fd = open("/adm/status", O_RDONLY);
  size_t n = fd >= 0 ? read_all(fd, st, sizeof st - 1) : 0;
  st[n] = 0;
  CHECK(fd >= 0 && strstr(st, " check=clean") != nullptr);
  if (fd >= 0) close(fd);
  if (!strstr(st, " check=clean")) printf("powercut: status: %s", st);
  printf("powercut: %d checks, %d failed\n", checks, failed);
  return failed != 0;
}

int main(void) { return access("/tmp/pc/marker", F_OK) == 0 ? second_boot() : first_boot(); }
