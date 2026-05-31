#!/usr/bin/env bash
# HMS test-image entrypoint:
#   1. wait for Postgres + Ozone OM
#   2. init schema if not present (idempotent)
#   3. start the metastore Thrift service
set -euo pipefail

PG_HOST="${PG_HOST:-postgres}"
PG_PORT="${PG_PORT:-5432}"
PG_USER="${PG_USER:-hive}"
PG_DB="${PG_DB:-metastore_db}"
OM_HOST="${OM_HOST:-om}"
OM_PORT="${OM_PORT:-9862}"

wait_for() {  # host port label
  local h="$1" p="$2" label="$3" tries=60
  while (( tries-- )); do
    if nc -z "$h" "$p" 2>/dev/null; then echo "  $label up ($h:$p)"; return 0; fi
    sleep 2
  done
  echo "  $label NEVER came up ($h:$p)" >&2
  return 1
}

echo "=== HMS entrypoint ==="
echo "  HADOOP_HOME=$HADOOP_HOME ($(du -sh "$HADOOP_HOME" 2>/dev/null | cut -f1))"
echo "  HIVE_HOME=$HIVE_HOME ($(ls "$HIVE_HOME/lib" 2>/dev/null | wc -l) jars)"

wait_for "$PG_HOST" "$PG_PORT" "Postgres"
wait_for "$OM_HOST" "$OM_PORT" "Ozone OM"

# Initialise the metastore schema if SCHEMA_VERSION doesn't exist yet.
# schematool -info exits 0 only when the schema is present and readable.
if ! /opt/hive/bin/schematool -dbType postgres -info >/tmp/hive/schematool-info.out 2>&1; then
  echo "=== schema not initialised; running -initSchema ==="
  /opt/hive/bin/schematool -dbType postgres -initSchema 2>&1 | tail -20
fi

echo "=== schema info ==="
/opt/hive/bin/schematool -dbType postgres -info 2>&1 | tail -10

echo "=== starting HMS (foreground) ==="
exec /opt/hive/bin/hive --service metastore
