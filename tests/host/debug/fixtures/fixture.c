// fixture.c: the C program tests/host/debug indexes in place of upstream's
// tests/host/debug_test.c and eval_test.c, which index themselves through
// /proc/self/exe on Linux. It holds those tests' fixtures, as they wrote
// them, and is built (fixtures/make.sh) as upstream builds its host tests:
// clang 22 at -O1 with frame pointers, not PIE, with a build ID, but
// freestanding, for x86_64 and aarch64. Upstream's are built under ASan,
// which keeps every global in memory; here `used` keeps those the tests read
// from memory, and clang folds the rest to DW_AT_const_value. The tests know
// its line numbers: keep them where they are.

#include <stdint.h>

// --- debug_test.c's ---

struct point {
  int x;
  long y;
  char name[8];
};
enum color { RED = 0, GREEN = 5 };

[[gnu::used]] static struct point origin = {1, 2, "o"};
[[gnu::used]] static enum color hue = GREEN;
[[gnu::used]] static int marker_line;
enum { FIXTURE_LINE = __LINE__ + 2 }; // fixture_add's (27)

[[gnu::used, gnu::noinline]] static int fixture_add(int a, int b) {
  int sum = a + b;
  marker_line = __LINE__;
  return sum + (int)hue;
}

// --- eval_test.c's ---

struct node {
  int value;
  struct node *next;
  const char *label;
};
[[gnu::used]] static struct node second = {2, nullptr, "two"};
[[gnu::used]] static struct node first = {1, &second, "one"};
[[gnu::used]] static int table[5] = {10, 20, 30, 40, 50};
static double ratio = 1.5;
static bool flag = true;
static char letter = 'x';
enum mode { OFF = 0, ON = 1 };
static enum mode mode = ON;

static volatile uint64_t seen_fp;

// Where eval_test stops: level3's frame is the innermost of the walk.
[[gnu::noinline, clang::optnone]] static void inspect(uint64_t fp) { seen_fp = fp; }

[[gnu::noinline, clang::optnone]] static int level3(int c) {
  inspect((uint64_t)(uintptr_t)__builtin_frame_address(0));
  return c;
}

[[gnu::noinline, clang::optnone]] static int level2(int b, const char *msg) {
  int local = b + 1;
  return level3(local) + (int)msg[0];
}

[[gnu::noinline, clang::optnone]] static int level1(int a) {
  int doubled = a * 2;
  return level2(doubled, "hello");
}

[[gnu::noinline]] int main(void) {
  int r = fixture_add(2, 3) + level1(5);
  // Read, so they are described, as eval_test's (void) casts and checks keep them.
  r += (int)ratio + (int)flag + letter + (int)mode + table[r & 3] + first.next->value + origin.name[0];
  return r;
}

[[noreturn]] void _start(void) {
  seen_fp = (uint64_t)main();
  for (;;) {
  }
}

// --- Beyond upstream's: the narrow and floating types, for casts and loads ---

struct widths {
  unsigned char uc;
  signed char sc;
  short s;
  unsigned short us;
  float f;
  long long ll;
};
[[gnu::used]] static struct widths widths = {200, -3, -2, 65535, 0.25f, -5};
