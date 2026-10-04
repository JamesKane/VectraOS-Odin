// mkfixture.c: runs an op script (ops.txt) against upstream VectraOS's
// lib/vx-fs and writes the volume it leaves, for tests/host/fs's
// cross-format test. Built by make.sh with clang against upstream's sources
// (UPSTREAM, M5 at 1976c1f); never part of this tree's build.
//
//   mkfixture OPS IMAGE > TRANSCRIPT
//
// tests/host/fs/xformat_test.odin interprets the same script with vx:fs,
// line for line: its transcript must be this one, and its image these bytes.
//
// The script, one op a line ('#' starts a comment; modes are octal; every
// entry made is owned by 1000:1000 and stamped with the current time):
//   format BLOCKS NARENAS COMPRESS_AT BRANCH...  mkfs: roots 0755, owned by 0
//   time NS                                      the current time
//   users NAME                                   /users in adm, home's root NAME's, as host/vxfs's mkfs
//   mkdir BR PATH MODE | create BR PATH MODE | symlink BR PATH TARGET
//   write BR PATH OFF LEN SEED                   bytes 'a' + (i / 3 + SEED) % 26
//   truncate BR PATH LEN | chmod BR PATH MODE
//   remove BR PATH | rename BR FROM TO | orphan BR PATH | reapall BR
//   commit | snap BR LABEL | fork LABEL BR | close BR | del LABEL
//   rollback BR LABEL                            the open branch, in place
//   compress ARENA                               that arena's log
// Each op prints "LINE OP STATUS" (and what it found, for some); the end
// prints the checker's counts.

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include UPSTREAM_CHECK_C
#include UPSTREAM_FILE_C

typedef struct memdev {
  uint8_t *bytes;
  uint64_t size;
} memdev;

static vx_status md_read(void *ctx, uint64_t addr, void *buf) {
  memcpy(buf, ((memdev *)ctx)->bytes + addr, VXFS_BLKSZ);
  return VX_OK;
}
static vx_status md_write(void *ctx, uint64_t addr, const void *buf) {
  memcpy(((memdev *)ctx)->bytes + addr, buf, VXFS_BLKSZ);
  return VX_OK;
}
static vx_status md_barrier([[maybe_unused]] void *ctx) { return VX_OK; }
static void *m_alloc([[maybe_unused]] void *ctx, size_t n) { return malloc(n); }
static void m_free([[maybe_unused]] void *ctx, void *p, [[maybe_unused]] size_t n) { free(p); }

static memdev dev;
static vxfs_vol vol;
static int64_t now;

// The parent of path and its last name: "" and "/" are the root.
static vx_status parent_of(vxfs_tree *t, const char *path, vxfs_file *dir, char *name) {
  const char *slash = strrchr(path, '/');
  char up[4096];
  size_t n = slash ? (size_t)(slash - path) : 0;
  memcpy(up, path, n);
  up[n] = 0;
  strcpy(name, slash ? slash + 1 : path);
  return vxfs_walk_path(&vol, t, up, dir);
}

static vxfs_tree *tree(const char *branch, vx_status *st) {
  vxfs_branch *br;
  *st = vxfs_branch_open(&vol, branch, &br);
  return *st == VX_OK ? &br->t : nullptr;
}

static uint8_t data[1 << 20];

