// Pre-start database preparation for the WG-Easy Home Assistant add-on.
//
// WHY THIS EXISTS
// WG-Easy hardcodes `device = 'eth0'` in its first database migration
// (/app/server/database/migrations/0001_classy_the_stranger.sql). That value is
// read back at startup and substituted into the PostUp hook
// (`iptables -t nat -A POSTROUTING -s <cidr> -o {{device}} -j MASQUERADE`), so
// the NAT rule is installed on `eth0` no matter what the real LAN interface is
// called. On hosts whose LAN interface is not `eth0` the MASQUERADE rule never
// matches, replies from other LAN machines are dropped, and only the Home
// Assistant host itself is reachable over the VPN.
//
// WHAT IT DOES
//   1. Runs WG-Easy's own drizzle migrations against the WG-Easy database
//      (same folder, same drizzle version as the app), so a fresh install gets
//      a fully seeded database and an existing one is left untouched
//      (migrations are recorded and re-running is a no-op).
//   2. Overwrites `interfaces_table.device` for `wg0` with the LAN device the
//      launcher detected (the default-route device).
//
// It runs BEFORE `node server/index.mjs`, i.e. before WG-Easy reads the row and
// writes /etc/wireguard/wg0.conf and runs `wg-quick up wg0`. Doing it in this
// order is what makes the fix effective on the very first run, with no restart
// and no manual step in the web UI.
//
// Usage: node fix-lan-device.mjs <device>
import { createClient } from "@libsql/client";
import { drizzle } from "drizzle-orm/libsql";
import { migrate } from "drizzle-orm/libsql/migrator";

const DB_URL = "file:/etc/wireguard/wg-easy.db";
const MIGRATIONS_FOLDER = "/app/server/database/migrations";

const device = (process.argv[2] || "").trim();
if (!device) {
    console.error("[fix-lan-device] no device given; refusing to touch the database.");
    process.exit(2);
}

const client = createClient({ url: DB_URL });
const db = drizzle({ client });

try {
    await migrate(db, { migrationsFolder: MIGRATIONS_FOLDER });
    console.log("[fix-lan-device] migrations up to date.");

    const res = await client.execute({
        sql: "UPDATE interfaces_table SET device = ? WHERE name = 'wg0'",
        args: [device],
    });
    const rows = Number(res.rowsAffected ?? 0);
    console.log(
        `[fix-lan-device] interfaces_table.device for wg0 set to '${device}' (rows updated: ${rows}).`,
    );
    if (rows === 0) {
        // Should not happen after a successful migrate (0001 seeds the row).
        console.error(
            "[fix-lan-device] WARNING: no wg0 row was updated; WG-Easy will keep its stored device.",
        );
        process.exit(3);
    }
} catch (err) {
    console.error("[fix-lan-device] ERROR:", err && err.message ? err.message : err);
    process.exit(1);
} finally {
    client.close();
}
