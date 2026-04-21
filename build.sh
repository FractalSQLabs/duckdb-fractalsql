#!/bin/bash
#
# duckdb-fractalsql multi-(version, arch) build driver.
#
# Drives docker/Dockerfile to produce ONE extension file per
# (DUCKDB_VERSION, ARCH) cell:
#
#   dist/${ARCH}/fractalsql.${DUCKDB_VERSION}.linux_${ARCH}.duckdb_extension
#
# e.g.:
#
#   dist/amd64/fractalsql.v1.5.2.linux_amd64.duckdb_extension
#
# Usage:
#   ./build.sh [amd64|arm64]          # default: amd64
#
# Per-DuckDB-version override:
#   DUCKDB_VERSION=v1.2.2 ./build.sh amd64

set -euo pipefail

ARCH="${1:-amd64}"
case "${ARCH}" in
    amd64|arm64) ;;
    *)
        echo "unknown arch '${ARCH}' — expected amd64 or arm64" >&2
        exit 2
        ;;
esac

DIST_DIR="${DIST_DIR:-./dist}"
DOCKERFILE="${DOCKERFILE:-docker/Dockerfile}"
PLATFORM="linux/${ARCH}"
OUT_DIR="${DIST_DIR}/${ARCH}"
DUCKDB_VERSION="${DUCKDB_VERSION:-v1.5.2}"
STAGING_DIR="${OUT_DIR}/.staging-${DUCKDB_VERSION}"

# Version/platform-tagged output name. DuckDB 1.4+ requires the
# filename to END with '.duckdb_extension' (the loader rejects any
# other suffix), so we put the tag in the MIDDLE of the name instead
# of after the extension. Identity still lives in the filename,
# DuckDB still accepts it at LOAD time.
OUT_NAME="fractalsql.${DUCKDB_VERSION}.linux_${ARCH}.duckdb_extension"

mkdir -p "${OUT_DIR}" "${STAGING_DIR}"

echo "------------------------------------------"
echo "Building duckdb-fractalsql for ${PLATFORM}"
echo "  DUCKDB_VERSION=${DUCKDB_VERSION}"
echo "  -> ${OUT_DIR}/${OUT_NAME}"
echo "------------------------------------------"

# CI sets BUILDX_CACHE_ARGS to plug in the GitHub Actions cache
# backend. Scope per (version, arch) so cells don't clobber.
BUILDX_CACHE_ARGS="${BUILDX_CACHE_ARGS:-}"

DOCKER_BUILDKIT=1 docker buildx build \
    --platform "${PLATFORM}" \
    --build-arg "BUILD_ARCH=${ARCH}" \
    --build-arg "DUCKDB_VERSION=${DUCKDB_VERSION}" \
    ${BUILDX_CACHE_ARGS} \
    --target export \
    --output "type=local,dest=${STAGING_DIR}" \
    -f "${DOCKERFILE}" \
    .

# Re-tag the extracted artifact with its (duckdb_version, platform)
# name on the host side. buildx always emits the fixed name the
# scratch export copies; we rename here so the matrix runner can
# upload each cell with an identifiable filename.
mv "${STAGING_DIR}/fractalsql.duckdb_extension" \
   "${OUT_DIR}/${OUT_NAME}"
rm -rf "${STAGING_DIR}"

echo
echo "Built artifact for ${ARCH} @ ${DUCKDB_VERSION}:"
ls -l "${OUT_DIR}/${OUT_NAME}"
file "${OUT_DIR}/${OUT_NAME}" 2>/dev/null || true
