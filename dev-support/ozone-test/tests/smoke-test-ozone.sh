#!/usr/bin/env bash
# smoke-test-ozone.sh -- end-to-end HMS+Ozone smoke against the running
# docker-compose stack. Each test independent; never fails fast.
#
# Tests:
#   1. HMS Thrift port reachable from host          (nc localhost:9083)
#   2. HMS schematool -info                         (RDBMS path)
#   3. HMS schematool -validate                     (schema integrity)
#   4. HMS metatool -listFSRoot                     (Thrift round-trip)
#   5. Ozone OM reachable from HMS container       (nc om:9862)
#   6. Ozone CLI: pre-create warehouse volume+bucket
#   7. ofs:// resolves from inside HMS container    (hadoop fs -ls ofs://om/)
#   8. HMS can WRITE metadata for an ofs://-located db (HiveMetaStoreClient via inline java)
#
# Exit 0 if no FAILs, 1 otherwise.

set -uo pipefail

PROJECT="${COMPOSE_PROJECT_NAME:-ozone-test}"
HMS="${PROJECT}-hms-1"
OM="${PROJECT}-om-1"

if [ -t 1 ]; then GRN=$'\033[32m'; RED=$'\033[31m'; YLW=$'\033[33m'; NC=$'\033[0m'
else                 GRN=''; RED=''; YLW=''; NC=''; fi
PASS=0; FAIL=0; SKIP=0; RESULTS=()
log()  { printf '\n=== %s\n' "$*"; }
pass() { printf '  %sPASS%s %s\n' "$GRN" "$NC" "$*"; PASS=$((PASS+1)); RESULTS+=("PASS  $*"); }
fail() { printf '  %sFAIL%s %s\n' "$RED" "$NC" "$*"; FAIL=$((FAIL+1)); RESULTS+=("FAIL  $*"); }
skip() { printf '  %sSKIP%s %s\n' "$YLW" "$NC" "$*"; SKIP=$((SKIP+1)); RESULTS+=("SKIP  $*"); }

require_container() {
  docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null | grep -q running || {
    fail "container $1 not running (is './run.sh up' done?)"
    return 1
  }
}

# ---------- 0. preflight ----------
log "preflight: containers running?"
ok=1
for c in "$HMS" "$OM" "${PROJECT}-postgres-1" "${PROJECT}-scm-1" "${PROJECT}-datanode-1"; do
  if docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null | grep -q running; then
    pass "container $c"
  else
    fail "container $c is not running"; ok=0
  fi
done
[ $ok -eq 1 ] || { log "SUMMARY: ${PASS} passed, ${FAIL} failed"; exit 1; }

# ---------- 1. HMS Thrift port ----------
log "Test 1: HMS Thrift port reachable from host (localhost:9083)"
if nc -z -w 5 localhost 9083 2>/dev/null; then pass "TCP localhost:9083"
else                                            fail "TCP localhost:9083 unreachable"; fi

# ---------- 2. schematool -info ----------
log "Test 2: schematool -info"
if out=$(docker exec "$HMS" /opt/hive/bin/schematool -dbType postgres -info 2>&1); then
  ver=$(echo "$out" | awk -F': *' '/Metastore schema version/ {print $2}')
  pass "schema version: ${ver:-unknown}"
else
  fail "schematool -info -> $(echo "$out" | tail -3 | tr '\n' ' | ')"
fi

# ---------- 3. schematool -validate ----------
log "Test 3: schematool -validate"
if docker exec "$HMS" /opt/hive/bin/schematool -dbType postgres -validate >/tmp/validate-$$.out 2>&1; then
  pass "schema validate clean"
else
  fail "schema validate failed"
  tail -5 /tmp/validate-$$.out | sed 's/^/      /'
fi
rm -f /tmp/validate-$$.out

# ---------- 4. metatool -listFSRoot ----------
log "Test 4: metatool -listFSRoot (HMS Thrift round-trip)"
# at this point no DBs exist yet; FS roots list will likely be empty (no
# warehouse roots registered). We just want the call itself to succeed.
if docker exec "$HMS" /opt/hive/bin/metatool -listFSRoot >/tmp/fsroots-$$.out 2>&1; then
  pass "metatool -listFSRoot succeeded"
  cat /tmp/fsroots-$$.out | sed 's/^/      /' | tail -6
