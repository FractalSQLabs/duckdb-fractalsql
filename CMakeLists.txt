# duckdb-fractalsql CMakeLists.txt
#
# Build strategy
#   DuckDB's release-bundle amalgamation (libduckdb-linux-*.zip) is
#   shaped for *embedding* DuckDB into an application, not for writing
#   extensions. Symbols every extension author needs (ExtensionUtil,
#   BoundFunctionExpression, CatalogTransaction) aren't there. To
#   build a real .duckdb_extension we need DuckDB's full source, so
#   we FetchContent it at the pinned tag and link against duckdb_static.
#
# C++ ABI pinning — DuckDB 1.3 broke this
#   DuckDB 1.0 / 1.1 / 1.2 official Linux CLI is built with the
#   legacy gcc4 std::string ABI (_GLIBCXX_USE_CXX11_ABI=0, platform
#   label linux_<arch>_gcc4). DuckDB 1.3 dropped legacy-ABI Linux
#   releases — their platform.hpp hard-errors if you try to build
#   extensions with legacy ABI against >=1.3 without setting
#   DUCKDB_EXPLICIT_PLATFORM.
#
#   So we select ABI per DuckDB major.minor:
#     <= 1.2.x  -> legacy ABI, platform linux_<arch>_gcc4
#     >= 1.3.x  -> new   ABI, platform linux_<arch>
#   Override with -DLEGACY_CXX11_ABI=ON|OFF if the CI's pinned
#   DuckDB version has a different expectation.
#
#   macOS and Windows have one C++ ABI; no _gcc4 suffix there, and
#   _GLIBCXX_USE_CXX11_ABI is libstdc++-specific so it doesn't apply
#   to Apple libc++ or MSVC's Dinkumware.
#
# Per-toolchain linker flags
#   Linux (GNU ld):  --whole-archive / --gc-sections / --exclude-libs
#   macOS (ld64):    -force_load per archive, -dead_strip, no exclude
#   Windows (MSVC):  /WHOLEARCHIVE:duckdb_static, static CRT via
#                    CMAKE_MSVC_RUNTIME_LIBRARY (not raw /MT, which
#                    CMake's default /MD clobbers at link time)
#
# Windows <windows.h> macro collision
#   DuckDB's src/main/extension/extension_install.cpp calls
#   fs.CreateDirectory(...) and fs.MoveFile(...). <windows.h> macros
#   these to CreateDirectoryA / MoveFileA, mangling the method call.
#   Fixed upstream in DuckDB main, not yet in 1.0 / 1.1 / 1.2 / 1.3.
#   We patch the file after FetchContent by injecting #undefs.
#
# Metadata footer
#   `.duckdb_extension` files carry a 534-byte custom section at the
#   end that DuckDB parses on LOAD. scripts/append_metadata.py
#   appends it via a POST_BUILD command.
#
# Knobs
#   DUCKDB_VERSION           — pinned DuckDB release (default v1.3.2)
#   BUILD_ARCH               — amd64 | arm64
#   DUCKDB_PLATFORM          — override the metadata platform string
#   LEGACY_CXX11_ABI         — force ON/OFF (default: auto from version)
#   EXTENSION_VERSION        — shipped in the extension metadata
#   LUAJIT_STATIC_LIB_PATH   — PIC-built libluajit-5.1.a / .lib
#   LUAJIT_INCLUDE_DIR       — LuaJIT include dir
#
# Output
#   ${CMAKE_BINARY_DIR}/fractalsql.duckdb_extension

cmake_minimum_required(VERSION 3.16)

# MSVC static-CRT must be selected before project() so the runtime
# choice flows into try_compile and into DuckDB's own compile lines.
# CMP0091 NEW tells CMake to drive /MT vs /MD via
# CMAKE_MSVC_RUNTIME_LIBRARY instead of baking /MD into
# CMAKE_CXX_FLAGS_RELEASE — otherwise CMake's default /MD lands last
# on the cl.exe command line and overrides our /MT (D9025 warnings).
if(POLICY CMP0091)
    cmake_policy(SET CMP0091 NEW)
endif()
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded" CACHE STRING
    "MSVC runtime library" FORCE)

