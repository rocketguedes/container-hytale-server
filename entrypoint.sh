#!/bin/bash
# =============================================================================
# Hytale Dedicated Server Cloud-Native Entrypoint
# =============================================================================
# Execution modes (HYTALE_MODE):
#   all     (default) - Install/update server payload if needed, merge config,
#                       and exec the Hytale Dedicated Server (Docker/Podman).
#   install           - Install/update server payload via native Java bootstrap
#                       and exit 0 (Kubernetes initContainer).
#   server            - Skip installation/network checks, merge config, and
#                       exec the Hytale Dedicated Server (Kubernetes runtime).
# =============================================================================

set -uo pipefail

log() {
    printf '[Launcher] %s\n' "$*"
}

log_warn() {
    printf '[Launcher] WARNING: %s\n' "$*" >&2
}

log_error() {
    printf '[Launcher] ERROR: %s\n' "$*" >&2
}

# Parse leading mode flags if provided via container args
MODE="${HYTALE_MODE:-all}"
if [ "${1:-}" = "--install-only" ]; then
    MODE="install"
    shift
elif [ "${1:-}" = "--server-only" ]; then
    MODE="server"
    shift
fi

case "${MODE}" in
    all|install|server) ;;
    *)
        log_error "Invalid HYTALE_MODE='${MODE}'. Expected 'all', 'install', or 'server'."
        exit 1
        ;;
esac

# Directory layout
DATA_DIR="${HYTALE_DATA_DIR:-/data}"
INSTALL_DIR="${HYTALE_INSTALL_DIR:-${DATA_DIR}/.install}"
TMP_DIR="${TMPDIR:-/tmp}"

SERVER_JAR="${INSTALL_DIR}/Server/HytaleServer.jar"
ASSETS_PATH="${INSTALL_DIR}/Assets.zip"
VERSION_MARKER="${INSTALL_DIR}/.installed-version"

# Bootstrap & update configuration
MAVEN_BASE_URL="${HYTALE_MAVEN_URL:-https://maven.hytale.com}"
PATCHLINE="${PATCHLINE:-release}"
HYTALE_VERSION="${HYTALE_VERSION:-latest}"
DOWNLOAD_ON_START="${DOWNLOAD_ON_START:-true}"
AUTO_UPDATE="${AUTO_UPDATE:-true}"
CONFIG_OVERRIDES_FILE="${CONFIG_OVERRIDES_FILE:-/etc/hytale/config-overrides.json}"

# Ensure runtime directories exist on writable state volume
if [ ! -w "${DATA_DIR}" ]; then
    log_error "State directory '${DATA_DIR}' is not writable by UID:GID $(id -u):$(id -g). Fix volume permissions or pass '--user <uid>:<gid>'."
    exit 1
fi
mkdir -p "${DATA_DIR}/backups" "${DATA_DIR}/logs" "${DATA_DIR}/mods" "${DATA_DIR}/telemetry" 2>/dev/null || true

# -----------------------------------------------------------------------------
# Helper: Inspect Implementation-Version embedded in HytaleServer.jar
# -----------------------------------------------------------------------------
read_installed_jar_version() {
    local jar_path="$1"
    [ -f "${jar_path}" ] || return 1
    local ver
    ver=$(unzip -p "${jar_path}" META-INF/MANIFEST.MF 2>/dev/null \
        | awk -F': ' '/^Implementation-Version:/ {gsub(/\r/, "", $2); print $2; exit}')
    [ -n "${ver}" ] || return 1
    printf '%s\n' "${ver}"
}

# -----------------------------------------------------------------------------
# Helper: Resolve latest release version from official Hytale Maven repository
# -----------------------------------------------------------------------------
resolve_maven_version() {
    local patchline="$1"
    local metadata_url="${MAVEN_BASE_URL}/${patchline}/com/hypixel/hytale/Server/maven-metadata.xml"
    local xml version

    if ! xml=$(curl -fsSL --connect-timeout 10 --max-time 30 "${metadata_url}" 2>/dev/null); then
        return 1
    fi

    version=$(printf '%s\n' "${xml}" | sed -n 's:.*<release>\([^<]*\)</release>.*:\1:p' | head -n 1 | tr -d ' \t\r\n')
    if [ -z "${version}" ]; then
        version=$(printf '%s\n' "${xml}" | sed -n 's:.*<latest>\([^<]*\)</latest>.*:\1:p' | head -n 1 | tr -d ' \t\r\n')
    fi

    [ -n "${version}" ] || return 1
    printf '%s\n' "${version}"
}

