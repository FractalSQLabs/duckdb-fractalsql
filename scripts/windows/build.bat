@echo off
REM scripts/windows/build.bat
REM
REM Builds fractalsql.duckdb_extension on Windows x64 with the MSVC
REM toolchain using static CRT (/MT) and whole-program optimization
REM (/GL /LTCG). Zero runtime dependency on the Visual C++
REM Redistributable, matching the Linux posture.
REM
REM Output filename matches the Linux convention — the DuckDB loader
REM validates the footer metadata against the artifact, so the
REM (duckdb_version, platform) tag rides in the filename:
REM
REM   dist\windows_amd64\fractalsql.<ver>.windows_amd64.duckdb_extension
REM
REM Prerequisites
REM   * Visual Studio Build Tools. Run from a Developer Command Prompt
REM     for VS 2022 x64, or invoke vcvarsall.bat x64 first.
REM   * CMake 3.16+ on PATH.
REM   * Git on PATH (CMake's FetchContent pulls the DuckDB source
REM     tree at the pinned tag).
REM   * A PIC-equivalent static LuaJIT archive: lua51.lib. Build it
REM     with msvcbuild.bat static:
REM         cd LuaJIT\src
REM         msvcbuild.bat static
REM     which emits lua51.lib and the lua.h / lualib.h / lauxlib.h
REM     headers. Set LUAJIT_DIR to that src directory.
REM
REM Environment overrides
REM   LUAJIT_DIR        directory with lua.h, luajit.h, lua51.lib
REM                     (default: C:\deps\LuaJIT\src)
REM   DUCKDB_VERSION    DuckDB tag to build against
REM                     (default: v1.5.2; e.g. v1.2.2 / v1.4.4 / v1.5.2)
REM   OUT_DIR           output directory
REM                     (default: dist\windows_amd64)
REM   BUILD_DIR         CMake build tree
REM                     (default: build-windows)
REM
REM Invocation
REM   scripts\windows\build.bat
REM   -- or --
REM   set DUCKDB_VERSION=v1.2.2
REM   scripts\windows\build.bat

setlocal ENABLEEXTENSIONS ENABLEDELAYEDEXPANSION

if "%LUAJIT_DIR%"==""     set LUAJIT_DIR=C:\deps\LuaJIT\src
if "%DUCKDB_VERSION%"=="" set DUCKDB_VERSION=v1.5.2
if "%OUT_DIR%"==""        set OUT_DIR=dist\windows_amd64
if "%BUILD_DIR%"==""      set BUILD_DIR=build-windows

if not exist "%OUT_DIR%"   mkdir "%OUT_DIR%"
if not exist "%BUILD_DIR%" mkdir "%BUILD_DIR%"

echo ==^> LUAJIT_DIR     = %LUAJIT_DIR%
echo ==^> DUCKDB_VERSION = %DUCKDB_VERSION%
echo ==^> OUT_DIR        = %OUT_DIR%
echo ==^> BUILD_DIR      = %BUILD_DIR%

REM LuaJIT lib: accept either the Makefile-style libluajit-5.1.lib or
REM the msvcbuild.bat static output lua51.lib.
set LUAJIT_LIB=%LUAJIT_DIR%\libluajit-5.1.lib
if not exist "%LUAJIT_LIB%" (
    if exist "%LUAJIT_DIR%\lua51.lib" set LUAJIT_LIB=%LUAJIT_DIR%\lua51.lib
)
if not exist "%LUAJIT_LIB%" (
    echo ==^> ERROR: no LuaJIT static library in %LUAJIT_DIR%
    echo         ^(expected libluajit-5.1.lib or lua51.lib^)
    exit /b 1
)
echo ==^> LUAJIT_LIB = %LUAJIT_LIB%

