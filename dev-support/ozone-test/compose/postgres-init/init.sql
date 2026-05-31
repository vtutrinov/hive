-- Idempotent: the HMS image's schematool -initSchema creates all tables.
-- This init only ensures the database/role exist (already covered by
-- POSTGRES_USER/POSTGRES_DB env on the postgres image), so this file is
-- intentionally minimal -- it's a hook for future test fixtures.
SELECT 'metastore_db init: ok' AS status;
