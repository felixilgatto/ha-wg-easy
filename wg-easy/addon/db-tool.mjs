// Database safety tool for the WG-Easy Home Assistant add-on.
//
// Lives in /app/server so that `@libsql/client` resolves from WG-Easy's own
// node_modules (same driver and SQLite build as the app itself).
//
// Usage:
//   node db-tool.mjs check <db>            exit 0 if PRAGMA integrity_check is "ok"
//   node db-tool.mjs snapshot <db> <dest>  write a consistent copy (VACUUM INTO)
//
// `snapshot` is safe while WG-Easy is running: VACUUM INTO reads a consistent
// view of the database and writes a standalone file (no -wal/-shm needed). The
// copy is written to <dest>.tmp, verified, then renamed, so <dest> is never a
// half-written file.
import { createClient } from "@libsql/client";
import { existsSync, renameSync, rmSync } from "node:fs";

const [cmd, db, dest] = process.argv.slice(2);

function fail(msg, code = 1) {
    console.error(`[db-tool] ${msg}`);
    process.exit(code);
}

async function integrity(path) {
    const client = createClient({ url: `file:${path}` });
    try {
        const res = await client.execute("PRAGMA integrity_check");
        const first = res.rows[0] ? Object.values(res.rows[0])[0] : null;
        return first === "ok" ? null : String(first);
    } catch (err) {
        return err && err.message ? err.message : String(err);
    } finally {
        client.close();
    }
}

if (!db || !existsSync(db)) fail(`database not found: ${db}`, 2);

if (cmd === "check") {
    const problem = await integrity(db);
    if (problem) fail(`integrity check FAILED for ${db}: ${problem}`);
    console.log(`[db-tool] integrity check ok: ${db}`);
} else if (cmd === "snapshot") {
    if (!dest) fail("snapshot needs a destination path", 2);
    const tmp = `${dest}.tmp`;
    rmSync(tmp, { force: true });
    const client = createClient({ url: `file:${db}` });
    try {
        await client.execute({ sql: "VACUUM INTO ?", args: [tmp] });
    } catch (err) {
        rmSync(tmp, { force: true });
        fail(`snapshot failed: ${err && err.message ? err.message : err}`);
    } finally {
        client.close();
    }
    const problem = await integrity(tmp);
    if (problem) {
        rmSync(tmp, { force: true });
        fail(`snapshot is not valid, discarded: ${problem}`);
    }
    renameSync(tmp, dest);
    console.log(`[db-tool] snapshot written: ${dest}`);
} else {
    fail(`unknown command '${cmd}' (expected: check | snapshot)`, 2);
}
