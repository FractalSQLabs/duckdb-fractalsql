// src/fractalsql_extension.cpp
//
// duckdb-fractalsql Community — vectorized Stochastic Fractal Search
// as a DuckDB loadable extension.
//
// SQL surface (registered in FractalsqlExtension::Load):
//
//   fractalsql_edition() -> VARCHAR              -- 'Community'
//   fractalsql_version() -> VARCHAR              -- '1.0.0'
//   fractal_search(vector DOUBLE[],
//                  query_vector DOUBLE[]) -> DOUBLE
//
// fractal_search returns the cosine distance between `vector` and an
// SFS-refined projection of `query_vector`. Typical usage:
//
//   SELECT id, fractal_search(embedding, [0.1, 0.2, -0.3]::DOUBLE[])
//       AS dist
//   FROM my_embeddings
//   ORDER BY dist
//   LIMIT 10;
//
// Vectorized execution
//   DuckDB hands us a DataChunk per call (typically 2048 rows) plus
//   the same constant query_vector broadcast across all rows. We:
//     1. Pull the constant query once from arg[1].
//     2. Run SFS once per distinct query (cached in the function's
//        FunctionLocalState), producing a refined best_point in R^dim.
//     3. Iterate the LIST<DOUBLE> rows in arg[0] and compute cosine
//        distance to best_point in a tight inner loop.
//
// LuaJIT is statically linked into fractalsql.duckdb_extension so
// the shipped artifact has zero runtime Lua dependency. The SFS
// optimizer ships as pre-compiled LuaJIT bytecode embedded via
// include/sfs_core_bc.h (symbol: luaJIT_BC_fractalsql_community).

#define DUCKDB_EXTENSION_MAIN

#include "fractalsql_extension.hpp"

// DuckDB's extension-facing API (available only from the full source
// tree pulled via FetchContent, not from the libduckdb-*.zip
// amalgamation the embedder bundle ships).
#include "duckdb/function/scalar_function.hpp"
#include "duckdb/parser/parsed_data/create_scalar_function_info.hpp"
#include "duckdb/planner/expression/bound_function_expression.hpp"
#include "duckdb/execution/expression_executor_state.hpp"

// Extension registration API — broke at 1.4 (PR #17772). The .hpp
// already selected FRACTALSQL_NEW_EXTENSION_API and included
// extension_loader.hpp in the new-API case; here we include
// extension_util.hpp only on the legacy branch.
#if !FRACTALSQL_NEW_EXTENSION_API
#  include "duckdb/main/extension_util.hpp"
#endif

#include <cmath>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

extern "C" {
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
#include <luajit.h>
}

// sfs_core_bc.h declares a plain C byte array; include it via extern "C".
extern "C" {
#include "sfs_core_bc.h"
}

// Export decoration for the C entry points DuckDB's loader looks up via
// dlsym / GetProcAddress. On POSIX we already emit them with default
// visibility from the Dockerfile's -fvisibility=default; on Windows we
// need __declspec(dllexport). Apply at the definition site only — never
// forward-declare an exported entry point (MSVC C2375).
#if defined(_WIN32) || defined(__CYGWIN__)
#  define FRACTAL_EXPORT __declspec(dllexport)
#else
#  define FRACTAL_EXPORT
#endif

namespace duckdb {

static constexpr const char *kFractalsqlEdition = "Community";
static constexpr const char *kFractalsqlVersion = "1.0.0";

// --------------------------------------------------------------------
// Helpers: Lua state wrapping the embedded SFS bytecode.
// --------------------------------------------------------------------

static constexpr int kDefaultIterations = 30;
static constexpr int kDefaultPopSize    = 50;
static constexpr int kDefaultDiff       = 2;
static constexpr double kDefaultWalk    = 0.5;

struct LuaState {
    lua_State *L = nullptr;
    int module_ref = LUA_NOREF;

    LuaState() {
        L = luaL_newstate();
        if (!L) {
            throw IOException("fractalsql: failed to allocate LuaJIT state");
        }
        luaL_openlibs(L);

        int rc = luaL_loadbuffer(L,
            reinterpret_cast<const char *>(luaJIT_BC_fractalsql_community),
            luaJIT_BC_fractalsql_community_SIZE,
            "=fractalsql_community");
        if (rc != 0) {
            const char *m = lua_tostring(L, -1);
            std::string msg = m ? m : "unknown";
            lua_close(L); L = nullptr;
            throw IOException("fractalsql: load bytecode: " + msg);
        }
        rc = lua_pcall(L, 0, 1, 0);
        if (rc != 0) {
            const char *m = lua_tostring(L, -1);
            std::string msg = m ? m : "unknown";
            lua_close(L); L = nullptr;
            throw IOException("fractalsql: init bytecode: " + msg);
        }
        module_ref = luaL_ref(L, LUA_REGISTRYINDEX);
    }

