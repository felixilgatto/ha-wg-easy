#!/usr/bin/env bash
# Home Assistant add-on launcher for WG-Easy.
#
# Prepares persistent storage and the WG-Easy database, then starts:
#   1. the wg-easy server (web UI + WireGuard management) on 127.0.0.1:51821,
#      under a fixed internal base path (/_haingress);
#   2. the ingress proxy (addon/ingress-proxy.mjs) on the Ingress port: it maps
#      the dynamic Ingress path to that base and logs the panel in automatically;
#   3. the Home Assistant bridge (addon/ha-bridge.mjs), which publishes MQTT
#      discovery entities when a broker is available.
#
# Design rule: the add-on must work right after installation with no option
# filled in, like a standalone WG-Easy. Everything WG-Easy can do is done in its
# own panel; options only cover what needs the add-on, plus optional overrides.
set -euo pipefail

OPTIONS=/data/options.json
ADDON=/app/server/addon
ADDON_VERSION="${ADDON_VERSION:-unknown}"

log() { echo "[add-on] $*"; }
opt() {
    # option value, or empty when unset / null / ""
    jq -r --arg k "$1" '.[$k] // empty | tostring' "$OPTIONS"
}
trim() {
    printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# ---- options -----------------------------------------------------------------
OPT_HOST="$(trim "$(opt host)")"
OPT_PORT="$(opt port)"; OPT_PORT="${OPT_PORT:-51820}"
OPT_ALLOWED_IPS="$(opt allowed_ips)"
OPT_DNS="$(trim "$(opt dns)")"
OPT_MTU="$(opt mtu)"
OPT_KEEPALIVE="$(opt persistent_keepalive)"
OPT_IPV4_CIDR="$(trim "$(opt ipv4_cidr)")"
OPT_IPV6_CIDR="$(trim "$(opt ipv6_cidr)")"
OPT_METRICS_PORT="$(opt metrics_port)"
DISABLE_IPV6_OPT="$(jq -r 'if .disable_ipv6 == false then "false" else "true" end' "$OPTIONS")"
HA_ENTITIES="$(jq -r 'if .home_assistant_entities == false then "false" else "true" end' "$OPTIONS")"

# Default of the old `allowed_ips` option (<= 15.4.5) and of WG-Easy's tunnel.
SHIPPED_TUNNEL_CIDR="10.8.0.0/24"
# WG-Easy's own default IPv6 tunnel range (migration 0001).
WG_EASY_DEFAULT_IPV6_CIDR="fdcc:ad94:bacf:61a4::cafe:0/112"

WEB_PORT=51821
INGRESS_PORT=8099
APP_BASE="/_haingress"
PERSIST_DIR=/data/wireguard
BACKUP_DIR=/data/backups
KEEP_BACKUPS=10
DB="$PERSIST_DIR/wg-easy.db"
ADMIN_SECRET_FILE=/data/.admin_password

# Filled in below.
LAN_DEV=""
HOST_LAN_IP=""
TUNNEL_CIDR=""
EFFECTIVE_ALLOWED_IPS=""   # tunnel + extras + this host: enforced and given to new clients
EXTRA_ALLOWED_IPS=""       # what goes beyond the tunnel and this host (drives the warning)

log "WG-Easy add-on ${ADDON_VERSION} starting."

# ---- persistent storage ------------------------------------------------------
# Supervisor recreates the add-on container on every start, restart and update,
# and only /data survives that. WG-Easy keeps everything (server keys, clients,
# users, settings) in /etc/wireguard, so that directory MUST live under /data;
# otherwise every restart silently starts from an empty database with new
# server keys, which breaks every existing client. The Dockerfile already makes
# /etc/wireguard a symlink to /data/wireguard; this re-asserts it at runtime.
setup_persistence() {
    mkdir -p "$PERSIST_DIR" "$BACKUP_DIR"
    chmod 700 "$PERSIST_DIR" "$BACKUP_DIR"
    if [ "$(readlink /etc/wireguard 2>/dev/null)" != "$PERSIST_DIR" ]; then
        if [ -d /etc/wireguard ] && [ ! -L /etc/wireguard ] \
            && [ -n "$(ls -A /etc/wireguard 2>/dev/null)" ] \
            && [ -z "$(ls -A "$PERSIST_DIR" 2>/dev/null)" ]; then
            log "Moving existing /etc/wireguard content to $PERSIST_DIR."
            cp -a /etc/wireguard/. "$PERSIST_DIR/"
        fi
        rm -rf /etc/wireguard
        ln -s "$PERSIST_DIR" /etc/wireguard
    fi
    log "Persistent storage: /etc/wireguard -> $PERSIST_DIR"
}

# Newest first: start-up snapshots plus the one taken for Home Assistant backups.
list_snapshots() {
    ls -1t "$BACKUP_DIR"/wg-easy-*.db "$BACKUP_DIR"/ha-backup.db 2>/dev/null || true
}

# ---- database integrity + automatic snapshots --------------------------------
# Runs before anything touches the database (migrations included):
#   - a database that fails PRAGMA integrity_check is moved aside and the newest
#     valid snapshot is restored; with no valid snapshot the add-on refuses to
#     start rather than silently creating a new, empty one;
#   - a healthy database is snapshotted, so an upgrade of WG-Easy (whose
#     migrations run right after this) can always be rolled back.
protect_database() {
    [ -f "$DB" ] || return 0

    if ! node "$ADDON/db-tool.mjs" check "$DB"; then
        local ts quarantine snap restored=""
        ts="$(date +%Y%m%d-%H%M%S)"
        quarantine="$BACKUP_DIR/corrupt-$ts"
        mkdir -p "$quarantine"
        mv "$DB" "$DB-wal" "$DB-shm" "$quarantine/" 2>/dev/null || true
        log "****************************************************************"
        log "The WG-Easy database is damaged. It was moved to $quarantine."
        while read -r snap; do
            [ -n "$snap" ] || continue
            if node "$ADDON/db-tool.mjs" check "$snap"; then
                cp "$snap" "$DB"
                restored="$snap"
                break
            fi
        done < <(list_snapshots)
        if [ -n "$restored" ]; then
            log "Restored the newest valid snapshot: $restored"
            log "Changes made after that snapshot are lost."
            log "****************************************************************"
        else
            log "No valid snapshot exists in $BACKUP_DIR. Refusing to start with"
            log "an empty database (it would get new server keys and break every"
            log "client). Restore a Home Assistant backup of this add-on, or"
            log "delete $quarantine to deliberately start from scratch."
            log "****************************************************************"
            exit 1
        fi
    fi

    local snap_file
    snap_file="$BACKUP_DIR/wg-easy-$(date +%Y%m%d-%H%M%S)-v${ADDON_VERSION}.db"
    if node "$ADDON/db-tool.mjs" snapshot "$DB" "$snap_file"; then
        ls -1t "$BACKUP_DIR"/wg-easy-*.db 2>/dev/null | tail -n +$((KEEP_BACKUPS + 1)) \
            | while read -r old; do rm -f "$old"; done
    else
        log "WARNING: could not snapshot the database before start-up."
    fi
}

# ---- internal admin account ----------------------------------------------------
# The panel is opened through Home Assistant, which has already authenticated an
# administrator, so the ingress proxy logs WG-Easy in by itself with this
# account. The password is random, kept in /data (and so in backups), and never
# needs to be typed. If it stops matching (changed in the web UI, 2FA enabled),
# the proxy re-applies it.
ensure_admin_secret() {
    if [ ! -s "$ADMIN_SECRET_FILE" ]; then
        local pw
        pw="$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')"
        ( umask 077; printf '%s' "${pw:0:40}" > "$ADMIN_SECRET_FILE" )
        log "Generated the internal WG-Easy admin password ($ADMIN_SECRET_FILE)."
    fi
    chmod 600 "$ADMIN_SECRET_FILE"
    ADMIN_PASSWORD="$(cat "$ADMIN_SECRET_FILE")"
}

# ---- IPv4 forwarding -----------------------------------------------------------
# A packet for ANOTHER host on the LAN must be forwarded from wg0 to the LAN
# interface, which needs net.ipv4.ip_forward=1. With host_network this is the
# host's own value. On HAOS it is normally already 1 (Docker enables it), and
# Supervisor mounts /proc/sys read-only, so the write is usually a no-op; the
# effective value is logged either way.
enable_ipv4_forwarding() {
    local before after
    before="$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo '?')"
    if [ "$before" != "1" ]; then
        if sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1; then
            log "IPv4 forwarding: enabled (was $before)."
        else
            log "WARNING: could not set net.ipv4.ip_forward=1. VPN clients will then"
            log "only reach the Home Assistant host itself, not other LAN machines."
        fi
    fi
    after="$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo '?')"
    log "IPv4 forwarding: net.ipv4.ip_forward=$after"
}

# ---- LAN device ----------------------------------------------------------------
# The device of the default route is where traffic to the internet and to the
# rest of the LAN leaves, which is exactly what WG-Easy's MASQUERADE rule must
# match. WG-Easy seeds it as 'eth0', which is wrong on most HAOS hosts (end0 on a
# Raspberry Pi, enp*/ens* on PCs and VMs), so it is set on every start.
detect_lan_device() {
    ip -o route show default 2>/dev/null \
        | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }}'
}
lan_device_address() {
    ip -o -4 addr show dev "$1" scope global 2>/dev/null \
        | awk '{for (i = 1; i <= NF; i++) if ($i == "inet") { print $(i + 1); exit }}' || true
}
wait_for_network() {
    local i addr
    # The network may not be fully up yet at boot (no DHCP lease, no default
    # route). Wait up to 30 s for a default route whose device has an address.
    for i in $(seq 1 30); do
        LAN_DEV="$(detect_lan_device)"
        if [ -n "$LAN_DEV" ]; then
            addr="$(lan_device_address "$LAN_DEV")"
            if [ -n "$addr" ]; then
                HOST_LAN_IP="${addr%%/*}"
                log "LAN device = $LAN_DEV, Home Assistant address = $HOST_LAN_IP"
                return 0
            fi
        fi
        [ "$i" = 1 ] && log "Waiting for the network (default route + IPv4 address)..."
        sleep 1
    done
    log "WARNING: could not determine the LAN device/address. WG-Easy keeps its"
    log "stored device and this host's address is not added to allowed IPs."
}

