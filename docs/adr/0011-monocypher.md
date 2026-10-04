# ADR-0011: Monocypher 4.0.3, vendored unchanged, behind a thin Odin layer

Status: accepted, 2026-10-04. The import is byte-identical to the one James Kane reviewed for upstream VectraOS, 2026-10-04 (upstream `third_party/VENDOR.ndb`); accepted here on that review, at his instruction.

## Context

Upstream's M5 step 9 builds the content store (its 06 §4): objects named by BLAKE2b-256, and, from its M10, release records checked with Ed25519. Upstream vendors Monocypher for both (its ADR-0032), at the first use of either. This tree must name objects exactly as upstream does (ADR-0002: the content store's format is an on-disk format), so it needs the same hash; and writing cryptographic primitives ourselves, in Odin or anything else, is out of the question. Odin's `core:crypto` has BLAKE2b and Ed25519, but shipped code may not import `core:` (ADR-0003, docs/CODING.md), and it is not audited.

Monocypher is small (about 3.5 kLOC with the optional Ed25519 file), portable C99 needing only `<stddef.h>` and `<stdint.h>`, audited (Cure53, 2020) and constant-time by design. Its BLAKE2b is the function Limine uses for module hashes, so the system keeps one hash function.

## Decision

- **Monocypher 4.0.3**, the latest release (2026-06-15, which fixes a timing leak in EdDSA signing), from `github.com/LoupVaillant/Monocypher`, vendored unchanged under `third_party/monocypher`, the same subset upstream keeps (`subset=`): `src/monocypher.{c,h}`, `src/optional/monocypher-ed25519.{c,h}` (SHA-512 and Ed25519 as RFC 8032 has them; the core's EdDSA uses BLAKE2b instead), and the licence, authors and changelog. Left out: the documentation, tests and build files. Licence: BSD-2-Clause or CC0-1.0, the user's choice; taken under BSD-2-Clause.
- **Provenance.** The release publishes no checksum and no signature. The tarball was fetched over HTTPS on 2026-10-04; its sha256 matches upstream VectraOS's `VENDOR.ndb` record (fetched independently there), and the seven kept files are byte-identical to upstream's vendored copy (`tree.sha256=` matches). It is Monocypher's code, not upstream VectraOS's, so ADR-0002's clean-room rule does not apply to it. When reviewing, confirm the checksum against a second fetch and compare the kept files with the release's git tag.
- **Behind a thin Odin layer, as ADR-0007 has it.** `lib/crypto` declares the C functions it uses in a `foreign _` block and wraps them in contextless procedures over slices: `blake2b`, its incremental form (`blake2b_begin`, `blake2b_add`, `blake2b_end`) and `ed25519_check`. Monocypher's `crypto_blake2b_ctx` is declared in Odin with `#assert`s on its size, alignment and offsets. A hash length Monocypher would write past is a trap, never a write. Nothing else calls Monocypher: `lib/store` (the content store's format) goes through `lib/crypto`.
- **The build** is `tools/build`'s, from `ports/monocypher/port.ndb` (upstream's flags: `-std=c99 -O2 -fno-strict-aliasing -fno-omit-frame-pointer -w`). `tools/build/cobj.odin` is the general mechanism for vendored C linked into Odin: a native port's sources become a static archive, once per architecture (freestanding, not PIC, no stack protector, cached as musl is) for the Odin programs whose `PROGRAMS` entry names the port in `cports`, and once for this machine (`out/monocypher/host/libmonocypher.a`) for the host test suites that say `// host-links: monocypher` and for `tools/vxstore`. No Odin package names a path to an archive, so checking a library needs nothing built.
- **What is used**: `crypto_blake2b` and its incremental form, for object names; `crypto_ed25519_check`, tested now and used for signatures from upstream's M10. No key is generated or held by this import.

## Consequences

- Upgrading is replacing the seven files with the next release's and updating the record.
- Monocypher's code is not under the house rules (ADR-0003): it builds with its own flags and warnings, and `./build check` does not lint it.
- C code now shares a link with Odin programs on the target (until now only the musl back end, the other way round). The archive is plain C with no runtime of its own; what it needs from the program (`memcpy`, `memset`, if the compiler emits them) Odin's runtime provides.
