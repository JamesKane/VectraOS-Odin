/*
 * ports/acpica/acvectra.h: ACPICA's environment on VectraOS (ADR-0012),
 * force-included before every ACPICA file, and before the headers the host
 * test of bus-acpi's ACPICA declarations compiles (tests/host/acpica_layout).
 *
 * ACPICA's platform/acenv.h knows a list of systems and stops at any other
 * with #error. This header takes acenv.h's include guard, so acenv.h is
 * skipped, and defines what acenv.h and a platform header would have.
 *
 * bus-acpi is a native VectraOS program: freestanding, 64-bit, one thread.
 * ACPICA is told the C library is the system's (ACPI_USE_SYSTEM_CLIBRARY),
 * so that its utclib.c defines none of it; bus-acpi's OS layer, in Odin,
 * gives the string, character and memcmp functions ACPICA calls, and Odin's
 * runtime memset, memcpy and memmove. Its object caches are ACPICA's own
 * (ACPI_USE_LOCAL_CACHE). No debugger, no disassembler, no debug output.
 */

#ifndef __ACENV_H__
#define __ACENV_H__

#define ACPI_BINARY_SEMAPHORE 0
#define ACPI_OSL_MUTEX 1
#define DEBUGGER_SINGLE_THREADED 0
#define DEBUGGER_MULTI_THREADED 1
#define ACPI_SRC_OS_LF_ONLY 0

#include "acgcc.h" /* ACPICA's own for GCC and clang: va_list, inline, flexible arrays */

#define ACPI_MACHINE_WIDTH 64
#define COMPILER_DEPENDENT_INT64 long long
#define COMPILER_DEPENDENT_UINT64 unsigned long long
#define ACPI_USE_SYSTEM_CLIBRARY
#define ACPI_USE_LOCAL_CACHE
#define ACPI_USE_DO_WHILE_0
#define ACPI_MUTEX_TYPE ACPI_BINARY_SEMAPHORE
#define DEBUGGER_THREADING DEBUGGER_SINGLE_THREADED

/* There is no FACS among the kernel's copies of the tables, so no global
 * lock shared with the firmware: it is always taken at once. */
#define ACPI_ACQUIRE_GLOBAL_LOCK(GLptr, Acquired) Acquired = 1
#define ACPI_RELEASE_GLOBAL_LOCK(GLptr, Pending) Pending = 0
#define ACPI_SEMAPHORE_NULL NULL
#define ACPI_FLUSH_CPU_CACHE()
#define ACPI_STRUCT_INIT(field, value) value
#define ACPI_SYSTEM_XFACE
#define ACPI_EXTERNAL_XFACE
#define ACPI_INTERNAL_XFACE
#define ACPI_INTERNAL_VAR_XFACE
#define ACPI_INIT_FUNCTION

#define ACPI_FILE void *
#define ACPI_FILE_OUT NULL
#define ACPI_FILE_ERR NULL

/* The C library functions ACPICA calls, declared as a system's headers
 * would (its acclib.h declares them only for its own library). */
#include <stddef.h>
void *memset(void *dst, int c, size_t n);
void *memcpy(void *restrict dst, const void *restrict src, size_t n);
void *memmove(void *dst, const void *src, size_t n);
int memcmp(const void *a, const void *b, size_t n);
size_t strlen(const char *s);
int strcmp(const char *a, const char *b);
int strncmp(const char *a, const char *b, size_t n);
char *strcpy(char *restrict dst, const char *restrict src);
char *strncpy(char *restrict dst, const char *restrict src, size_t n);
char *strcat(char *restrict dst, const char *restrict src);
char *strncat(char *restrict dst, const char *restrict src, size_t n);
char *strchr(const char *s, int c);
char *strstr(const char *haystack, const char *needle);
unsigned long strtoul(const char *restrict s, char **restrict end, int base);
int toupper(int c);
int tolower(int c);
int isdigit(int c);
int isspace(int c);
int isxdigit(int c);
int isupper(int c);
int islower(int c);
int isprint(int c);
int isalpha(int c);

#endif /* __ACENV_H__ */
