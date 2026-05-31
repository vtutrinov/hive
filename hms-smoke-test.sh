#!/usr/bin/env bash
# hms-smoke-test.sh — Hive Metastore smoke/integration tests on a deployed cluster.
#
# Pure HMS — no HiveServer2 / hive CLI / beeline dependencies. Designed for
# clusters where HS2 is not deployed and HS2-related jars are stripped.
#
# Tests (each independent; the script never fails fast):
#   1. tooling present              (nc, curl, schematool, metatool)
#   2. HMS Thrift port reachable
#   3. JMX/Prometheus /metrics      (if HMS_METRICS_PORT set)
#   4. schematool -info             (reads SCHEMA_VERSION from metastore RDBMS)
#   5. schematool -validate         (offline schema integrity)
#   6. metatool -listFSRoot         (HMS Thrift round-trip — read side)
#   7. hmsbench CRUD                (HMS Thrift write side; --bench only)
#
# USAGE:
#   HMS_HOST=metastore.example.com ./hms-smoke-test.sh
#   HMS_HOST=...                   ./hms-smoke-test.sh --bench
#   HMS_HOST=... HMS_METRICS_PORT=8080 ./hms-smoke-test.sh --bench
#
# ENV:
#   HMS_HOST            (required)  metastore hostname
#   HMS_PORT            (9083)
#   HMS_METRICS_PORT    (unset)     jmx_prometheus_javaagent port -> /metrics
#   HIVE_HOME           (/opt/hive) install root (with bin/, lib/, conf/)
#   HADOOP_HOME         (/opt/hadoop)
#   HIVE_CONF_DIR       (${HIVE_HOME}/conf)  must contain metastore-site.xml / hive-site.xml
#   METASTORE_DB_TYPE   (postgres)  postgres | mysql | oracle | mssql | derby
#   KRB_PRINCIPAL       (unset)     "user@REALM"
#   KRB_KEYTAB          (unset)     keytab path; both required with --kerberos
#
# Flags:
#   --bench       run hmsbench (writes/drops a throwaway db; see caveat in test 7)
#   --kerberos    kinit using KRB_PRINCIPAL / KRB_KEYTAB before tests
#   -h | --help
#
# Exit 0 if no FAILs, 1 otherwise.

set -uo pipefail

# ---------- config ----------
: "${HMS_HOST:?HMS_HOST must be set, e.g. export HMS_HOST=metastore.example.com}"
: "${HMS_PORT:=9083}"
: "${HIVE_HOME:=/opt/hive}"
: "${HADOOP_HOME:=/opt/hadoop}"
: "${HIVE_CONF_DIR:=${HIVE_HOME}/conf}"
: "${METASTORE_DB_TYPE:=postgres}"
: "${HMS_METRICS_PORT:=}"
: "${KRB_PRINCIPAL:=}"
: "${KRB_KEYTAB:=}"

export HIVE_HOME HADOOP_HOME HIVE_CONF_DIR
export PATH="$HIVE_HOME/bin:$HADOOP_HOME/bin:$PATH"

DO_BENCH=0; DO_KRB=0
for arg in "$@"; do
  case "$arg" in
    --bench)    DO_BENCH=1 ;;
    --kerberos) DO_KRB=1 ;;
    -h|--help)  sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown arg: $arg (try --help)" >&2; exit 2 ;;
  esac
done

# ---------- output helpers ----------
if [ -t 1 ]; then GRN=$'\033[32m'; RED=$'\033[31m'; YLW=$'\033[33m'; NC=$'\033[0m'
else                 GRN=''; RED=''; YLW=''; NC=''; fi
PASS=0; FAIL=0; SKIP=0; RESULTS=()
log()  { printf '\n=== %s\n' "$*"; }
pass() { printf '  %sPASS%s %s\n' "$GRN" "$NC" "$*"; PASS=$((PASS+1)); RESULTS+=("PASS  $*"); }
fail() { printf '  %sFAIL%s %s\n' "$RED" "$NC" "$*"; FAIL=$((FAIL+1)); RESULTS+=("FAIL  $*"); }
skip() { printf '  %sSKIP%s %s\n' "$YLW" "$NC" "$*"; SKIP=$((SKIP+1)); RESULTS+=("SKIP  $*"); }

TMPDIR_RUN="$(mktemp -d -t hms-smoke.XXXXXX)"
trap 'rm -rf "$TMPDIR_RUN"' EXIT INT TERM

# ---------- 0. Kerberos (optional) ----------
if [ "$DO_KRB" = 1 ]; then
  log "Test 0: Kerberos init"
  if [ -z "$KRB_PRINCIPAL" ] || [ -z "$KRB_KEYTAB" ]; then
    fail "--kerberos requires KRB_PRINCIPAL and KRB_KEYTAB"
    printf '\nABORTED: cannot continue without Kerberos auth\n'; exit 1
  fi
  if kinit -kt "$KRB_KEYTAB" "$KRB_PRINCIPAL" 2>"$TMPDIR_RUN/kinit.err"; then
    pass "kinit as ${KRB_PRINCIPAL}"
  else
    fail "kinit: $(tr '\n' ' ' < "$TMPDIR_RUN/kinit.err")"
    exit 1
  fi
fi

# ---------- 1. tooling ----------
log "Test 1: required tools present"
for t in nc curl schematool metatool; do
  if command -v "$t" >/dev/null 2>&1; then pass "$t -> $(command -v $t)"
  else                                      fail "missing: $t"; fi
