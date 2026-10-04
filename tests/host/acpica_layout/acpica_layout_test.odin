// bus-acpi's ACPICA declarations (servers/bus-acpi/acpica) against ACPICA's
// own headers (ADR-0012), as tests/host/musl_layout checks the musl back
// end's: for each architecture, a C file of _Static_asserts, one per size,
// offset and constant, with Odin's values in it, compiled by the pinned
// clang against the vendored headers under ports/acpica/acvectra.h, as
// ACPICA itself is compiled. A declaration that drifts from ACPICA's fails
// to compile, and clang names it.
package acpica_layout_test

import "core:fmt"
import "core:os"
import "core:reflect"
import "core:strings"
import "core:testing"
import acpica "../../../servers/bus-acpi/acpica"

when ODIN_OS == .Darwin {
	CLANG :: "/opt/homebrew/opt/llvm@22/bin/clang"
} else {
	CLANG :: "/usr/bin/clang"
}

HEADERS :: `#include <stddef.h>
#include "acpi.h"
`

Arch :: enum {
	X86_64,
	Aarch64,
}

ARCH_NAMES := [Arch]string {
	.X86_64  = "x86_64",
	.Aarch64 = "aarch64",
}

// One assertion: a C expression and the value Odin has for it.
Check :: struct {
	expr:  string,
	value: i64,
}

check :: proc(out: ^[dynamic]Check, expr: string, value: $T) {
	append(out, Check{expr, i64(value)})
}

// C's names for the members of Odin's enums, by Odin's name.
Name :: struct {
	odin, c: string,
}

STATUS_NAMES := []Name {
	{"Ok", "AE_OK"},
	{"No_Memory", "AE_NO_MEMORY"},
	{"Not_Found", "AE_NOT_FOUND"},
	{"Not_Exist", "AE_NOT_EXIST"},
	{"Time", "AE_TIME"},
	{"Bad_Data", "AE_BAD_DATA"},
}

RESOURCE_TYPE_NAMES := []Name {
	{"Irq", "ACPI_RESOURCE_TYPE_IRQ"},
	{"Io", "ACPI_RESOURCE_TYPE_IO"},
	{"Fixed_Io", "ACPI_RESOURCE_TYPE_FIXED_IO"},
	{"End_Tag", "ACPI_RESOURCE_TYPE_END_TAG"},
	{"Memory32", "ACPI_RESOURCE_TYPE_MEMORY32"},
	{"Fixed_Memory32", "ACPI_RESOURCE_TYPE_FIXED_MEMORY32"},
	{"Extended_Irq", "ACPI_RESOURCE_TYPE_EXTENDED_IRQ"},
}

EXECUTE_TYPE_NAMES := []Name {
	{"Global_Lock_Handler", "OSL_GLOBAL_LOCK_HANDLER"},
	{"Notify_Handler", "OSL_NOTIFY_HANDLER"},
	{"Gpe_Handler", "OSL_GPE_HANDLER"},
	{"Debugger_Main_Thread", "OSL_DEBUGGER_MAIN_THREAD"},
	{"Debugger_Exec_Thread", "OSL_DEBUGGER_EXEC_THREAD"},
	{"Ec_Poll_Handler", "OSL_EC_POLL_HANDLER"},
	{"Ec_Burst_Handler", "OSL_EC_BURST_HANDLER"},
}

VALID_NAMES := []Name {
	{"Adr", "ACPI_VALID_ADR"},
	{"Hid", "ACPI_VALID_HID"},
	{"Uid", "ACPI_VALID_UID"},
	{"Cid", "ACPI_VALID_CID"},
	{"Cls", "ACPI_VALID_CLS"},
	{"Sxds", "ACPI_VALID_SXDS"},
	{"Sxws", "ACPI_VALID_SXWS"},
}

OBJECT_TYPE_NAMES := []Name {
	{"Any", "ACPI_TYPE_ANY"},
	{"Integer", "ACPI_TYPE_INTEGER"},
}

// Every member of an enum, as C's constant; a flag enum as its bit.
enum_checks :: proc(out: ^[dynamic]Check, $E: typeid, names: []Name, bits := false) {
	for f in reflect.enum_fields_zipped(E) {
		c := fmt.tprintf("no C name for %v.%s", typeid_of(E), f.name) // fails to compile
		for n in names {
			if n.odin == f.name {
				c = n.c
			}
		}
		append(out, Check{c, bits ? i64(1) << uint(f.value) : i64(f.value)})
	}
}

