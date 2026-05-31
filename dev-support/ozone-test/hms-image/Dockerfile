# syntax=docker/dockerfile:1
#
# HMS test image built from this branch's CVE-bumped Hive jars + Hadoop 3.3.6 (pruned).
# Standalone HMS only -- no HS2.
#
# Build context layout (created by build.sh):
#   ./hive-staging/lib/*.jar         -- all Hive runtime jars from local ~/.m2
#   ./hive-staging/bin/*             -- hive, schematool, metatool, hive-config.sh
#   ./hive-staging/conf/             -- default conf templates (real conf bind-mounted at run)
#   ./entrypoint.sh
#   ./Dockerfile

ARG BASE_IMAGE=eclipse-temurin:8-jre-jammy
ARG HADOOP_VERSION=3.3.6
ARG OZONE_FS_HADOOP3_VERSION=1.4.1
ARG POSTGRES_JDBC_VERSION=42.7.4
ARG JMX_EXPORTER_VERSION=1.5.0
# Legacy compat shim: set ADD_LEGACY_PROTOBUF=1 to drop protobuf-java-2.5.0.jar
# into /opt/hadoop/share/hadoop/common/lib/. Needed when pairing
# ozone-filesystem-hadoop3 1.4.x (which references com.google.protobuf.ServiceException)
# with Hadoop 3.4+ (which dropped protobuf-java 2.5.0 from common/lib).
# WARNING: protobuf-java 2.5.0 (2013) has known CVEs (CVE-2015-5237, CVE-2021-22569,
# CVE-2022-3171, CVE-2024-7254). Enable only when you must pin the Ozone client
# version, and accept the residual finding for that jar.
ARG ADD_LEGACY_PROTOBUF=0
ARG LEGACY_PROTOBUF_VERSION=2.5.0

# -----------------------------------------------------------------------------
# Stage 1: fetch + prune Hadoop, fetch extra jars
# -----------------------------------------------------------------------------
FROM debian:bookworm-slim AS fetcher
ARG HADOOP_VERSION
ARG OZONE_FS_HADOOP3_VERSION
ARG POSTGRES_JDBC_VERSION
ARG JMX_EXPORTER_VERSION

RUN apt-get update && apt-get install -y --no-install-recommends \
      curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /stage

# Hadoop from Apache archive (public; ~700 MB). Internal Sber mirror not used here.
RUN echo ">>> downloading Hadoop ${HADOOP_VERSION}" \
 && curl -fSL --retry 3 -o hadoop.tar.gz \
      "https://archive.apache.org/dist/hadoop/common/hadoop-${HADOOP_VERSION}/hadoop-${HADOOP_VERSION}.tar.gz" \
 && mkdir hadoop \
 && tar -xf hadoop.tar.gz -C hadoop --strip-components=1 \
 && rm hadoop.tar.gz

# Strip subtrees HMS doesn't use -- SAME removal list as
# apache-builders component-hive-community/sdp-package/x86_64/component.spec
# (HDFS/Ozone-only profile). Cuts ~1.4 GB -> ~388 MB, eliminates the
# /opt/hadoop/** CVE hotspots (yarn apps-catalog webapp, yarn/timelineservice/htrace,
# tools/aws-java-sdk-bundle, ini4j, client-minicluster).
RUN H=/stage/hadoop \
 && rm -rf $H/share/hadoop/yarn $H/share/hadoop/mapreduce $H/share/hadoop/tools \
 && rm -f  $H/share/hadoop/client/hadoop-client-minicluster-*.jar \
 && rm -f  $H/bin/mapred $H/bin/mapred.cmd $H/bin/yarn $H/bin/yarn.cmd $H/bin/distcp $H/bin/distcp.cmd \
 && rm -rf $H/share/doc \
 && echo "after prune: $(du -sh $H | cut -f1)"