# -----------------------------------------------------------------------------
# Helper: Download & SHA-1 verify bootstrap HytaleServer.jar from Maven
# -----------------------------------------------------------------------------
download_bootstrap_jar() {
    local patchline="$1"
    local version="$2"
    local dest_jar="$3"
    local base="${MAVEN_BASE_URL}/${patchline}/com/hypixel/hytale/Server/${version}/Server-${version}.jar"
    local expected_sha1 actual_sha1

    log "Fetching Hytale bootstrap JAR (${version}, patchline: ${patchline})..."
    if ! curl -fsSL --retry 3 --connect-timeout 10 --max-time 60 "${base}.sha1" -o "${dest_jar}.sha1"; then
        log_error "Failed to fetch SHA-1 checksum from ${base}.sha1"
        return 1
    fi

    if ! curl -fL --retry 3 --connect-timeout 10 "${base}" -o "${dest_jar}"; then
        rm -f "${dest_jar}" "${dest_jar}.sha1"
        log_error "Failed to download bootstrap JAR from ${base}"
        return 1
    fi

    expected_sha1=$(awk '{print $1}' "${dest_jar}.sha1" | tr -d ' \t\r\n' | tr '[:upper:]' '[:lower:]')
    actual_sha1=$(sha1sum "${dest_jar}" | awk '{print $1}' | tr '[:upper:]' '[:lower:]')
    rm -f "${dest_jar}.sha1"

    if [ -z "${expected_sha1}" ] || [ "${expected_sha1}" != "${actual_sha1}" ]; then
        rm -f "${dest_jar}"
        log_error "SHA-1 verification failed for Server-${version}.jar (expected '${expected_sha1}', got '${actual_sha1}')."
        return 1
    fi

    log "SHA-1 verified for Server-${version}.jar (${actual_sha1})."
    return 0
}

# -----------------------------------------------------------------------------
# Helper: Migrate legacy flat /data/{Server,Assets.zip} layout into INSTALL_DIR
# -----------------------------------------------------------------------------
migrate_legacy_install_layout() {
    if [ ! -f "${SERVER_JAR}" ] && [ -f "${DATA_DIR}/Server/HytaleServer.jar" ] && [ -f "${DATA_DIR}/Assets.zip" ]; then
        log "Detected legacy server layout in ${DATA_DIR}; migrating install artifacts to ${INSTALL_DIR}..."
        mkdir -p "${INSTALL_DIR}"
        mv -f "${DATA_DIR}/Server" "${INSTALL_DIR}/Server"
        mv -f "${DATA_DIR}/Assets.zip" "${INSTALL_DIR}/Assets.zip"
        [ -f "${DATA_DIR}/.installed-version" ] && mv -f "${DATA_DIR}/.installed-version" "${VERSION_MARKER}"
        rm -f "${INSTALL_DIR}/Server/HytaleServer.aot.config" "${INSTALL_DIR}/Server/HytaleServer.aot"
        rm -f "${DATA_DIR}/start.sh" "${DATA_DIR}/start.bat"
        rm -rf "${DATA_DIR}/updater"
        log "Legacy layout migration completed."
    fi
}

