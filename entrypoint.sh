#!/bin/bash
set -euo pipefail

err() { printf 'error: %s\n' "$*" >&2; }

# Allow running arbitrary system commands (e.g. bash, sh, debugging utilities)
# following standard OCI / Docker Official Images entrypoint conventions.
if [ "$#" -gt 0 ] && [ "${1#-}" = "$1" ] && [ "$1" != "install" ] && [ "$1" != "server" ]; then
    exec "$@"
fi

MODE="all"
case "${1:-}" in
    install) MODE="install"; shift ;;
    server)  MODE="server";  shift ;;
esac

DATA_DIR="${DATA_DIR:-/data}"
INSTALL_DIR="${INSTALL_DIR:-${DATA_DIR}/.install}"
STAGE_DIR="${INSTALL_DIR}/.staging"
TMP_DIR="${TMPDIR:-/tmp}"
SERVER_JAR="${SERVER_JAR:-${INSTALL_DIR}/Server/HytaleServer.jar}"
ASSETS_ZIP="${ASSETS_ZIP:-${INSTALL_DIR}/Assets.zip}"
PATCHLINE="${PATCHLINE:-release}"
MAVEN_URL="${MAVEN_URL:-https://maven.hytale.com/${PATCHLINE}/com/hypixel/hytale/Server}"

jar_version() {
    local jar="${1:-${SERVER_JAR}}"
    [ -s "${jar}" ] || return 1
    unzip -p "${jar}" META-INF/MANIFEST.MF 2>/dev/null \
        | awk -F': ' '/^Implementation-Version:/ {gsub(/\r/, "", $2); print $2}'
}

latest_version() {
    curl -fsSL --connect-timeout 10 --max-time 30 "${MAVEN_URL}/maven-metadata.xml" 2>/dev/null \
        | awk -F'[<>]' '/<release>/ {gsub(/[ \t\r]/, "", $3); print $3; exit}'
}

commit_staged_install() {
    local f
    for f in "${STAGE_DIR}/Server/auth.enc" "${STAGE_DIR}/auth.enc"; do
        [ -s "${f}" ] && { cp -f "${f}" "${DATA_DIR}/auth.enc"; break; }
    done
    if [ ! -s "${DATA_DIR}/auth.key" ]; then
        for f in "${STAGE_DIR}/Server/auth.key" "${STAGE_DIR}/auth.key"; do
            [ -s "${f}" ] && { cp -f "${f}" "${DATA_DIR}/auth.key"; break; }
        done
    fi
    if [ ! -s "${DATA_DIR}/config.json" ]; then
        for f in "${STAGE_DIR}/Server/config.json" "${STAGE_DIR}/config.json"; do
            [ -s "${f}" ] && { cp -f "${f}" "${DATA_DIR}/config.json"; break; }
        done
    fi

    local server_dir
    server_dir="$(dirname "${SERVER_JAR}")"
    mkdir -p "${server_dir}" "$(dirname "${ASSETS_ZIP}")"
    mv -f "${STAGE_DIR}/Server/HytaleServer.jar" "${SERVER_JAR}"
    if [ -d "${STAGE_DIR}/Server/Licenses" ]; then
        rm -rf "${server_dir}/Licenses"
        mv "${STAGE_DIR}/Server/Licenses" "${server_dir}/Licenses"
    fi
    mv -f "${STAGE_DIR}/Assets.zip" "${ASSETS_ZIP}"
    rm -rf "${STAGE_DIR}"
}