# ---- allowed IPs ---------------------------------------------------------------
# What VPN clients may reach: the tunnel subnet, this Home Assistant host, and
# whatever the `allowed_ips` option adds (e.g. the LAN subnet). The result is
# both ENFORCED on the server (restrict_client_forwarding) and written as the
# default AllowedIPs of NEW clients.
derive_allowed_ips() {
    local p parts extra="" result allowed="$OPT_ALLOWED_IPS" host32=""
    [ -n "$HOST_LAN_IP" ] && host32="$HOST_LAN_IP/32"

    # The old shipped default of this option was the tunnel range 10.8.0.0/24;
    # if the tunnel was moved elsewhere, that saved value is stale, not a
    # deliberate extra range.
    if [ "$(trim "$allowed")" = "$SHIPPED_TUNNEL_CIDR" ] && [ "$TUNNEL_CIDR" != "$SHIPPED_TUNNEL_CIDR" ]; then
        allowed=""
    fi

    result="$TUNNEL_CIDR"
    IFS=',' read -ra parts <<< "$allowed"
    for p in "${parts[@]}"; do
        p="$(trim "$p")"
        [ -z "$p" ] && continue
        [ "$p" = "$TUNNEL_CIDR" ] && continue
        [ -n "$host32" ] && [ "$p" = "$host32" ] && continue
        result="$result, $p"
        extra="$extra $p"
    done
    [ -n "$host32" ] && result="$result, $host32"

    EFFECTIVE_ALLOWED_IPS="$result"
    EXTRA_ALLOWED_IPS="$(trim "$extra")"
}