# Ozone FileSystem hadoop3 client (the bridge that makes ofs:// work in HMS)
RUN echo ">>> downloading ozone-filesystem-hadoop3 ${OZONE_FS_HADOOP3_VERSION}" \
 && mkdir -p /stage/extra-jars \
 && curl -fSL --retry 3 -o /stage/extra-jars/ozone-filesystem-hadoop3.jar \
      "https://repo1.maven.org/maven2/org/apache/ozone/ozone-filesystem-hadoop3/${OZONE_FS_HADOOP3_VERSION}/ozone-filesystem-hadoop3-${OZONE_FS_HADOOP3_VERSION}.jar"

# Postgres JDBC driver
RUN echo ">>> downloading postgresql-${POSTGRES_JDBC_VERSION}" \
 && curl -fSL --retry 3 -o /stage/extra-jars/postgresql.jar \
      "https://repo1.maven.org/maven2/org/postgresql/postgresql/${POSTGRES_JDBC_VERSION}/postgresql-${POSTGRES_JDBC_VERSION}.jar"

# JMX Prometheus exporter (matches Sber-pinned version; only on github releases, not Central)
RUN echo ">>> downloading jmx_prometheus_javaagent ${JMX_EXPORTER_VERSION}" \
 && curl -fSL --retry 3 -o /stage/extra-jars/jmx_prometheus_javaagent.jar \
      "https://github.com/prometheus/jmx_exporter/releases/download/${JMX_EXPORTER_VERSION}/jmx_prometheus_javaagent-${JMX_EXPORTER_VERSION}.jar"

# Optional legacy protobuf-java for older Ozone clients on Hadoop 3.4+
ARG ADD_LEGACY_PROTOBUF
ARG LEGACY_PROTOBUF_VERSION
RUN if [ "$ADD_LEGACY_PROTOBUF" = "1" ]; then \
      echo ">>> downloading legacy protobuf-java ${LEGACY_PROTOBUF_VERSION} (compat shim)" ; \
      curl -fSL --retry 3 -o /stage/extra-jars/protobuf-java-legacy.jar \
        "https://repo1.maven.org/maven2/com/google/protobuf/protobuf-java/${LEGACY_PROTOBUF_VERSION}/protobuf-java-${LEGACY_PROTOBUF_VERSION}.jar" ; \
    else \
      echo "ADD_LEGACY_PROTOBUF=0 -- skipping legacy protobuf-java" ; \
    fi

# -----------------------------------------------------------------------------
# Stage 2: optional surgical jackson/netty swap in /opt/hadoop/common/lib (Phase 2)
# Controlled by the SWAP_HADOOP_LIBS build arg. When =1, drops Hadoop's bundled
# old jackson 2.12.7 / netty 4.1.89 and replaces with the bumped versions.
# -----------------------------------------------------------------------------
FROM fetcher AS hadoop-patched
ARG SWAP_HADOOP_LIBS=0
ARG JACKSON_VERSION=2.17.0
ARG NETTY_VERSION=4.1.128.Final
RUN if [ "$SWAP_HADOOP_LIBS" = "1" ]; then \
      echo ">>> swapping jackson -> ${JACKSON_VERSION}, netty -> ${NETTY_VERSION} in /stage/hadoop/share/hadoop/common/lib" ; \
      cd /stage/hadoop/share/hadoop/common/lib && \
      rm -f jackson-core-*.jar jackson-databind-*.jar jackson-annotations-*.jar \
            netty-*.jar netty-all-*.jar && \
      for art in jackson-core jackson-databind jackson-annotations ; do \
        curl -fSL --retry 3 -O "https://repo1.maven.org/maven2/com/fasterxml/jackson/core/${art}/${JACKSON_VERSION}/${art}-${JACKSON_VERSION}.jar" ; \
      done && \
      # netty-all is meta; pull the all-in-one
      curl -fSL --retry 3 -O "https://repo1.maven.org/maven2/io/netty/netty-all/${NETTY_VERSION}/netty-all-${NETTY_VERSION}.jar" ; \
      echo "swap complete" ; \
    else \
      echo "SWAP_HADOOP_LIBS=0 -- not swapping" ; \
    fi