project(duckdb_fractalsql CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# -----------------------------------------------------------------------
# Knobs.
# -----------------------------------------------------------------------
if(NOT DUCKDB_VERSION)
    set(DUCKDB_VERSION "v1.3.2")
endif()

if(NOT BUILD_ARCH)
    if(CMAKE_SYSTEM_PROCESSOR MATCHES "x86_64|amd64|AMD64")
        set(BUILD_ARCH "amd64")
    elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|arm64|ARM64")
        set(BUILD_ARCH "arm64")
    else()
        message(FATAL_ERROR "Unsupported CMAKE_SYSTEM_PROCESSOR: ${CMAKE_SYSTEM_PROCESSOR}")
    endif()
endif()

# Parse DuckDB major.minor from DUCKDB_VERSION (e.g. "v1.3.2" -> 1, 3).
# Gotcha: `if(NOT DUCKDB_MINOR)` treats the literal "0" as falsey, so a
# valid "v1.0.0" parse would fire the error. Check the match variable
# (empty on no match), not the captured numbers.
string(REGEX MATCH "^v?([0-9]+)\\.([0-9]+)" _dv_match "${DUCKDB_VERSION}")
if(_dv_match STREQUAL "")
    message(FATAL_ERROR "Cannot parse DuckDB major.minor from '${DUCKDB_VERSION}'")
endif()
set(DUCKDB_MAJOR "${CMAKE_MATCH_1}")
set(DUCKDB_MINOR "${CMAKE_MATCH_2}")
math(EXPR _dv_key "${DUCKDB_MAJOR} * 100 + ${DUCKDB_MINOR}")

# Legacy libstdc++ ABI applies on Linux only (glibc/libstdc++).
# Default: ON for DuckDB <= 1.2, OFF for >= 1.3.
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    if(_dv_key LESS 103)
        set(_default_legacy_abi ON)
    else()
        set(_default_legacy_abi OFF)
    endif()
else()
    set(_default_legacy_abi OFF)
endif()
option(LEGACY_CXX11_ABI
    "Build with _GLIBCXX_USE_CXX11_ABI=0 (legacy gcc4 std::string ABI)"
    ${_default_legacy_abi})

if(LEGACY_CXX11_ABI)
    message(STATUS "duckdb-fractalsql: legacy gcc4 C++ ABI (_GLIBCXX_USE_CXX11_ABI=0)")
    add_compile_definitions(_GLIBCXX_USE_CXX11_ABI=0)
else()
    message(STATUS "duckdb-fractalsql: new libstdc++ C++ ABI")
endif()

# Propagate the parsed DuckDB major/minor to the source so it can
# preprocessor-branch over API breaks. DuckDB 1.4 removed
# ExtensionUtil (PR #17772) and changed Extension::Load's signature
# from (DuckDB &) to (ExtensionLoader &). Without compile-time
# branching, one source file can't target both the v1.2.x and
# v1.4+/v1.5+ APIs simultaneously.
add_compile_definitions(
    FRACTALSQL_DUCKDB_MAJOR=${DUCKDB_MAJOR}
    FRACTALSQL_DUCKDB_MINOR=${DUCKDB_MINOR})

# DuckDB platform label. Linux legacy-ABI builds append _gcc4; macOS
# and Windows use one ABI. Override via -DDUCKDB_PLATFORM=... (CI
# sets this per matrix cell).
if(NOT DUCKDB_PLATFORM)
    if(CMAKE_SYSTEM_NAME STREQUAL "Darwin")
        set(DUCKDB_PLATFORM "osx_${BUILD_ARCH}")
    elseif(CMAKE_SYSTEM_NAME STREQUAL "Windows")
        set(DUCKDB_PLATFORM "windows_${BUILD_ARCH}")
    elseif(BUILD_ARCH STREQUAL "amd64" OR BUILD_ARCH STREQUAL "arm64")
        if(LEGACY_CXX11_ABI)
            set(DUCKDB_PLATFORM "linux_${BUILD_ARCH}_gcc4")
        else()
            set(DUCKDB_PLATFORM "linux_${BUILD_ARCH}")
        endif()
    else()
        message(FATAL_ERROR "Cannot infer DUCKDB_PLATFORM — pass -DDUCKDB_PLATFORM=... explicitly")
    endif()
endif()
message(STATUS "duckdb-fractalsql: DUCKDB_PLATFORM=${DUCKDB_PLATFORM}")

if(NOT EXTENSION_VERSION)
    set(EXTENSION_VERSION "v1.0.0")
endif()

if(NOT LUAJIT_STATIC_LIB_PATH)
    if(WIN32)
        set(LUAJIT_STATIC_LIB_PATH "C:/deps/LuaJIT/src/lua51.lib")
    else()
        set(LUAJIT_STATIC_LIB_PATH "/usr/local/lib/libluajit-5.1.a")
    endif()
endif()
if(NOT LUAJIT_INCLUDE_DIR)
    if(WIN32)
        set(LUAJIT_INCLUDE_DIR "C:/deps/LuaJIT/src")
    else()
        set(LUAJIT_INCLUDE_DIR "/usr/local/include/luajit-2.1")
    endif()
endif()

if(NOT EXISTS "${LUAJIT_STATIC_LIB_PATH}")
    message(FATAL_ERROR "LuaJIT archive not found at ${LUAJIT_STATIC_LIB_PATH} "
                        "— build LuaJIT with XCFLAGS=\"-fPIC\" BUILDMODE=static (or "
                        "msvcbuild.bat static) first.")
endif()

# -----------------------------------------------------------------------
# Disable DuckDB's optional components BEFORE FetchContent.
# -----------------------------------------------------------------------
set(BUILD_SHELL                  OFF    CACHE BOOL   "" FORCE)
set(BUILD_TESTS                  OFF    CACHE BOOL   "" FORCE)
set(BUILD_UNITTESTS              OFF    CACHE BOOL   "" FORCE)
set(BUILD_BENCHMARKS             OFF    CACHE BOOL   "" FORCE)
set(BUILD_PYTHON                 OFF    CACHE BOOL   "" FORCE)
set(BUILD_NODE                   OFF    CACHE BOOL   "" FORCE)
set(BUILD_ODBC_DRIVER            OFF    CACHE BOOL   "" FORCE)
set(DISABLE_UNITY                ON     CACHE BOOL   "" FORCE)
set(DISABLE_SANITIZER            ON     CACHE BOOL   "" FORCE)
set(ENABLE_ASAN                  OFF    CACHE BOOL   "" FORCE)
set(ENABLE_UBSAN                 OFF    CACHE BOOL   "" FORCE)
set(ENABLE_THREAD_SANITIZER      OFF    CACHE BOOL   "" FORCE)
set(BUILD_JEMALLOC               OFF    CACHE BOOL   "" FORCE)
set(BUILD_EXTENSIONS             ""     CACHE STRING "" FORCE)
set(CORE_EXTENSIONS              ""     CACHE STRING "" FORCE)
set(BUILD_PARQUET_EXTENSION      OFF    CACHE BOOL   "" FORCE)
set(BUILD_JSON_EXTENSION         OFF    CACHE BOOL   "" FORCE)
set(BUILD_HTTPFS_EXTENSION       OFF    CACHE BOOL   "" FORCE)
set(BUILD_ICU_EXTENSION          OFF    CACHE BOOL   "" FORCE)
set(BUILD_TPCH_EXTENSION         OFF    CACHE BOOL   "" FORCE)
set(BUILD_TPCDS_EXTENSION        OFF    CACHE BOOL   "" FORCE)
set(BUILD_FTS_EXTENSION          OFF    CACHE BOOL   "" FORCE)
set(BUILD_AUTOCOMPLETE_EXTENSION OFF    CACHE BOOL   "" FORCE)
set(BUILD_VISUALIZER_EXTENSION   OFF    CACHE BOOL   "" FORCE)
set(BUILD_TPCE                   OFF    CACHE BOOL   "" FORCE)

set(EXTENSION_STATIC_BUILD       ON     CACHE BOOL   "" FORCE)

# -----------------------------------------------------------------------
# Fetch DuckDB source at the pinned tag.
# -----------------------------------------------------------------------
include(FetchContent)
set(FETCHCONTENT_QUIET OFF)

FetchContent_Declare(
    duckdb
    GIT_REPOSITORY https://github.com/duckdb/duckdb.git
    GIT_TAG        ${DUCKDB_VERSION}
    GIT_SHALLOW    TRUE
    GIT_PROGRESS   TRUE
)
FetchContent_MakeAvailable(duckdb)

# -----------------------------------------------------------------------
# Windows: no source patch needed. DuckDB's extension_install.cpp
# already includes duckdb/common/windows_undefs.hpp, which #undefs
# CreateDirectory / MoveFile / min / max / etc. — but its top-level
# guard is `#ifdef WIN32`, not `#ifdef _WIN32`. `WIN32` is a Windows
# SDK convention (not a compiler builtin), and CMake's default MSVC
# flags don't set it. We add /DWIN32 /D_WINDOWS in scripts/windows/
# build.bat so DuckDB's upstream undef machinery activates.
# -----------------------------------------------------------------------

# -----------------------------------------------------------------------
# Our extension target.
# -----------------------------------------------------------------------
set(EXTENSION_NAME fractalsql)

add_library(${EXTENSION_NAME}_extension SHARED
    src/fractalsql_extension.cpp)

target_include_directories(${EXTENSION_NAME}_extension PRIVATE
    src/include
    include
    ${LUAJIT_INCLUDE_DIR}
    # Explicit DuckDB include paths. Relying on duckdb_static's
    # INTERFACE_INCLUDE_DIRECTORIES to propagate happens to work on
    # Linux but not reliably on macOS / Windows with this FetchContent
    # setup — so we pin the paths here. duckdb_SOURCE_DIR is set by
    # FetchContent_MakeAvailable(duckdb) above.
    ${duckdb_SOURCE_DIR}/src/include
    ${duckdb_SOURCE_DIR}/third_party/concurrentqueue
    ${duckdb_SOURCE_DIR}/third_party/fmt/include)

# --- Compile options per toolchain ------------------------------------
if(MSVC)
    # Static CRT is already selected via CMAKE_MSVC_RUNTIME_LIBRARY.
    # Whole-program optimization + LTCG kept in scripts/windows/build.bat.
    target_compile_options(${EXTENSION_NAME}_extension PRIVATE
        /EHsc /utf-8)
else()
    target_compile_options(${EXTENSION_NAME}_extension PRIVATE
        -Wall -Wextra -O3 -fPIC
        # DO NOT set -fvisibility=hidden. DuckDB's loader dlsyms
        # <extname>_init / <extname>_version from .dynsym. On Linux we
        # rely on -Wl,--exclude-libs,ALL for third-party hygiene; on
        # macOS dead-strip handles unused code, and ld64 doesn't have
        # an --exclude-libs equivalent (we accept that tradeoff).
        -fvisibility=default
        -Wno-unused-parameter
        -Wno-unused-variable)
endif()

# --- Link layout per toolchain ----------------------------------------
if(MSVC)
    target_link_libraries(${EXTENSION_NAME}_extension PRIVATE
        duckdb_static
        ${LUAJIT_STATIC_LIB_PATH})
    # /WHOLEARCHIVE pulls every .obj from duckdb_static into the
    # final .duckdb_extension. No /LTCG — we don't compile with /GL
    # (would make duckdb_static.lib blow past the 4 GiB lib.exe cap).
    target_link_options(${EXTENSION_NAME}_extension PRIVATE
        /WHOLEARCHIVE:duckdb_static)
    # DuckDB 1.5 split out per-extension static archives:
    #   duckdb_generated_extension_loader  (defines LoadAllExtensions)
    #   core_functions_extension           (referenced by generated loader)
    #   parquet_extension                  (referenced by generated loader)
    # /WHOLEARCHIVE / force_load only covers the named archive —
    # listing core/parquet via target_link_libraries alone isn't
    # enough because the generated loader's references need the
    # symbols eagerly pulled into the output.
    #
    # Guarded on target existence AND TYPE == STATIC_LIBRARY, since
    # v1.2.x keeps these as OBJECT libraries (folded into
    # duckdb_static via ALL_OBJECT_FILES) which have no .lib on disk
    # for /WHOLEARCHIVE to name.
    foreach(_dep duckdb_generated_extension_loader
                 core_functions_extension
                 parquet_extension)
        if(TARGET ${_dep})
            get_target_property(_dep_type ${_dep} TYPE)
            if(_dep_type STREQUAL "STATIC_LIBRARY")
                target_link_libraries(${EXTENSION_NAME}_extension PRIVATE
                    ${_dep})
                target_link_options(${EXTENSION_NAME}_extension PRIVATE
                    /WHOLEARCHIVE:${_dep})
            endif()
        endif()
    endforeach()
elseif(APPLE)
    # ld64 lacks --whole-archive / --gc-sections / --exclude-libs.
    # -force_load is the per-archive equivalent; -dead_strip is the
    # gc-sections equivalent. No exclude-libs equivalent — the
    # default-visibility symbols land in the export table, but we
    # rely on DuckDB's entry-point naming convention to stay tidy.
    #
    # duckdb_static is listed in target_link_libraries so its
    # INTERFACE_INCLUDE_DIRECTORIES propagate (duckdb.hpp etc.), and
    # also force-loaded via target_link_options so the whole archive
    # is pulled into the .duckdb_extension. Listing the same archive
    # twice is fine — ld64 resolves every symbol from the force_load
    # pass; the second reference is a no-op.
    target_link_libraries(${EXTENSION_NAME}_extension PRIVATE
        duckdb_static
        ${LUAJIT_STATIC_LIB_PATH})
    target_link_options(${EXTENSION_NAME}_extension PRIVATE
        -Wl,-force_load,$<TARGET_FILE:duckdb_static>
        -Wl,-dead_strip)

    # DuckDB 1.5 split the static-extension loader AND per-extension
    # code into their own STATIC archives:
    #   duckdb_generated_extension_loader  (LoadAllExtensions)
    #   core_functions_extension           (referenced by loader)
    #   parquet_extension                  (referenced by loader)
    # ld64's -force_load only loads the one archive we name, so each
    # one that's a STATIC_LIBRARY target needs its own force_load
    # directive. v1.2.x keeps these as OBJECT libraries (folded into
    # duckdb_static via ALL_OBJECT_FILES) — $<TARGET_FILE:> on an
    # OBJECT library fails with "Target is not an executable or
    # library", so we gate on TYPE.
    foreach(_dep duckdb_generated_extension_loader
                 core_functions_extension
                 parquet_extension)
        if(TARGET ${_dep})
            get_target_property(_dep_type ${_dep} TYPE)
            if(_dep_type STREQUAL "STATIC_LIBRARY")
                target_link_libraries(${EXTENSION_NAME}_extension PRIVATE
                    ${_dep})
                target_link_options(${EXTENSION_NAME}_extension PRIVATE
                    -Wl,-force_load,$<TARGET_FILE:${_dep}>)
            endif()
        endif()
    endforeach()
else()
    # GNU ld / Linux.
    target_link_libraries(${EXTENSION_NAME}_extension PRIVATE
        # --whole-archive pulls every .o from duckdb_static into the
        # output, including the members that satisfy only indirect
        # references. Without this the linker drops archive members
        # it thinks are unused and LOAD fails with undefined typeinfo
        # at dlopen time — DuckDB's CLI exports no DuckDB symbols,
        # so every definition must live inside the .duckdb_extension.
        -Wl,--whole-archive
        duckdb_static
        -Wl,--no-whole-archive
        ${LUAJIT_STATIC_LIB_PATH}
        -Wl,--gc-sections
        -Wl,--exclude-libs,ALL
        m dl pthread)
endif()

set_target_properties(${EXTENSION_NAME}_extension PROPERTIES
    PREFIX ""
    SUFFIX ".duckdb_extension"
    OUTPUT_NAME ${EXTENSION_NAME})

# Append DuckDB's required metadata footer so `LOAD` accepts the file.
# ABI_TYPE=CPP marks this as a C++ extension (DatabaseInstance&),
# which is what src/fractalsql_extension.cpp implements.
add_custom_command(TARGET ${EXTENSION_NAME}_extension POST_BUILD
    COMMAND python3 ${CMAKE_CURRENT_SOURCE_DIR}/scripts/append_metadata.py
        --extension $<TARGET_FILE:${EXTENSION_NAME}_extension>
        --platform ${DUCKDB_PLATFORM}
        --duckdb-version ${DUCKDB_VERSION}
        --extension-version ${EXTENSION_VERSION}
        --abi-type CPP
    COMMENT "Appending DuckDB extension metadata footer (${DUCKDB_PLATFORM})"
    VERBATIM)