# ---- enforce allowed IPs on the server -----------------------------------------
# A client's own AllowedIPs only decide what the CLIENT routes into the tunnel;
# the client controls that file, so it is not a security boundary. This
# installs a forwarding filter in the host's netfilter (shared via host_network)
# so that traffic arriving from wg0 is only forwarded to the allowed
# destinations. Anything else is dropped, whatever the client's config says.
#
#   FORWARD:            -i wg0 -j HA_WGEASY_CLIENTS   (inserted at position 1)
#   HA_WGEASY_CLIENTS:  -d <allowed range> -j RETURN  (one per range)
#                       -j DROP
#
# RETURN hands allowed traffic back to FORWARD, so the rules that follow
# (Docker's chains, WG-Easy's own `-i wg0 -j ACCEPT`) apply as before. Traffic
# to this host itself goes through INPUT, so Home Assistant stays reachable.
# Idempotent: the chain is refilled and the jump re-inserted on every start.
CLIENT_CHAIN="HA_WGEASY_CLIENTS"
install_client_filter() {
    local ipt="$1" r
    shift
    "$ipt" -N "$CLIENT_CHAIN" 2>/dev/null || true
    "$ipt" -F "$CLIENT_CHAIN" || return 1
    for r in "$@"; do
        "$ipt" -A "$CLIENT_CHAIN" -d "$r" -j RETURN || return 1
    done
    "$ipt" -A "$CLIENT_CHAIN" -j DROP || return 1
    while "$ipt" -D FORWARD -i wg0 -j "$CLIENT_CHAIN" 2>/dev/null; do :; done
    "$ipt" -I FORWARD 1 -i wg0 -j "$CLIENT_CHAIN" || return 1
}
restrict_client_forwarding() {
    local p parts v4=() v6=()
    IFS=',' read -ra parts <<< "$EFFECTIVE_ALLOWED_IPS"
    for p in "${parts[@]}"; do
        p="$(trim "$p")"
        [ -z "$p" ] && continue
        case "$p" in
            *:*) v6+=("$p") ;;
            *) v4+=("$p") ;;
        esac
    done
    if install_client_filter iptables "${v4[@]}"; then
        log "Forwarding filter: VPN clients may be forwarded only to: ${v4[*]:-nothing}"
    else
        log "****************************************************************"
        log "WARNING: could not install the IPv4 forwarding filter (see the"
        log "error above). allowed_ips is then NOT enforced on the server:"
        log "a client that edits its own AllowedIPs can reach the whole LAN."
        log "****************************************************************"
    fi
    if [ "$DISABLE_IPV6_OPT" != "true" ]; then
        if install_client_filter ip6tables "${v6[@]}"; then
            log "Forwarding filter (IPv6): clients may be forwarded only to: ${v6[*]:-nothing}"
        else
            log "WARNING: could not install the IPv6 forwarding filter;"
            log "allowed_ips is NOT enforced for IPv6 traffic."
        fi
    fi
}

