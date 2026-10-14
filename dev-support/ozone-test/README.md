# HMS + Ozone integration test harness

Local docker-compose stack that brings up:
- Apache Ozone mini-cluster (OM + SCM + 1 datanode, `apache/ozone:1.4.1`)
- PostgreSQL 14 (HMS backing RDBMS)
- **Hive Metastore** built from this repo's CVE-bumped Hive 4.2.1 source

Purpose: prove the dependency upgrades on this branch don't regress HMS
functionality end-to-end against a real Ozone warehouse (`ofs://...`), and give
us a fast iteration loop for further fixes (jackson/netty in /opt/hadoop, the
Hadoop 3.4.1 upgrade attempt).

## Layout

```
dev-support/ozone-test/
├── README.md                       you are here
├── run.sh                          convenience: build | up | down | smoke | all | logs
├── .env.example                    knobs (versions, ports)
├── hms-image/
│   ├── Dockerfile                  builds the HMS image
│   ├── entrypoint.sh               waits for deps, init-schemas, starts HMS
│   ├── build.sh                    collects Hive jars from ~/.m2 + docker build
│   └── .dockerignore
├── compose/
│   ├── docker-compose.yml          the stack
│   ├── ozone-config/ozone-site.xml
│   ├── hms-config/
│   │   ├── hive-site.xml           HMS pointed at Postgres + ofs:// warehouse
│   │   └── metastore-log4j2.properties
│   └── postgres-init/init.sql      creates metastore_db
└── tests/
    └── smoke-test-ozone.sh         adapted from ../hms-smoke-test.sh
```

## Prerequisites

- Docker 20.10+ with Compose v2
- ~8 GB free RAM for the stack
- ~10 GB free disk for images + Ozone data
- JDK 8 + Maven (only the first time, to populate `~/.m2` with the bumped jars)

## Quick start

```bash
# 1. (one-time) make sure the bumped Hive jars are in ~/.m2
cd /work/sber/component-hive-community
JAVA_HOME=/usr/lib/jvm/java-8-openjdk \
  mvn -B clean install -DskipTests -Drat.skip=true   # ~25 min the first time

# 2. build + run + test, all-in-one
cd dev-support/ozone-test
./run.sh all
```

`run.sh all` does: `build → up → wait for HMS healthy → smoke → leave running`.
Use `./run.sh down` to tear everything down.

## Individual commands

```bash
./run.sh build          # build the HMS docker image from ~/.m2
./run.sh up             # docker compose up -d
./run.sh logs hms       # tail HMS logs
./run.sh logs om        # tail Ozone OM logs
./run.sh smoke          # run smoke-test-ozone.sh against the running HMS
./run.sh down           # docker compose down -v (also wipes volumes)
```

## Verifying it works

After `./run.sh up`, you should see in `docker compose ps`:
- `ozone-test_om_1`        healthy (port 9874 web UI, 9862 RPC)
- `ozone-test_scm_1`       healthy
- `ozone-test_datanode_1`  healthy
- `ozone-test_postgres_1`  healthy
- `ozone-test_hms_1`       healthy (port 9083 Thrift)

`./run.sh smoke` runs the 7-test smoke that creates a database with location
`ofs://omservice/warehouse/<dbname>`, lists FS roots (you should see `ofs://`),
and exercises `hmsbench` Thrift CRUD. Exit 0 = clean.

## Iterating on CVE fixes

The Dockerfile is parameterised so you can flip versions without editing it.
All knobs honour caller env vars first, with `.env` providing defaults.

```bash
# Phase 1 baseline (no swaps)
./run.sh build

# Phase 2: swap jackson + netty in /opt/hadoop/common/lib
SWAP_HADOOP_LIBS=1 ./run.sh build

# Phase 3: Hadoop 3.4.1. The 1.4.1 ozone-filesystem-hadoop3 client (from
# upstream Maven Central) references com.google.protobuf.ServiceException
# (legacy protobuf-java 2.5.0 API), which Hadoop 3.4 dropped from common/lib.
# Bump the Ozone client to 2.0.0+ which links against modern protobuf; wire
# protocol stays backward-compatible so a 2.x client talks to a 1.4.x Ozone
# server fine.
HADOOP_VERSION=3.4.1 OZONE_FS_HADOOP3_VERSION=2.0.0 ./run.sh build

# Max-coverage: Phase 2 + Phase 3 combined
HADOOP_VERSION=3.4.1 OZONE_FS_HADOOP3_VERSION=2.0.0 SWAP_HADOOP_LIBS=1 ./run.sh build
```

After each rebuild: `./run.sh down && ./run.sh up && ./run.sh smoke`.

The smoke test's Test 8 does a real CREATE TABLE -- which forces HMS
to `Warehouse.mkdirs()` against the `ofs://` location -- so it exercises
the actual FileSystem write path, not just metadata.

## Known limits

- `apache/ozone:1.4.1` ships with Hadoop 3.3.x client. If you bump HMS to
  Hadoop 3.4.1 (Phase 3), the Ozone OM/SCM/DN images stay on 3.3.x — that's
  fine because they're separate processes; the HMS-side Hadoop is what matters
  for our CVE scan.
- Internal Sber mirrors (`tslew-psdp00001.esrt.sber.ru`) are not used here —
  everything comes from public Apache archive / Docker Hub / Maven Central.
  This harness is for local validation; production builds still go through the
  Sber Jenkins pipeline.
