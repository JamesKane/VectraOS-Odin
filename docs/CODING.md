# Writing Odin for VectraOS-Odin

The rules are ADR-0003's; this is how they look in practice. The aim is Odin written as Odin, not C transliterated into Odin: let the type system carry what C leaves to comments and discipline. Good models: `lib/str`, `lib/ndb`, `kernel/task.odin` (handles), `kernel/list.odin`, `tests/host/p9_codec/tables_test.odin`.

Most of the "Idiomatic Odin" section below came out of the October 2026 review of P0–P2, which found the same handful of C habits in every area. Each rule names the habit it replaces.

## Layout

- `lib/<name>/`: one package per library (`package <name>`), imported as `vx:<name>` (`-collection:vx=lib`).
- `abi/vx/`: the kernel/user ABI, imported as `abi:vx` (`-collection:abi=abi`). `abi_gen.odin` is generated from the `.def` tables by `tools/abigen`, which the `./build` wrapper runs first: run any `./build` command (`./build loc` is quick) before compiling by hand.
- `out/gen/`: packages `./build` generates, imported as `gen:` (`-collection:gen=out/gen`): a program with a page in `man/` takes its usage message from the page's usage fence as `usage.TEXT` (`import usage "gen:usage/<program>"`), and the fence's lines for another word as `usage.TEXT_<word>` (rc's builtins: `TEXT_bind`); `./build check` refuses a `"usage:` string of its own (`tools/build/man.odin`), and a program that prints no usage message needs no import. Run a `./build` command that builds programs (`./build all`) before `odin check` on such a program.
- Key tables: an ndb format with keys of its own keeps them in `NAME.def` (`KEY("scope", "key")` lines, copied from upstream) beside the package that parses it (`lib/slots`, `lib/store`, `servers/svcd`, `servers/devmgr`). `tools/abigen` expands each into `NAME_keys_gen.odin` there (`NAME_KEYS`, not committed), which the parser hands to `ndb.unknown_key`; `./build man --check` holds the format's page in `man/6` to the same table.
- `man/<sect>/<page>`: the manual, in guide (guide(6)); `man/missing` is the ledger of what has no page yet, which only shrinks. Copied from upstream as contracts: `man`'s output must match upstream's byte for byte.
- `tests/host/<name>/`: host tests for `lib/<name>`, as `package <name>_test`, run by `./build check` under ASan. Helpers shared by several suites live in a test-free package beside them (`tests/host/p9test`), imported relatively.
- `kernel/`: one package; architecture files end in `_amd64.odin` / `_arm64.odin`; assembly in `kernel/arch/<arch>/*.S`.

## Rules

- **Shipped code imports only `base:` and `vx:`/`abi:` packages.** No `core:`: there is no Odin OS layer for VectraOS, and most of `core:` takes a context or allocates. Tools and host tests may use `core:` freely. Before writing a string, number or buffer helper, look in `vx:str` and `vx:memory`.
- **No implicit allocation.** Libraries take buffers or an explicit arena; they never use `context.allocator`.
- **Who is `proc "contextless"`:** the kernel and every library under `lib/`, throughout. A user program's own code (servers, drivers, commands, tests/user, tests/kernel) may use ordinary procedures, since `rt.start` sets up a default context before `main`, and that buys `assert`, `inject_at`, `ordered_remove` and, later, an arena through `context.allocator`. Anything stored in a contextless procedure type stays contextless: `p9.Fs` and `driver.Cons` callbacks, `p9.Rpc`, `proc "c"` thread entries.
- **Behaviour matches upstream byte for byte:** console output, wire and on-disk formats, error strings, ndb output, the order of 9P messages and of spawn records and handles. Port upstream's host tests and fuzz corpora as the oracle, and keep their case comments.
- **Zero is initialisation.** Design structs so all zeroes is a valid empty value. With `-disable-non-constant-globals` a global needs a constant initialiser; a zero value (`task_pool: Pool(Task)`) always qualifies.
- **Slices, not NUL-terminated strings.** `string`/`[]u8` everywhere; C strings only at the Limine and POSIX boundaries (`str.from_nul_padded` for fixed fields).
- **Every size, offset or count from another task** goes through `intrinsics.overflow_add` / `overflow_mul` (or `memory.page_round`) before use.
- **`@(require_results)`** on every procedure that returns a status, in the kernel and libraries alike. A deliberate discard is written `_ = f()`.
- **`@(private="file")`** for anything not used outside its file; `@(private)` (package) when a sibling file needs it, rather than copying it.
- **Comments** explain why, in full sentences, as the existing files do. Upstream's comments are a good source; reword them to fit Odin.
- **Format:** tabs, `-strict-style`, `-vet -vet-shadowing`, `-warnings-as-errors`. Every package must also pass `odin check <dir> -no-entry-point -target:freestanding_arm64 -collection:vx=lib -collection:abi=abi -vet -strict-style -warnings-as-errors` (and `freestanding_amd64_sysv`) if the kernel or user space will use it.

## Idiomatic Odin

### Types say what a value is

- **One distinct type per kind of value, converted only at boundaries.** `Paddr`, `Uva` and `Pte` in the kernel, `p9.Fid` and `p9.Node`, `vx.Handle`: a physical address passed where a user address belongs is then a compile error, not a corrupted page table. The boundaries are the syscall dispatch, foreign asm calls and firmware/Limine fields. *(Replaces: `u64` for everything.)*
- **Flag words are `bit_set`s; packed fields are `bit_field`s.** Rights are `vx.Rights`, as/vmo/task options are `vx.Map_Options` and friends, 9P qid types and open modes, ELF segment flags, the AArch64 ESR, the x86 page-fault code. On the wire a set is still the integer whose bit *i* is the member with value *i*; validate an incoming word once, at the boundary (`options_of` in `kernel/syscall.odin`). Keep a plain integer only where atomics need one (`RING_NEED_WAKEUP`). *(Replaces: `x & FLAG != 0`, hand-shifted masks.)*
- **A value that means several things is an enum, or a `(value, ok)` pair**, never a sentinel integer: `p9.serve` returns `(n, Serve_Result)`, not a length that is sometimes −1. A sentinel silently takes another meaning once the value passes through a different procedure type. *(Replaces: −1/0 sentinels, `"ok"` strings.)*
- **Let the field's type carry its width and layout.** The p9 codec's `put(o, v: $T)` takes the width from `T`; on-disk and register layouts are structs (`#packed` with `u32le`/`u64le` fields for disk formats) with `#assert(size_of(...))` and `#assert(offset_of(...))` beside them. Array fields in a register block then bounds-check an index such as an IRQ line. *(Replaces: width literals, `put32(p[84:], ...)`, `base + 0x6000 + 8*line`.)*
- **Index with enumerated arrays:** `ends: [Side]^Channel`, `ARCHES: [Arch_Kind]Arch`, `MODES: [Mode]...`. Adding a case then fails to compile until every table has it. *(Replaces: `1 - side`, string switches on an arch name.)*

### Bounds checks stay on

- **Slices or `^[N]T`, not `[^]T` plus a length kept elsewhere.** ADR-0003's guarantee that bounds checks stay on only holds for slices and arrays; every multi-pointer with an implied length is a hole in it. Firmware tables (`acpi_table` returns `[]u8` of the table's own length), page lists (`[]Paddr`), handle tables (`^[HANDLE_SLOTS]Handle_Entry`), page tables (`^[512]Pte`).
- **Copy with `copy` and slices**, not pointer arithmetic and `mem_copy`: `copy(page_bytes(pa)[off:], s)` computes the count too.
- **Read foreign bytes by slicing first, then reinterpreting:** `intrinsics.unaligned_load((^T)(raw_data(b[:size_of(T)])))`, or `slice.reinterpret` in tools. Never `slice.from_ptr` with a length taken from the input.
- **Don't cast a pointer into a `[N]u8` to store a typed header.** Give the header a field — `struct { header: vx.Msg_Header, bytes: [N]u8 }` — and send it with `memory.ptr_to_bytes`; the cast emits an aligned store into storage that is only byte-aligned.