warn_if_lan_reachable() {
    if [ -n "$EXTRA_ALLOWED_IPS" ]; then
        log "****************************************************************"
        log "WARNING: VPN clients can reach MORE than this Home Assistant host:"
        log "  ${EXTRA_ALLOWED_IPS}"
        log "Every machine in those ranges (cameras, NAS, admin interfaces, ...)"
        log "is reachable by any connected client. To restrict clients to Home"
        log "Assistant only, empty the 'allowed_ips' option."
        log "****************************************************************"
    else
        log "allowed_ips: VPN clients reach this Home Assistant host only."
    fi
}

# ---- WG-Easy database: inspect, then apply what the add-on manages -------------
json_array_from_csv() {
    jq -cn --arg v "$1" '$v | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != ""))'
}
prepare_database() {
    local state apply
    if ! state="$(node "$ADDON/prepare-db.mjs" inspect)"; then
        log "ERROR: could not open or migrate the WG-Easy database (see above)."
        exit 1
    fi
    SETUP_DONE="$(jq -r '.setupDone' <<< "$state")"
    DB_IPV4_CIDR="$(jq -r '.ipv4Cidr // empty' <<< "$state")"
    DB_ADMIN="$(jq -r '.adminUsername // empty' <<< "$state")"

    if [ "$SETUP_DONE" = "true" ]; then
        TUNNEL_CIDR="${DB_IPV4_CIDR:-$SHIPPED_TUNNEL_CIDR}"
        if [ -n "$OPT_IPV4_CIDR" ] && [ "$OPT_IPV4_CIDR" != "$TUNNEL_CIDR" ]; then
            log "NOTE: ipv4_cidr ($OPT_IPV4_CIDR) only applies to a new installation."
            log "The tunnel uses $TUNNEL_CIDR; change it in the WG-Easy panel"
            log "(Administration > Interface), which also renumbers existing clients."
        fi
    else
        TUNNEL_CIDR="${OPT_IPV4_CIDR:-${DB_IPV4_CIDR:-$SHIPPED_TUNNEL_CIDR}}"
    fi
    derive_allowed_ips

    apply="$(jq -cn \
        --arg device "$LAN_DEV" \
        --argjson allowed "$(json_array_from_csv "$EFFECTIVE_ALLOWED_IPS")" \
        --arg host "$OPT_HOST" \
        --arg port "$OPT_PORT" \
        --argjson dns "$(json_array_from_csv "$OPT_DNS")" \
        --arg mtu "$OPT_MTU" \
        --arg keepalive "$OPT_KEEPALIVE" \
        '{
            device: (if $device == "" then null else $device end),
            defaultAllowedIps: $allowed,
            host: (if $host == "" then null else $host end),
            port: ($port | tonumber),
            dns: (if ($dns | length) == 0 then null else $dns end),
            mtu: (if $mtu == "" then null else ($mtu | tonumber) end),
            keepalive: (if $keepalive == "" then null else ($keepalive | tonumber) end)
        } | with_entries(select(.value != null))')"
    if ! node "$ADDON/prepare-db.mjs" apply "$apply"; then
        log "WARNING: could not apply the add-on settings to the WG-Easy database;"
        log "WG-Easy starts with its stored settings."
    fi
}

