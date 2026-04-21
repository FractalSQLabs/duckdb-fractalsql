# syntax=docker/dockerfile:1.7
#
# duckdb-fractalsql Factory build — Community edition, zero-dependency
# posture.
#
# Produces ONE .duckdb_extension per (duckdb_version, platform) cell:
#   /fractalsql.duckdb_extension
#
# The CI driver invokes this Dockerfile once per matrix cell with
# DUCKDB_VERSION set to the pinned patch release and --platform set to
# linux/amd64 or linux/arm64. build.sh renames the output to the
# version/platform-tagged name on the host side after the buildx
# extract.
#
# Build posture
#   * LuaJIT 2.1 compiled with -fPIC BUILDMODE=static, folded into
#     fractalsql.duckdb_extension. No libluajit-5.1.so at runtime.
#   * DuckDB's full source tree pulled via CMake FetchContent at the
#     pinned tag (needed because libduckdb-*.zip doesn't expose the
#     extension-facing C++ API — ExtensionUtil, BoundFunctionExpression,
#     CatalogTransaction, etc.).
#   * -D_GLIBCXX_USE_CXX11_ABI=0 throughout. DuckDB's official release
#     CLI is built with the legacy gcc4 std::string ABI
#     (platform label linux_{amd64,arm64}_gcc4); our std::string
#     layouts must match so the CLI can dlopen us.
#   * -static-libgcc -static-libstdc++: the extension depends on glibc
#     alone (no libstdc++.so.6, no libgcc_s.so.1).
#   * -Wl,--exclude-libs,ALL: duckdb_static + libluajit symbols stay
#     local; they don't bleed into .dynsym.
#   * -Wl,--gc-sections + --strip-all: drop unused code, strip .symtab.
#     .dynsym survives, which is what DuckDB's loader reads.
#
# Naming gotchas
#   * LuaJIT's Makefile uses TARGET_ARCH as a compiler flag knob; we
#     deliberately name our arch variable BUILD_ARCH and unset
#     TARGET_ARCH inside the luajit-static stage.
#   * LuaJIT from the github.com/LuaJIT mirror, not luajit.org/git —
#     the latter serves dumb HTTP and rejects shallow clones.
#
# CI time
#   Cold builds of DuckDB from source are ~15-30 min on amd64 and
#   ~60+ min under QEMU for arm64. BuildKit cache mounts + ccache
#   amortize subsequent runs to ~1-2 min.

# --------------------------------------------------------------------
# GLOBAL ARGs — declared BEFORE the first FROM so every stage can
# re-import them with bare `ARG NAME`. ARGs declared inside a stage
# are stage-scoped; later stages that re-import them pick up empty
# strings, which silently drops flags.
# --------------------------------------------------------------------

# Per-DuckDB-minor pinned patch releases. Updating any of these is a
# one-line change when a new point release lands upstream. CI selects
# one of these per matrix cell via --build-arg DUCKDB_VERSION=...
# (values passed with the leading 'v', e.g. v1.5.2).
#
# Matrix rationale (April 2026):
#   DuckDB 1.2.2 — legacy gcc4 ABI regression canary. Kept as proof
#                  that the legacy-ABI path still works; dropping
#                  would leave no coverage for users still on pre-1.3.
#   DuckDB 1.4.4 — current LTS (Andium, supported until Sept 2026).
#                  This is what most production users should target.
#   DuckDB 1.5.2 — current stable (Variegata). Latest available from
#                  duckdb.org's download page.
#
# Dropped (no longer useful to ship):
#   v1.0.0 / v1.1.3  — neither is on duckdb.org's download page; LTS
#                      for 1.1 ended February 2025; upstream loader
#                      has a quirk that crashed our extension at LOAD.
#   v1.3.2           — superseded by 1.4 LTS on the supported-release
#                      ladder; no LTS commitment.
ARG DUCKDB_V_1_2=v1.2.2
ARG DUCKDB_V_1_4=v1.4.4
ARG DUCKDB_V_1_5=v1.5.2

# Active version for this build. CI sets this to one of the pinned
# values above.
ARG DUCKDB_VERSION=v1.5.2

# LuaJIT source.
ARG LUAJIT_GIT_URL=https://github.com/LuaJIT/LuaJIT.git
ARG LUAJIT_GIT_REF=v2.1

# BUILD_ARCH — the host-visible arch tag. Deliberately not named
# TARGET_ARCH (clashes with LuaJIT's Makefile).
ARG BUILD_ARCH=amd64

# EXT_CFLAGS / EXT_LDFLAGS — hardened flag set.
#
# -D_GLIBCXX_USE_CXX11_ABI is NOT set here. CMakeLists.txt picks the
# ABI per DuckDB version: legacy (=0) for <=1.2, new (unset) for >=1.3.
# DuckDB 1.3+ Linux releases dropped the legacy-ABI posture, so forcing
# =0 against 1.3+ now hits a hard #error in platform.hpp.
#
# -ffunction-sections / -fdata-sections
#     Per-symbol sectioning, pairs with -Wl,--gc-sections.
# -static-libgcc / -static-libstdc++
#     Link runtime helpers statically.
# -Wl,--strip-all
#     Drop .symtab. .dynsym survives (the loader needs it).
# -Wl,--gc-sections / --exclude-libs are emitted by CMakeLists.txt's
# per-toolchain link rules (GNU ld only); not duplicated here.
ARG EXT_CFLAGS="-ffunction-sections -fdata-sections"
ARG EXT_LDFLAGS="-static-libgcc -static-libstdc++ -Wl,--strip-all"