### Errors and cleanup

- **`or_return` and conditional `defer`, not status ladders.** `vx.Status.Ok` is zero, so `x := f() or_return` works on statuses. Put each release next to its acquisition: `defer if st != .Ok { pool_free(&task_pool, t) }`. *(Replaces: `if st == .Ok && ...` waterfalls, `if o == nil { return err(st) }`, hand-written close loops.)*
- **Cleanup defers name locals, never the named results.** `return nil, .Err_No_Memory` assigns the results before deferred code runs, so a defer that frees the named result frees nil.
- **Never move an observable action behind `defer` if that reorders it.** A 9P clunk, a handle close or a kill is seen by the other side; clunk explicitly where the protocol order needs it, and declare several cleanup defers in reverse so the exit order matches the old code.
- **Internal procedures return `vx.Status`, with any value beside it.** The ABI's count-or-negative-status `i64` exists only in `syscall_dispatch`.
- **Typed access to objects:** `handle_get_as(t, h, Port, {.Wait})` returns a `^Port`; every object struct carries `#assert(offset_of(T, obj) == 0)`, because objects are cast from `^Object`.
- **Typed user copies:** `copy_in(&x, uva)`, `copy_in_slice(values[:n], uva)` — the size comes from the type.
- **Locks:** `spin_guard(&l)` (`@(deferred_in=spin_unlock)`) where a procedure has several exits under one lock; `spin_lock`/`spin_unlock` by hand where the lock is dropped part-way or held across a context switch.
- **`object_destroy` and other switches over a growing enum are complete** (`switch`, with an explicit `case .None: kpanic(...)`), so a new member is a compile error rather than a silent leak. `#partial switch` only where ignoring the rest is the point.
- **Give a resource its `defer` straight after acquiring it.** `ns.close`, `rt.close_all` and `object_release` paths are safe on zero values, so early returns stay leak-free. To hand a set of handles on, collect them through a `(Handle, Status)` sink with `or_return` and one `defer if !given { rt.close_all(..g.handles[:]) }` (svcd's `grant`).
- **In tools, every failing path says why where it fails.** Never `_ =` or `or_else` away an `os.Error` or a lookup miss; the bool + `eprintfln` + `or_return` style is the house style there.

### Containers without an allocator

- **`[dynamic; N]T` for an array and its count.** It works with no allocator, under `-no-rtti`, in contextless code: `len` is the count, `for &x in a` iterates it, `append` checks capacity. `append` returns how many it stored — 0 when full, and it truncates a string that doesn't fit — so check the result wherever the old code checked capacity. *(Replaces: `buf` + `count`, `name` + `name_len`, parallel arrays.)*
- **An array of structs, not parallel arrays:** `io: [dynamic; TASK_MAX_IO]Io_Range`, not `io_base`/`io_count`.
- **Generic once, not copied per type:** `Pool($T)` (wrong-pool frees don't compile), `Fifo($T)` and `unlink(head, x, "next")` in `kernel/list.odin`, `Byte_Queue($N)`. Intrusive lists are right in a kernel with no allocator; copying their code is not.
- **A struct that points into itself must never be copied.** Store a length and offer an accessor (`tar.entry_path(&e)`), or hold the text in a `[dynamic; N]u8`, so values can be returned by value and used from iterators. Where a struct must keep self-pointers (`rt.Conn`), say it must not be moved.
- **Name the fields in literals of ABI and wire types** (`vx.Ring_Params{sq_entries = 3, ...}`): a reordered `.def` table then breaks the build instead of silently changing what a test sends.
- **Iterators are procedures returning `(value, ok)`:** `for word in str.split_iterator(&s, ' ')`, `for e in p9.next_entry(&it)`, `for w in cmdline_word(&rest)`.

### Programs

- Every program's entry point is `@(export, link_name = "vx_main") vx_main :: proc() -> int`; `rt.start` calls it with a default context.
- Null handles are `vx.HANDLE_NONE`, never `0`.

### Shared helpers

`vx:str` (search, `split_iterator`, `join`, `format_u64`/`parse_u64`, `from_nul_padded`, and the bounded writer `Buf` that `ndb.Writer` and `tar.Writer` embed with `using`) and `vx:memory` (`ptr_to_bytes`, `PAGE_SIZE`, `page_round`). In user space also `rt.close_all`, `rt.args`, `rt.read_all`, `ns.read_all`, `rt.boot_image_size`, and the union-variadic `rt.print("served ", u64(n), " files\n")`. Use them rather than writing another loop; stay inside a type's API rather than poking its fields.

### Compiler facts that bite

- `a > b` and `a < b` on bit_sets are **strict** superset and subset. "Lacks something asked for" is `want - have != {}`; writing it as `want > have` passes a request for `{.Read}` on a handle holding only `{.Write}`.
- An untyped compound literal inside `||` is read as a bool: write `flags >= {.W, .X}`, not `{.W, .X} <= flags`.
- Untyped constants are ambiguous across union members and procedure groups: `rt.print(u64(n))`, not `rt.print(n)` with a literal.
- Under `-no-rtti` you cannot iterate an enum type (`for e in Side`); iterate an enumerated array (`for &x, side in ends`).
- `transmute` is not a constant expression: assert a set's encoding through its enum values (`u32(Map_Option.Exec) == 1`).
- `inject_at`, `pop`, `ordered_remove` and `assert` need a context. In contextless code, test and `intrinsics.trap()` (or `kpanic`) instead.
- `fmt`'s `%7d` zero-pads (`0001234`); use `%7s` with `fmt.tprint(n)` for right-aligned numbers.
- Builtin names are not caught by `-vet-shadowing`: don't name parameters `len`, `cap`, `max` or `min`.

### Tests

- `testing.expect_value(t, got, want)`, not `expect(t, got == want)`: only the former prints what it got.
- One condition per check, never `a && b && c`.
- Helpers take `t: ^testing.T` and `loc := #caller_location` and pass `loc` on, so a failure points at the calling line.
- Repeated near-identical calls become a `[]Case` table, with upstream's case comment on each row and an `expectf` message naming the case.
- Buffers results point into are locals the caller passes in, not `@(thread_local)` globals.
- Don't `free_all(context.temp_allocator)` in a test: the runner does it before every test.
- Don't replace a SIGALRM watchdog with `testing.set_fail_timeout` where a thread may block in `sync.cond_wait`: the runner cancels by `pthread_cancel`, which a futex wait on macOS never sees, so the run hangs.

### Tools

- Reset the temp allocator per iteration (`runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()`) in any loop over heavy work.
- Never build a large file as one buffer: create it at its size (`os.truncate`) and write the parts at their offsets.
- Return `(why: string, ok: bool)` rather than a sentinel string.
- To compare build outputs across commits, pin `SOURCE_DATE_EPOCH`: by default it follows the last commit's time, which reaches the debug info.

## Checking your work

Testing is risk-based: the full scenario matrix runs only at the close of a
milestone. Every change runs the cheap checks, then the scenarios its risk calls
for, on both architectures:

```sh
./build all          # both architectures; warnings are errors
./build check        # the manual's pass, host tests under ASan, vendor-check
odin check lib/<name> -no-entry-point -target:freestanding_arm64 -collection:vx=lib -collection:abi=abi -vet -strict-style -warnings-as-errors
./build test m6/<scenario> ...   # the scenarios the change can affect
```

Which scenarios a change can affect:
- **A library or program:** the scenarios that run it (grep `tests/qemu/m6/` and
  `tests/user/` for the program's name), plus its host suite.
- **The kernel, lib/rt, the ring or 9P transport, svcd, devmgr or the build
  tool's image or runner code:** these sit under everything, so add a broad
  sample: `m6/ktest m6/boot m6/shell m6/posix m6/fsd m6/net`.
- **An on-disk or wire format:** its host cross-check suites, and every scenario
  that reads or writes that format.
- **A page in `man/`, or a program's usage message:** `./build man --check`
  (the manual's pass alone, in milliseconds), and `m6/man`.

At a milestone's close, the full matrix, every scenario of the newest
`tests/qemu/mN/` on both architectures (some are for one architecture only,
and `u9fs` needs Linux user namespaces):

```sh
ls tests/qemu/m6/*.ndb | xargs -n1 basename | sed 's/\.ndb$//; s#^#m6/#' | xargs ./build test simd
```

(In zsh, don't put the scenario names in one unquoted variable: it does not
split, and the runner sees one name.)