# -----------------------------------------------------------------------------
# Stage 3: runtime
# -----------------------------------------------------------------------------
FROM ${BASE_IMAGE}

ENV HIVE_HOME=/opt/hive \
    HADOOP_HOME=/opt/hadoop \
    HADOOP_YARN_HOME=/opt/hadoop \
    HADOOP_MAPRED_HOME=/opt/hadoop \
    HADOOP_HDFS_HOME=/opt/hadoop \
    HADOOP_COMMON_HOME=/opt/hadoop \
    HIVE_CONF_DIR=/opt/hive/conf \
    HADOOP_CONF_DIR=/opt/hive/conf \
    PATH=/opt/java/openjdk/bin:/opt/hive/bin:/opt/hadoop/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# DEBIAN_FRONTEND=noninteractive + drop krb5-user (which prompts for default
# realm even with apt -y). The test env has Kerberos OFF; libkrb5-3 (which
# Hadoop's UGI loads via JNI) comes in transitively with the JRE.
RUN DEBIAN_FRONTEND=noninteractive apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      procps netcat-openbsd curl postgresql-client tini passwd \
 && rm -rf /var/lib/apt/lists/*

# Pruned Hadoop (+ optional jackson/netty swap)
COPY --from=hadoop-patched /stage/hadoop /opt/hadoop

# Hive runtime: collected by build.sh from local ~/.m2 + bin scripts + conf templates
# Includes /opt/hive/smoke-tests/SmokeTest.class (pre-compiled host-side; see SmokeTest.java)
COPY ./hive-staging/ /opt/hive/

# Extra jars onto the Hive classpath
COPY --from=hadoop-patched /stage/extra-jars/postgresql.jar               /opt/hive/lib/postgresql.jar
COPY --from=hadoop-patched /stage/extra-jars/jmx_prometheus_javaagent.jar /opt/hive/lib/jmx_prometheus_javaagent.jar
# Ozone client jar goes into /opt/hadoop's common/lib so the hadoop FileSystem
# loader finds the OzoneFileSystem implementation when resolving ofs://.
COPY --from=hadoop-patched /stage/extra-jars/ozone-filesystem-hadoop3.jar /opt/hadoop/share/hadoop/common/lib/ozone-filesystem-hadoop3.jar

# Legacy protobuf-java shim (only present when ADD_LEGACY_PROTOBUF=1 during build).
# The fetcher only creates this file when the arg is on; otherwise the COPY
# uses the placeholder created below.
ARG ADD_LEGACY_PROTOBUF
ARG LEGACY_PROTOBUF_VERSION
COPY --from=hadoop-patched /stage/extra-jars/ /tmp/extra-jars/
RUN if [ "$ADD_LEGACY_PROTOBUF" = "1" ] && [ -f /tmp/extra-jars/protobuf-java-legacy.jar ]; then \
      mv /tmp/extra-jars/protobuf-java-legacy.jar \
         /opt/hadoop/share/hadoop/common/lib/protobuf-java-${LEGACY_PROTOBUF_VERSION}.jar ; \
      echo "legacy protobuf-java ${LEGACY_PROTOBUF_VERSION} installed" ; \
    fi \
 && rm -rf /tmp/extra-jars

# Entry script
COPY ./entrypoint.sh /opt/hive/bin/hms-entrypoint.sh
RUN chmod +x /opt/hive/bin/hms-entrypoint.sh /opt/hive/bin/* 2>/dev/null || true

# Non-root user (matches the prod image's UID 10001 to keep volume perms aligned)
RUN groupadd -g 10001 hive && useradd -u 10001 -g hive -d /opt/hive -s /bin/bash hive \
 && mkdir -p /var/log/hive /var/lib/hive/metastore /tmp/hive \
 && chown -R hive:hive /var/log/hive /var/lib/hive /opt/hive /tmp/hive

USER hive
WORKDIR /opt/hive
EXPOSE 9083
ENTRYPOINT ["tini", "--", "/opt/hive/bin/hms-entrypoint.sh"]
