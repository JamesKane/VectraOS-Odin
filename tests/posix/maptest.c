// maptest: a mapped file on fsd across what can change under it (M5 step
// 10): a snapshot, then a rollback of the branch (fsd forgets the file's
// pages, so the mapping shows the rolled-back bytes); the snapshot through
// the dump view, mapped too; and a commit, then the file read through a
// second attach. tests/qemu/maptest.ndb runs it as vectra (in adm's group),
// with home on /tmp, adm on /adm, the dump view on /n and home again on /s.

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

static int checks, failed;

#define CHECK(c) check((c), #c, __LINE__)

static void check(bool ok, const char *what, int line) {
  checks++;
  if (ok) return;
  failed++;
  printf("maptest: FAILED line %d: %s\n", line, what);
}

static constexpr size_t SIZE = 65536;

static bool all(const char *p, char c) {
  for (size_t i = 0; i < SIZE; i++)
    if (p[i] != c) return false;
  return true;
}

// SIZE bytes from offset 0, however short each read (a 9P read is at most a message's worth).
static bool read_all(int fd, char *buf) {
  for (size_t got = 0; got < SIZE;) {
    ssize_t n = pread(fd, buf + got, SIZE - got, (off_t)got);
    if (n <= 0) return false;
    got += (size_t)n;
  }
  return true;
}

static bool ctl(const char *cmd) {
  int fd = open("/adm/ctl", O_WRONLY);
  if (fd < 0) return false;
  bool ok = write(fd, cmd, strlen(cmd)) == (ssize_t)strlen(cmd);
  return close(fd) == 0 && ok;
}

int main(void) {
  static char a[SIZE];
  memset(a, 'A', sizeof a);
  int fd = open("/tmp/m.bin", O_CREAT | O_RDWR | O_TRUNC, 0644);
  CHECK(fd >= 0 && write(fd, a, sizeof a) == (ssize_t)sizeof a);
  char *p = mmap(nullptr, SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  CHECK(p != MAP_FAILED);
  if (p == MAP_FAILED) return 1;

  // B through the mapping, then a snapshot of it.
  memset(p, 'B', SIZE);
  CHECK(msync(p, SIZE, MS_SYNC) == 0);
  CHECK(ctl("snap home home@2026-12-31"));

  // The snapshot through the dump view: read, and mapped.
  int snap = open("/n/2026/1231/home/m.bin", O_RDONLY);
  CHECK(snap >= 0);
  char *q = snap >= 0 ? mmap(nullptr, SIZE, PROT_READ, MAP_SHARED, snap, 0) : MAP_FAILED;
  CHECK(q != MAP_FAILED && all(q, 'B'));
  CHECK(snap < 0 ||
        mmap(nullptr, SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, snap, 0) == MAP_FAILED); // read-only

  // C, then the branch rolled back to the snapshot: the mapping shows B again.
  memset(p, 'C', SIZE);
  CHECK(msync(p, SIZE, MS_SYNC) == 0);
  CHECK(ctl("rollback home home@2026-12-31"));
  CHECK(all(p, 'B'));
  static char back[SIZE];
  CHECK(read_all(fd, back) && all(back, 'B'));
  CHECK(q == MAP_FAILED || all(q, 'B')); // the snapshot's mapping, untouched

  // D, committed, then read through a second attach.
  memset(p, 'D', SIZE);
  CHECK(msync(p, SIZE, MS_SYNC) == 0);
  CHECK(ctl("sync"));
  int other = open("/s/m.bin", O_RDONLY);
  CHECK(other >= 0 && read_all(other, back) && all(back, 'D'));

  printf("maptest: %d checks, %d failed\n", checks, failed);
  return failed ? 1 : 0;
}
