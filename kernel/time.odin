package kernel

import "base:intrinsics"

// The monotonic clock and the one-shot deadline timer.
//
// The clock is the CPU's cycle counter (the TSC, or the aarch64 virtual
// counter), converted to nanoseconds exactly. The timer is one-shot:
// arch_timer_arm programs the next deadline as a counter value, and its
// interrupt calls timer_interrupt. Hardware that counts down rather than
// comparing with the counter may interrupt early, so an interrupt before the
// deadline only re-arms. The kernel is tickless: nothing fires unless a
// deadline is armed.

NS_PER_S :: u64(1_000_000_000)

Instant :: distinct i64 // nanoseconds on the one monotonic clock

// A value splits into whole seconds and a remainder, so every step fits 64
// bits for counters up to 18 GHz, with 64-bit divisions only: no fixed-point
// factor, whose rounding error would grow with uptime. Counter to nanoseconds
// rounds down; nanoseconds to counter rounds up, so the counter reaching the
// value it gives means the nanosecond deadline has passed: a timer never
// fires early.
time_counter_to_ns :: proc "contextless" (count, hz: u64) -> u64 {
	return count / hz * NS_PER_S + count % hz * NS_PER_S / hz
}

time_ns_to_counter :: proc "contextless" (ns, hz: u64) -> u64 {
	return ns / NS_PER_S * hz + (ns % NS_PER_S * hz + NS_PER_S - 1) / NS_PER_S
}

clock: struct {
	hz:         u64, // the counter's frequency
	boot_count: u64, // the counter at kernel entry: log timestamps count from here
}

// Each CPU arms its own timer.
Cpu_Timer :: struct {
	armed: u64, // the armed deadline as a counter value; 0 if none
	fired: u64, // how many deadlines have passed here
}

cpu_timer: [MAX_CPUS]Cpu_Timer

// The simd self-test's (main.odin): while it is above zero, each timer
// interrupt wipes the vector registers, as any interrupt's Odin code may, and
// arms the next interrupt a millisecond later.
simd_test_irqs: u64

clock_init :: proc "contextless" (hz, boot_count: u64) {
	if hz == 0 || hz > 18_000_000_000 {
		kpanic("the cycle counter's frequency is unknown, or past 18 GHz")
	}
	clock.hz = hz
	clock.boot_count = boot_count
}

counter_to_ns :: proc "contextless" (count: u64) -> u64 {
	return time_counter_to_ns(count, clock.hz)
}

ns_to_counter :: proc "contextless" (ns: u64) -> u64 {
	return time_ns_to_counter(ns, clock.hz)
}

clock_now :: proc "contextless" () -> Instant {
	return Instant(counter_to_ns(arch_counter()))
}

// Arms this CPU's timer for an absolute deadline on the monotonic clock.
timer_arm :: proc "contextless" (deadline: Instant) {
	count := ns_to_counter(u64(deadline))
	t := &cpu_timer[arch_cpu_index()]
	t.armed = count != 0 ? count : 1
	arch_timer_arm(t.armed)
}

// Called by the architecture's timer interrupt, with the interrupt acknowledged.
timer_interrupt :: proc "contextless" () {
	t := &cpu_timer[arch_cpu_index()]
	if t.armed == 0 {
		return
	}
	if arch_counter() < t.armed { // early: a countdown ran out first
		arch_timer_arm(t.armed)
		return
	}
	t.armed = 0
	if simd_test_irqs > 0 {
		simd_test_irqs -= 1
		arch_clobber_vregs()
		if simd_test_irqs > 0 {
			timer_arm(clock_now() + 1_000_000)
		}
	}
	intrinsics.atomic_add_explicit(&t.fired, 1, .Release)
	sched_timer()
}

// The log prefix: "[    s.mmm] ", seconds since kernel entry.
kput_stamp :: proc "contextless" () {
	ms := clock.hz != 0 ? counter_to_ns(arch_counter() - clock.boot_count) / 1_000_000 : 0
	buf := [12]u8{'[', ' ', ' ', ' ', ' ', '0', '.', '0', '0', '0', ']', ' '}
	s := ms / 1000
	buf[7] = u8('0' + ms % 1000 / 100)
	buf[8] = u8('0' + ms % 100 / 10)
	buf[9] = u8('0' + ms % 10)
	for i := 5; i >= 1 && (s != 0 || i == 5); i -= 1 {
		buf[i] = u8('0' + s % 10)
		s /= 10
	}
	console_emit(string(buf[:]))
}
