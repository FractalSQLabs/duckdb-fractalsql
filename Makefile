# duckdb-fractalsql Makefile — thin wrapper around CMake.
#
# For multi-arch release artifacts use:
#   ./build.sh amd64 | ./build.sh arm64
#
# This Makefile is the quick-iteration path for native-arch dev.

BUILD_DIR ?= build
BUILD_ARCH ?= amd64
DUCKDB_VERSION ?= v1.5.2

.PHONY: all configure build clean distclean test

all: build

configure:
	cmake -S . -B $(BUILD_DIR) \
	    -DCMAKE_BUILD_TYPE=Release \
	    -DBUILD_ARCH=$(BUILD_ARCH) \
	    -DDUCKDB_VERSION=$(DUCKDB_VERSION)

build: configure
	cmake --build $(BUILD_DIR) -j$(shell nproc 2>/dev/null || echo 2)
	@echo
	@echo "Built $(BUILD_DIR)/fractalsql.duckdb_extension"

# `make test` runs the smoke-test SQL through the DuckDB CLI.
# Requires the `duckdb` binary on PATH.
#
#  -unsigned:  enable unsigned-extension loading at startup.
#              DuckDB 1.1+ rejects SET allow_unsigned_extensions=true
#              once the DB is open, so it must be a CLI flag.
#  -init vs stdin: DuckDB runs the -init script BEFORE any -cmd
#              statements take effect, which means the LOAD must be
#              in the SQL stream itself. Simplest reliable setup:
#              feed the LOAD + smoke_test.sql via stdin.
test: build
	{ echo "LOAD '$(BUILD_DIR)/fractalsql.duckdb_extension';"; \
	  cat test/smoke_test.sql; } | duckdb -bail -unsigned

clean:
	cmake --build $(BUILD_DIR) --target clean 2>/dev/null || true

distclean:
	rm -rf $(BUILD_DIR)