done

# ---------- 2. TCP probe ----------
log "Test 2: HMS Thrift port reachable (${HMS_HOST}:${HMS_PORT})"
if nc -z -w 5 "$HMS_HOST" "$HMS_PORT" 2>/dev/null; then pass "TCP ${HMS_HOST}:${HMS_PORT}"
else                                                     fail "TCP ${HMS_HOST}:${HMS_PORT} unreachable"; fi

# ---------- 3. Prometheus metrics ----------
log "Test 3: HMS JMX/Prometheus metrics endpoint"
if [ -n "$HMS_METRICS_PORT" ]; then
  url="http://${HMS_HOST}:${HMS_METRICS_PORT}/metrics"
  body="$TMPDIR_RUN/metrics.txt"
  if curl -sf --max-time 10 "$url" -o "$body"; then
    if grep -qE 'metastore_|hive_metastore|jvm_' "$body"; then
      pass "scrape OK ($url, $(wc -l <"$body") lines)"
    else
      fail "scrape returned 200 but no metastore/jvm metric names found"
    fi
  else
    fail "scrape failed: $url"
  fi
else
  skip "HMS_METRICS_PORT not set"
fi

# ---------- 4. schematool -info ----------
log "Test 4: schematool -info (queries SCHEMA_VERSION on the metastore RDBMS)"
if schematool -dbType "$METASTORE_DB_TYPE" -info >"$TMPDIR_RUN/info.out" 2>&1; then
  ver=$(awk -F': *' '/Metastore schema version/ {print $2}' "$TMPDIR_RUN/info.out")
  pass "schema version: ${ver:-unknown}"
else
  fail "schematool -info -> $(tail -3 "$TMPDIR_RUN/info.out" | tr '\n' ' | ')"
fi

# ---------- 5. schematool -validate ----------
log "Test 5: schematool -validate (offline schema integrity)"
if schematool -dbType "$METASTORE_DB_TYPE" -validate >"$TMPDIR_RUN/validate.out" 2>&1; then
  pass "schema validate clean"
else
  fail "schema validate failed (see ${TMPDIR_RUN}/validate.out)"
  tail -8 "$TMPDIR_RUN/validate.out" | sed 's/^/      /'
fi

# ---------- 6. metatool -listFSRoot (read-side Thrift) ----------
log "Test 6: HMS Thrift round-trip (metatool -listFSRoot)"
# the standalone-metastore 'metatool' script reads metastore-site.xml/hive-site.xml
# from HIVE_CONF_DIR; if you need to point at a different HMS, override there.
if metatool -listFSRoot >"$TMPDIR_RUN/fsroots.out" 2>&1; then
  if grep -qE '^(hdfs|s3a|s3|gs|abfs|wasb|file):/' "$TMPDIR_RUN/fsroots.out"; then
    n=$(grep -cE '^[a-z0-9]+:/' "$TMPDIR_RUN/fsroots.out")
    pass "listFSRoot returned ${n} root(s)"
  else
    fail "metatool returned 0 FS roots (warehouse not initialised?)"
  fi
else
  fail "metatool -listFSRoot failed (see ${TMPDIR_RUN}/fsroots.out)"
fi

# ---------- 7. hmsbench (write-side Thrift CRUD) ----------
if [ "$DO_BENCH" = 1 ]; then
  log "Test 7: hmsbench (Thrift CRUD: createDatabase/createTable/dropTable)"
  # hmsbench is a pure-Thrift HMS client built in this repo at
  #   standalone-metastore/metastore-tools/metastore-benchmarks
  # Build with: mvn -pl standalone-metastore/metastore-tools/metastore-benchmarks -Pperf package
  bench_jar=$(
    ls "$HIVE_HOME"/lib/hmsbench*.jar \
       "$HIVE_HOME"/lib/hive-standalone-metastore-tools-benchmarks*.jar \
       "$HIVE_HOME"/lib/standalone-metastore/hmsbench*.jar \
       2>/dev/null | head -1
  )
  if [ -z "$bench_jar" ]; then
    skip "hmsbench jar not found under \$HIVE_HOME/lib"
  else
    BENCH_DB="hms_smoke_$$"
    # BenchmarkTool flags: -H host  -P port  -d db  -W warmup  -L iterations
    if java -jar "$bench_jar" \
         -H "$HMS_HOST" -P "$HMS_PORT" \
         -W 1 -L 5 \
         -d "$BENCH_DB" \
         --benchmark listDatabases createTable dropTable \
         >"$TMPDIR_RUN/bench.out" 2>&1
    then
      pass "hmsbench completed 5 iterations (db: $BENCH_DB)"
      printf '    --- last 8 lines ---\n'; tail -8 "$TMPDIR_RUN/bench.out" | sed 's/^/    /'
    else
      fail "hmsbench failed (see ${TMPDIR_RUN}/bench.out — leftover db '$BENCH_DB' may need manual drop)"
      tail -8 "$TMPDIR_RUN/bench.out" | sed 's/^/    /'
    fi
  fi
else
  skip "Test 7: hmsbench (pass --bench to enable)"
fi

# ---------- summary ----------
log "SUMMARY (${PASS} passed, ${FAIL} failed, ${SKIP} skipped)"
for line in "${RESULTS[@]}"; do printf '  %s\n' "$line"; done
printf '\nartifacts kept under: %s (cleaned on exit)\n' "$TMPDIR_RUN"
[ "$FAIL" -eq 0 ]