# Size ceiling. DuckDB extensions historically run 500 KB - 2 MB;
# ours bundles LuaJIT + DuckDB's internal dependencies, so 20 MiB
# leaves headroom. Bump only with a commit-message explanation.
ARG SIZE_CEILING_BYTES=20971520

# --------------------------------------------------------------------
# Stage: PIC-built LuaJIT static archive.
# --------------------------------------------------------------------
FROM debian:bookworm-slim AS luajit-static
ARG LUAJIT_GIT_URL
ARG LUAJIT_GIT_REF
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        build-essential ca-certificates git \
 && rm -rf /var/lib/apt/lists/*
RUN git clone --depth=1 --branch "${LUAJIT_GIT_REF}" \
        "${LUAJIT_GIT_URL}" /src/luajit
WORKDIR /src/luajit
RUN unset TARGET_ARCH \
 && make BUILDMODE=static XCFLAGS="-fPIC" PREFIX=/opt/luajit -j"$(nproc)" TARGET_ARCH= \
 && make install BUILDMODE=static PREFIX=/opt/luajit \
 && test -f /opt/luajit/lib/libluajit-5.1.a \
 && ! test -f /opt/luajit/lib/libluajit-5.1.so

# --------------------------------------------------------------------
# Stage: fractalsql.duckdb_extension builder.
#
# One generic stage. DUCKDB_VERSION is a build-arg the CI driver sets
# per matrix cell — the global ARG block above provides the canonical
# pins per minor. Rolling any minor to a new patch release is a
# one-line change to the ARG block at the top of this file.
# --------------------------------------------------------------------
FROM debian:bookworm-slim AS builder

ARG DUCKDB_VERSION
ARG BUILD_ARCH
ARG EXT_CFLAGS
ARG EXT_LDFLAGS
ARG SIZE_CEILING_BYTES

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        build-essential \
        binutils \
        cmake \
        ccache \
        ninja-build \
        pkg-config \
        curl \
        file \
        git \
        python3 \
        ca-certificates \
 && rm -rf /var/lib/apt/lists/*

COPY --from=luajit-static /opt/luajit /opt/luajit

WORKDIR /build
COPY CMakeLists.txt      /build/
COPY src/                /build/src/
COPY include/            /build/include/
COPY scripts/            /build/scripts/
COPY docker/assert_so.sh /build/docker/assert_so.sh

# Configure + build.
#
# --target fractalsql_extension restricts the build to the minimal
# set of targets our extension transitively needs (essentially
# duckdb_static + its third-party deps + our .cpp). Skips
# libduckdb.so, parquet.duckdb_extension, jemalloc_extension.a, and
# the rest of DuckDB's default target set.
#
# EXT_CFLAGS / EXT_LDFLAGS ride in via CMAKE_CXX_FLAGS and
# CMAKE_SHARED_LINKER_FLAGS so they appear AFTER CMakeLists.txt's
# -fvisibility=hidden on the command line — the last flag wins, so
# the DuckDB entry points land in .dynsym.
RUN --mount=type=cache,target=/build/cmake-build,sharing=locked \
    --mount=type=cache,target=/root/.ccache,sharing=locked \
    set -eux; \
    export CCACHE_DIR=/root/.ccache; \
    export CC="ccache gcc"; \
    export CXX="ccache g++"; \
    cmake -G Ninja -S /build -B /build/cmake-build \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_ARCH="${BUILD_ARCH}" \
        -DDUCKDB_VERSION="${DUCKDB_VERSION}" \
        -DLUAJIT_STATIC_LIB_PATH=/opt/luajit/lib/libluajit-5.1.a \
        -DLUAJIT_INCLUDE_DIR=/opt/luajit/include/luajit-2.1 \
        -DCMAKE_C_COMPILER_LAUNCHER=ccache \
        -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
        -DCMAKE_CXX_FLAGS="${EXT_CFLAGS}" \
        -DCMAKE_SHARED_LINKER_FLAGS="${EXT_LDFLAGS}"; \
    cmake --build /build/cmake-build -j"$(nproc)" \
          --target fractalsql_extension; \
    cp /build/cmake-build/fractalsql.duckdb_extension /fractalsql.duckdb_extension; \
    # Pass ABI=legacy for DuckDB <=1.2.x, ABI=new for >=1.3. The
    # version parse in CMakeLists.txt already decides the compile
    # flags; the script assertion has to agree or it trips on
    # correctly-built new-ABI artifacts.
    case "${DUCKDB_VERSION}" in \
        v1.0.*|v1.1.*|v1.2.*) ABI=legacy ;; \
        *)                    ABI=new    ;; \
    esac; \
    sh /build/docker/assert_so.sh /fractalsql.duckdb_extension "${SIZE_CEILING_BYTES}" "${ABI}"

# --------------------------------------------------------------------
# Scratch export — buildx --output=local drops just the .duckdb_extension.
# --------------------------------------------------------------------
FROM scratch AS export
COPY --from=builder /fractalsql.duckdb_extension /fractalsql.duckdb_extension
