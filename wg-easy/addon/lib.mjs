// Shared helpers for the add-on's Node processes (ingress proxy, HA bridge).
//
// Everything here talks to WG-Easy on the container's loopback, under the fixed
// internal base path the launcher starts it with.
import { execFile } from "node:child_process";

export const UPSTREAM_HOST = process.env.WEB_HOST || "127.0.0.1";
export const UPSTREAM_PORT = parseInt(process.env.WEB_PORT || "51821", 10);
export const BASE = process.env.APP_BASE || "/_haingress";
export const UPSTREAM_URL = `http://${UPSTREAM_HOST}:${UPSTREAM_PORT}${BASE}`;

// WG-Easy's session cookie name (server: `const name = "wg-easy"`).
export const SESSION_COOKIE = "wg-easy";

// Internal admin account managed by the add-on (see run.sh). The password is
// random, stored in /data, and never shown to anyone: Home Assistant already
// authenticated the user before Ingress forwards a request.
const ADMIN_USERNAME = process.env.ADDON_ADMIN_USERNAME || "admin";
const ADMIN_PASSWORD = process.env.ADDON_ADMIN_PASSWORD || "";

export function log(tag, ...args) {
    console.log(`[${tag}]`, ...args);
}

// Re-apply the managed password to WG-Easy's admin user (user id 1). This also
// clears 2FA. Used when a login fails, e.g. because someone changed the
// password or enabled 2FA in the web UI, which would otherwise lock the
// automatic login out.
let resetInFlight = null;
export function resetAdminPassword() {
    if (resetInFlight) return resetInFlight;
    resetInFlight = new Promise((resolve) => {
        execFile(
            "node",
            ["server/cli.mjs", "db:admin:reset", "--password", ADMIN_PASSWORD],
            { cwd: "/app", timeout: 60_000 },
            (err) => {
                if (err) log("auth", "WARNING: could not reset the admin password:", err.message);
                else log("auth", "Admin password re-applied (the managed login had stopped working).");
                resetInFlight = null;
                resolve();
            },
        );
    });
    return resetInFlight;
}

function sessionCookieFrom(headers) {
    const list = typeof headers.getSetCookie === "function" ? headers.getSetCookie() : [];
    for (const c of list) {
        const pair = c.split(";")[0];
        if (pair.startsWith(`${SESSION_COOKIE}=`)) return pair;
    }
    return null;
}

async function tryLogin() {
    const res = await fetch(`${UPSTREAM_URL}/api/auth/password`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ username: ADMIN_USERNAME, password: ADMIN_PASSWORD, remember: true }),
    });
    let body = null;
    try {
        body = await res.json();
    } catch {
        /* not JSON */
    }
    if (res.ok && body && body.status === "success") {
        const cookie = sessionCookieFrom(res.headers);
        if (cookie) return { cookie };
    }
    // 5xx = WG-Easy problem, not a credentials problem: do not reset for that.
    return { cookie: null, retryable: res.status < 500 };
}

// One logged-in WG-Easy session, re-established on demand.
export class UpstreamSession {
    constructor(tag) {
        this.tag = tag;
        this.cookie = null;
        this.pending = null;
    }

    invalidate() {
        this.cookie = null;
    }

    // Returns "wg-easy=<sealed>" or throws (e.g. WG-Easy not up yet).
    async get() {
        if (this.cookie) return this.cookie;
        if (!ADMIN_PASSWORD) throw new Error("ADDON_ADMIN_PASSWORD is not set");
        if (!this.pending) {
            this.pending = (async () => {
                let r = await tryLogin();
                if (!r.cookie && r.retryable) {
                    await resetAdminPassword();
                    r = await tryLogin();
                }
                if (!r.cookie) throw new Error("automatic login to WG-Easy failed");
                this.cookie = r.cookie;
                return r.cookie;
            })().finally(() => {
                this.pending = null;
            });
        }
        return this.pending;
    }

    // Track a Set-Cookie from upstream: WG-Easy refreshes or clears the session.
    observe(setCookieList) {
        for (const c of setCookieList || []) {
            const pair = c.split(";")[0];
            if (!pair.startsWith(`${SESSION_COOKIE}=`)) continue;
            const value = pair.slice(SESSION_COOKIE.length + 1);
            const expired = /max-age=0\b/i.test(c) || /expires=thu, 01 jan 1970/i.test(c);
            this.cookie = value && !expired ? pair : null;
        }
    }

    // fetch() against WG-Easy's API with the session, re-logging in once on 401.
    async fetch(path, init = {}) {
        for (let attempt = 0; attempt < 2; attempt++) {
            const cookie = await this.get();
            const res = await fetch(`${UPSTREAM_URL}${path}`, {
                ...init,
                headers: { ...(init.headers || {}), cookie },
            });
            if (res.status === 401 && attempt === 0) {
                this.invalidate();
                continue;
            }
            this.observe(res.headers.getSetCookie?.());
            return res;
        }
        throw new Error("unreachable");
    }
}

// Replace (or add) WG-Easy's session cookie in a browser Cookie header.
export function withSessionCookie(cookieHeader, sessionPair) {
    const parts = (cookieHeader || "")
        .split(";")
        .map((s) => s.trim())
        .filter((s) => s && !s.startsWith(`${SESSION_COOKIE}=`));
    parts.push(sessionPair);
    return parts.join("; ");
}
