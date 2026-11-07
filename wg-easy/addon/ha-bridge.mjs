// Home Assistant entities for WG-Easy, through MQTT discovery.
//
// When an MQTT broker is available (normally the official Mosquitto add-on, whose
// credentials the Supervisor hands out automatically), this process publishes:
//
//   Device "WG-Easy VPN"
//     sensor   Clients              number of clients
//     sensor   Connected clients    clients with a handshake in the last 3 min
//     button   Restart interface    restarts wg0 (POST /api/admin/interface/restart)
//   One device per VPN client ("VPN <name>"), linked to the one above
//     switch         Enabled         enable / disable the client
//     binary_sensor  Connected       handshake in the last 3 min
//     sensor         Received / Sent bytes (total_increasing)
//     sensor         Last handshake  timestamp
//     sensor         Endpoint, IPv4 address, Expires (diagnostic)
//
// Clients created, renamed or deleted in the web UI appear, are renamed or are
// removed in Home Assistant automatically.
//
// Exit codes: 0 = stopped, 3 = no broker / disabled (the launcher does not
// restart it), anything else = error (the launcher restarts it after a delay).
import mqtt from "mqtt";
import { readFileSync, writeFileSync, renameSync } from "node:fs";
import { UpstreamSession, log as baseLog } from "./lib.mjs";

const log = (...a) => baseLog("ha-bridge", ...a);
const POLL_MS = parseInt(process.env.HA_BRIDGE_POLL_MS || "10000", 10);
const CONNECTED_WINDOW_MS = 3 * 60 * 1000; // WireGuard re-handshakes every 2 min
const STATE_FILE = process.env.HA_BRIDGE_STATE_FILE || "/data/ha-bridge.json";
const PREFIX = process.env.HA_DISCOVERY_PREFIX || "homeassistant";
const NODE = "wg_easy";
const T = `${NODE}`; // base topic
const AVAILABILITY = `${T}/status`;
const SERVER_DEVICE = {
    identifiers: [`${NODE}_server`],
    name: "WG-Easy VPN",
    manufacturer: "WG-Easy",
    model: "WireGuard server",
    sw_version: process.env.ADDON_VERSION || undefined,
};

// ---- broker discovery --------------------------------------------------------
async function brokerOptions() {
    if (process.env.MQTT_URL) {
        // Manual override (tests, or a broker the Supervisor does not know about).
        return { url: process.env.MQTT_URL, username: process.env.MQTT_USERNAME, password: process.env.MQTT_PASSWORD };
    }
    const token = process.env.SUPERVISOR_TOKEN;
    if (!token) return null;
    try {
        const res = await fetch("http://supervisor/services/mqtt", {
            headers: { authorization: `Bearer ${token}` },
            signal: AbortSignal.timeout(10_000),
        });
        if (!res.ok) return null;
        const { data } = await res.json();
        if (!data || !data.host) return null;
        return {
            url: `${data.ssl ? "mqtts" : "mqtt"}://${data.host}:${data.port}`,
            username: data.username,
            password: data.password,
        };
    } catch {
        return null;
    }
}

// ---- persisted list of published clients (to clean up after deletions) ------
function loadKnown() {
    try {
        return new Map(Object.entries(JSON.parse(readFileSync(STATE_FILE, "utf8")).clients || {}));
    } catch {
        return new Map();
    }
}
function saveKnown(known) {
    try {
        const tmp = `${STATE_FILE}.tmp`;
        writeFileSync(tmp, JSON.stringify({ clients: Object.fromEntries(known) }));
        renameSync(tmp, STATE_FILE);
    } catch (err) {
        log("WARNING: could not save state:", err.message);
    }
}

