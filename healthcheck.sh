#!/bin/sh
set -eu

PORT="${1:-5520}"

case "${PORT}" in
    ''|*[!0-9]*) exit 1 ;;
esac

HEX_PORT=$(printf "%04X" "${PORT}")

check_udp_table() {
    [ -r "$1" ] || return 1
    while read -r _ local_addr _ state _; do
        case "${local_addr}:${state}" in
            *:"${HEX_PORT}:07") return 0 ;;
        esac
    done < "$1"
    return 1
}

check_udp_table /proc/net/udp || check_udp_table /proc/net/udp6