bootstrap_version() {
    local version="$1"
    shift
    local jar="${TMP_DIR}/hytale-bootstrap.jar"
    local url="${MAVEN_URL}/${version}/Server-${version}.jar"

    curl -fsSL --retry 3 --connect-timeout 10 --max-time 15 "${url}.sha1" -o "${jar}.sha1" || return 1
    curl -fsSL --retry 3 --connect-timeout 10 --max-time 120 "${url}" -o "${jar}" || { rm -f "${jar}" "${jar}.sha1"; return 1; }

    local expected actual
    expected=$(awk '{print tolower($1)}' "${jar}.sha1" | tr -d '\r\n')
    actual=$(sha1sum "${jar}" | awk '{print tolower($1)}')
    rm -f "${jar}.sha1"
    if [ -z "${expected}" ] || [ "${expected}" != "${actual}" ]; then
        rm -f "${jar}"
        err "SHA-1 verification failed for Server-${version}.jar"
        return 1
    fi

    local -a boot_args=("--bootstrap")
    if [ "${MODE}" = "install" ]; then
        boot_args+=("$@")
    else
        local skip_next=0 arg
        for arg in "$@"; do
            if [ "${skip_next}" -eq 1 ]; then
                skip_next=0
                continue
            fi
            case "${arg}" in
                --boot-command|--assets) skip_next=1 ;;
                --boot-command=*|--assets=*) ;;
                *) boot_args+=("${arg}") ;;
            esac
        done
    fi

    # Workaround Hytale 0.7.5 --bootstrap IOException when permissions.json is absent
    rm -rf "${STAGE_DIR}"
    mkdir -p "${STAGE_DIR}"
    printf '{}\n' > "${STAGE_DIR}/permissions.json"

    if [ -s "${DATA_DIR}/auth.enc" ]; then
        cp -f "${DATA_DIR}/auth.enc" "${STAGE_DIR}/auth.enc"
        [ -s "${DATA_DIR}/auth.key" ] && cp -f "${DATA_DIR}/auth.key" "${STAGE_DIR}/auth.key"
        printf '{"AuthCredentialStore":{"Type":"Encrypted","Path":"auth.enc"}}\n' > "${STAGE_DIR}/config.json"

        (
            cd "${STAGE_DIR}"
            env -u HYTALE_DISABLE_UPDATES java -jar "${jar}" \
                "${boot_args[@]}" \
                --boot-command "update download" \
                --boot-command "stop"
        ) || true

        if [ "$(jar_version "${STAGE_DIR}/Server/HytaleServer.jar" || true)" = "${version}" ] && [ -s "${STAGE_DIR}/Assets.zip" ]; then
            rm -f "${jar}"
            commit_staged_install
            return 0
        fi
        rm -rf "${STAGE_DIR}"
        mkdir -p "${STAGE_DIR}"
        printf '{}\n' > "${STAGE_DIR}/permissions.json"
    fi

    local fifo="${TMP_DIR}/hytale-auth.fifo"
    rm -f "${fifo}"
    mkfifo "${fifo}"
    exec 3<>"${fifo}"
    rm -f "${fifo}"

    (
        cd "${STAGE_DIR}"
        exec env -u HYTALE_DISABLE_UPDATES java -jar "${jar}" \
            "${boot_args[@]}" \
            --boot-command "auth persistence Encrypted" \
            --boot-command "auth login device"
    ) <&3 &
    local pid=$!

    while kill -0 "${pid}" 2>/dev/null; do
        if [ -s "${STAGE_DIR}/auth.enc" ]; then
            sleep 3
            printf 'update download\n' >&3
            break
        fi
        sleep 2
    done

    wait "${pid}" || true
    exec 3>&-
    rm -f "${jar}"

    if [ "$(jar_version "${STAGE_DIR}/Server/HytaleServer.jar" || true)" = "${version}" ] && [ -s "${STAGE_DIR}/Assets.zip" ]; then
        commit_staged_install
        return 0
    fi

    rm -rf "${STAGE_DIR}"
    return 1
}

install_or_update() {
    local current target
    current=$(jar_version || true)

    if [ -n "${current}" ] && [ -s "${ASSETS_ZIP}" ] && [ "${AUTO_UPDATE:-true}" != "true" ]; then
        return 0
    fi

    target="${HYTALE_VERSION:-$(latest_version || true)}"
    if [ -z "${target}" ]; then
        [ -n "${current}" ] && [ -s "${ASSETS_ZIP}" ] && return 0
        err "unable to resolve latest version from ${MAVEN_URL}"
        exit 1
    fi

    if [ "${current}" = "${target}" ] && [ -s "${ASSETS_ZIP}" ]; then
        return 0
    fi

    if ! bootstrap_version "${target}" "$@"; then
        if [ -n "${current}" ] && [ -s "${ASSETS_ZIP}" ]; then
            err "update to ${target} failed; keeping ${current}"
            return 0
        fi
        err "bootstrap installation failed"
        exit 1
    fi
}

if [ "${MODE}" != "server" ]; then
    install_or_update "$@"
    [ "${MODE}" = "install" ] && exit 0
fi

if [ ! -s "${SERVER_JAR}" ] || [ ! -s "${ASSETS_ZIP}" ]; then
    err "server payload missing in ${INSTALL_DIR}"
    exit 1
fi

cd "${DATA_DIR}"
case " $* " in
    *" --assets "*|*" --assets="*) exec java -jar "${SERVER_JAR}" "$@" ;;
    *) exec java -jar "${SERVER_JAR}" --assets "${ASSETS_ZIP}" "$@" ;;
esac