# ---- first installation: seed WG-Easy so no setup wizard is needed --------------
# WG-Easy only reads INIT_* while its setup is not finished, and only creates
# the admin user when username, password, host and port are all present.
configure_first_run() {
    if [ "$SETUP_DONE" = "true" ]; then
        ADMIN_USERNAME="${DB_ADMIN:-admin}"
        log "Existing WG-Easy installation: keeping its stored configuration."
        return 0
    fi
    local host="$OPT_HOST"
    if [ -z "$host" ]; then
        if host="$(node "$ADDON/public-ip.mjs")"; then
            log "First start: public address detected as $host (change it any time in"
            log "the WG-Easy panel, or set the 'host' option, e.g. to a DDNS name)."
        else
            host="${HOST_LAN_IP:-127.0.0.1}"
            log "WARNING: could not detect the public address. Client configs will use"
            log "$host, which only works inside your network. Set your public IP or"
            log "DDNS name in the WG-Easy panel (Administration > Config) or in 'host'."
        fi
    fi
    ADMIN_USERNAME="admin"
    log "First start: creating the WG-Easy configuration (no setup wizard needed)."
    export INIT_ENABLED=true
    export INIT_USERNAME="$ADMIN_USERNAME"
    export INIT_PASSWORD="$ADMIN_PASSWORD"
    export INIT_HOST="$host"
    export INIT_PORT="$OPT_PORT"
    export INIT_ALLOWED_IPS="$EFFECTIVE_ALLOWED_IPS"
    [ -n "$OPT_DNS" ] && export INIT_DNS="$OPT_DNS"
    if [ -n "$OPT_IPV4_CIDR" ] || [ -n "$OPT_IPV6_CIDR" ]; then
        # WG-Easy applies the CIDRs only when both are given.
        export INIT_IPV4_CIDR="${OPT_IPV4_CIDR:-$SHIPPED_TUNNEL_CIDR}"
        export INIT_IPV6_CIDR="${OPT_IPV6_CIDR:-$WG_EASY_DEFAULT_IPV6_CIDR}"
    fi
    return 0
}

# ---- network diagnostics (background, once wg0 is up) ----------------------------
dump_network_state() {
    set +e
    local masq
    for _ in $(seq 1 30); do
        ip link show wg0 >/dev/null 2>&1 && break
        sleep 1
    done
    log "---- network state ----"
    if ip link show wg0 >/dev/null 2>&1; then
        log "  wg0 = $(ip -4 addr show wg0 2>/dev/null | sed -n 's/.*inet \([^ ]*\).*/\1/p')"
    else
        log "  wg0 = not present (the tunnel did not come up, see WG-Easy's log above)"
    fi
    log "  LAN device = ${LAN_DEV:-unknown}, allowed = ${EFFECTIVE_ALLOWED_IPS:-unknown}"
    masq="$(iptables -t nat -S POSTROUTING 2>&1 | grep -F -- "-s ${TUNNEL_CIDR} " | grep -i masquerade | head -n1)"
    if [ -z "$masq" ]; then
        log "  NAT: no MASQUERADE rule for ${TUNNEL_CIDR}: other LAN hosts cannot answer."
    elif [ -n "$LAN_DEV" ] && ! grep -q -- "-o ${LAN_DEV} " <<< "$masq "; then
        log "  NAT: MASQUERADE is not on the LAN device ${LAN_DEV}: $masq"
    else
        log "  NAT: OK ($masq)"
    fi
    log "---- end network state ----"
}

