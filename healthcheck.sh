#!/bin/sh
# =============================================================================
# Hytale Dedicated Server Healthcheck Probe
# =============================================================================
# Zero-fork POSIX /bin/sh probe that inspects /proc/net/udp and /proc/net/udp6
# directly to verify that the QUIC UDP socket is bound (state 07 = UNCONN).
# Compatible with readOnlyRootFilesystem: true and capabilities.drop: [ALL].
#
# Exit codes:
#   0 - Healthy (QUIC listener socket bound on target UDP port)
#   1 - Unhealthy (socket not bound or server still initializing)
# =============================================================================

set -eu

if [ -n "${HYTALE_PORT:-}" ]; then
    PORT="${HYTALE_PORT}"
elif [ -n "${BIND_ADDRESS:-}" ]; then
    PORT="${BIND_ADDRESS##*:}"
else
    PORT="5520"
fi

case "${PORT}" in
    ''|*[!0-9]*)
        exit 1
        ;;
esac

HEX_PORT=$(printf "%04X" "${PORT}")

check_udp_table() {
    table="$1"
    [ -r "${table}" ] || return 1
    while read -r _ local_addr _ state _; do
        case "${local_addr}:${state}" in
            *:"${HEX_PORT}:07")
                return 0
                ;;
        esac
    done < "${table}"
    return 1
}

if check_udp_table /proc/net/udp || check_udp_table /proc/net/udp6; then
    exit 0
fi

exit 1
