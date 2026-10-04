# Upstream findings

Bugs the port found in upstream VectraOS, behaviour this tree deliberately does differently, and why. Each is worth reporting upstream.

| Found | Where upstream | What | Here |
|---|---|---|---|
| P2 clean-up | `kernel/obj/device.c` (M2) | `iorange_create` accepts a 65,536-port range (`end > 0x1'0000`) and stores its count in a `uint16_t`: 0, so the task gets no ports while the console is still handed off. | Fixed in this tree before upstream's M3 fixed it the same way (`count` as 32 bits). |
| P3 | `lib/vx-ns` (M3) | Unmount lets a connection go once no *mount* uses it, even while a *bind* still holds a fid on it; the next walk through that bind follows a null client and crashes. | Any member, mount or bind, keeps the connection. Found by comparing random namespace scripts against upstream's C. |
| P3 | `kernel/arch/*/arch.c` (M3) | Not a bug: M3 makes FP/SIMD trap in user tasks until the kernel saves it. | ADR-0004: saved eagerly at every entry, so user tasks have it; ktest checks that it works where upstream checks that it faults. |
