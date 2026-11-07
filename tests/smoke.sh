#!/usr/bin/env bash
# End-to-end smoke test of the add-on image, in plain Docker.
#
# It plays the Supervisor's part: a persistent /data volume, an options.json, a
# container recreated on every "restart"/"update", and an MQTT broker standing
# in for the Mosquitto add-on. It does NOT reproduce Home Assistant OS itself
# (kernel, read-only /proc/sys, Supervisor network); see DOCS.md.
#
# Usage: tests/smoke.sh [image]   (builds wg-easy/ as wgeasy-addon:test if no image)
# Needs: docker, and a host kernel with WireGuard (any recent Linux).
set -euo pipefail

cd "$(dirname "$0")/.."
IMAGE="${1:-}"
P=wgsmoke                  # prefix of every docker object created here
NET="$P-net"; VOL="$P-data"; ADDON="$P-addon"; MQTT="$P-mqtt"
FAILS=0
# Helper images, pinned so the test does not change under our feet.
ALPINE=alpine:3.22
CURL=curlimages/curl:8.16.0
MOSQUITTO=eclipse-mosquitto:2.0.22

pass() { printf '  \033[32mok\033[0m   %s\n' "$*"; }
fail() {
    printf '  \033[31mFAIL\033[0m %s\n' "$*"
    FAILS=$((FAILS + 1))
    # Show the add-on log once, at the first failure, where it explains most.
    if [ "$FAILS" -eq 1 ]; then
        echo "  ---- add-on log at first failure (last 60 lines) ----"
        docker logs "$ADDON" 2>&1 | tail -n 60 | sed 's/^/  | /'
        echo "  ---- end of add-on log ----"
    fi
}
check() { local what="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$what"; else fail "$what"; fi; }
section() { printf '\n== %s\n' "$*"; }