# -----------------------------------------------------------------------------
# Helper: Clean transient files from INSTALL_DIR and persist auth.enc to DATA_DIR
# -----------------------------------------------------------------------------
finalize_bootstrap_dir() {
    local extracted_auth=""
    if [ -s "${INSTALL_DIR}/Server/auth.enc" ]; then
        extracted_auth="${INSTALL_DIR}/Server/auth.enc"
    elif [ -s "${INSTALL_DIR}/auth.enc" ]; then
        extracted_auth="${INSTALL_DIR}/auth.enc"
    fi

    if [ -n "${extracted_auth}" ]; then
        cp -f "${extracted_auth}" "${DATA_DIR}/.auth.enc.tmp"
        chmod 0600 "${DATA_DIR}/.auth.enc.tmp" 2>/dev/null || true
        mv -f "${DATA_DIR}/.auth.enc.tmp" "${DATA_DIR}/auth.enc"
    fi

    # Preserve auto-generated auth.key only when no external encryption key is configured
    if [ -z "${HYTALE_AUTH_KEY_FILE:-}" ] && [ -z "${HYTALE_AUTH_KEY:-}" ]; then
        if [ -s "${INSTALL_DIR}/Server/auth.key" ] && [ ! -f "${DATA_DIR}/auth.key" ]; then
            cp -f "${INSTALL_DIR}/Server/auth.key" "${DATA_DIR}/.auth.key.tmp"
            chmod 0600 "${DATA_DIR}/.auth.key.tmp" 2>/dev/null || true
            mv -f "${DATA_DIR}/.auth.key.tmp" "${DATA_DIR}/auth.key"
        elif [ -s "${INSTALL_DIR}/auth.key" ] && [ ! -f "${DATA_DIR}/auth.key" ]; then
            cp -f "${INSTALL_DIR}/auth.key" "${DATA_DIR}/.auth.key.tmp"
            chmod 0600 "${DATA_DIR}/.auth.key.tmp" 2>/dev/null || true
            mv -f "${DATA_DIR}/.auth.key.tmp" "${DATA_DIR}/auth.key"
        fi
    fi

    # Keep INSTALL_DIR strictly immutable-clean (no secrets, logs, or x86 AOT recordings)
    rm -f "${INSTALL_DIR}/auth.enc" "${INSTALL_DIR}/auth.key" "${INSTALL_DIR}/config.json" "${INSTALL_DIR}/config.json.bak"
    rm -f "${INSTALL_DIR}/Server/auth.enc" "${INSTALL_DIR}/Server/auth.key" "${INSTALL_DIR}/Server/config.json" "${INSTALL_DIR}/Server/config.json.bak"
    rm -f "${INSTALL_DIR}/Server/HytaleServer.aot.config" "${INSTALL_DIR}/Server/HytaleServer.aot" "${INSTALL_DIR}/start.bat"
    rm -rf "${INSTALL_DIR}/logs" "${INSTALL_DIR}/telemetry" "${INSTALL_DIR}/universe" "${INSTALL_DIR}/.cache" "${INSTALL_DIR}/mods"
}

