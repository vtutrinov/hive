#!/usr/bin/env bash
# Build the HMS test image from the bumped Hive jars in local ~/.m2.
# Idempotent: re-running rebuilds the image but reuses jar cache.
#
# ENV / args:
#   HIVE_REPO       (../../..)        path to the Hive source repo (this branch)
#   M2_REPO         ($HOME/.m2/repository)
#   HIVE_VERSION    (4.0.0)
#   HADOOP_VERSION  (3.3.6)
#   HMS_IMAGE       (hms-ozone-test:cve-bumped)
#   SWAP_HADOOP_LIBS (0)              set to 1 to surgically swap jackson/netty
#   JACKSON_VERSION  (2.17.0)
#   NETTY_VERSION    (4.1.128.Final)
#   OZONE_FS_HADOOP3_VERSION (1.4.1)
#   NO_CACHE         (0)              set to 1 for `docker build --no-cache`

set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
HARNESS_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
HIVE_REPO="${HIVE_REPO:-$(cd "$HARNESS_ROOT/../.." && pwd)}"

# Load .env if present -- BUT caller-supplied env vars take precedence.
# (`set -a; . .env; set +a` clobbers caller env -- not what we want.)
if [ -f "$HARNESS_ROOT/.env" ]; then
  while IFS='=' read -r key val; do
    [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
    # only export if not already set in the caller's environment
    [ -z "${!key+x}" ] && export "$key=$val"
  done < "$HARNESS_ROOT/.env"
fi

: "${M2_REPO:=$HOME/.m2/repository}"
: "${HIVE_VERSION:=4.0.0}"
: "${HADOOP_VERSION:=3.3.6}"
: "${HMS_IMAGE:=hms-ozone-test:cve-bumped}"
: "${SWAP_HADOOP_LIBS:=0}"
: "${JACKSON_VERSION:=2.17.0}"
: "${NETTY_VERSION:=4.1.128.Final}"
: "${OZONE_FS_HADOOP3_VERSION:=1.4.1}"
: "${OZONE_FS_LOCAL_JAR:=}"   # set to a path to use a locally-built ozone client jar
: "${NO_CACHE:=0}"

echo "=== build config ==="
echo "  HIVE_REPO       : $HIVE_REPO"
echo "  M2_REPO         : $M2_REPO"
echo "  HIVE_VERSION    : $HIVE_VERSION"
echo "  HADOOP_VERSION  : $HADOOP_VERSION"
echo "  OZONE_FS_VER    : $OZONE_FS_HADOOP3_VERSION"
echo "  SWAP_HADOOP_LIBS: $SWAP_HADOOP_LIBS"
echo "  HMS_IMAGE       : $HMS_IMAGE"

[ -d "$HIVE_REPO" ] || { echo "HIVE_REPO not a dir: $HIVE_REPO" >&2; exit 1; }
[ -d "$M2_REPO/org/apache/hive" ] || { echo "no Hive jars in $M2_REPO -- run 'mvn install -DskipTests' first" >&2; exit 1; }

STAGING="$SCRIPT_DIR/hive-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING/lib" "$STAGING/bin" "$STAGING/conf" "$STAGING/scripts"

# ---------- 1. Hive jars from local m2 ----------
echo "=== collecting Hive ${HIVE_VERSION} jars from m2 ==="
found=0
while IFS= read -r jar; do
  cp "$jar" "$STAGING/lib/"
  found=$((found+1))
done < <(find "$M2_REPO/org/apache/hive" -name "*-${HIVE_VERSION}.jar" \
         ! -name "*-sources.jar" ! -name "*-javadoc.jar" ! -name "*-tests.jar" \
         ! -name "hive-metastore-benchmarks-*")
# Filter rationale: hive-metastore-benchmarks-*.jar matches the 'hive-metastore-*.jar'
# glob used by `hive --service metastore` to locate the entry-point jar -- having
# it in /opt/hive/lib causes the metastore service to mis-launch with the benchmarks
# jar as its main class. It's only used by the hmsbench tool, not the HMS daemon.
echo "  -> $found Hive jars"
[ "$found" -gt 30 ] || { echo "expected >30 Hive jars, got $found -- did the build complete?" >&2; exit 1; }

# ---------- 2. transitive runtime deps (resolve via mvn for metastore-server) ----------
echo "=== resolving transitive runtime dependencies of standalone-metastore-server ==="
DEP_OUT=$(mktemp -d)
trap "rm -rf $DEP_OUT" EXIT

# Settings file: prefer the verify-settings if present (https-central mirror),
# otherwise rely on the user's default settings. The Sber pom's http central
# repo is blocked by Maven 3.9 -- the mirror handles that.
MVN_SETTINGS_ARG=""
[ -f /tmp/verify-settings.xml ] && MVN_SETTINGS_ARG="-s /tmp/verify-settings.xml"

# Resolve transitive runtime deps from packaging+beeline -- packaging is the
# meta-module that depends on everything in the dist tarball; beeline is
# needed because schematool -initSchema invokes BeeLine.execSql internally.
JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-8-openjdk}" \
mvn -B -q $MVN_SETTINGS_ARG \
  -pl packaging,beeline,standalone-metastore/metastore-server -f "$HIVE_REPO/pom.xml" \
  dependency:copy-dependencies \
  -DoutputDirectory="$DEP_OUT" \
  -DincludeScope=runtime \
  -Dmdep.useRepositoryLayout=false \
  -Dmdep.copyPom=false \
  -Drat.skip=true \
  > /tmp/build-mvn-resolve.log 2>&1 || {
    echo "mvn dependency:copy-dependencies failed; last 30 lines:" >&2
    tail -30 /tmp/build-mvn-resolve.log >&2
    exit 1
  }

