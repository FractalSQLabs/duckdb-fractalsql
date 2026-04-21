#!/bin/sh
# docker/assert_so.sh — zero-dependency posture check for the built
# fractalsql.duckdb_extension. Runs inside the builder stage so any
# regression trips the build before the artifact is emitted.
#
# Usage:
#   assert_so.sh <extension> <size_ceiling_bytes> [abi]
#
# where [abi] is:
#   legacy  — built with -D_GLIBCXX_USE_CXX11_ABI=0 (DuckDB <= 1.2.x).
#             Assert that NO __cxx11::basic_string symbols appear:
#             their presence means the legacy-ABI flag didn't stick.
#   new     — built against modern libstdc++ (DuckDB >= 1.3). The
#             __cxx11::basic_string namespace IS the expected symbol
#             name for std::string on this ABI; skip the check.
#             (default)
#
# Fails if:
#   * ldd reports any dynamic library outside the glibc shortlist
#   * nm reports __cxx11::basic_string symbols AND abi == legacy
#   * the file exceeds the size ceiling
#   * expected extension entry points are missing from .dynsym

set -eu

SO="${1:?usage: assert_so.sh <extension> <ceiling> [abi]}"
CEILING="${2:?usage: assert_so.sh <extension> <ceiling> [abi]}"
ABI="${3:-new}"

echo "=== assert_so.sh ${SO} (ceiling ${CEILING} bytes) ==="

echo "--- file ---"
file "${SO}"

echo "--- ldd ---"
ldd "${SO}" || true

# Assertion 1: no dynamic libluajit / libstdc++ dependency.
if ldd "${SO}" | grep -E 'libluajit|libstdc\+\+' >/dev/null; then
    echo "FAIL: ${SO} links dynamic libluajit or libstdc++" >&2
    exit 1
fi

# Assertion 2: every library listed by ldd is on the glibc shortlist.
#   linux-vdso.so.1       (kernel-provided, no file)
#   libc.so.6
#   libm.so.6
#   libdl.so.2            (merged into libc on glibc 2.34+, may still appear)
#   libpthread.so.0       (merged into libc on glibc 2.34+, may still appear)
#   librt.so.1            (merged into libc on glibc 2.34+, may still appear)
#   /lib*/ld-linux-*.so.* (dynamic loader)
BAD=$(ldd "${SO}" \
        | awk '{print $1}' \
        | grep -vE '^(linux-vdso\.so\.1|libc\.so\.6|libm\.so\.6|libdl\.so\.2|libpthread\.so\.0|librt\.so\.1|/.*/ld-linux.*\.so\.[0-9]+)$' \
        | grep -v '^$' || true)
if [ -n "${BAD}" ]; then
    echo "FAIL: ${SO} has disallowed dynamic deps:" >&2
    echo "${BAD}" >&2
    exit 1
fi

# Assertion 3: __cxx11::basic_string symbols.
#   legacy ABI (<=1.2): MUST NOT appear — their presence means
#                       _GLIBCXX_USE_CXX11_ABI=0 didn't take effect,
#                       and the extension's std::string layout won't
#                       match what DuckDB's release CLI expects.
#   new ABI (>=1.3):    normal and expected — std::__cxx11::basic_string
#                       is the libstdc++ tagged C++11 std::string symbol.
echo "--- nm -D -C | grep __cxx11::basic_string (abi=${ABI}) ---"
case "${ABI}" in
    legacy)
        if nm -D -C "${SO}" 2>/dev/null | grep -F '__cxx11::basic_string' >/dev/null; then
            echo "FAIL: legacy-ABI build leaked __cxx11::basic_string symbols" >&2
            nm -D -C "${SO}" | grep -F '__cxx11::basic_string' >&2 || true
            exit 1
        fi
        echo "  no __cxx11 symbols (legacy ABI intact)"
        ;;
    new)
        echo "  skipping cxx11 check (new libstdc++ ABI expected)"
        ;;
    *)
        echo "FAIL: unknown ABI '${ABI}' (want 'legacy' or 'new')" >&2
        exit 1
        ;;
esac

# Assertion 4: size ceiling.
SZ=$(stat -c '%s' "${SO}")
echo "size: ${SZ} bytes (ceiling ${CEILING})"
if [ "${SZ}" -gt "${CEILING}" ]; then
    echo "FAIL: ${SO} exceeds size ceiling ${CEILING}" >&2
    exit 1
fi

# Assertion 5: DuckDB-expected entry points are exported.
#
# DuckDB's loader resolves the init/version symbols via dlsym. The
# names vary per DuckDB major.minor:
#
#   <=1.2.x   C++ ABI:   <extname>_init          + <extname>_version
#             C ABI:     <extname>_init_c_api
#   >=1.4.x   C++ ABI:   <extname>_duckdb_cpp_init
#                      + <extname>_duckdb_cpp_version
#             C ABI:     <extname>_init_c_api
#
# We require at least ONE init symbol and at least ONE version
# symbol to be present — whichever name the ABI-matched DuckDB CLI
# will dlsym at LOAD time.
echo "--- dynsym DuckDB entry points ---"
HAS_INIT=0
for sym in fractalsql_init fractalsql_init_c_api fractalsql_duckdb_cpp_init; do
    if nm -D "${SO}" 2>/dev/null | awk '{print $NF}' | grep -Fx "${sym}" >/dev/null; then
        echo "  ${sym}: present"
        HAS_INIT=1
    fi
done
if [ "${HAS_INIT}" -eq 0 ]; then
    echo "FAIL: no fractalsql init entry point in .dynsym" >&2
    echo "      (looked for fractalsql_init / fractalsql_init_c_api / fractalsql_duckdb_cpp_init)" >&2
    exit 1
fi
HAS_VERSION=0
for sym in fractalsql_version fractalsql_duckdb_cpp_version; do
    if nm -D "${SO}" 2>/dev/null | awk '{print $NF}' | grep -Fx "${sym}" >/dev/null; then
        echo "  ${sym}: present"
        HAS_VERSION=1
    fi
done
if [ "${HAS_VERSION}" -eq 0 ]; then
    echo "FAIL: no fractalsql version entry point in .dynsym" >&2
    echo "      (looked for fractalsql_version / fractalsql_duckdb_cpp_version)" >&2
    exit 1
fi

# Assertion 6: DuckDB metadata footer is present. The footer is
# appended by scripts/append_metadata.py with a recognizable
# 'duckdb_signature' tag inside a WebAssembly-style custom section.
echo "--- metadata footer ---"
if ! grep -a -c 'duckdb_signature' "${SO}" >/dev/null; then
    echo "FAIL: ${SO} missing DuckDB metadata footer" >&2
    exit 1
fi
echo "  duckdb_signature: present"

echo "OK: ${SO}"