# -----------------------------------------------------------------------------
# Helper: Execute Hytale native Java --bootstrap to download Server/ + Assets.zip
# -----------------------------------------------------------------------------
run_native_bootstrap() {
    local bootstrap_jar="$1"
    local bootstrap_log="${TMP_DIR}/hytale-bootstrap.log"
    local fifo="${TMP_DIR}/hytale-bootstrap.fifo"
    local -a bootstrap_args=("--bootstrap" "--disable-sentry")

    [ -n "${OWNER_UUID:-}" ] && bootstrap_args+=("--owner-uuid" "${OWNER_UUID}")
    [ -n "${OWNER_NAME:-}" ] && bootstrap_args+=("--owner-name" "${OWNER_NAME}")

    mkdir -p "${INSTALL_DIR}"

    # Seed minimal bootstrap config ensuring Encrypted credential store and target patchline
    jq -n --arg patchline "${PATCHLINE}" '{
        AuthCredentialStore: { Type: "Encrypted", Path: "auth.enc" },
        Update: { Patchline: $patchline }
    }' > "${INSTALL_DIR}/config.json"

    # Attempt 1: Headless non-interactive download when stored auth.enc already exists
    if [ -s "${DATA_DIR}/auth.enc" ]; then
        log "Restoring stored OAuth credentials for headless payload download..."
        cp -f "${DATA_DIR}/auth.enc" "${INSTALL_DIR}/auth.enc"
        [ -s "${DATA_DIR}/auth.key" ] && cp -f "${DATA_DIR}/auth.key" "${INSTALL_DIR}/auth.key"
        : > "${bootstrap_log}"

        (
            cd "${INSTALL_DIR}" || exit 1
            java -Djava.io.tmpdir="${TMP_DIR}" -Xms128M -Xmx512M -jar "${bootstrap_jar}" \
                "${bootstrap_args[@]}" \
                --boot-command "update download" \
                --boot-command "stop"
        ) 2>&1 | tee "${bootstrap_log}"

        if grep -q "Bootstrap install .* extracted to" "${bootstrap_log}" 2>/dev/null \
            && [ -s "${SERVER_JAR}" ] && [ -s "${ASSETS_PATH}" ]; then
            finalize_bootstrap_dir
            rm -f "${bootstrap_log}"
            return 0
        fi

        if grep -qE "Failed to restore session|not authenticated|Authentication required" "${bootstrap_log}" 2>/dev/null; then
            log_warn "Stored OAuth credentials expired or could not be restored; falling back to OAuth2 Device Flow."
            rm -f "${INSTALL_DIR}/auth.enc" "${INSTALL_DIR}/auth.key"
        else
            rm -f "${bootstrap_log}"
            finalize_bootstrap_dir
            return 1
        fi
    fi

    # Attempt 2: Day-0 OAuth2 Device Flow + automatic payload download
    if [ "${ALLOW_INTERACTIVE_AUTH:-true}" != "true" ]; then
        log_error "OAuth credentials (${DATA_DIR}/auth.enc) not found and ALLOW_INTERACTIVE_AUTH=false."
        rm -f "${bootstrap_log}"
        finalize_bootstrap_dir
        return 1
    fi

    log "=================================================================="
    log "OAuth2 Device Authentication required for initial server setup."
    log "Follow the verification URL and enter the code printed below."
    log "=================================================================="

    rm -f "${fifo}" "${bootstrap_log}"
    mkfifo "${fifo}"
    : > "${bootstrap_log}"

    # Open FIFO read-write so stdin stays open across multiple commands
    exec 3<>"${fifo}"

    (
        cd "${INSTALL_DIR}" || exit 1
        exec java -Djava.io.tmpdir="${TMP_DIR}" -Xms128M -Xmx512M -jar "${bootstrap_jar}" \
            "${bootstrap_args[@]}" \
            --boot-command "auth login device"
    ) <&3 > >(tee "${bootstrap_log}") 2>&1 &
    local bootstrap_pid=$!

    local auth_done=false
    local profile_selected=false
    local stop_sent=false

    while kill -0 "${bootstrap_pid}" 2>/dev/null; do
        if [ "${auth_done}" = "false" ]; then
            if [ "${profile_selected}" = "false" ] \
                && grep -qE "profile selection required|Multiple profiles" "${bootstrap_log}" 2>/dev/null; then
                profile_selected=true
                if [ -n "${OWNER_NAME:-}" ]; then
                    log "Selecting game profile '${OWNER_NAME}'..."
                    printf 'auth select %s\n' "${OWNER_NAME}" >&3
                elif [ "${AUTO_SELECT_FIRST_PROFILE:-true}" = "true" ]; then
                    log "Multiple profiles detected without OWNER_UUID/OWNER_NAME; selecting profile #1..."
                    printf 'auth select 1\n' >&3
                fi
            fi

            if grep -q "Authentication successful! Mode:" "${bootstrap_log}" 2>/dev/null; then
                auth_done=true
                log "OAuth authentication completed. Starting Hytale server & assets download..."
                printf 'update download\n' >&3
            elif grep -qE "Device authorization expired|Authentication failed" "${bootstrap_log}" 2>/dev/null; then
                log_error "OAuth2 Device Flow expired or failed."
                printf 'stop\n' >&3
                break
            fi
        elif [ "${stop_sent}" = "false" ]; then
            if grep -qE "Failed to download update|Update check failed" "${bootstrap_log}" 2>/dev/null; then
                stop_sent=true
                log_error "Bootstrap payload download failed."
                printf 'stop\n' >&3
            fi
        fi
        sleep 1
    done

    exec 3>&-
    rm -f "${fifo}"
    wait "${bootstrap_pid}" 2>/dev/null || true

    local ok=false
    if grep -q "Bootstrap install .* extracted to" "${bootstrap_log}" 2>/dev/null \
        && [ -s "${SERVER_JAR}" ] && [ -s "${ASSETS_PATH}" ]; then
        ok=true
    fi

    rm -f "${bootstrap_log}"
    finalize_bootstrap_dir

    [ "${ok}" = "true" ]
}

