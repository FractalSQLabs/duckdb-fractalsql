-- sql/load_extension.sql — canonical DuckDB load sequence.
--
-- DuckDB has no CREATE FUNCTION ... SONAME equivalent. Scalar
-- functions are registered automatically by the extension's Load()
-- entry point the moment you LOAD the artifact. Distribution is just
-- the single-file .duckdb_extension — no system package, no
-- per-server plugin dir, no INSTALL step required.
--
-- The Community edition ships UNSIGNED. DuckDB's loader refuses
-- unsigned extensions unless you opt in, via one of:
--
--   * duckdb -unsigned                     (CLI flag at startup)
--   * Connect with config allow_unsigned_extensions=true BEFORE the
--     database is opened (DuckDB 1.1+ rejects a runtime SET for this).
--   * SET allow_unsigned_extensions = true;   (only on pre-1.1 or when
--                                              set before first LOAD)
--
-- Invocation pattern from the DuckDB shell:
--
--     duckdb -unsigned
--     D .read sql/load_extension.sql
--
-- or programmatic from Python:
--
--     import duckdb
--     con = duckdb.connect(config={'allow_unsigned_extensions': True})
--     con.execute("LOAD '/path/to/fractalsql.duckdb_extension.v1.3.2.linux_amd64';")
--     con.sql("SELECT fractalsql_edition(), fractalsql_version()").show()

-- Tolerated by pre-1.1 DuckDB; 1.1+ will ignore or error harmlessly
-- if the DB is already open unsigned. Prefer the -unsigned CLI flag.
SET allow_unsigned_extensions = true;

-- Absolute path is required: the file name encodes (duckdb_version,
-- platform) in the tail, and the loader validates it against the
-- footer metadata at load time.
LOAD '/path/to/fractalsql.duckdb_extension';

-- ----------------------------------------------------------------------
-- Verify registration.
-- ----------------------------------------------------------------------
SELECT fractalsql_edition();   -- 'Community'
SELECT fractalsql_version();   -- '1.0.0'

-- ----------------------------------------------------------------------
-- Basic call.
-- ----------------------------------------------------------------------
SELECT fractal_search(
    [0.6, 0.8, 0.0]::DOUBLE[],           -- row vector
    [0.6, 0.8, 0.0]::DOUBLE[]            -- query vector
);

-- ----------------------------------------------------------------------
-- Typical analytics pattern.
-- ----------------------------------------------------------------------
CREATE OR REPLACE TABLE embeddings AS
SELECT
    i AS id,
    [random(), random(), random()]::DOUBLE[] AS embedding
FROM range(1, 1000) t(i);

SELECT id, fractal_search(embedding, [0.5, 0.5, 0.5]::DOUBLE[]) AS dist
FROM embeddings
ORDER BY dist
LIMIT 10;

-- ----------------------------------------------------------------------
-- Parquet / Iceberg / S3 — no data movement required.
-- ----------------------------------------------------------------------
-- SELECT id, fractal_search(embedding, $query::DOUBLE[]) AS dist
-- FROM read_parquet('s3://my-bucket/embeddings/*.parquet')
-- ORDER BY dist
-- LIMIT 50;