    ~LuaState() {
        if (L) lua_close(L);
    }

    LuaState(const LuaState &) = delete;
    LuaState &operator=(const LuaState &) = delete;
};

// Run SFS sniper-mode with fitness = cosine_distance(., query). Returns
// the best_point found (length == query.size()).
static std::vector<double>
RunSfsBestPoint(LuaState &st, const std::vector<double> &query) {
    lua_State *L = st.L;
    int dim = static_cast<int>(query.size());
    int saved_top = lua_gettop(L);

    lua_rawgeti(L, LUA_REGISTRYINDEX, st.module_ref);
    lua_getfield(L, -1, "run");
    lua_getfield(L, -2, "cosine_fitness");
    lua_remove(L, -3);

    lua_createtable(L, dim, 0);
    for (int i = 0; i < dim; i++) {
        lua_pushnumber(L, query[i]);
        lua_rawseti(L, -2, i + 1);
    }
    if (lua_pcall(L, 1, 1, 0) != 0) {
        std::string msg = lua_tostring(L, -1) ? lua_tostring(L, -1) : "?";
        lua_settop(L, saved_top);
        throw IOException("fractalsql: cosine_fitness: " + msg);
    }

    lua_createtable(L, 0, 8);
    lua_createtable(L, dim, 0);
    for (int i = 1; i <= dim; i++) { lua_pushnumber(L, -1.0); lua_rawseti(L, -2, i); }
    lua_setfield(L, -2, "lower");
    lua_createtable(L, dim, 0);
    for (int i = 1; i <= dim; i++) { lua_pushnumber(L,  1.0); lua_rawseti(L, -2, i); }
    lua_setfield(L, -2, "upper");
    lua_pushinteger(L, kDefaultIterations); lua_setfield(L, -2, "max_generation");
    lua_pushinteger(L, kDefaultPopSize);    lua_setfield(L, -2, "population_size");
    lua_pushinteger(L, kDefaultDiff);       lua_setfield(L, -2, "maximum_diffusion");
    lua_pushnumber (L, kDefaultWalk);       lua_setfield(L, -2, "walk");
    lua_pushboolean(L, 1);                  lua_setfield(L, -2, "bound_clipping");
    lua_pushvalue(L, -2);
    lua_setfield(L, -2, "fitness");
    lua_remove(L, -2);

    if (lua_pcall(L, 1, 4, 0) != 0) {
        std::string msg = lua_tostring(L, -1) ? lua_tostring(L, -1) : "?";
        lua_settop(L, saved_top);
        throw IOException("fractalsql: sfs_core.run: " + msg);
    }

    int bp_idx = saved_top + 1;
    std::vector<double> best(dim);
    for (int i = 0; i < dim; i++) {
        lua_rawgeti(L, bp_idx, i + 1);
        best[i] = lua_tonumber(L, -1);
        lua_pop(L, 1);
    }
    lua_settop(L, saved_top);
    return best;
}

// --------------------------------------------------------------------
// FunctionLocalState — one Lua state per DuckDB pipeline thread, plus
// a cache of (query -> best_point).
// --------------------------------------------------------------------

struct FractalLocalState : public FunctionLocalState {
    LuaState lua;
    std::vector<double> cached_query;
    std::vector<double> cached_best_point;
};

static unique_ptr<FunctionLocalState>
InitLocalState(ExpressionState &state,
               const BoundFunctionExpression &expr,
               FunctionData *bind_data) {
    return make_uniq<FractalLocalState>();
}

static bool
PullRowVector(Vector &list_vec, idx_t row_idx, std::vector<double> &out) {
    UnifiedVectorFormat list_fmt;
    list_vec.ToUnifiedFormat(1, list_fmt);
    auto list_entries = ListVector::GetData(list_vec);
    auto &child = ListVector::GetEntry(list_vec);

    UnifiedVectorFormat parent_fmt;
    list_vec.ToUnifiedFormat(row_idx + 1, parent_fmt);
    idx_t mapped = parent_fmt.sel->get_index(row_idx);
    if (!parent_fmt.validity.RowIsValid(mapped)) return false;

    auto entry = list_entries[mapped];
    out.resize(entry.length);

    UnifiedVectorFormat child_fmt;
    child.ToUnifiedFormat(entry.offset + entry.length, child_fmt);
    auto child_data = reinterpret_cast<const double *>(child_fmt.data);
    for (idx_t j = 0; j < entry.length; j++) {
        idx_t cm = child_fmt.sel->get_index(entry.offset + j);
        if (!child_fmt.validity.RowIsValid(cm)) return false;
        out[j] = child_data[cm];
    }
    return true;
}

static bool
PullConstantVector(Vector &list_vec, std::vector<double> &out) {
    if (list_vec.GetVectorType() != VectorType::CONSTANT_VECTOR) {
        return PullRowVector(list_vec, 0, out);
    }
    if (ConstantVector::IsNull(list_vec)) return false;
    return PullRowVector(list_vec, 0, out);
}

static double
CosineDistance(const double *a, const double *b, int dim) {
    double dot = 0, na = 0, nb = 0;
    for (int i = 0; i < dim; i++) {
        dot += a[i] * b[i];
        na  += a[i] * a[i];
        nb  += b[i] * b[i];
    }
    if (na == 0 || nb == 0) return 1.0;
    return 1.0 - dot / (std::sqrt(na) * std::sqrt(nb));
}

// --------------------------------------------------------------------
// Scalar function bodies.
// --------------------------------------------------------------------

static void
FractalSearchFunction(DataChunk &args, ExpressionState &state, Vector &result) {
    auto &local = ExecuteFunctionState::GetFunctionState(state)
                      ->Cast<FractalLocalState>();

    auto &vec_col   = args.data[0];
    auto &query_col = args.data[1];
    idx_t count     = args.size();

    std::vector<double> query;
    if (!PullConstantVector(query_col, query)) {
        result.SetVectorType(VectorType::CONSTANT_VECTOR);
        ConstantVector::SetNull(result, true);
        return;
    }

    bool hit_cache = (query == local.cached_query)
                     && !local.cached_best_point.empty();
    if (!hit_cache) {
        local.cached_best_point = RunSfsBestPoint(local.lua, query);
        local.cached_query      = query;
    }
    const auto &best_point = local.cached_best_point;
    int dim = static_cast<int>(best_point.size());

    auto result_data = FlatVector::GetData<double>(result);
    auto &result_validity = FlatVector::Validity(result);

    std::vector<double> row;
    row.reserve(dim);

    for (idx_t i = 0; i < count; i++) {
        if (!PullRowVector(vec_col, i, row) || row.size() != static_cast<size_t>(dim)) {
            result_validity.SetInvalid(i);
            continue;
        }
        result_data[i] = CosineDistance(row.data(), best_point.data(), dim);
    }
}

// fractalsql_edition() -> VARCHAR = 'Community'
// fractalsql_version() -> VARCHAR = '1.0.0'
//
// Zero-argument scalar functions. DuckDB's idiomatic pattern for a
// scalar function emitting a constant string is Vector::Reference()
// onto a Value, not SetVectorType(CONSTANT) + direct string_t write
// — the latter leaks string storage ownership across DuckDB's vector
// recycle boundary and surfaces as `free(): invalid pointer` at
// DataChunk destruction time on Linux glibc. See how DuckDB's own
// version() scalar function is written for the reference pattern.
static void
FractalsqlEditionFunction(DataChunk &args, ExpressionState &state, Vector &result) {
    (void) args;
    (void) state;
    result.Reference(Value(kFractalsqlEdition));
}

static void
FractalsqlVersionFunction(DataChunk &args, ExpressionState &state, Vector &result) {
    (void) args;
    (void) state;
    result.Reference(Value(kFractalsqlVersion));
}

// --------------------------------------------------------------------
// Registration
//
// Wrapped behind DoRegister() so the ExtensionUtil (v1.2.x) vs
// ExtensionLoader (v1.4+) split only affects one line per function.
// --------------------------------------------------------------------

#if FRACTALSQL_NEW_EXTENSION_API
using Registrar = ExtensionLoader;
static inline void DoRegister(Registrar &r, ScalarFunction fn) {
    r.RegisterFunction(std::move(fn));
}
#else
using Registrar = DatabaseInstance;
static inline void DoRegister(Registrar &r, ScalarFunction fn) {
    ExtensionUtil::RegisterFunction(r, std::move(fn));
}
#endif

static void
RegisterFractalSearch(Registrar &r) {
    ScalarFunction fn(
        "fractal_search",
        {LogicalType::LIST(LogicalType::DOUBLE),
         LogicalType::LIST(LogicalType::DOUBLE)},
        LogicalType::DOUBLE,
        FractalSearchFunction,
        /* bind        */ nullptr,
        /* dependency  */ nullptr,
        /* statistics  */ nullptr,
        /* init_local  */ InitLocalState);
    DoRegister(r, std::move(fn));
}

static void
RegisterFractalsqlEdition(Registrar &r) {
    ScalarFunction fn(
        "fractalsql_edition",
        {},
        LogicalType::VARCHAR,
        FractalsqlEditionFunction);
    DoRegister(r, std::move(fn));
}

static void
RegisterFractalsqlVersion(Registrar &r) {
    ScalarFunction fn(
        "fractalsql_version",
        {},
        LogicalType::VARCHAR,
        FractalsqlVersionFunction);
    DoRegister(r, std::move(fn));
}

// --------------------------------------------------------------------
// Extension lifecycle
//
// FractalsqlExtension kept only as a compatibility shim for anything
// that looks at Name() / Version() through the Extension base class.
// The actual registration path is via the C entry points below, which
// directly call RegisterFunction — matching what DuckDB's own
// parquet / json / httpfs extensions do, and avoiding the DuckDB(
// DatabaseInstance&) + LoadExtension<T> code path (shared_from_this,
// Connection setup, transaction begin/commit). That path is fragile
// for out-of-tree extensions and was the source of `free(): invalid
// pointer` during LOAD on Linux — observed in CI and eliminated here
// by never entering it.
// --------------------------------------------------------------------

#if FRACTALSQL_NEW_EXTENSION_API
void FractalsqlExtension::Load(ExtensionLoader &loader) {
    RegisterFractalSearch(loader);
    RegisterFractalsqlEdition(loader);
    RegisterFractalsqlVersion(loader);
}
#else
void FractalsqlExtension::Load(DuckDB &db) {
    RegisterFractalSearch(*db.instance);
    RegisterFractalsqlEdition(*db.instance);
    RegisterFractalsqlVersion(*db.instance);
}
#endif

std::string FractalsqlExtension::Name() {
    return "fractalsql";
}

std::string FractalsqlExtension::Version() const {
    return kFractalsqlVersion;
}

} // namespace duckdb