# -----------------------------------------------------------------------------
# Install / Update Orchestration (Modes: 'install' and 'all')
# -----------------------------------------------------------------------------
install_or_update() {
    mkdir -p "${INSTALL_DIR}" 2>/dev/null || true
    migrate_legacy_install_layout

    local installed_version=""
    if [ -s "${SERVER_JAR}" ] && [ -s "${ASSETS_PATH}" ]; then
        installed_version=$(read_installed_jar_version "${SERVER_JAR}" || true)
        if [ -z "${installed_version}" ] && [ -f "${VERSION_MARKER}" ]; then
            installed_version=$(tr -d ' \t\r\n' < "${VERSION_MARKER}")
        fi
    fi

    # Case A: Fresh installation required
    if [ ! -s "${SERVER_JAR}" ] || [ ! -s "${ASSETS_PATH}" ]; then
        if [ "${DOWNLOAD_ON_START}" != "true" ]; then
            log_error "Server payload missing in ${INSTALL_DIR} and DOWNLOAD_ON_START=false."
            exit 1
        fi

        local target_version="${HYTALE_VERSION}"
        if [ "${target_version}" = "latest" ]; then
            if ! target_version=$(resolve_maven_version "${PATCHLINE}"); then
                log_error "Unable to resolve latest Hytale version from ${MAVEN_BASE_URL} (patchline: ${PATCHLINE})."
                exit 1
            fi
        fi

        local bootstrap_jar="${TMP_DIR}/hytale-bootstrap-${target_version}.jar"
        if ! download_bootstrap_jar "${PATCHLINE}" "${target_version}" "${bootstrap_jar}"; then
            exit 1
        fi

        if ! run_native_bootstrap "${bootstrap_jar}"; then
            rm -f "${bootstrap_jar}"
            log_error "Initial server bootstrap installation failed."
            exit 1
        fi
        rm -f "${bootstrap_jar}"

        installed_version=$(read_installed_jar_version "${SERVER_JAR}" || printf '%s' "${target_version}")
        printf '%s\n' "${installed_version}" > "${VERSION_MARKER}"
        log "Initial installation completed (version: ${installed_version})."
        return 0
    fi

    # Case B: Existing installation — check for updates if enabled
    if [ "${AUTO_UPDATE}" != "true" ]; then
        log "AUTO_UPDATE=false; keeping installed server version (${installed_version:-unknown})."
        return 0
    fi

    local target_version="${HYTALE_VERSION}"
    if [ "${target_version}" = "latest" ]; then
        if ! target_version=$(resolve_maven_version "${PATCHLINE}"); then
            log_warn "Could not reach ${MAVEN_BASE_URL} to check updates; continuing with installed version (${installed_version:-unknown})."
            return 0
        fi
    fi

    if [ -n "${installed_version}" ] && [ "${installed_version}" = "${target_version}" ]; then
        if [ -w "${INSTALL_DIR}" ]; then
            { printf '%s\n' "${installed_version}" > "${VERSION_MARKER}"; } 2>/dev/null || true
        fi
        log "Server payload is up to date (${installed_version}, patchline: ${PATCHLINE})."
        return 0
    fi

    log "Update available: ${installed_version:-unknown} -> ${target_version} (patchline: ${PATCHLINE})."
    local bootstrap_jar="${TMP_DIR}/hytale-bootstrap-${target_version}.jar"
    if ! download_bootstrap_jar "${PATCHLINE}" "${target_version}" "${bootstrap_jar}"; then
        log_warn "Failed to download bootstrap JAR for ${target_version}; continuing with installed version (${installed_version:-unknown})."
        return 0
    fi

    if run_native_bootstrap "${bootstrap_jar}"; then
        rm -f "${bootstrap_jar}"
        installed_version=$(read_installed_jar_version "${SERVER_JAR}" || printf '%s' "${target_version}")
        printf '%s\n' "${installed_version}" > "${VERSION_MARKER}"
        log "Updated server payload to version ${installed_version}."
    else
        rm -f "${bootstrap_jar}"
        log_warn "Update to ${target_version} failed; continuing with installed version (${installed_version:-unknown})."
    fi
}