else
  fail "metatool -listFSRoot failed"
  tail -5 /tmp/fsroots-$$.out | sed 's/^/      /'
fi
rm -f /tmp/fsroots-$$.out

# ---------- 5. Ozone reachable from HMS container ----------
log "Test 5: Ozone OM reachable from inside HMS container (om:9862)"
if docker exec "$HMS" nc -z -w 5 om 9862 2>/dev/null; then pass "om:9862"
else                                                       fail "om:9862 unreachable from HMS container"; fi

# ---------- 6. Pre-create warehouse volume + bucket via Ozone CLI ----------
log "Test 6: Ozone volume + bucket exist (create if missing)"
if docker exec "$OM" ozone sh volume create /warehouse 2>&1 | grep -qiE 'created|already exists'; then
  pass "ozone volume /warehouse"
else
  # `volume create` may exit 0 silently or non-zero with VOLUME_ALREADY_EXISTS; treat as ok
  if docker exec "$OM" ozone sh volume info /warehouse >/dev/null 2>&1; then
    pass "ozone volume /warehouse (already existed)"
  else
    fail "ozone volume /warehouse missing and create failed"
  fi
fi
if docker exec "$OM" ozone sh bucket create /warehouse/tablespace 2>&1 | grep -qiE 'created|already exists'; then
  pass "ozone bucket /warehouse/tablespace"
else
  if docker exec "$OM" ozone sh bucket info /warehouse/tablespace >/dev/null 2>&1; then
    pass "ozone bucket /warehouse/tablespace (already existed)"
  else
    fail "ozone bucket /warehouse/tablespace missing and create failed"
  fi
fi

# ---------- 7. ofs:// resolves from HMS container ----------
log "Test 7: hadoop fs -ls ofs://om/ inside HMS container (proves OzoneFileSystem on classpath)"
if docker exec "$HMS" /opt/hadoop/bin/hadoop fs -ls ofs://om/ >/tmp/ofs-$$.out 2>&1; then
  pass "hadoop fs -ls ofs://om/ succeeded"
  head -5 /tmp/ofs-$$.out | sed 's/^/      /'
else
  fail "hadoop fs -ls ofs://om/ failed"
  tail -8 /tmp/ofs-$$.out | sed 's/^/      /'
fi
rm -f /tmp/ofs-$$.out

# ---------- 8. HMS CREATE_DATABASE via Thrift, ofs:// location ----------
log "Test 8: HMS CREATE_DATABASE testdb LOCATION ofs://om/warehouse/tablespace/testdb"
# Uses /opt/hive/smoke-tests/SmokeTest.class (pre-compiled host-side by build.sh)
# so the runtime image stays JRE-only.
TESTDB="hms_ozone_smoke_$$"
CP='/opt/hive/smoke-tests:/opt/hive/lib/*:/opt/hadoop/share/hadoop/common/*:/opt/hadoop/share/hadoop/common/lib/*:/opt/hadoop/share/hadoop/hdfs/*:/opt/hadoop/share/hadoop/hdfs/lib/*:/opt/hadoop/share/hadoop/client/*:/opt/hive/conf'

if ! docker exec "$HMS" test -f /opt/hive/smoke-tests/SmokeTest.class; then
  skip "SmokeTest.class not in image (build.sh failed to compile it on host)"
elif docker exec "$HMS" bash -c "java -cp '$CP' SmokeTest 'thrift://hms:9083' '$TESTDB' 'ofs://om/warehouse/tablespace/$TESTDB'" >/tmp/smoke-$$.out 2>&1; then
  pass "create / readback / drop $TESTDB via HMS Thrift"
  cat /tmp/smoke-$$.out | sed 's/^/      /'
else
  fail "SmokeTest run failed"
  tail -15 /tmp/smoke-$$.out | sed 's/^/      /'
fi
rm -f /tmp/smoke-$$.out

# ---------- summary ----------
log "SUMMARY (${PASS} passed, ${FAIL} failed, ${SKIP} skipped)"
for line in "${RESULTS[@]}"; do printf '  %s\n' "$line"; done
[ "$FAIL" -eq 0 ]
