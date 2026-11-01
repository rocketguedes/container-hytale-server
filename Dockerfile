# syntax=docker/dockerfile:1
# =============================================================================
# Hytale Dedicated Server Container
# =============================================================================
# Cloud-native, rootless, multi-arch (linux/amd64, linux/arm64) OCI image for
# Hytale Dedicated Server. Uses native Java 25 bootstrap (zero user-space QEMU
# emulation) and supports standalone Docker/Podman as well as Kubernetes
# initContainer + read-only root filesystem deployments.
# =============================================================================

FROM eclipse-temurin:25.0.5_8-jre-noble@sha256:39d8a64f84d4c0aab4639757e1502264da350be831df4bb25d182d6a514113c2

ARG IMAGE_VERSION="dev"
ARG VCS_REF=""
ARG BUILD_DATE=""
ARG USER="hytale"
ARG UID="1000"
ARG GID="1000"

LABEL org.opencontainers.image.title="Hytale Dedicated Server" \
      org.opencontainers.image.description="Cloud-native, rootless, multi-arch container image for Hytale Dedicated Server" \
      org.opencontainers.image.url="https://github.com/rocketguedes/container-hytale-server" \
      org.opencontainers.image.documentation="https://github.com/rocketguedes/container-hytale-server#readme" \
      org.opencontainers.image.source="https://github.com/rocketguedes/container-hytale-server" \
      org.opencontainers.image.vendor="rocketguedes" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}"

# Install minimal runtime dependencies:
# - tini: PID 1 zombie reaping and signal forwarding
# - ca-certificates: TLS trust store for Maven/Hytale endpoints
# - curl: verified Hytale bootstrap JAR retrieval from maven.hytale.com
# - jq: atomic declarative merging of config.json overrides
# - unzip: MANIFEST.MF version inspection and archive utilities
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates \
       curl \
       jq \
       tini \
       unzip \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Create dedicated non-root user and prepare writable state layout (g=u for rootless/arbitrary UID compatibility)
RUN userdel -r ubuntu 2>/dev/null || true \
    && groupadd --gid "${GID}" "${USER}" \
    && useradd --uid "${UID}" --gid "${GID}" --home-dir /data --no-create-home --shell /usr/sbin/nologin "${USER}" \
    && mkdir -p /data/.install /data/backups /data/logs /data/mods /data/telemetry /mods \
    && chown -R "${UID}:${GID}" /data /mods \
    && chmod -R 0775 /data /mods

COPY --chmod=0755 entrypoint.sh /entrypoint.sh
COPY --chmod=0755 healthcheck.sh /healthcheck.sh

ENV HOME="/data" \
    TMPDIR="/tmp" \
    LANG="C.UTF-8"

USER 1000:1000

VOLUME ["/data"]
WORKDIR /data

EXPOSE 5520/udp

STOPSIGNAL SIGTERM

HEALTHCHECK --interval=15s --timeout=3s --start-period=60s --retries=3 CMD ["/healthcheck.sh"]

# Remap JVM SIGTERM exit status (143) to 0 for clean container orchestrator lifecycle
ENTRYPOINT ["/usr/bin/tini", "-g", "-e", "143", "--", "/entrypoint.sh"]
CMD []