// ---- discovery payloads --------------------------------------------------------
function clientEntities(id, name) {
    const state = `${T}/client/${id}`;
    const device = {
        identifiers: [`${NODE}_client_${id}`],
        // "VPN <client>": readable, and entity ids (switch.vpn_phone_enabled)
        // cannot collide with another device of the same name, such as the
        // Home Assistant companion app's phone.
        name: `VPN ${name}`,
        manufacturer: "WG-Easy",
        model: "WireGuard client",
        via_device: `${NODE}_server`,
    };
    const common = (key) => ({
        unique_id: `${NODE}_client_${id}_${key}`,
        availability_topic: AVAILABILITY,
        state_topic: state,
        device,
    });
    return [
        ["switch", "enabled", {
            ...common("enabled"), name: "Enabled", icon: "mdi:vpn",
            command_topic: `${state}/set`,
            value_template: "{{ 'ON' if value_json.enabled else 'OFF' }}",
        }],
        ["binary_sensor", "connected", {
            ...common("connected"), name: "Connected", device_class: "connectivity",
            value_template: "{{ 'ON' if value_json.connected else 'OFF' }}",
        }],
        ["sensor", "received", {
            ...common("received"), name: "Received", device_class: "data_size", unit_of_measurement: "B",
            state_class: "total_increasing", icon: "mdi:download", value_template: "{{ value_json.rx }}",
        }],
        ["sensor", "sent", {
            ...common("sent"), name: "Sent", device_class: "data_size", unit_of_measurement: "B",
            state_class: "total_increasing", icon: "mdi:upload", value_template: "{{ value_json.tx }}",
        }],
        ["sensor", "last_handshake", {
            ...common("last_handshake"), name: "Last handshake", device_class: "timestamp",
            value_template: "{{ value_json.handshake if value_json.handshake else 'None' }}",
        }],
        ["sensor", "endpoint", {
            ...common("endpoint"), name: "Endpoint", entity_category: "diagnostic", icon: "mdi:ip-network",
            value_template: "{{ value_json.endpoint if value_json.endpoint else 'None' }}",
        }],
        ["sensor", "address", {
            ...common("address"), name: "IPv4 address", entity_category: "diagnostic", icon: "mdi:ip",
            value_template: "{{ value_json.ipv4 }}",
        }],
        ["sensor", "expires", {
            ...common("expires"), name: "Expires", device_class: "timestamp", entity_category: "diagnostic",
            value_template: "{{ value_json.expires if value_json.expires else 'None' }}",
        }],
    ];
}

function serverEntities() {
    const state = `${T}/server`;
    const common = (key) => ({
        unique_id: `${NODE}_server_${key}`,
        availability_topic: AVAILABILITY,
        device: SERVER_DEVICE,
    });
    return [
        ["sensor", "clients", {
            ...common("clients"), name: "Clients", icon: "mdi:account-multiple", state_class: "measurement",
            state_topic: state, value_template: "{{ value_json.clients }}",
        }],
        ["sensor", "connected_clients", {
            ...common("connected_clients"), name: "Connected clients", icon: "mdi:account-network",
            state_class: "measurement", state_topic: state, value_template: "{{ value_json.connected }}",
        }],
        ["button", "restart", {
            ...common("restart"), name: "Restart interface", icon: "mdi:restart",
            entity_category: "config", command_topic: `${T}/server/restart`,
        }],
    ];
}

const configTopic = (component, uid) => `${PREFIX}/${component}/${NODE}/${uid}/config`;

// ---- main ----------------------------------------------------------------------
const broker = await brokerOptions();
if (!broker) {
    log("No MQTT broker available: Home Assistant entities are disabled.");
    log("Install the official Mosquitto broker add-on to get them; this add-on");
    log("then picks it up automatically on its next start.");
    process.exit(3);
}

const session = new UpstreamSession("ha-bridge");
const known = loadKnown(); // id -> name, as published
let lastStates = new Map();

const client = mqtt.connect(broker.url, {
    username: broker.username,
    password: broker.password,
    clientId: `wg_easy_${Math.random().toString(16).slice(2, 10)}`,
    will: { topic: AVAILABILITY, payload: "offline", retain: true, qos: 1 },
    reconnectPeriod: 5000,
});

const publish = (topic, payload, retain = true) =>
    new Promise((resolve) => client.publish(topic, payload, { retain, qos: 1 }, () => resolve()));

function publishDiscovery(entities, uidPrefix) {
    return Promise.all(
        entities.map(([component, key, payload]) => publish(configTopic(component, `${uidPrefix}_${key}`), JSON.stringify(payload))),
    );
}

async function removeClient(id, name) {
    await Promise.all(
        clientEntities(id, name).map(([component, key]) => publish(configTopic(component, `client_${id}_${key}`), "")),
    );
    await publish(`${T}/client/${id}`, "");
    log(`Removed entities of deleted client #${id} (${name}).`);
}