# -----------------------------------------------------------------------------
# Declarative config.json Merge (idempotent & preserves runtime-managed keys)
# -----------------------------------------------------------------------------
merge_declarative_config() {
    local target_cfg="${DATA_DIR}/config.json"
    local base_json="{}"

    if [ -s "${target_cfg}" ]; then
        if jq empty "${target_cfg}" >/dev/null 2>&1; then
            base_json=$(cat "${target_cfg}")
        else
            log_warn "${target_cfg} is not valid JSON; backing up to ${target_cfg}.corrupt and regenerating."
            cp -f "${target_cfg}" "${target_cfg}.corrupt" 2>/dev/null || true
        fi
    fi

    local file_overrides="{}"
    if [ -s "${CONFIG_OVERRIDES_FILE}" ]; then
        if ! file_overrides=$(jq '.' "${CONFIG_OVERRIDES_FILE}"); then
            log_error "Invalid JSON in CONFIG_OVERRIDES_FILE (${CONFIG_OVERRIDES_FILE})."
            exit 1
        fi
    fi

    local env_overrides
    env_overrides=$(jq -n \
        --arg server_name "${SERVER_NAME:-}" \
        --arg motd "${MOTD:-}" \
        --arg password "${SERVER_PASSWORD:-}" \
        --arg max_players "${MAX_PLAYERS:-}" \
        --arg max_view_radius "${MAX_VIEW_RADIUS:-}" \
        --arg patchline "${PATCHLINE:-}" \
        '{
            AuthCredentialStore: { Type: "Encrypted", Path: "auth.enc" }
        }
        | if $patchline != "" then .Update = ((.Update // {}) + { Patchline: $patchline }) else . end
        | if $server_name != "" then .ServerName = $server_name else . end
        | if $motd != "" then .MOTD = $motd else . end
        | if $password != "" then .Password = $password else . end
        | if $max_players != "" then .MaxPlayers = ($max_players | tonumber) else . end
        | if $max_view_radius != "" then .MaxViewRadius = ($max_view_radius | tonumber) else . end
        ')

    local tmp_cfg="${DATA_DIR}/.config.json.tmp"
    if printf '%s\n%s\n%s\n' "${base_json}" "${file_overrides}" "${env_overrides}" \
        | jq -s '.[0] * .[1] * .[2]' > "${tmp_cfg}"; then
        mv -f "${tmp_cfg}" "${target_cfg}"
    else
        rm -f "${tmp_cfg}"
        log_error "Failed to merge declarative configuration into ${target_cfg}."
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Execute Requested Lifecycle Phase
# -----------------------------------------------------------------------------
if [ "${MODE}" = "install" ]; then
    install_or_update
    exit 0
fi

if [ "${MODE}" = "all" ]; then
    install_or_update
fi

# Verify server binaries exist before starting runtime
if [ ! -s "${SERVER_JAR}" ] || [ ! -s "${ASSETS_PATH}" ]; then
    log_error "Server files not found at ${SERVER_JAR} / ${ASSETS_PATH}. Run HYTALE_MODE=install first or set HYTALE_MODE=all."
    exit 1
fi

merge_declarative_config

# Disable built-in runtime self-updater by default (updates are managed declaratively on container start/init)
export HYTALE_DISABLE_UPDATES="${HYTALE_DISABLE_UPDATES:-true}"

# Build JVM arguments
JVM_ARGS=(
    "-Djava.io.tmpdir=${TMP_DIR}"
)

if [ -n "${JAVA_MEMORY:-}" ]; then
    # shellcheck disable=SC2206
    JVM_ARGS+=(${JAVA_MEMORY})
else
    JVM_ARGS+=(
        "-XX:InitialRAMPercentage=${JVM_INITIAL_RAM_PERCENTAGE:-50.0}"
        "-XX:MaxRAMPercentage=${JVM_MAX_RAM_PERCENTAGE:-75.0}"
        "-XX:+UseG1GC"
    )
fi

if [ -n "${JVM_OPTS:-}" ]; then
    # shellcheck disable=SC2206
    JVM_ARGS+=(${JVM_OPTS})
fi

if [ -f "${DATA_DIR}/jvm.options" ]; then
    JVM_ARGS+=("@${DATA_DIR}/jvm.options")
fi

# Optional Ahead-of-Time (JEP 483) cache keyed by exact JVM version + JAR SHA-256
if [ "${ENABLE_AOT:-false}" = "true" ]; then
    JVM_FINGERPRINT=$( (java -fullversion 2>&1; sha256sum "${SERVER_JAR}" | awk '{print $1}') | sha256sum | cut -c1-16 )
    AOT_DIR="${TMP_DIR}"
    [ -w "${INSTALL_DIR}" ] && AOT_DIR="${INSTALL_DIR}"
    AOT_CACHE_FILE="${AOT_DIR}/HytaleServer-${JVM_FINGERPRINT}.aot"
    AOT_CONFIG_TMP="${TMP_DIR}/hytale-${JVM_FINGERPRINT}.aot.config"

    if [ ! -s "${AOT_CACHE_FILE}" ]; then
        log "Recording JEP 483 AOT cache (${AOT_CACHE_FILE})..."
        rm -f "${AOT_CACHE_FILE}" "${AOT_CONFIG_TMP}"
        java -Djava.io.tmpdir="${TMP_DIR}" -XX:AOTMode=record -XX:AOTConfiguration="${AOT_CONFIG_TMP}" \
            -cp "${SERVER_JAR}" com.hypixel.hytale.Main --help >/dev/null 2>&1 || true
        if [ -s "${AOT_CONFIG_TMP}" ]; then
            java -Djava.io.tmpdir="${TMP_DIR}" -XX:AOTMode=create -XX:AOTConfiguration="${AOT_CONFIG_TMP}" \
                -XX:AOTCache="${AOT_CACHE_FILE}" -cp "${SERVER_JAR}" >/dev/null 2>&1 || true
            rm -f "${AOT_CONFIG_TMP}"
        fi
    fi

    if [ -s "${AOT_CACHE_FILE}" ]; then
        JVM_ARGS+=("-XX:AOTCache=${AOT_CACHE_FILE}")
    fi
fi

# Build Hytale Dedicated Server CLI arguments
SERVER_ARGS=(
    "--assets" "${ASSETS_PATH}"
    "--backup"
    "--backup-dir" "${BACKUP_DIR:-${DATA_DIR}/backups}"
    "--backup-frequency" "${BACKUP_FREQUENCY:-30}"
)

# Register external read-only managed mod directories (e.g., Kubernetes ImageVolume at /mods)
if [ -n "${MODS_DIRS:-}" ]; then
    IFS=',:' read -ra EXTRA_MOD_PATHS <<< "${MODS_DIRS}"
    for mod_dir in "${EXTRA_MOD_PATHS[@]}"; do
        [ -n "${mod_dir}" ] && [ -d "${mod_dir}" ] && SERVER_ARGS+=("--mods" "${mod_dir}")
    done
elif [ -d "/mods" ] && [ -n "$(ls -A /mods 2>/dev/null)" ]; then
    SERVER_ARGS+=("--mods" "/mods")
fi

[ -n "${AUTH_MODE:-}" ] && SERVER_ARGS+=("--auth-mode" "${AUTH_MODE}")
[ -n "${BIND_ADDRESS:-}" ] && SERVER_ARGS+=("--bind" "${BIND_ADDRESS}")
[ -n "${BACKUP_MAX_COUNT:-}" ] && SERVER_ARGS+=("--backup-max-count" "${BACKUP_MAX_COUNT}")
[ -n "${BACKUP_ARCHIVE_MAX_COUNT:-}" ] && SERVER_ARGS+=("--backup-archive-max-count" "${BACKUP_ARCHIVE_MAX_COUNT}")
[ -n "${OWNER_NAME:-}" ] && SERVER_ARGS+=("--owner-name" "${OWNER_NAME}")
[ -n "${OWNER_UUID:-}" ] && SERVER_ARGS+=("--owner-uuid" "${OWNER_UUID}")
[ -n "${IDENTITY_TOKEN:-}" ] && SERVER_ARGS+=("--identity-token" "${IDENTITY_TOKEN}")
[ -n "${SESSION_TOKEN:-}" ] && SERVER_ARGS+=("--session-token" "${SESSION_TOKEN}")
[ -n "${BOOT_COMMAND:-}" ] && SERVER_ARGS+=("--boot-command" "${BOOT_COMMAND}")
[ "${DISABLE_SENTRY:-false}" = "true" ] && SERVER_ARGS+=("--disable-sentry")
[ "${DISABLE_FILE_WATCHER:-false}" = "true" ] && SERVER_ARGS+=("--disable-file-watcher")
[ "${IGNORE_BROKEN_MODS:-false}" = "true" ] && SERVER_ARGS+=("--ignore-broken-mods")
[ "${ACCEPT_EARLY_PLUGINS:-false}" = "true" ] && SERVER_ARGS+=("--accept-early-plugins")
[ "${ALLOW_OP:-false}" = "true" ] && SERVER_ARGS+=("--allow-op")
[ -n "${LOG_LEVEL:-}" ] && SERVER_ARGS+=("--log" "${LOG_LEVEL}")

cd "${DATA_DIR}" || exit 1

INSTALLED_VER=$(read_installed_jar_version "${SERVER_JAR}" || printf 'unknown')
log "Starting Hytale Dedicated Server v${INSTALLED_VER} (workdir: ${DATA_DIR})..."
exec java "${JVM_ARGS[@]}" -jar "${SERVER_JAR}" "${SERVER_ARGS[@]}" "$@"