checks :: proc(out: ^[dynamic]Check) {
	// The scalar types.
	check(out, "sizeof(ACPI_STATUS)", size_of(acpica.Status))
	check(out, "sizeof(ACPI_SIZE)", size_of(acpica.Size))
	check(out, "sizeof(ACPI_PHYSICAL_ADDRESS)", size_of(acpica.Physical_Address))
	check(out, "sizeof(ACPI_IO_ADDRESS)", size_of(acpica.Io_Address))
	check(out, "sizeof(ACPI_HANDLE)", size_of(acpica.Handle))
	check(out, "sizeof(ACPI_CPU_FLAGS)", size_of(acpica.Cpu_Flags))
	check(out, "sizeof(ACPI_THREAD_ID)", size_of(acpica.Thread_Id))
	check(out, "sizeof(ACPI_OBJECT_TYPE)", size_of(acpica.Object_Type))
	check(out, "sizeof(ACPI_EXECUTE_TYPE)", size_of(acpica.Execute_Type))
	check(out, "sizeof(BOOLEAN)", size_of(b8))
	check(out, "sizeof(ACPI_SPINLOCK)", size_of(rawptr))
	check(out, "sizeof(ACPI_SEMAPHORE)", size_of(rawptr))

	// ACPI_OBJECT and ACPI_BUFFER.
	check(out, "sizeof(ACPI_OBJECT)", size_of(acpica.Object))
	check(out, "_Alignof(ACPI_OBJECT)", align_of(acpica.Object))
	check(out, "offsetof(ACPI_OBJECT, Integer.Value)", offset_of(acpica.Object_Integer, value))
	check(out, "sizeof(((ACPI_OBJECT *)0)->Integer)", size_of(acpica.Object_Integer))
	check(out, "sizeof(ACPI_BUFFER)", size_of(acpica.Buffer))
	check(out, "offsetof(ACPI_BUFFER, Pointer)", offset_of(acpica.Buffer, pointer))

	// ACPI_DEVICE_INFO, up to its compatible ID list.
	check(out, "sizeof(ACPI_PNP_DEVICE_ID)", size_of(acpica.Pnp_Device_Id))
	check(out, "offsetof(ACPI_PNP_DEVICE_ID, String)", offset_of(acpica.Pnp_Device_Id, value))
	check(out, "offsetof(ACPI_DEVICE_INFO, Name)", offset_of(acpica.Device_Info, name))
	check(out, "offsetof(ACPI_DEVICE_INFO, Type)", offset_of(acpica.Device_Info, type))
	check(out, "offsetof(ACPI_DEVICE_INFO, ParamCount)", offset_of(acpica.Device_Info, param_count))
	check(out, "offsetof(ACPI_DEVICE_INFO, Valid)", offset_of(acpica.Device_Info, valid))
	check(out, "sizeof(((ACPI_DEVICE_INFO *)0)->Valid)", size_of(acpica.Valid_Flags))
	check(out, "offsetof(ACPI_DEVICE_INFO, Flags)", offset_of(acpica.Device_Info, flags))
	check(out, "offsetof(ACPI_DEVICE_INFO, HighestDstates)", offset_of(acpica.Device_Info, highest_dstates))
	check(out, "offsetof(ACPI_DEVICE_INFO, LowestDstates)", offset_of(acpica.Device_Info, lowest_dstates))
	check(out, "offsetof(ACPI_DEVICE_INFO, Address)", offset_of(acpica.Device_Info, address))
	check(out, "offsetof(ACPI_DEVICE_INFO, HardwareId)", offset_of(acpica.Device_Info, hardware_id))
	check(out, "offsetof(ACPI_DEVICE_INFO, UniqueId)", offset_of(acpica.Device_Info, unique_id))
	check(out, "offsetof(ACPI_DEVICE_INFO, ClassCode)", offset_of(acpica.Device_Info, class_code))
	check(out, "offsetof(ACPI_DEVICE_INFO, CompatibleIdList)", size_of(acpica.Device_Info))

	// ACPI_PCI_ID and ACPI_PREDEFINED_NAMES.
	check(out, "sizeof(ACPI_PCI_ID)", size_of(acpica.Pci_Id))
	check(out, "offsetof(ACPI_PCI_ID, Bus)", offset_of(acpica.Pci_Id, bus))
	check(out, "offsetof(ACPI_PCI_ID, Device)", offset_of(acpica.Pci_Id, device))
	check(out, "offsetof(ACPI_PCI_ID, Function)", offset_of(acpica.Pci_Id, function))
	check(out, "sizeof(ACPI_PREDEFINED_NAMES)", size_of(acpica.Predefined_Names))
	check(out, "offsetof(ACPI_PREDEFINED_NAMES, Type)", offset_of(acpica.Predefined_Names, type))
	check(out, "offsetof(ACPI_PREDEFINED_NAMES, Val)", offset_of(acpica.Predefined_Names, val))

	// The resources, packed.
	check(out, "offsetof(ACPI_RESOURCE, Length)", offset_of(acpica.Resource, length))
	check(out, "offsetof(ACPI_RESOURCE, Data)", offset_of(acpica.Resource, data))
	check(out, "sizeof(ACPI_RESOURCE_IO)", size_of(acpica.Resource_Io))
	check(out, "offsetof(ACPI_RESOURCE_IO, AddressLength)", offset_of(acpica.Resource_Io, address_length))
	check(out, "offsetof(ACPI_RESOURCE_IO, Minimum)", offset_of(acpica.Resource_Io, minimum))
	check(out, "offsetof(ACPI_RESOURCE_IO, Maximum)", offset_of(acpica.Resource_Io, maximum))
	check(out, "sizeof(ACPI_RESOURCE_FIXED_IO)", size_of(acpica.Resource_Fixed_Io))
	check(out, "offsetof(ACPI_RESOURCE_FIXED_IO, AddressLength)", offset_of(acpica.Resource_Fixed_Io, address_length))
	check(out, "sizeof(ACPI_RESOURCE_MEMORY32)", size_of(acpica.Resource_Memory32))
	check(out, "offsetof(ACPI_RESOURCE_MEMORY32, Minimum)", offset_of(acpica.Resource_Memory32, minimum))
	check(out, "offsetof(ACPI_RESOURCE_MEMORY32, AddressLength)", offset_of(acpica.Resource_Memory32, address_length))
	check(out, "sizeof(ACPI_RESOURCE_FIXED_MEMORY32)", size_of(acpica.Resource_Fixed_Memory32))
	check(out, "offsetof(ACPI_RESOURCE_FIXED_MEMORY32, Address)", offset_of(acpica.Resource_Fixed_Memory32, address))
	check(out, "offsetof(ACPI_RESOURCE_FIXED_MEMORY32, AddressLength)", offset_of(acpica.Resource_Fixed_Memory32, address_length))
	check(out, "offsetof(ACPI_RESOURCE_IRQ, InterruptCount)", offset_of(acpica.Resource_Irq, interrupt_count))
	check(out, "offsetof(ACPI_RESOURCE_IRQ, Interrupt)", offset_of(acpica.Resource_Irq, interrupt))
	check(out, "sizeof(((ACPI_RESOURCE_IRQ *)0)->Interrupt)", size_of(u8))
	check(out, "sizeof(ACPI_RESOURCE_SOURCE)", size_of(acpica.Resource_Source))
	check(out, "offsetof(ACPI_RESOURCE_SOURCE, StringPtr)", offset_of(acpica.Resource_Source, string_ptr))
	check(out, "offsetof(ACPI_RESOURCE_EXTENDED_IRQ, InterruptCount)", offset_of(acpica.Resource_Extended_Irq, interrupt_count))
	check(out, "offsetof(ACPI_RESOURCE_EXTENDED_IRQ, ResourceSource)", offset_of(acpica.Resource_Extended_Irq, resource_source))
	check(out, "offsetof(ACPI_RESOURCE_EXTENDED_IRQ, Interrupt)", offset_of(acpica.Resource_Extended_Irq, interrupt))
	check(out, "sizeof(((ACPI_RESOURCE_EXTENDED_IRQ *)0)->Interrupt)", size_of(u32))
	check(out, "offsetof(ACPI_RESOURCE_DATA, Irq)", offset_of(acpica.Resource_Data, irq))
	check(out, "offsetof(ACPI_RESOURCE_DATA, Io)", offset_of(acpica.Resource_Data, io))
	check(out, "offsetof(ACPI_RESOURCE_DATA, FixedIo)", offset_of(acpica.Resource_Data, fixed_io))
	check(out, "offsetof(ACPI_RESOURCE_DATA, Memory32)", offset_of(acpica.Resource_Data, memory32))
	check(out, "offsetof(ACPI_RESOURCE_DATA, FixedMemory32)", offset_of(acpica.Resource_Data, fixed_memory32))
	check(out, "offsetof(ACPI_RESOURCE_DATA, ExtendedIrq)", offset_of(acpica.Resource_Data, extended_irq))

	// The enums, every member.
	enum_checks(out, acpica.Status, STATUS_NAMES)
	enum_checks(out, acpica.Resource_Type, RESOURCE_TYPE_NAMES)
	enum_checks(out, acpica.Execute_Type, EXECUTE_TYPE_NAMES)
	enum_checks(out, acpica.Valid_Flag, VALID_NAMES, bits = true)
	enum_checks(out, acpica.Object_Type, OBJECT_TYPE_NAMES)

	// The constants.
	check(out, "ACPI_STA_DEVICE_PRESENT", acpica.STA_DEVICE_PRESENT)
	check(out, "ACPI_FULL_PATHNAME_NO_TRAILING", acpica.FULL_PATHNAME_NO_TRAILING)
	check(out, "ACPI_FULL_INITIALIZATION", acpica.FULL_INITIALIZATION)
	check(out, "ACPI_STATE_S5", acpica.STATE_S5)
	check(out, "offsetof(ACPI_TABLE_FADT, Flags)", acpica.FADT_FLAGS)
	check(out, "ACPI_FADT_HW_REDUCED", acpica.FADT_HW_REDUCED)
	check(out, fmt.tprintf("__builtin_strcmp(METHOD_NAME__CRS, \"%s\")", acpica.METHOD_NAME__CRS), 0)
}

