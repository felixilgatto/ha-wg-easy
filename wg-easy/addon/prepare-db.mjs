// Pre-start database preparation for the WG-Easy Home Assistant add-on.
//
// Runs BEFORE WG-Easy starts, i.e. before it writes /etc/wireguard/wg0.conf and
// runs `wg-quick up wg0`, so everything set here is effective on the very first
// start, with no restart and no manual step in the web UI.
//
//   node prepare-db.mjs inspect
//       Runs WG-Easy's own migrations (a fresh install gets a fully seeded
//       database; an existing one is upgraded or left as is) and prints the
//       current state as JSON on stdout:
//       { setupDone, ipv4Cidr, ipv6Cidr, host, port, adminUsername }
//
//   node prepare-db.mjs apply '<json>'
//       Writes the values the add-on manages. Every key is optional; a missing
//       key leaves WG-Easy's stored value (i.e. whatever the web UI set) alone:
//         device            LAN device for the MASQUERADE rule. WG-Easy seeds
//                           'eth0', which is wrong on most HAOS hosts.
//         defaultAllowedIps AllowedIPs copied into NEW clients.
//         host              public endpoint written into client configs.
//         port              WireGuard listen port (see below for the public port).
//         dns               DNS servers for NEW clients (array).
//         mtu               interface MTU and default MTU for NEW clients.
//         keepalive         default PersistentKeepalive for NEW clients.
//
// Logs go to stderr so that stdout stays machine-readable.
import { createClient } from "@libsql/client";
import { drizzle } from "drizzle-orm/libsql";
import { migrate } from "drizzle-orm/libsql/migrator";

const DB_URL = "file:/etc/wireguard/wg-easy.db";
const MIGRATIONS_FOLDER = "/app/server/database/migrations";

const log = (...a) => console.error("[prepare-db]", ...a);

const [cmd, arg] = process.argv.slice(2);
const client = createClient({ url: DB_URL });

async function one(sql, args = []) {
    const res = await client.execute({ sql, args });
    return res.rows[0] || null;
}

async function update(label, sql, args) {
    const res = await client.execute({ sql, args });
    const rows = Number(res.rowsAffected ?? 0);
    if (rows === 0) throw new Error(`no row updated for ${label}`);
    log(`${label} set (${JSON.stringify(args[0])}).`);
}

try {
    await migrate(drizzle({ client }), { migrationsFolder: MIGRATIONS_FOLDER });

    if (cmd === "inspect") {
        const general = await one("SELECT setup_step FROM general_table WHERE id = 1");
        const iface = await one("SELECT ipv4_cidr, ipv6_cidr, port FROM interfaces_table WHERE name = 'wg0'");
        const uc = await one("SELECT host, port FROM user_configs_table WHERE id = 'wg0'");
        const admin = await one("SELECT username FROM users_table WHERE id = 1");
        process.stdout.write(
            JSON.stringify({
                // WG-Easy marks setup as finished with setup_step = 0.
                setupDone: general ? Number(general.setup_step) === 0 : false,
                ipv4Cidr: iface?.ipv4_cidr ?? null,
                ipv6Cidr: iface?.ipv6_cidr ?? null,
                listenPort: iface ? Number(iface.port) : null,
                host: uc?.host ?? null,
                port: uc ? Number(uc.port) : null,
                adminUsername: admin?.username ?? null,
            }) + "\n",
        );
    } else if (cmd === "apply") {
        const want = JSON.parse(arg || "{}");

        if (want.device) {
            await update("interface device", "UPDATE interfaces_table SET device = ? WHERE name = 'wg0'", [want.device]);
        }
        if (Array.isArray(want.defaultAllowedIps) && want.defaultAllowedIps.length) {
            // Stored as JSON, like WG-Easy's own column (drizzle text json mode).
            await update(
                "default AllowedIPs for new clients",
                "UPDATE user_configs_table SET default_allowed_ips = ? WHERE id = 'wg0'",
                [JSON.stringify(want.defaultAllowedIps)],
            );
        }
        if (want.host) {
            await update("public host", "UPDATE user_configs_table SET host = ? WHERE id = 'wg0'", [want.host]);
        }
        if (Number.isInteger(want.port)) {
            // The PUBLIC port clients connect to (user_configs.port) can differ
            // from the listen port when the router maps another external port,
            // and that is set in the web UI. Only move it along with the listen
            // port when the two were equal, i.e. it was never customised.
            const iface = await one("SELECT port FROM interfaces_table WHERE name = 'wg0'");
            const uc = await one("SELECT port FROM user_configs_table WHERE id = 'wg0'");
            if (iface && Number(iface.port) !== want.port) {
                await update("listen port", "UPDATE interfaces_table SET port = ? WHERE name = 'wg0'", [want.port]);
                if (uc && Number(uc.port) === Number(iface.port)) {
                    await update("public port", "UPDATE user_configs_table SET port = ? WHERE id = 'wg0'", [want.port]);
                }
            }
        }
        if (Array.isArray(want.dns) && want.dns.length) {
            await update(
                "default DNS for new clients",
                "UPDATE user_configs_table SET default_dns = ? WHERE id = 'wg0'",
                [JSON.stringify(want.dns)],
            );
        }
        if (Number.isInteger(want.mtu)) {
            await update("interface MTU", "UPDATE interfaces_table SET mtu = ? WHERE name = 'wg0'", [want.mtu]);
            await update(
                "default MTU for new clients",
                "UPDATE user_configs_table SET default_mtu = ? WHERE id = 'wg0'",
                [want.mtu],
            );
        }
        if (Number.isInteger(want.keepalive)) {
            await update(
                "default PersistentKeepalive for new clients",
                "UPDATE user_configs_table SET default_persistent_keepalive = ? WHERE id = 'wg0'",
                [want.keepalive],
            );
        }
    } else {
        throw new Error(`unknown command '${cmd}' (expected: inspect | apply)`);
    }
} catch (err) {
    log("ERROR:", err && err.message ? err.message : err);
    process.exitCode = 1;
} finally {
    client.close();
}
