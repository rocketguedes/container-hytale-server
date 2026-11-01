# syntax=docker/dockerfile:1
FROM eclipse-temurin:25.0.5_8-jre-noble@sha256:39d8a64f84d4c0aab4639757e1502264da350be831df4bb25d182d6a514113c2

ARG IMAGE_VERSION="dev"
ARG VCS_REF=""
ARG BUILD_DATE=""
ARG USER="hytale"
ARG UID="1000"
ARG GID="1000"

LABEL org.opencontainers.image.title="Hytale Dedicated Server" \
      org.opencontainers.image.description="Rootless, multi-arch container image for Hytale Dedicated Server" \
      org.opencontainers.image.url="https://github.com/rocketguedes/container-hytale-server" \
      org.opencontainers.image.documentation="https://github.com/rocketguedes/container-hytale-server#readme" \
      org.opencontainers.image.source="https://github.com/rocketguedes/container-hytale-server" \
      org.opencontainers.image.vendor="rocketguedes" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}"

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates \
       curl \
       tini \
       unzip \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

RUN userdel -r ubuntu 2>/dev/null || true \
    && groupadd --gid "${GID}" "${USER}" \
    && useradd --uid "${UID}" --gid "${GID}" --home-dir /data --no-create-home --shell /usr/sbin/nologin "${USER}" \
    && mkdir -p /data/.install /data/backups /data/logs /data/mods /data/telemetry \
    && chown -R "${UID}:${GID}" /data \
    && chmod -R 0775 /data

COPY --chmod=0755 entrypoint.sh /entrypoint.sh
COPY --chmod=0755 healthcheck.sh /healthcheck.sh

ENV HOME="/data" \
    TMPDIR="/tmp" \
    LANG="C.UTF-8" \
    HYTALE_DISABLE_UPDATES="true" \
    JDK_JAVA_OPTIONS="-XX:InitialRAMPercentage=50.0 -XX:MaxRAMPercentage=75.0 -XX:+UseG1GC"

USER 1000:1000

VOLUME ["/data"]
WORKDIR /data

EXPOSE 5520/udp

STOPSIGNAL SIGTERM

HEALTHCHECK --interval=15s --timeout=3s --start-period=60s --retries=3 CMD ["/healthcheck.sh"]

ENTRYPOINT ["/usr/bin/tini", "-g", "-e", "143", "--", "/entrypoint.sh"]
CMD []