cleanup() {
    docker rm -f "$ADDON" "$MQTT" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
    docker volume rm -f "$VOL" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

if [ -z "$IMAGE" ]; then
    IMAGE=wgeasy-addon:test
    docker build -q --build-arg BUILD_VERSION=test --build-arg BUILD_ARCH=amd64 -t "$IMAGE" wg-easy >/dev/null
fi

docker network create "$NET" >/dev/null
docker volume create "$VOL" >/dev/null
docker run -d --name "$MQTT" --network "$NET" "$MOSQUITTO" \
    sh -c 'printf "listener 1883\nallow_anonymous true\n" > /tmp/m.conf; exec mosquitto -c /tmp/m.conf' >/dev/null

options() { docker run --rm -i -v "$VOL:/data" "$ALPINE" sh -c "cat > /data/options.json" <<< "$1"; }
start() {
    docker rm -f "$ADDON" >/dev/null 2>&1 || true
    docker run -d --name "$ADDON" --network "$NET" --cap-add NET_ADMIN \
        -e MQTT_URL="mqtt://$MQTT:1883" -e HA_BRIDGE_POLL_MS=2000 \
        -v "$VOL:/data" "$IMAGE" >/dev/null
    # ready when the proxy answers with a logged-in session
    for _ in $(seq 1 60); do
        [ "$(px GET /api/session | head -c 3)" = 200 ] && return 0
        sleep 1
    done
    docker logs "$ADDON" | tail -30
    return 1
}
# Request through the ingress proxy exactly as Home Assistant would (from the
# container's loopback, which the proxy accepts like the Supervisor address).
px() {
    docker exec "$ADDON" node -e '
        const [m, p, b] = process.argv.slice(1);
        fetch("http://127.0.0.1:8099" + p, { method: m, redirect: "manual",
            headers: { "x-ingress-path": "/api/hassio_ingress/T", "content-type": "application/json" },
            body: b || undefined })
          .then(async (r) => console.log(r.status, (r.headers.get("location") || "") + " " + (await r.text())))
          .catch((e) => console.log("ERR", e.message));' "$@"
}
mqtt_get() { docker exec "$MQTT" timeout 3 mosquitto_sub -h localhost -t "$1" -C 1 2>/dev/null || true; }
mqtt_count() { docker exec "$MQTT" sh -c "timeout 2 mosquitto_sub -h localhost -t '$1' -v 2>/dev/null | grep -c . || true"; }
logs() { docker logs "$ADDON" 2>&1; }

# -------------------------------------------------------------------------------
section "fresh install, no option filled in"
options '{"host":"","port":51820,"allowed_ips":"","disable_ipv6":true,"home_assistant_entities":true}'
check "add-on starts and the panel is logged in automatically" start
check "no setup wizard: first-start configuration created" grep -q "First start: creating" <(logs)
check "start-up log names the add-on and the bundled WG-Easy version" grep -qE "WG-Easy add-on .+ \(WG-Easy [0-9]+\.[0-9]+\.[0-9]+\) starting" <(logs)
check "page renders with ingress-rewritten asset URLs" grep -q "hassio_ingress/T/_nuxt" <(px GET /)
check "/login goes straight to the panel" grep -q "^302 /api/hassio_ingress/T" <(px GET /login)
check "wg0 is up" docker exec "$ADDON" ip link show wg0
check "allowed IPs restricted to the tunnel and this host" grep -q "reach this Home Assistant host only" <(logs)
check "forwarding filter installed" docker exec "$ADDON" iptables -C FORWARD -i wg0 -j HA_WGEASY_CLIENTS
check "health endpoint reports healthy" docker exec "$ADDON" wget -q -O /dev/null http://127.0.0.1:8099/_addon/health

section "source filter"
check "a request with a forged Ingress header from the network is refused" \
    grep -q "403" <(docker run --rm --network "$NET" "$CURL" -s -o /dev/null -w '%{http_code}' \
        -H 'X-Ingress-Path: /api/hassio_ingress/x' "http://$ADDON:8099/api/session")

section "clients and Home Assistant entities"
check "create a client through the panel" grep -q '"success":true' <(px POST /api/client '{"name":"phone","expiresAt":null}')
sleep 4
check "switch discovered in Home Assistant" grep -q '"command_topic":"wg_easy/client/1/set"' <(mqtt_get 'homeassistant/switch/wg_easy/client_1_enabled/config')
check "server sensors discovered" grep -q 'Connected clients' <(mqtt_get 'homeassistant/sensor/wg_easy/server_connected_clients/config')
check "HA device shows the WG-Easy version" grep -qE '"sw_version":"[^"]+ \(WG-Easy [0-9.]+\)"' <(mqtt_get 'homeassistant/sensor/wg_easy/server_clients/config')
check "client state published" grep -q '"enabled":true' <(mqtt_get 'wg_easy/client/1')
docker exec "$MQTT" mosquitto_pub -h localhost -t wg_easy/client/1/set -m OFF
sleep 3
check "switch OFF from Home Assistant disables the client" grep -q '"enabled":false' <(px GET /api/client)

section "automatic login heals itself"
px DELETE /api/session >/dev/null
check "after a logout in the UI the panel is still logged in" grep -q "^200" <(px GET /api/session)
pw="$(docker exec "$ADDON" cat /data/.admin_password)"
px POST /api/me/password "{\"currentPassword\":\"$pw\",\"newPassword\":\"ChangedInTheUi123\",\"confirmPassword\":\"ChangedInTheUi123\"}" >/dev/null
check "restart after the password was changed in the UI" start
check "the proxy re-applied the managed password" grep -q "Admin password re-applied" <(logs)

section "persistence across container re-creation (= add-on update)"
key_before="$(docker exec "$ADDON" sh -c 'grep PrivateKey /etc/wireguard/wg0.conf' | md5sum)"
t0=$(date +%s); docker stop "$ADDON" >/dev/null; t1=$(date +%s)
check "clean shutdown in under 5 s (signal forwarded to WG-Easy)" test $((t1 - t0)) -lt 5
check "WG-Easy took wg0 down itself" grep -q "wg-quick down wg0" <(logs)
check "re-created container starts" start
check "client still there" grep -q '"name":"phone"' <(px GET /api/client)
check "server key unchanged" test "$key_before" = "$(docker exec "$ADDON" sh -c 'grep PrivateKey /etc/wireguard/wg0.conf' | md5sum)"
check "start-up snapshot written" docker exec "$ADDON" sh -c 'ls /data/backups/wg-easy-*.db'

section "client deleted in the UI disappears from Home Assistant"
px DELETE /api/client/1 >/dev/null
sleep 4
check "entities of the deleted client removed" test "$(mqtt_count 'homeassistant/+/wg_easy/#')" = 3

section "optional overrides and metrics"
px POST /api/admin/general '{"sessionTimeout":3600,"metricsPrometheus":true,"metricsJson":false,"metricsPassword":null}' >/dev/null
options '{"host":"vpn.example.org","port":51999,"allowed_ips":"192.168.50.0/24","disable_ipv6":true,"home_assistant_entities":true,"dns":"9.9.9.9","mtu":1380,"persistent_keepalive":25,"metrics_port":9586}'
check "restart with overrides" start
check "listen port applied" docker exec "$ADDON" grep -q "ListenPort = 51999" /etc/wireguard/wg0.conf
check "MTU applied" docker exec "$ADDON" grep -q "MTU = 1380" /etc/wireguard/wg0.conf
check "LAN warning printed when allowed_ips opens the LAN" grep -q "can reach MORE than this Home Assistant host" <(logs)
check "LAN subnet enforced in the forwarding filter" docker exec "$ADDON" iptables -C HA_WGEASY_CLIENTS -d 192.168.50.0/24 -j RETURN
check "Prometheus metrics served on the metrics port" docker exec "$ADDON" sh -c 'wget -qO- http://127.0.0.1:9586/metrics/prometheus | grep -q wireguard_configured_peers'
check "the API is NOT served on the metrics port" docker exec "$ADDON" sh -c '! wget -qO- http://127.0.0.1:9586/api/client'

section "Home Assistant backup hook + corruption recovery"
check "backup_pre snapshot works while running" docker exec "$ADDON" node /app/server/addon/db-tool.mjs snapshot /data/wireguard/wg-easy.db /data/backups/ha-backup.db
docker stop "$ADDON" >/dev/null
docker run --rm -v "$VOL:/data" "$ALPINE" sh -c 'rm -f /data/wireguard/wg-easy.db-wal /data/wireguard/wg-easy.db-shm; dd if=/dev/urandom of=/data/wireguard/wg-easy.db bs=1024 seek=4 count=20 conv=notrunc 2>/dev/null'
check "restart with a damaged database" start
check "damaged database detected and a snapshot restored" grep -q "Restored the newest valid snapshot" <(logs)

section "no MQTT broker"
docker stop "$MQTT" >/dev/null
docker rm -f "$ADDON" >/dev/null
docker run -d --name "$ADDON" --network "$NET" --cap-add NET_ADMIN -v "$VOL:/data" "$IMAGE" >/dev/null
sleep 12
check "add-on runs without a broker" grep -q "^200" <(px GET /api/session)
check "explains how to get entities" grep -q "Install the official Mosquitto broker" <(logs)

printf '\n'
if [ "$FAILS" -eq 0 ]; then echo "All smoke tests passed."; else echo "$FAILS smoke test(s) FAILED."; exit 1; fi
