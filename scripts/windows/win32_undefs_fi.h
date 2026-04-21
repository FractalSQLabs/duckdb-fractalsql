/* scripts/windows/win32_undefs_fi.h
 *
 * Force-included (via MSVC /FI) at the TOP of every TU compiled
 * during the duckdb-fractalsql Windows build. Fixes the same
 * CreateDirectory / MoveFile / min / max macro collision that
 * DuckDB's own duckdb/common/windows_undefs.hpp targets.
 *
 * Why /FI and not DuckDB's in-source undef header
 *   DuckDB includes windows_undefs.hpp after its DuckDB headers but
 *   BEFORE <fstream> in extension_install.cpp. On MSVC, <fstream>
 *   transitively includes <windows.h> for the first time, which
 *   re-establishes the offending macros AFTER windows_undefs.hpp has
 *   already run. The undef therefore wipes nothing, and the macros
 *   are back in force for the rest of the TU.
 *
 *   Force-including this header FIRST pulls <windows.h> immediately
 *   (via its own include guard) and undefs at the top of the TU.
 *   Any subsequent transitive <windows.h> include is a no-op, so
 *   the undefs stick for the entire translation unit.
 *
 * Why the undefs are safe in DuckDB's build
 *   DuckDB's FileSystem abstraction calls into Win32 via explicit
 *   CreateDirectoryW / MoveFileW (always the W suffix), bypassing
 *   the ANSI/Wide A/W macro trampoline. Wiping the bare
 *   CreateDirectory/MoveFile macros therefore doesn't interfere
 *   with DuckDB's own Win32 API usage.
 */

#ifndef FRACTALSQL_WIN32_UNDEFS_FI_H
#define FRACTALSQL_WIN32_UNDEFS_FI_H

#ifdef _WIN32
/* Keep <windows.h> small. These defines must land before the
 * #include or they have no effect. */
#ifndef NOMINMAX
#  define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#  define WIN32_LEAN_AND_MEAN
#endif

#include <windows.h>

/* Collisions with DuckDB identifiers. Each macro is something
 * windows.h defines that also appears as a C++ identifier in the
 * DuckDB source we're compiling:
 *
 *   CreateDirectory / MoveFile / RemoveDirectory / CopyFile
 *       — fileapi.h A/W suffix macros; collide with duckdb::
 *         FileSystem method calls (extension_install.cpp).
 *   min / max
 *       — windef.h arithmetic macros; collide with
 *         std::numeric_limits<T>::min/max.
 *   ERROR / small
 *       — wingdi.h / rpcndr.h macros; collide with enum values.
 *   STRICT
 *       — windef.h flag macro (empty when enabled). Collides with
 *         enum values like DecodeErrorBehavior::STRICT in v1.5's
 *         core_functions/scalar/blob/encode.cpp.
 *   IGNORE
 *       — winuser.h MessageBox return value (expands to 5). Collides
 *         with DecodeErrorBehavior::IGNORE added in v1.5.2's
 *         core_functions/scalar/blob/encode.cpp. MSVC reports the
 *         resulting `Enum::5` as "illegal token 'constant' on right
 *         side of '::'", hence the characteristic 'constant' errors.
 *
 * Macros NOT undef'd even though they collide with plain C++
 * identifiers:
 *
 *   VOID / CONST / INTERFACE / IN / OUT / OPTIONAL
 *       — the Windows SDK ITSELF uses these in header declarations
 *         (e.g. `VOID __cdecl BCryptFree(...)` in bcrypt.h). If we
 *         undef them at the top of the TU, any subsequent transitive
 *         include of a Windows SDK header that hasn't been pulled
 *         in yet produces C2143/C2061 syntax errors.
 *
 * The test of "safe to undef globally" is: no Windows SDK header
 * that might be included later relies on the macro's expansion.
 */
#ifdef CreateDirectory
#  undef CreateDirectory
#endif
#ifdef MoveFile
#  undef MoveFile
#endif
#ifdef RemoveDirectory
#  undef RemoveDirectory
#endif
#ifdef CopyFile
#  undef CopyFile
#endif
#ifdef min
#  undef min
#endif
#ifdef max
#  undef max
#endif
#ifdef ERROR
#  undef ERROR
#endif
#ifdef small
#  undef small
#endif
#ifdef STRICT
#  undef STRICT
#endif
#ifdef IGNORE
#  undef IGNORE
#endif
#endif /* _WIN32 */

#endif /* FRACTALSQL_WIN32_UNDEFS_FI_H */
