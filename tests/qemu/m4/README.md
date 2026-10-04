# M4-era scenarios

Upstream's scenarios as they stood when M4 was done (`002a9a8`, its review pass), copied once (ADR-0002). P4 is judged by these, and they take over from `m3/` as regression checks once they pass. Run one with `./build test m4/<name>`.

The C test programs these scenarios run (`tests/posix/*.c`, `tests/user/dbgdemo.c`) and their rc, Lua and debugger scripts are copied with them as contracts (ADR-0007): they exercise the POSIX personality and the debugger, so they stay C.