// --------------------------------------------------------------------
// C entry points required by DuckDB's loader.
//
// DuckDB's extension loader resolves <extname>_init (C++ ABI) and
// <extname>_version from the shared object via dlsym / GetProcAddress.
// These symbols MUST be exported — default visibility on POSIX
// (enforced by the Dockerfile's -fvisibility=default),
// __declspec(dllexport) on Windows via FRACTAL_EXPORT.
//
// Direct registration path (no DuckDB wrapper, no LoadExtension<T>):
// this matches the official DuckDB extensions' init convention and
// sidesteps the shared_from_this / Connection / BeginTransaction
// chain that was observed to crash at LOAD time.
//
// Naming quirk: the C entry point `fractalsql_version` collides by
// spelling with the SQL-visible scalar function of the same name.
// Different namespaces — the C symbol is what DuckDB's loader dlsyms
// to check library ABI; the SQL function is resolved through DuckDB's
// catalog. No conflict at runtime.
// --------------------------------------------------------------------

extern "C" {

// DuckDB renamed the expected C++-extension entry point between 1.2
// and 1.4, AND changed the argument type it passes:
//
//   <=1.2.x:  <ext>_init(DatabaseInstance &)
//   >=1.4.x:  <ext>_duckdb_cpp_init(ExtensionLoader &)
//
// Passing an ExtensionLoader through a DatabaseInstance& reference
// would reinterpret a loader pointer as a db instance; the
// subsequent `ExtensionLoader(bogus_db, "fractalsql")` ctor reads
// from wild memory and SIGSEGVs during LOAD. We export BOTH entry
// points with their respective correct signatures so the same
// binary is accepted by both generations.

#if FRACTALSQL_NEW_EXTENSION_API
// v1.4+ entry point. DuckDB's loader calls this with the
// ExtensionLoader it constructed itself; we register against that
// loader directly — no ExtensionLoader of our own to build.
FRACTAL_EXPORT void fractalsql_duckdb_cpp_init(duckdb::ExtensionLoader &loader) {
    duckdb::RegisterFractalSearch(loader);
    duckdb::RegisterFractalsqlEdition(loader);
    duckdb::RegisterFractalsqlVersion(loader);
}
#else
// v1.2.x entry point. ExtensionUtil::RegisterFunction under the hood
// (wrapped in DoRegister).
FRACTAL_EXPORT void fractalsql_init(duckdb::DatabaseInstance &db) {
    duckdb::RegisterFractalSearch(db);
    duckdb::RegisterFractalsqlEdition(db);
    duckdb::RegisterFractalsqlVersion(db);
}
#endif

// Library-version probe — DuckDB's loader dlsyms one of these to
// check ABI compatibility. Name varies per DuckDB version just like
// the init entry point.
#if FRACTALSQL_NEW_EXTENSION_API
FRACTAL_EXPORT const char *fractalsql_duckdb_cpp_version() {
    return duckdb::DuckDB::LibraryVersion();
}
#else
FRACTAL_EXPORT const char *fractalsql_version() {
    return duckdb::DuckDB::LibraryVersion();
}
#endif

}

#ifndef DUCKDB_EXTENSION_MAIN
#error DUCKDB_EXTENSION_MAIN not defined
#endif
