# M3-era scenarios

Upstream's scenarios as they stood when M3 was done (`ec7b1ef`), copied once (ADR-0002). P3 is judged by these, and they take over from `m2/` as regression checks: `boot`, `cons`, `ktest`, `ns` and `shell` here are the M2 scenarios as M3 left them. Run one with `./build test m3/<name>`.

`mount` and `u9fs` need host servers that the scenario runner starts through QEMU's `guestfwd`; `u9fs` also needs unprivileged user namespaces (`unshare -r`), so it runs on Linux only and is skipped elsewhere.