# ---- Home Assistant bridge (supervised, optional) --------------------------------
start_bridge() {
    BRIDGE_PID=""
    if [ "$HA_ENTITIES" != "true" ]; then
        log "Home Assistant entities: disabled by the 'home_assistant_entities' option."
        return 0
    fi
    (
        child=""
        trap '[ -n "$child" ] && kill -TERM "$child" 2>/dev/null; wait "$child" 2>/dev/null; exit 0' TERM INT
        while true; do
            node "$ADDON/ha-bridge.mjs" &
            child=$!
            rc=0; wait "$child" || rc=$?
            child=""
            # 3 = no broker / nothing to do: do not retry until the next start.
            [ "$rc" = 3 ] && exit 0
            echo "[add-on] Home Assistant bridge exited ($rc); restarting in 30 s."
            sleep 30 & wait $!
        done
    ) &
    BRIDGE_PID=$!
}

# ==================================================================================
setup_persistence
protect_database
ensure_admin_secret

# A previous run that was killed (instead of stopped) can leave wg0 behind in
# the host's network namespace; WG-Easy would then fail to bring it up again.
if ip link show wg0 >/dev/null 2>&1; then
    log "Removing a stale wg0 interface left by a previous run."
    ip link del wg0 2>/dev/null || true
fi

enable_ipv4_forwarding
wait_for_network
prepare_database
restrict_client_forwarding
warn_if_lan_reachable
configure_first_run

# ---- WG-Easy environment -----------------------------------------------------------
# The web UI listens on the loopback only; the ingress proxy is the only way in,
# and it accepts connections only from the Supervisor (see ingress-proxy.mjs).
# INSECURE=true because HA Ingress terminates TLS in front of it.
export PORT="$WEB_PORT"
export HOST="127.0.0.1"
export INSECURE=true
export NUXT_APP_BASE_URL="$APP_BASE"
export DISABLE_IPV6="$DISABLE_IPV6_OPT"
# Credentials of the managed admin account, for the proxy and the bridge.
export ADDON_ADMIN_USERNAME="$ADMIN_USERNAME"
export ADDON_ADMIN_PASSWORD="$ADMIN_PASSWORD"
export WEB_PORT APP_BASE ADDON_VERSION

cd /app
node server/index.mjs &
WGEASY_PID=$!

INGRESS_PORT="$INGRESS_PORT" METRICS_PORT="${OPT_METRICS_PORT:-0}" node "$ADDON/ingress-proxy.mjs" &
PROXY_PID=$!

start_bridge
dump_network_state &

# ---- clean shutdown ------------------------------------------------------------------
# bash runs as PID 1 (init: false) and PID 1 ignores SIGTERM unless it traps it.
# Without this trap Supervisor's stop would wait for its timeout and SIGKILL
# everything: WG-Easy would die in the middle of a database write and never take
# wg0 down. Forward the signal and wait for WG-Easy's own graceful shutdown.
shutdown() {
    local code="${1:-0}"
    trap - TERM INT
    log "Stopping: asking WG-Easy to shut down cleanly."
    kill -TERM "$WGEASY_PID" "$PROXY_PID" ${BRIDGE_PID:+"$BRIDGE_PID"} 2>/dev/null || true
    wait "$WGEASY_PID" 2>/dev/null || true
    wait "$PROXY_PID" 2>/dev/null || true
    [ -n "${BRIDGE_PID:-}" ] && { wait "$BRIDGE_PID" 2>/dev/null || true; }
    log "Stopped."
    exit "$code"
}
trap 'shutdown 0' TERM INT

# Exit with an error if WG-Easy or the proxy dies, so that the Supervisor
# watchdog restarts the add-on.
wait -n "$WGEASY_PID" "$PROXY_PID" || true
log "WG-Easy or the ingress proxy exited unexpectedly; stopping the add-on."
shutdown 1
