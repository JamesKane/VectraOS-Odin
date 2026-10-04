// Builds upstream's host/vxfs (written for Linux) on macOS too, and pins its
// clock to SOURCE_DATE_EPOCH when that is set, as tools/vxfs's is, so the two
// tools make the same image from the same tree. Included first by make.sh.
#pragma once
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
#ifdef __APPLE__
#define fdatasync fsync
#define st_mtim st_mtimespec
#endif
static inline int vxfs_clock(clockid_t id, struct timespec *ts) {
  const char *e = getenv("SOURCE_DATE_EPOCH");
  if (e && *e) {
    ts->tv_sec = (time_t)strtoll(e, NULL, 10);
    ts->tv_nsec = 0;
    return 0;
  }
  return clock_gettime(id, ts);
}
#define clock_gettime vxfs_clock
