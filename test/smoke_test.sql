-- test/smoke_test.sql — CI smoke test. Exits non-zero on failure when
-- run with `duckdb -bail`.
--
-- Invocation pattern (see `make test` and .github/workflows/release.yml):
--
--     { echo "LOAD '<path>';"; cat test/smoke_test.sql; } \
--         | duckdb -bail -unsigned
--
-- LOAD must live in the SQL stream (stdin), not on -cmd: DuckDB runs
-- -init BEFORE -cmd, so a LOAD on -cmd runs too late for any -init
-- that references the extension's functions.

-- ----------------------------------------------------------------------
-- Function registration — all three must be present after LOAD.
-- ----------------------------------------------------------------------
SELECT
    CASE
        WHEN count_star() < 3 THEN
            error('expected fractal_search + fractalsql_edition + fractalsql_version; got '
                  || count_star())
        ELSE 'registration ok: ' || count_star() || ' functions'
    END AS status
FROM duckdb_functions()
WHERE function_name IN
    ('fractal_search', 'fractalsql_edition', 'fractalsql_version');

-- ----------------------------------------------------------------------
-- Edition / version strings — exact match.
-- ----------------------------------------------------------------------
SELECT CASE WHEN fractalsql_edition() <> 'Community'
            THEN error('fractalsql_edition() != Community: ' || fractalsql_edition())
            ELSE 'edition ok' END AS status;

SELECT CASE WHEN fractalsql_version() <> '1.0.0'
            THEN error('fractalsql_version() != 1.0.0: ' || fractalsql_version())
            ELSE 'version ok' END AS status;

-- ----------------------------------------------------------------------
-- Convergence check — cosine similarity, NOT absolute coordinates.
--
-- Cosine distance is magnitude-invariant: any point on the ray from
-- the origin through the query vector is a global optimum. So we
-- compute cos_sim between the SFS-refined best_point and the query,
-- and require it > 0.99.
--
-- We can't directly read best_point out of a scalar function, but we
-- CAN assert that fractal_search(query, query) is ~0 — that IS the
-- cosine distance between query and the refined best_point, and for
-- a good refinement it should be ~0 (best_point parallel to query).
-- Query is [0.6, 0.8] — a unit vector on the x-y plane.
-- ----------------------------------------------------------------------
SELECT
    CASE
        WHEN abs(fractal_search(
                   [0.6, 0.8]::DOUBLE[],
                   [0.6, 0.8]::DOUBLE[])) > 0.01
        THEN error('convergence failed: fractal_search(q,q) = '
                   || fractal_search(
                          [0.6, 0.8]::DOUBLE[],
                          [0.6, 0.8]::DOUBLE[]))
        ELSE 'convergence ok'
    END AS status;

-- ----------------------------------------------------------------------
-- Vectorized-execution smoke: 32 rows, 3-D embeddings, top-3 nearest.
-- ----------------------------------------------------------------------
CREATE TABLE smoke_vectors AS
SELECT
    i AS id,
    [sin(i * 0.1), cos(i * 0.1), sin(i * 0.2)]::DOUBLE[] AS embedding
FROM range(0, 32) t(i);

CREATE TABLE smoke_result AS
SELECT id, fractal_search(embedding, [0.5, 0.5, 0.0]::DOUBLE[]) AS dist
FROM smoke_vectors
ORDER BY dist
LIMIT 3;

SELECT
    CASE
        WHEN count_star() <> 3 THEN error('expected 3 top-k rows')
        WHEN count_if(dist IS NULL) > 0 THEN error('got NULL dist')
        WHEN count_if(NOT isfinite(dist)) > 0 THEN error('got non-finite dist')
        ELSE 'smoke test passed: ' || count_star() || ' rows'
    END AS status
FROM smoke_result;
