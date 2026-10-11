#!/usr/bin/env bash
# Home Assistant add-on launcher for WG-Easy.
#
# Starts two processes inside the container:
#   1. the wg-easy server (web UI + WireGuard management), on 127.0.0.1:51821
#      and served under a fixed internal base path (/_haingress) so it can be
#      safely placed behind Home Assistant Ingress by the proxy below;
#   2. a tiny reverse proxy (ingress-proxy.mjs) on the Ingress port, which
#      translates the dynamic Home Assistant Ingress prefix to that fixed base.
set -euo pipefail

OPTIONS=/data/options.json

get() {
    # required string option
    jq -r --arg k "$1" '.[$k] // empty' "$OPTIONS"
}
get_default() {
    # option with fallback
    jq -r --arg k "$1" --arg d "$2" 'if (.[$k] // "") == "" then $d else .[$k] end' "$OPTIONS"
}

WG_HOST="$(get host)"
WG_PORT="$(get_default port 51820)"
WG_USERNAME="$(get_default username admin)"
WG_PASSWORD="$(get password)"
WG_DNS="$(get_default dns 1.1.1.1)"
WG_ALLOWED_IPS="$(get_default allowed_ips 0.0.0.0/0, ::/0)"
WG_IPV4_CIDR="$(get_default ipv4_cidr 10.8.0.0/24)"
WG_IPV6_CIDR="$(get_default ipv6_cidr fdcc:ad94:bacf:61a4::/64)"
DISABLE_IPV6_OPT="$(jq -r '.disable_ipv6 // true' "$OPTIONS")"
RESET_ADMIN_PW="$(jq -r '.reset_admin_password // false' "$OPTIONS")"

WEB_PORT=51821
INGRESS_PORT=8099
APP_BASE="/_haingress"
DB="/etc/wireguard/wg-easy.db"

if [ -z "$WG_HOST" ]; then
    echo "[add-on] ERROR: option 'host' is empty. Set it to the public IP or"
    echo "[add-on] hostname your VPN clients will connect to, then restart."
    exit 1
fi

mkdir -p /etc/wireguard

# ---- wg-easy environment -------------------------------------------------
# Web UI listens only on the loopback inside the container; the ingress proxy
# is the only thing exposed. INSECURE=true because HA Ingress terminates the
# (already authenticated) connection; the port is never published to the LAN.
export PORT="$WEB_PORT"
export HOST="127.0.0.1"
export INSECURE=true
# Fixed internal base path; the proxy rewrites it to the dynamic ingress path.
export NUXT_APP_BASE_URL="$APP_BASE"
# Default: no IPv6 in the tunnel. Many kernels (including some Home Assistant OS
# builds and this test host) lack the ip6_tables nat table, which would make
# `wg-quick up` fail. IPv4 is enough to reach a home LAN.
export DISABLE_IPV6="$DISABLE_IPV6_OPT"

# INIT_* variables are consumed by wg-easy only on the very first start, when
# the database does not exist yet. See DOCS.md for the "first run only" caveat.
if [ ! -f "$DB" ]; then
    echo "[add-on] First run: applying initial configuration from add-on options."
    export INIT_ENABLED=true
    export INIT_USERNAME="$WG_USERNAME"
    export INIT_PASSWORD="$WG_PASSWORD"
    export INIT_HOST="$WG_HOST"
    export INIT_PORT="$WG_PORT"
    export INIT_DNS="$WG_DNS"
    export INIT_ALLOWED_IPS="$WG_ALLOWED_IPS"
    export INIT_IPV4_CIDR="$WG_IPV4_CIDR"
    export INIT_IPV6_CIDR="$WG_IPV6_CIDR"
else
    echo "[add-on] Existing database found: keeping stored WG-Easy configuration."
    if [ "$RESET_ADMIN_PW" = "true" ]; then
        echo "[add-on] reset_admin_password=true: resetting admin password from options."
        ( cd /app && node server/cli.mjs db:admin:reset --password "$WG_PASSWORD" ) || \
            echo "[add-on] WARNING: password reset failed (password must be >= 12 chars)."
    fi
fi

# ---- start wg-easy -------------------------------------------------------
cd /app
node server/index.mjs &
WGEASY_PID=$!

# ---- start the ingress reverse proxy -------------------------------------
INGRESS_PORT="$INGRESS_PORT" WEB_PORT="$WEB_PORT" APP_BASE="$APP_BASE" \
    node /ingress-proxy.mjs &
PROXY_PID=$!

echo "[add-on] wg-easy pid=$WGEASY_PID  ingress-proxy pid=$PROXY_PID  ingress port=$INGRESS_PORT"

# Exit (and let Supervisor restart) if either process dies.
wait -n "$WGEASY_PID" "$PROXY_PID" || true
echo "[add-on] a child process exited; stopping container."
kill "$WGEASY_PID" "$PROXY_PID" 2>/dev/null || true
exit 0