int main(int argc, char **argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: mkfixture OPS IMAGE\n");
    return 2;
  }
  FILE *in = fopen(argv[1], "r");
  if (!in) return 1;
  char line[4096];
  int lineno = 0;
  while (fgets(line, sizeof line, in)) {
    lineno++;
    char *hash = strchr(line, '#');
    if (hash) *hash = 0;
    char *w[16];
    int n = 0;
    for (char *p = strtok(line, " \t\n"); p && n < 16; p = strtok(nullptr, " \t\n")) w[n++] = p;
    if (!n) continue;
    const char *op = w[0];
    vx_status st = VX_ERR_INVALID;
    vxfs_tree *t = nullptr;
    vxfs_file dir, f, to;
    char name[4096], name2[4096];
    printf("%d %s", lineno, op);
    if (!strcmp(op, "format")) {
      dev.size = strtoull(w[1], nullptr, 10) * VXFS_BLKSZ;
      dev.bytes = calloc(1, dev.size);
      vxfs_dev d = {.ctx = &dev, .read = md_read, .write = md_write, .barrier = md_barrier, .size = dev.size};
      st = vxfs_mkfs(&vol, d, (vxfs_mem){.alloc = m_alloc, .free = m_free}, 256, (uint32_t)atoi(w[2]),
                     (const char *const *)w + 4, (uint32_t)(n - 4), 0755, 0, 0, now);
      vol.fs.compress_at = (uint32_t)atoi(w[3]);
      for (int i = 4; st == VX_OK && i < n; i++) tree(w[i], &st);
    } else if (!strcmp(op, "time")) {
      now = strtoll(w[1], nullptr, 10);
      st = VX_OK;
    } else if (!strcmp(op, "users")) {
      char text[256];
      int len = snprintf(text, sizeof text, "0:adm:adm:%s\n1:none::\n%u:%s:%s:\n", w[1], 1000u, w[1], w[1]);
      if ((t = tree("adm", &st)) && (st = vxfs_root(&vol, t, &dir)) == VX_OK &&
          (st = vxfs_create(&vol, t, &dir, "users", 0664, 0, 0, now, &f)) == VX_OK)
        st = vxfs_write(&vol, t, &f, 0, text, (uint64_t)len, now, 0);
      vxfs_attr a = {.valid = VXFS_WUID | VXFS_WGID, .uid = 1000, .gid = 1000};
      if (st == VX_OK && (t = tree("home", &st)) && (st = vxfs_root(&vol, t, &dir)) == VX_OK)
        st = vxfs_setattr(&vol, t, &dir, &a, now);
    } else if (!strcmp(op, "mkdir") || !strcmp(op, "create")) {
      uint32_t mode = (uint32_t)strtoul(w[3], nullptr, 8) | (op[0] == 'm' ? VXFS_DMDIR : 0);
      if ((t = tree(w[1], &st)) && (st = parent_of(t, w[2], &dir, name)) == VX_OK)
        st = vxfs_create(&vol, t, &dir, name, mode, 1000, 1000, now, &f);
    } else if (!strcmp(op, "symlink")) {
      if ((t = tree(w[1], &st)) && (st = parent_of(t, w[2], &dir, name)) == VX_OK)
        st = vxfs_symlink(&vol, t, &dir, name, w[3], 1000, 1000, now, &f);
    } else if (!strcmp(op, "write")) {
      uint64_t off = strtoull(w[3], nullptr, 10), len = strtoull(w[4], nullptr, 10),
               seed = strtoull(w[5], nullptr, 10);
      for (uint64_t i = 0; i < len; i++) data[i] = (uint8_t)('a' + (i / 3 + seed) % 26);
      if ((t = tree(w[1], &st)) && (st = vxfs_walk_path(&vol, t, w[2], &f)) == VX_OK)
        st = vxfs_write(&vol, t, &f, off, data, len, now, 1000);
    } else if (!strcmp(op, "truncate") || !strcmp(op, "chmod")) {
      vxfs_attr a = {.valid = op[0] == 't' ? VXFS_WSIZE : VXFS_WMODE,
                     .length = strtoull(w[3], nullptr, 10),
                     .mode = (uint32_t)strtoul(w[3], nullptr, 8)};
      if ((t = tree(w[1], &st)) && (st = vxfs_walk_path(&vol, t, w[2], &f)) == VX_OK)
        st = vxfs_setattr(&vol, t, &f, &a, now);
    } else if (!strcmp(op, "remove") || !strcmp(op, "orphan")) {
      if ((t = tree(w[1], &st)) && (st = parent_of(t, w[2], &dir, name)) == VX_OK)
        st = (op[0] == 'r' ? vxfs_remove : vxfs_orphan)(&vol, t, &dir, name, now);
    } else if (!strcmp(op, "rename")) {
      if ((t = tree(w[1], &st)) && (st = parent_of(t, w[2], &dir, name)) == VX_OK &&
          (st = parent_of(t, w[3], &to, name2)) == VX_OK)
        st = vxfs_rename(&vol, t, &dir, name, &to, name2, now, nullptr, nullptr);
    } else if (!strcmp(op, "reapall")) {
      uint32_t got = 0;
      if ((t = tree(w[1], &st))) st = vxfs_reap_all(&vol, t, &got);
      printf(" %u", got);
    } else if (!strcmp(op, "commit")) {
      st = vxfs_commit(&vol);
      printf(" %llu", (unsigned long long)vol.sb.commit);
    } else if (!strcmp(op, "snap")) {
      st = vxfs_label(&vol, w[1], w[2], 0);
    } else if (!strcmp(op, "fork")) {
      st = vxfs_label(&vol, w[1], w[2], VXFS_LMUT);
      if (st == VX_OK) tree(w[2], &st);
    } else if (!strcmp(op, "close")) {
      vxfs_branch *br;
      st = vxfs_branch_open(&vol, w[1], &br);
      if (st == VX_OK) st = vxfs_branch_close(br);
    } else if (!strcmp(op, "del")) {
      st = vxfs_unlabel(&vol, w[1]);
    } else if (!strcmp(op, "rollback")) {
      vxfs_branch *br;
      st = vxfs_branch_open(&vol, w[1], &br);
      if (st == VX_OK) st = vxfs_branch_rollback(&vol, br, w[2]);
    } else if (!strcmp(op, "compress")) {
      uint32_t i = (uint32_t)atoi(w[1]);
      st = i < vol.fs.narenas && vxfs_log_compress(&vol.fs, &vol.fs.arenas[i]) ? VX_OK : vol.fs.err;
      if (i < vol.fs.narenas && st != VX_OK) vol.fs.err = VX_OK; // a refusal (BAD_STATE), not a failure
    }
    printf(" %d\n", st);
  }
  fclose(in);
  vxfs_check c;
  vx_status st = vxfs_check_volume(&vol, &c);
  printf("check %d: %u snapshots, %u labels, %u deadlists; %llu used, %llu in trees, %llu else\n", st,
         c.snapshots, c.labels, c.dlists, (unsigned long long)c.used, (unsigned long long)c.trees,
         (unsigned long long)c.other);
  vxfs_unmount(&vol);
  FILE *out = fopen(argv[2], "wb");
  if (!out || fwrite(dev.bytes, 1, dev.size, out) != dev.size || fclose(out)) return 1;
  return 0;
}
