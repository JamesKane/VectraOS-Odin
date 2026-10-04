// ACPICA's interface, as much of it as bus-acpi uses (ADR-0012): its types,
// in Odin, laid out as ACPICA's headers lay them out for a 64-bit target
// under ports/acpica/acvectra.h, and the procedures bus-acpi calls. Each
// size and offset is asserted here, and checked against the headers
// themselves, compiled by clang for both targets, by tests/host/acpica_layout.
//
// The OS layer ACPICA calls (AcpiOs*) is bus-acpi's, in Odin, exported under
// ACPICA's names (servers/bus-acpi/osl.odin).
package acpica

import "base:intrinsics"

// ACPI_STATUS: what every call returns. ACPICA has many more; the OS layer
// returns these, and the rest are only passed on to format_exception.
Status :: enum u32 {
	Ok        = 0x0000,
	No_Memory = 0x0004, // AE_NO_MEMORY
	Not_Found = 0x0005, // AE_NOT_FOUND
	Not_Exist = 0x0006, // AE_NOT_EXIST
	Time      = 0x0011, // AE_TIME
	Bad_Data  = 0x1004, // AE_BAD_DATA
}

Size :: u64 // ACPI_SIZE
Physical_Address :: u64 // ACPI_PHYSICAL_ADDRESS
Io_Address :: u64 // ACPI_IO_ADDRESS
Handle :: distinct rawptr // ACPI_HANDLE: a namespace node
Cpu_Flags :: Size // ACPI_CPU_FLAGS
Thread_Id :: u64 // ACPI_THREAD_ID

Object_Type :: enum u32 {
	Any     = 0,
	Integer = 1, // ACPI_TYPE_INTEGER
}

// ACPI_OBJECT: a union whose first member is always the type. Only what
// bus-acpi reads is named; `_processor`, the largest member, gives the size.
Object :: struct #raw_union {
	type:       Object_Type,
	integer:    Object_Integer,
	_processor: struct {
		type:         Object_Type,
		proc_id:      u32,
		pblk_address: Io_Address,
		pblk_length:  u32,
	},
}

Object_Integer :: struct {
	type:  Object_Type, // .Integer
	value: u64,
}

#assert(size_of(Object) == 24)
#assert(offset_of(Object_Integer, value) == 8)

// ACPI_BUFFER: a caller's buffer, or (length ACPI_ALLOCATE_BUFFER) one
// ACPICA allocates.
Buffer :: struct {
	length:  Size,
	pointer: rawptr,
}

#assert(size_of(Buffer) == 16)

// ACPI_PNP_DEVICE_ID
Pnp_Device_Id :: struct {
	length: u32, // of the string, with its NUL
	value:  cstring,
}

#assert(size_of(Pnp_Device_Id) == 16)

// What ACPI_DEVICE_INFO's Valid says is there.
Valid_Flag :: enum u16 {
	Adr  = 1, // ACPI_VALID_ADR
	Hid  = 2, // ACPI_VALID_HID
	Uid  = 3,
	Cid  = 5,
	Cls  = 6,
	Sxds = 8,
	Sxws = 9,
}
Valid_Flags :: bit_set[Valid_Flag;u16]

// ACPI_DEVICE_INFO, as AcpiGetObjectInfo allocates it, up to the compatible
// ID list ACPICA appends (never read here, so not declared: the struct is
// only ever used through ACPICA's pointer).
Device_Info :: struct {
	info_size:       u32,
	name:            u32,
	type:            Object_Type,
	param_count:     u8,
	valid:           Valid_Flags,
	flags:           u8,
	highest_dstates: [4]u8,
	lowest_dstates:  [5]u8,
	address:         u64,
	hardware_id:     Pnp_Device_Id,
	unique_id:       Pnp_Device_Id,
	class_code:      Pnp_Device_Id,
}

#assert(offset_of(Device_Info, param_count) == 12)
#assert(offset_of(Device_Info, valid) == 14)
#assert(offset_of(Device_Info, flags) == 16)
#assert(offset_of(Device_Info, address) == 32)
#assert(offset_of(Device_Info, hardware_id) == 40)
#assert(offset_of(Device_Info, class_code) == 72)
#assert(size_of(Device_Info) == 88) // the offset of CompatibleIdList

// ACPI_PCI_ID: the function an access to PCI configuration space is for.
Pci_Id :: struct {
	segment:  u16,
	bus:      u16,
	device:   u16,
	function: u16,
}

#assert(size_of(Pci_Id) == 8)

// ACPI_PREDEFINED_NAMES
Predefined_Names :: struct {
	name: cstring,
	type: u8,
	val:  cstring,
}

#assert(size_of(Predefined_Names) == 24)

Table_Header :: struct {} // ACPI_TABLE_HEADER: only ever pointed to

// ACPI_EXECUTE_TYPE: what AcpiOsExecute is asked to run.
Execute_Type :: enum u32 {
	Global_Lock_Handler,
	Notify_Handler,
	Gpe_Handler,
	Debugger_Main_Thread,
	Debugger_Exec_Thread,
	Ec_Poll_Handler,
	Ec_Burst_Handler,
}

// --- Resources (acrestyp.h, which ACPICA packs) ---

Resource_Type :: enum u32 {
	Irq            = 0,
	Io             = 4,
	Fixed_Io       = 5,
	End_Tag        = 7,
	Memory32       = 9,
	Fixed_Memory32 = 10,
	Extended_Irq   = 15,
}

Resource_Io :: struct #packed {
	io_decode:      u8,
	alignment:      u8,
	address_length: u8,
	minimum:        u16,
	maximum:        u16,
}

