# M5-era scenarios

Upstream's scenarios as they stood when M5 was done (`1976c1f`), copied once (ADR-0002). P5 is judged by these, and they take over from `m4/` as regression checks once they pass. Run one with `./build test m5/<name>`.

The POSIX C fixtures (`tests/posix/*.c`) and the manifests and rc scripts under `tests/user/` are copied with them as contracts (ADR-0007). Scenarios that need a host feature this machine lacks (Linux user namespaces for `u9fs`, an IOMMU-capable QEMU configuration, and the like) are skipped with the reason.
