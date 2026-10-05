# M6-era scenarios

Upstream's scenarios as they stood after its M6 step 6a5 (`025911e`), copied once (ADR-0002): M5's, with the shell renamed from gsh to rc (step 6a4: `svcd: started rc`, `vx.skip=rc`, `rc:` in its messages), and `man`, the manual on the target (step 6a5). They run as the m5/ scenarios do, with the machine's IOMMU. Run one with `./build test m6/<name>`.

From step 6a4 on, the shell is `/boot/bin/rc` and its service `rc`, so the older eras' scenarios that start or skip `gsh` (most of `m2/` to `m5/`) no longer pass as written: these take over from `m5/` as regression checks.

The manifests and rc scripts under `tests/user/` are copied with them as contracts (ADR-0007), the renamed ones and `mantest.{ndb,rc}` among them. Scenarios that need a host feature this machine lacks (Linux user namespaces for `u9fs`, and the like) are skipped with the reason.
