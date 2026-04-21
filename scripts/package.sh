#!/usr/bin/env bash
#
# scripts/package.sh — duckdb-fractalsql packaging.
#
# DuckDB extensions are NOT system-installed. There's no .deb / .rpm /
# .msi — distribution is just the single-file .duckdb_extension per
# (duckdb_version, platform) cell. This script emits two artifacts per
# cell into dist/packages/:
#
#   1. The raw extension file, copied with the version/platform tag in
#      its name so it survives a Release upload with identity intact:
#
#        dist/packages/fractalsql.v1.5.2.linux_amd64.duckdb_extension
#
#   2. A per-(duckdb_version, platform) .zip bundle containing the
#      extension + LICENSE + LICENSE-THIRD-PARTY + README.txt:
#
#        dist/packages/duckdb-fractalsql-v1.5.2-linux_amd64.zip
#
# Assumes build.sh has already produced:
#   dist/${ARCH}/fractalsql.${DUCKDB_VERSION}.linux_${ARCH}.duckdb_extension
#
# Usage:
#   scripts/package.sh [amd64|arm64]     # default: amd64
#
# Per-version override:
#   DUCKDB_VERSION=v1.2.2 scripts/package.sh amd64
#
# LICENSE staging note
#   Files staged via `install -Dm0644` into a scratch dir before
#   zipping. Explicit src=dst zip mappings with absolute paths run
#   into the same chroot trap as fpm -C, so keep staging explicit.

set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="1.0.0"
DIST_DIR="dist/packages"
mkdir -p "${DIST_DIR}"

PKG_ARCH="${1:-amd64}"
case "${PKG_ARCH}" in
    amd64|arm64) ;;
    *)
        echo "unknown arch '${PKG_ARCH}' — expected amd64 or arm64" >&2
        exit 2
        ;;
esac

DUCKDB_VERSION="${DUCKDB_VERSION:-v1.5.2}"
PLATFORM_TAG="linux_${PKG_ARCH}"
EXT_NAME="fractalsql.${DUCKDB_VERSION}.${PLATFORM_TAG}.duckdb_extension"
SRC_EXT="dist/${PKG_ARCH}/${EXT_NAME}"

if [ ! -f "${SRC_EXT}" ]; then
    echo "missing ${SRC_EXT} — run:" >&2
    echo "    DUCKDB_VERSION=${DUCKDB_VERSION} ./build.sh ${PKG_ARCH}" >&2
    exit 1
fi

for f in LICENSE THIRD-PARTY-NOTICES.md; do
    if [ ! -f "${f}" ]; then
        echo "missing ${f} — refusing to package without it" >&2
        exit 1
    fi
done

# ---------------------------------------------------------------------
# Artifact 1: raw extension file, version/platform-tagged filename,
# copied straight into dist/packages/.
# ---------------------------------------------------------------------
install -Dm0644 "${SRC_EXT}" "${DIST_DIR}/${EXT_NAME}"
echo "staged ${DIST_DIR}/${EXT_NAME}"

# ---------------------------------------------------------------------
# Artifact 2: .zip bundle with LICENSE + LICENSE-THIRD-PARTY + README.
# ---------------------------------------------------------------------
ZIP_NAME="duckdb-fractalsql-${DUCKDB_VERSION}-${PLATFORM_TAG}.zip"
ZIP_OUT="${DIST_DIR}/${ZIP_NAME}"

STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT

install -Dm0644 "${SRC_EXT}"                "${STAGE}/${EXT_NAME}"
install -Dm0644 LICENSE                     "${STAGE}/LICENSE"
install -Dm0644 THIRD-PARTY-NOTICES.md      "${STAGE}/LICENSE-THIRD-PARTY"
install -Dm0644 sql/load_extension.sql      "${STAGE}/load_extension.sql"
cat > "${STAGE}/README.txt" <<EOF
duckdb-fractalsql ${VERSION} Community (${DUCKDB_VERSION} / ${PLATFORM_TAG})

This archive ships an UNSIGNED DuckDB extension. Load it with the
-unsigned CLI flag (DuckDB 1.1+ rejects a runtime SET for this):

    duckdb -unsigned \\
        -cmd "LOAD '\$(pwd)/${EXT_NAME}';"

SQL surface:
    fractalsql_edition()          VARCHAR   -- 'Community'
    fractalsql_version()          VARCHAR   -- '${VERSION}'
    fractal_search(vec, query)    DOUBLE    -- SFS-refined cosine distance

Programmatic (Python):
    import duckdb
    con = duckdb.connect(config={'allow_unsigned_extensions': True})
    con.load_extension('/path/to/${EXT_NAME}')
    con.sql("SELECT fractalsql_edition(), fractalsql_version()").show()

Verify the extension built against DuckDB ${DUCKDB_VERSION} only.
Mismatched builds are refused by the loader.

See load_extension.sql in this archive for more examples.
EOF

(
    cd "${STAGE}"
    zip -9 -r "${OLDPWD}/${ZIP_OUT}" . > /dev/null
)
rm -rf "${STAGE}"
trap - EXIT

echo "built ${ZIP_OUT}"
echo
echo "Done. Artifacts in ${DIST_DIR}:"
ls -l "${DIST_DIR}"
