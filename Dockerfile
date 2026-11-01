# syntax=docker/dockerfile:1
FROM eclipse-temurin:25.0.5_8-jre-noble@sha256:39d8a64f84d4c0aab4639757e1502264da350be831df4bb25d182d6a514113c2

ARG USER="hytale"
ARG UID="1000"
ARG GID="1000"

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
    && mkdir -p /data \
    && chown "${UID}:${GID}" /data

COPY --chmod=0755 entrypoint.sh /entrypoint.sh
COPY --chmod=0755 healthcheck.sh /healthcheck.sh

ENV HOME="/data"

USER ${UID}:${GID}

VOLUME ["/data"]
WORKDIR /data

EXPOSE 5520/udp

STOPSIGNAL SIGTERM

HEALTHCHECK --interval=15s --timeout=3s --start-period=60s --retries=3 CMD ["/healthcheck.sh"]

ENTRYPOINT ["/usr/bin/tini", "-g", "-e", "143", "--", "/entrypoint.sh"]
CMD []