added=0
for jar in "$DEP_OUT"/*.jar; do
  [ -e "$jar" ] || continue
  base=$(basename "$jar")
  # Skip if the same artifact (any version) already present from step 1
  artifact=$(echo "$base" | sed -E 's/-[0-9].*\.jar$//')
  if ! ls "$STAGING/lib/${artifact}-"*.jar >/dev/null 2>&1; then
    cp "$jar" "$STAGING/lib/"
    added=$((added+1))
  fi
done
echo "  -> $added new transitive jars added (total $(ls $STAGING/lib | wc -l))"

# ---------- 3. bin scripts + conf templates from source ----------
echo "=== copying bin scripts + conf templates ==="
for f in hive hive-config.sh schematool metatool beeline hplsql hiveserver2 init-hive-dfs.sh ext; do
  src="$HIVE_REPO/bin/$f"
  if [ -e "$src" ]; then
    cp -r "$src" "$STAGING/bin/"
  fi
done
chmod +x "$STAGING/bin"/* 2>/dev/null || true

# The standalone metastore has its own start-metastore + metastore-config.sh that
# we don't strictly need (we use `hive --service metastore`), but include them.
for f in start-metastore metastore-config.sh; do
  src="$HIVE_REPO/standalone-metastore/metastore-server/src/scripts/$f"
  [ -e "$src" ] && cp "$src" "$STAGING/scripts/" || true
done

cp "$HIVE_REPO"/conf/*.template "$STAGING/conf/" 2>/dev/null || true

# Drop the conf bind mount point as an empty dir so docker doesn't auto-create as root
mkdir -p "$STAGING/conf"

# ---------- 3.5 optional: stage a locally-built ozone client jar ----------
if [ -n "$OZONE_FS_LOCAL_JAR" ]; then
  if [ ! -f "$OZONE_FS_LOCAL_JAR" ]; then
    echo "OZONE_FS_LOCAL_JAR='$OZONE_FS_LOCAL_JAR' not a file" >&2; exit 1
  fi
  cp "$OZONE_FS_LOCAL_JAR" "$STAGING/ozone-fs-local.jar"
  echo "  staged local Ozone client jar: $(du -h "$OZONE_FS_LOCAL_JAR" | cut -f1) from $OZONE_FS_LOCAL_JAR"
fi

# ---------- 3a. metastore schema SQL (needed by schematool -initSchema) ----------
echo "=== staging metastore schema SQL ==="
SCRIPT_TARGET="$STAGING/scripts/metastore/upgrade"
mkdir -p "$SCRIPT_TARGET"
# Standalone metastore (Hive 4) ships SQL under src/main/sql/<dbtype>/
if [ -d "$HIVE_REPO/standalone-metastore/metastore-server/src/main/sql" ]; then
  cp -r "$HIVE_REPO/standalone-metastore/metastore-server/src/main/sql"/* "$SCRIPT_TARGET/"
fi
# Legacy metastore module overlays/supplements
if [ -d "$HIVE_REPO/metastore/scripts/upgrade" ]; then
  cp -rn "$HIVE_REPO/metastore/scripts/upgrade"/* "$SCRIPT_TARGET/" 2>/dev/null || true
fi
echo "  -> $(find $SCRIPT_TARGET -name 'hive-schema-*.postgres.sql' | wc -l) postgres schema files staged"

# ---------- 3b. Pre-compile SmokeTest.java on the host so the runtime
# image can stay JRE-only (no javac inside the image). ----------
if [ -f "$SCRIPT_DIR/SmokeTest.java" ]; then
  echo "=== pre-compiling SmokeTest.java (host JDK) ==="
  mkdir -p "$STAGING/smoke-tests"
  CP=$(printf '%s\n' "$STAGING/lib"/*.jar | tr '\n' ':')
  "${JAVA_HOME:-/usr/lib/jvm/java-8-openjdk}/bin/javac" \
      -d "$STAGING/smoke-tests" \
      -cp "$CP" \
      "$SCRIPT_DIR/SmokeTest.java" \
      2> /tmp/smoketest-compile.log \
    && echo "  -> $STAGING/smoke-tests/SmokeTest.class" \
    || { echo "  SmokeTest.java compile failed (non-fatal); errors:"; cat /tmp/smoketest-compile.log; }
fi

# ---------- 4. docker build ----------
echo "=== docker build $HMS_IMAGE  (NO_CACHE=$NO_CACHE) ==="
NO_CACHE_FLAG=""; [ "$NO_CACHE" = "1" ] && NO_CACHE_FLAG="--no-cache"
docker build $NO_CACHE_FLAG \
  --build-arg HADOOP_VERSION="$HADOOP_VERSION" \
  --build-arg OZONE_FS_HADOOP3_VERSION="$OZONE_FS_HADOOP3_VERSION" \
  --build-arg SWAP_HADOOP_LIBS="$SWAP_HADOOP_LIBS" \
  --build-arg JACKSON_VERSION="$JACKSON_VERSION" \
  --build-arg NETTY_VERSION="$NETTY_VERSION" \
  -t "$HMS_IMAGE" \
  "$SCRIPT_DIR"

echo
docker images "$HMS_IMAGE" --format "  {{.Repository}}:{{.Tag}}  {{.Size}}  {{.CreatedSince}}"
echo "=== done. image: $HMS_IMAGE ==="