async function announceAll() {
    await publishDiscovery(serverEntities(), "server");
    for (const [id, name] of known) await publishDiscovery(clientEntities(id, name), `client_${id}`);
    lastStates = new Map(); // force a state refresh
}

async function poll() {
    let clients;
    try {
        const res = await session.fetch("/api/client");
        if (!res.ok) throw new Error(`GET /api/client -> ${res.status}`);
        clients = await res.json();
    } catch (err) {
        await publish(AVAILABILITY, "offline");
        log("WG-Easy not reachable yet:", err.message);
        return;
    }

    const now = Date.now();
    const seen = new Set();
    let connectedCount = 0;
    for (const c of clients) {
        const id = String(c.id);
        seen.add(id);
        if (known.get(id) !== c.name) {
            await publishDiscovery(clientEntities(id, c.name), `client_${id}`);
            log(`${known.has(id) ? "Updated" : "Added"} entities for client #${id} (${c.name}).`);
            known.set(id, c.name);
            saveKnown(known);
        }
        const handshake = c.latestHandshakeAt ? new Date(c.latestHandshakeAt) : null;
        const connected = !!handshake && now - handshake.getTime() < CONNECTED_WINDOW_MS;
        if (connected) connectedCount++;
        const state = JSON.stringify({
            enabled: !!c.enabled,
            connected,
            rx: c.transferRx ?? 0,
            tx: c.transferTx ?? 0,
            handshake: handshake ? handshake.toISOString() : null,
            endpoint: c.endpoint || null,
            ipv4: c.ipv4Address,
            expires: c.expiresAt ? new Date(c.expiresAt).toISOString() : null,
        });
        if (lastStates.get(id) !== state) {
            await publish(`${T}/client/${id}`, state);
            lastStates.set(id, state);
        }
    }
    for (const [id, name] of [...known]) {
        if (!seen.has(id)) {
            await removeClient(id, name);
            known.delete(id);
            lastStates.delete(id);
            saveKnown(known);
        }
    }
    const server = JSON.stringify({ clients: clients.length, connected: connectedCount });
    if (lastStates.get("server") !== server) {
        await publish(`${T}/server`, server);
        lastStates.set("server", server);
    }
    await publish(AVAILABILITY, "online");
}

async function command(topic, payload) {
    const m = topic.match(new RegExp(`^${T}/client/(\\d+)/set$`));
    let res;
    if (m) {
        const action = payload === "ON" ? "enable" : payload === "OFF" ? "disable" : null;
        if (!action) return;
        res = await session.fetch(`/api/client/${m[1]}/${action}`, { method: "POST" });
        log(`Client #${m[1]} ${action}d from Home Assistant (${res.status}).`);
    } else if (topic === `${T}/server/restart`) {
        res = await session.fetch("/api/admin/interface/restart", { method: "POST" });
        log(`Interface restart requested from Home Assistant (${res.status}).`);
    } else {
        return;
    }
    if (!res.ok) log("WARNING: WG-Easy refused the command:", res.status, await res.text().catch(() => ""));
    await poll();
}

let timer = null;
let polling = false;
async function tick() {
    if (polling) return;
    polling = true;
    try {
        await poll();
    } catch (err) {
        log("poll error:", err.message);
    } finally {
        polling = false;
    }
}

client.on("connect", async () => {
    log(`Connected to MQTT broker ${broker.url}.`);
    client.subscribe([`${T}/client/+/set`, `${T}/server/restart`, `${PREFIX}/status`], { qos: 1 });
    await announceAll();
    await tick();
    if (!timer) timer = setInterval(tick, POLL_MS);
});

client.on("message", (topic, buf) => {
    const payload = buf.toString();
    if (topic === `${PREFIX}/status`) {
        // Home Assistant restarted: re-announce so entities come back at once.
        if (payload === "online") announceAll().then(tick).catch((e) => log("re-announce failed:", e.message));
        return;
    }
    command(topic, payload).catch((err) => log("command failed:", err.message));
});

client.on("error", (err) => log("MQTT error:", err.message));

async function stop() {
    clearInterval(timer);
    await publish(AVAILABILITY, "offline");
    client.end(false, () => process.exit(0));
    setTimeout(() => process.exit(0), 2000).unref();
}
process.on("SIGTERM", stop);
process.on("SIGINT", stop);