REM CMake configure.
REM
REM Do NOT pass /MT via CMAKE_CXX_FLAGS. CMake's own
REM CMAKE_CXX_FLAGS_RELEASE lands /MD later on the cl.exe command
REM line, which silently overrides /MT (D9025 "overriding /MT with
REM /MD" warnings). The CMakeLists.txt drives the static-CRT choice
REM via CMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded under policy
REM CMP0091 NEW, which CMake enforces throughout — including in
REM DuckDB's own build rules.
REM
REM Do NOT pass /GL + /LTCG. /GL embeds the full IL into every
REM .obj; when lib.exe packs DuckDB's 1400+ objects into the single
REM duckdb_static.lib archive, the total IL blows past MSVC's hard
REM 4 GiB static-library size cap (LNK1248 "image size exceeds
REM maximum allowable size FFFFFFFF"). Stick with plain /O2; LTCG
REM is academic at this scale anyway.
REM
REM DuckDB's platform label on Windows x64 is 'windows_amd64' (no
REM _gcc4 suffix — MSVC uses a single std::string ABI).
REM /FI force-includes win32_undefs_fi.h at the top of every TU.
REM Fixes the CreateDirectory / MoveFile macro collision at the source
REM (see that header for the full explanation). Absolute path needed
REM because cl.exe treats /FI paths relative to its own cwd, not ours.
set FI_HEADER=%CD%\scripts\windows\win32_undefs_fi.h
if not exist "%FI_HEADER%" (
    echo ==^> ERROR: %FI_HEADER% missing
    exit /b 1
)

cmake -S . -B %BUILD_DIR% ^
    -G "Ninja" ^
    -DCMAKE_BUILD_TYPE=Release ^
    -DBUILD_ARCH=amd64 ^
    -DDUCKDB_VERSION=%DUCKDB_VERSION% ^
    -DDUCKDB_PLATFORM=windows_amd64 ^
    -DLUAJIT_STATIC_LIB_PATH=%LUAJIT_LIB% ^
    -DLUAJIT_INCLUDE_DIR=%LUAJIT_DIR% ^
    -DCMAKE_CXX_FLAGS="/DWIN32 /D_WINDOWS /O2 /EHsc /utf-8 /FI\"%FI_HEADER%\"" ^
    -DCMAKE_SHARED_LINKER_FLAGS=""
if errorlevel 1 (
    echo ==^> CMake configure failed
    exit /b 1
)

cmake --build %BUILD_DIR% --target fractalsql_extension --config Release
if errorlevel 1 (
    echo ==^> Build failed
    exit /b 1
)

set OUT_NAME=fractalsql.%DUCKDB_VERSION%.windows_amd64.duckdb_extension
copy /Y "%BUILD_DIR%\fractalsql.duckdb_extension" "%OUT_DIR%\%OUT_NAME%" > nul
if errorlevel 1 (
    echo ==^> Failed to copy extension to %OUT_DIR%
    exit /b 1
)

echo.
echo ==^> Built %OUT_DIR%\%OUT_NAME%

REM ------------------------------------------------------------------
REM Zero-dependency posture checks via dumpbin.
REM ------------------------------------------------------------------
echo.
echo --- dumpbin /dependents ---
dumpbin /nologo /dependents "%OUT_DIR%\%OUT_NAME%"

dumpbin /nologo /dependents "%OUT_DIR%\%OUT_NAME%" | findstr /I "vcruntime msvcp140 msvcr lua51.dll libluajit" > nul
if not errorlevel 1 (
    echo ==^> FAIL: extension has a forbidden runtime dep ^(MSVC CRT or LuaJIT DLL^)
    exit /b 1
)

echo.
echo --- dumpbin /exports ---
dumpbin /nologo /exports "%OUT_DIR%\%OUT_NAME%"

REM DuckDB's extension API renamed its entry points across major
REM versions, and fractalsql_extension.cpp compiles exactly one of the
REM three variants based on FRACTALSQL_NEW_EXTENSION_API:
REM
REM   v1.2.x : fractalsql_init           + fractalsql_version
REM   v1.3.x : fractalsql_init_c_api     + (loader queries version via C API)
REM   v1.4+  : fractalsql_duckdb_cpp_init + fractalsql_duckdb_cpp_version
REM
REM Accept any of the three init names; the Linux assert_so.sh uses the
REM same "any-of" pattern. Hardcoding fractalsql_init fails on 1.4.4 /
REM 1.5.2 which emit the fractalsql_duckdb_cpp_init symbol instead.
set INIT_FOUND=0
dumpbin /nologo /exports "%OUT_DIR%\%OUT_NAME%" | findstr /C:"fractalsql_init" > nul && set INIT_FOUND=1
dumpbin /nologo /exports "%OUT_DIR%\%OUT_NAME%" | findstr /C:"fractalsql_init_c_api" > nul && set INIT_FOUND=1
dumpbin /nologo /exports "%OUT_DIR%\%OUT_NAME%" | findstr /C:"fractalsql_duckdb_cpp_init" > nul && set INIT_FOUND=1
if "%INIT_FOUND%"=="0" (
    echo ==^> FAIL: no fractalsql init entry point exported
    echo         ^(expected fractalsql_init / fractalsql_init_c_api / fractalsql_duckdb_cpp_init^)
    exit /b 1
)

REM Version entry point: 1.2.x exports fractalsql_version; 1.4+ exports
REM fractalsql_duckdb_cpp_version; 1.3.x skips this symbol entirely.
set VER_FOUND=0
dumpbin /nologo /exports "%OUT_DIR%\%OUT_NAME%" | findstr /C:"fractalsql_version" > nul && set VER_FOUND=1
dumpbin /nologo /exports "%OUT_DIR%\%OUT_NAME%" | findstr /C:"fractalsql_duckdb_cpp_version" > nul && set VER_FOUND=1
REM Only enforce the version-symbol check on majors that require it
REM (1.2.x + 1.4+). 1.3.x intentionally omits this symbol, so a
REM missing symbol there is correct, not a failure.
REM
REM findstr /B /C: = anchor at start, literal match. "v1.3." matches
REM v1.3.0 / v1.3.2 / etc. but not v1.2.x / v1.4.x / v1.5.x.
echo %DUCKDB_VERSION% | findstr /B /C:"v1.3." > nul
if errorlevel 1 (
    if "%VER_FOUND%"=="0" (
        echo ==^> FAIL: no fractalsql version entry point exported
        echo         ^(expected fractalsql_version or fractalsql_duckdb_cpp_version^)
        exit /b 1
    )
)

echo.
echo ==^> OK: %OUT_DIR%\%OUT_NAME%
dir "%OUT_DIR%\%OUT_NAME%"

endlocal
