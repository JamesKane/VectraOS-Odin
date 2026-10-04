# M3-era scenarios

Upstream's scenarios as they stood when M3 was done (`ec7b1ef`), copied once (ADR-0002). P3 is judged by these, and they take over from `m2/` as regression checks: `boot`, `cons`, `ktest`, `ns` and `shell` here are the M2 scenarios as M3 left them. Run one with `./build test m3/<name>`.

`mount` and `u9fs` need host servers that the scenario runner starts through QEMU's `guestfwd`; `u9fs` also needs unprivileged user namespaces (`unshare -r`), so it runs on Linux only and is skipped elsewhere.

Each run serves a fresh copy of `tests/fixtures/share` (`out/<arch>/<mode>/run-<name>/share`, and `run-<name>/u9fs` for u9fs), where `host=` records are checked once the run has passed. The runner builds `out/host/vx9pserve` from `tools/vx9pserve` when a scenario first dials 10.0.2.100!5640, and `out/host/u9fs` from `third_party/u9fs` (ADR-0006) when it dials 10.0.2.101!564; `iso` boots `./build image --iso`'s CD image on virtio-scsi, with no disk.