Resource_Fixed_Io :: struct #packed {
	address:        u16,
	address_length: u8,
}

Resource_Memory32 :: struct #packed {
	write_protect:  u8,
	minimum:        u32,
	maximum:        u32,
	alignment:      u32,
	address_length: u32,
}

Resource_Fixed_Memory32 :: struct #packed {
	write_protect:  u8,
	address:        u32,
	address_length: u32,
}

// ACPI_RESOURCE_IRQ: interrupt_count lines follow from `interrupt` (C's
// union of Interrupt and the flexible array Interrupts); only the first is
// read here.
Resource_Irq :: struct #packed {
	descriptor_length: u8,
	triggering:        u8,
	polarity:          u8,
	shareable:         u8,
	wake_capable:      u8,
	interrupt_count:   u8,
	interrupt:         u8,
}

Resource_Source :: struct #packed {
	index:         u8,
	string_length: u16,
	string_ptr:    cstring,
}

Resource_Extended_Irq :: struct #packed {
	producer_consumer: u8,
	triggering:        u8,
	polarity:          u8,
	shareable:         u8,
	wake_capable:      u8,
	interrupt_count:   u8,
	resource_source:   Resource_Source,
	interrupt:         u32, // the first of interrupt_count
}

Resource_Data :: struct #raw_union {
	irq:            Resource_Irq,
	io:             Resource_Io,
	fixed_io:       Resource_Fixed_Io,
	memory32:       Resource_Memory32,
	fixed_memory32: Resource_Fixed_Memory32,
	extended_irq:   Resource_Extended_Irq,
}

// ACPI_RESOURCE, of which AcpiWalkResources passes one at a time.
Resource :: struct #packed {
	type:   Resource_Type,
	length: u32,
	data:   Resource_Data,
}

#assert(size_of(Resource_Io) == 7)
#assert(size_of(Resource_Fixed_Io) == 3)
#assert(size_of(Resource_Memory32) == 17)
#assert(size_of(Resource_Fixed_Memory32) == 9)
#assert(offset_of(Resource_Irq, interrupt) == 6)
#assert(size_of(Resource_Source) == 11)
#assert(offset_of(Resource_Extended_Irq, interrupt) == 17)
#assert(offset_of(Resource, data) == 8)

// --- Constants ---

STA_DEVICE_PRESENT :: 0x01 // _STA's bit for a device that is there
FULL_PATHNAME_NO_TRAILING :: 2 // AcpiGetName: \_SB.PCI0, without trailing underscores
FULL_INITIALIZATION :: 0 // AcpiEnableSubsystem, AcpiInitializeObjects
STATE_S5 :: 5 // soft off
METHOD_NAME__CRS :: "_CRS"

// FADT (actbl1.h's offsets in the table): Flags, and its hardware-reduced bit.
FADT_FLAGS :: 112
FADT_HW_REDUCED :: 1 << 20

// --- ACPICA's procedures, as bus-acpi calls them ---

Walk_Callback :: #type proc "c" (object: Handle, nesting_level: u32, ctx: rawptr, ret: ^rawptr) -> Status
Walk_Resource_Callback :: #type proc "c" (resource: ^Resource, ctx: rawptr) -> Status
Osd_Exec_Callback :: #type proc "c" (ctx: rawptr)
Osd_Handler :: #type proc "c" (ctx: rawptr) -> u32

foreign _ {
	@(link_name = "AcpiInitializeSubsystem")
	initialize_subsystem :: proc "c" () -> Status ---
	@(link_name = "AcpiInitializeTables")
	initialize_tables :: proc "c" (initial_storage: rawptr, initial_count: u32, allow_resize: b8) -> Status ---
	@(link_name = "AcpiLoadTables")
	load_tables :: proc "c" () -> Status ---
	@(link_name = "AcpiEnableSubsystem")
	enable_subsystem :: proc "c" (flags: u32) -> Status ---
	@(link_name = "AcpiInitializeObjects")
	initialize_objects :: proc "c" (flags: u32) -> Status ---
	@(link_name = "AcpiGetDevices")
	get_devices :: proc "c" (hid: cstring, callback: Walk_Callback, ctx: rawptr, ret: ^rawptr) -> Status ---
	@(link_name = "AcpiGetObjectInfo")
	get_object_info :: proc "c" (object: Handle, info: ^^Device_Info) -> Status ---
	@(link_name = "AcpiEvaluateObject")
	evaluate_object :: proc "c" (object: Handle, pathname: cstring, params: rawptr, ret: ^Buffer) -> Status ---
	@(link_name = "AcpiGetName")
	get_name :: proc "c" (object: Handle, name_type: u32, ret: ^Buffer) -> Status ---
	@(link_name = "AcpiWalkResources")
	walk_resources :: proc "c" (device: Handle, name: cstring, callback: Walk_Resource_Callback, ctx: rawptr) -> Status ---
	@(link_name = "AcpiFormatException")
	format_exception :: proc "c" (st: Status) -> cstring ---
	@(link_name = "AcpiGetSleepTypeData")
	get_sleep_type_data :: proc "c" (state: u8, a, b: ^u8) -> Status ---
	@(link_name = "AcpiEnterSleepStatePrep")
	enter_sleep_state_prep :: proc "c" (state: u8) -> Status ---
	@(link_name = "AcpiEnterSleepState")
	enter_sleep_state :: proc "c" (state: u8) -> Status ---
	// ACPICA's own (utprint.c), which ACPICA's messages are formatted by.
	vsnprintf :: proc "c" (buf: [^]u8, size: Size, format: cstring, args: ^intrinsics.c_va_list) -> i32 ---
}
