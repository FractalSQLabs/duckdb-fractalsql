// src/include/fractalsql_extension.hpp
//
// duckdb-fractalsql — Stochastic Fractal Search as a DuckDB extension.
//
// This header declares the extension's public entry points. The
// extension registers three scalar functions:
//
//   fractalsql_edition() -> VARCHAR   -- 'Community'
//   fractalsql_version() -> VARCHAR   -- '1.0.0'
//   fractal_search(vector DOUBLE[], query_vector DOUBLE[]) -> DOUBLE
//
// fractal_search returns the cosine distance between `vector` and an
// SFS-refined projection of `query_vector`. The refinement runs once
// per distinct `query_vector` per function instance (cached in the
// function's local state); the per-row work is a tight cosine-distance
// loop on DuckDB's columnar `DataChunk`.

#pragma once

#include "duckdb.hpp"

// DuckDB 1.4 (PR #17772) changed Extension::Load's signature from
// (DuckDB&) to (ExtensionLoader&). FRACTALSQL_DUCKDB_MAJOR /
// FRACTALSQL_DUCKDB_MINOR are defined by CMakeLists.txt per the
// DUCKDB_VERSION tag being built.
#if defined(FRACTALSQL_DUCKDB_MAJOR) && \
    (FRACTALSQL_DUCKDB_MAJOR > 1 || \
     (FRACTALSQL_DUCKDB_MAJOR == 1 && FRACTALSQL_DUCKDB_MINOR >= 4))
#  define FRACTALSQL_NEW_EXTENSION_API 1
#  include "duckdb/main/extension/extension_loader.hpp"
#else
#  define FRACTALSQL_NEW_EXTENSION_API 0
#endif

namespace duckdb {

class FractalsqlExtension : public Extension {
public:
#if FRACTALSQL_NEW_EXTENSION_API
    void Load(ExtensionLoader &loader) override;
#else
    void Load(DuckDB &db) override;
#endif
    std::string Name() override;
    std::string Version() const override;
};

} // namespace duckdb
