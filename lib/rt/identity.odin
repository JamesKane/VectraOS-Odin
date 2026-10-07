package rt

// Identity (upstream's M6 step 6e1c3, os-requirements R16, R17), libvx's
// until libvx. The machine's name is vx:procns's (hostname): it reads
// /sys/name through the namespace.

// The process's id: its task's, which procfs names it by (ADR-0011).
pid :: proc "contextless" () -> u64 {
	@(static) id: u64
	if id == 0 {
		if me, st := task_info(self); st == .Ok {
			id = me.id
		}
	}
	return id
}

// The program's path, as its spawner found it (exe=); "" if it did not say.
exe_path :: proc "contextless" () -> string {
	return spawn.exe
}

// Who the process runs as (user=), none without it.
user_name :: proc "contextless" () -> string {
	return len(spawn.user) > 0 ? spawn.user : "none"
}

// The value of name in the environment the process was given (env=); ok is
// false if it has none. The environment is spawn.envs, NAME=VALUE strings;
// /env is the shared store beside it (ADR-0022).
getenv :: proc "contextless" (name: string) -> (value: string, ok: bool) {
	for e in spawn.envs {
		if len(e) > len(name) && e[len(name)] == '=' && e[:len(name)] == name {
			return e[len(name) + 1:], true
		}
	}
	return "", false
}
