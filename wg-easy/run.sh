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

# ---- enable IPv4 forwarding ----------------------------------------------
# A packet addressed to the Home Assistant host itself is delivered locally and
# needs no routing, but a packet addressed to *another* host on the home LAN
# must be FORWARDED from the tunnel interface (wg0) to the LAN interface. The
# kernel only forwards between interfaces when `net.ipv4.ip_forward=1`.
#
# `net.ipv4.ip_forward` is a per-network-namespace sysctl. Because this add-on
# runs with `host_network: true` it shares the Home Assistant host's network
# namespace, so the value read/written here *is* the host's value; `NET_ADMIN`
# (already requested) is the capability a sysctl write in that namespace needs.
#
# On Home Assistant OS this sysctl is normally ALREADY 1: HAOS relies on the
# Docker daemon to enable IPv4 forwarding at boot. The write below is therefore
# usually a no-op that simply confirms the value. It matters on hosts where it
# is 0. Note that Supervisor mounts /proc/sys read-only inside add-on
# containers, so if the value *is* 0 the write will fail with
# "Read-only file system" - the effective value is logged either way. See
# DOCS.md ("Reaching the rest of the LAN") for what to do in that case.
enable_ipv4_forwarding() {
    local before after
    before="$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo '?')"
    echo "[add-on] IPv4 forwarding: net.ipv4.ip_forward=$before (before)"
    if [ "$before" != "1" ]; then
        if sysctl -w net.ipv4.ip_forward=1 2>&1; then
            echo "[add-on] IPv4 forwarding: set net.ipv4.ip_forward=1."
        else
            echo "[add-on] WARNING: could not set net.ipv4.ip_forward=1 (see the"
            echo "[add-on] error above). VPN clients will then only reach the Home"
            echo "[add-on] Assistant host itself, not other LAN machines."
        fi
    fi
    after="$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo '?')"
    echo "[add-on] IPv4 forwarding: net.ipv4.ip_forward=$after (effective)"
}

# ---- dump the state that decides whether LAN routing works ----------------
# Runs once, in the background, after wg-easy has had a chance to create wg0.
# Logs the effective forwarding state plus the interface and the exact nft/ipt
# rules wg-quick installs, so the add-on log alone shows whether a VPN client
# should be able to reach other LAN hosts.
dump_network_state() {
    # Best-effort diagnostic. Runs in its own subshell, but the launcher runs
    # under `set -euo pipefail`, so disable -e here: a failing diagnostic must
    # never abort the function or the container.
    set +e
    local dev nat masq_line masq_dev forward_dump forward_policy
    for _ in $(seq 1 30); do
        ip link show wg0 >/dev/null 2>&1 && break
        sleep 1
    done

    echo "[add-on] ---- network state ----"
    echo "[add-on]   net.ipv4.ip_forward = $(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo '?')"
    if ip link show wg0 >/dev/null 2>&1; then
        echo "[add-on]   wg0 = $(ip -4 addr show wg0 2>/dev/null | sed -n 's/.*inet \([^ ]*\).*/\1/p')"
    else
        echo "[add-on]   wg0 = not present (tunnel did not come up)"
    fi
    dev="$(ip -o route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1)}}')"
    echo "[add-on]   LAN device (default route) = ${dev:-unknown}"

    nat="$(iptables -t nat -S POSTROUTING 2>&1)"
    masq_line="$(printf '%s\n' "$nat" | grep -F -- "-s ${WG_IPV4_CIDR} " | grep -i masquerade | head -n1)"
    if [ -n "$masq_line" ]; then
        echo "[add-on]   NAT MASQUERADE: $masq_line"
        masq_dev="$(printf '%s\n' "$masq_line" | sed -n 's/.* -o \([^ ]*\).*/\1/p')"
        if [ -n "$dev" ] && [ -n "$masq_dev" ] && [ "$masq_dev" != "$dev" ]; then
            echo "[add-on]   NOTE: MASQUERADE is applied on '-o ${masq_dev}' but the"
            echo "[add-on]   default-route (LAN) device is '${dev}'. If they differ,"
            echo "[add-on]   LAN-bound traffic is not NATed and other LAN hosts are"
            echo "[add-on]   unreachable (the Home Assistant host itself still works)."
        fi
    else
        echo "[add-on]   NAT MASQUERADE: none for ${WG_IPV4_CIDR} - return traffic"
        echo "[add-on]   from other LAN hosts will be dropped."
    fi

    forward_dump="$(iptables -S FORWARD 2>&1)"
    forward_policy="$(printf '%s\n' "$forward_dump" | sed -n 's/^-P FORWARD //p' | head -n1)"
    echo "[add-on]   FORWARD policy = ${forward_policy:-unknown}"
    echo "[add-on]   FORWARD rules:"
    printf '%s\n' "$forward_dump" | sed 's/^/[add-on]     /'
    echo "[add-on] ---- end network state ----"
}

enable_ipv4_forwarding

# ---- wg-easy environment -------------------------------------------------
# Web UI listens only on the loopback inside the container; the ingress proxy
# is the only thing exposed. INSECURE=true because HA Ingress terminates the
# (already authenticated) connection; the port is never published to the LAN.
export PORT="$WEB_PORT"
export HOST="127.0.0.1"
export INSECURE=true
# Fixed internal base path; the proxy rewrites it to the dynamic ingress path.
export NUXT_APP_BASE_URL="$APP_BASE"
# Default: no IPv6 in the tunnel. The add-on now runs iptables on the nftables
# backend (see Dockerfile), which HAOS's kernel does provide, so IPv6 *can* be
# enabled; it stays off by default because IPv4 is enough to reach a home LAN
# and this keeps the first-run config minimal. Set disable_ipv6: false to enable.
# IPv6 forwarding is intentionally never touched: it is not needed while IPv6
# is disabled in the tunnel.
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

# ---- log the resulting network state -------------------------------------
dump_network_state &

echo "[add-on] wg-easy pid=$WGEASY_PID  ingress-proxy pid=$PROXY_PID  ingress port=$INGRESS_PORT"

# Exit (and let Supervisor restart) if either process dies.
wait -n "$WGEASY_PID" "$PROXY_PID" || true
echo "[add-on] a child process exited; stopping container."
kill "$WGEASY_PID" "$PROXY_PID" 2>/dev/null || true
exit 0
