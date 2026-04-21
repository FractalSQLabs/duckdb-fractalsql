#!/usr/bin/env python3
"""Appends DuckDB's loadable-extension metadata footer to a .so.

Port of duckdb/scripts/append_metadata.cmake. The footer is a 534-byte
custom section DuckDB parses at `LOAD` time to validate compatibility.

Layout:
    [1  byte    : 0x00                   custom section marker      ]
    [2  bytes   : ULEB128(531)           payload length             ]
    [1  byte    : 0x10 = 16              name length                ]
    [16 bytes   : 'duckdb_signature'     name                       ]
    [2  bytes   : ULEB128(512)           metadata+signature length  ]
    [8 x 32     : metadata fields        appended in REVERSE order  ]
    [256 bytes  : zeros                  unsigned-signature placeholder ]

Metadata field mapping (matches the cmake script):
    META1 = literal '4'                  metadata format version
    META2 = platform                     e.g. 'linux_amd64_gcc4'
    META3 = duckdb version               e.g. 'v1.1.3'
    META4 = extension version            e.g. 'v1.0.0'
    META5 = ABI type                     '' for C++ extensions,
                                         'C_STRUCT' for C-API extensions
    META6..8 = empty

Usage:
    python3 append_metadata.py \\
        --extension path/to/fractalsql.duckdb_extension \\
        --platform linux_amd64_gcc4 \\
        --duckdb-version v1.1.3 \\
        --extension-version v1.0.0
"""

import argparse


def pad32(s: str) -> bytes:
    b = s.encode("utf-8")[:32]
    return b + b"\x00" * (32 - len(b))


def build_footer(platform: str, duckdb_version: str,
                 extension_version: str, abi_type: str) -> bytes:
    f = bytearray()
    f += b"\x00"                    # custom section marker
    f += b"\x93\x04"                # payload length = 531, ULEB128
    f += b"\x10"                    # name length = 16
    f += b"duckdb_signature"        # 16 bytes
    f += b"\x80\x04"                # inner length = 512, ULEB128

    # Metadata fields appended in REVERSE order (8 .. 1).
    f += pad32("")                  # META8
    f += pad32("")                  # META7
    f += pad32("")                  # META6
    f += pad32(abi_type)            # META5 — empty = C++ extension
    f += pad32(extension_version)   # META4
    f += pad32(duckdb_version)      # META3
    f += pad32(platform)            # META2
    f += pad32("4")                 # META1

    # 256-byte signature (zero fill = unsigned extension).
    f += b"\x00" * 256
    return bytes(f)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--extension", required=True,
                    help="Path to the .duckdb_extension (modified in place)")
    ap.add_argument("--platform", required=True,
                    help="DuckDB platform string, e.g. linux_amd64_gcc4")
    ap.add_argument("--duckdb-version", required=True)
    ap.add_argument("--extension-version", required=True)
    ap.add_argument("--abi-type", default="",
                    help="ABI type. Empty = C++ extension (default). "
                         "'C_STRUCT' = new C-API extension.")
    args = ap.parse_args()

    footer = build_footer(
        platform=args.platform,
        duckdb_version=args.duckdb_version,
        extension_version=args.extension_version,
        abi_type=args.abi_type,
    )
    with open(args.extension, "ab") as f:
        f.write(footer)
    print(f"appended {len(footer)}-byte metadata footer to {args.extension}")


if __name__ == "__main__":
    main()
