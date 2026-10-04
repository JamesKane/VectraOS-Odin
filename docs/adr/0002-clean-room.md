# ADR-0002: A clean-room rewrite, judged by behaviour

Status: proposed, 2026-10-03.

## Context

Upstream VectraOS is C23 by decision (its ADR-0005) and places Odin outside the base system. This tree re-implements it in Odin as a separate project. It could couple to upstream tightly (a submodule, shared ABI headers, mixed C and Odin images) or loosely.

## Decision

- **Loose coupling.** The contracts were copied once from upstream commit `b18bd2515b6650bd530fd81967dc40d918caea39` and are this tree's own: `abi/vx/*.def` and `tests/qemu/*.ndb`. There is no submodule and no mixed image.
- **Behaviour is the contract.** Serial output, error strings, `/proc` and namespace layout, 9Px and ring wire formats, and on-disk formats match upstream byte for byte. Internals are free.
- **Divergence needs an ADR.** An intended observable difference (for example, the vector-state trap frame of ADR-0004 if it ever shows in `dbg` output) is recorded with its reason.
- **Tracking is per milestone.** At each milestone boundary, upstream's new commits are read, logged in `docs/PORTING.ndb` against the components they touch, and the changed scenarios are copied again.
- Upstream's BSD-3-Clause licence is kept (`LICENSE`); copied files keep their upstream copyright.

## Consequences

- Equivalence is shown only by behaviour: the scenarios, ported host tests and cross-format tests (an Odin `fsd` reads a C-written volume, and the reverse).
- No component can be validated by dropping it into the other tree's image. The Odin kernel is checked by Odin user space alone, so milestones are ported end to end, in upstream's order.