compile :: proc(a: Arch, tag, source: string) -> (ok: bool, why: string) {
	name := ARCH_NAMES[a]
	path := fmt.tprintf("out/host/acpica_layout_%s_%s.c", tag, name) // one per test: they run at once
	if err := os.make_directory_all("out/host"); err != nil && err != .Exist {
		return false, fmt.tprintf("cannot make out/host: %v", err)
	}
	if err := os.write_entire_file(path, transmute([]u8)source); err != nil {
		return false, fmt.tprintf("cannot write %s: %v", path, err)
	}
	// What tools/build compiles ACPICA with (ports/acpica/port.ndb), as far
	// as the headers care.
	cmd := []string {
		CLANG,
		fmt.tprintf("--target=%s-unknown-none-elf", name),
		"-ffreestanding",
		"-std=gnu11",
		"-include", "ports/acpica/acvectra.h",
		"-Iports/acpica",
		"-Ithird_party/acpica/source/include",
		"-Ithird_party/acpica/source/include/platform",
		"-fsyntax-only",
		path,
	}
	state, _, stderr, err := os.process_exec({command = cmd}, context.temp_allocator)
	if err != nil {
		return false, fmt.tprintf("cannot run %s: %v", CLANG, err)
	}
	if !state.exited || state.exit_code != 0 {
		return false, string(stderr)
	}
	return true, ""
}

layout_source :: proc(extra: []Check = nil) -> string {
	all := make([dynamic]Check, context.temp_allocator)
	checks(&all)
	append(&all, ..extra)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, HEADERS)
	for c in all {
		quoted, _ := strings.replace_all(c.expr, "\"", "'", context.temp_allocator)
		fmt.sbprintf(&b, "_Static_assert((long long)(%s) == %dLL, \"%s is %d in servers/bus-acpi/acpica\");\n", c.expr, c.value, quoted, c.value)
	}
	return strings.to_string(b)
}

@(test)
layouts_match_acpica_x86_64 :: proc(t: ^testing.T) {
	ok, why := compile(.X86_64, "layout", layout_source())
	testing.expectf(t, ok, "x86_64: %s", why)
}

@(test)
layouts_match_acpica_aarch64 :: proc(t: ^testing.T) {
	ok, why := compile(.Aarch64, "layout", layout_source())
	testing.expectf(t, ok, "aarch64: %s", why)
}

// A drift is caught: a wrong value fails to compile.
@(test)
a_wrong_value_fails :: proc(t: ^testing.T) {
	ok, _ := compile(.X86_64, "wrong", layout_source({{"sizeof(ACPI_OBJECT)", size_of(acpica.Object) + 8}}))
	testing.expect(t, !ok, "a wrong sizeof(ACPI_OBJECT) compiled")
}
