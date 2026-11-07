// Ingress reverse proxy for the WG-Easy add-on.
//
// Home Assistant Ingress forwards requests to this port and sets the header
// `X-Ingress-Path: /api/hassio_ingress/<token>`.
//
// 1. PATH TRANSLATION
// wg-easy 15.x cannot be served from a dynamic sub-path: it bakes its base URL
// in at start-up and its middleware redirects are absolute. So we start wg-easy
// with a FIXED internal base (APP_BASE) and, per request, translate between that
// fixed base and the dynamic ingress path:
//
//   request   HA strips prefix  ->  "/"          -> proxy prepends APP_BASE
//   response  wg-easy emits     ->  "/_haingress/_nuxt/x.js"
//             proxy rewrites    ->  "/api/hassio_ingress/<token>/_nuxt/x.js"
//
// This keeps absolute asset URLs, JS runtime API calls, redirect Location
// headers and cookie paths all pointing at the ingress entry point.
//
// 2. AUTOMATIC LOGIN
// Home Assistant has already authenticated the user (and the panel is limited
// to administrators, see config.yaml), so a second WG-Easy login adds nothing.
// The proxy holds one WG-Easy session for the add-on's internal admin account
// and injects it into every request. The browser never sees that session
// cookie. If the session is lost (logout, expiry, password changed in the UI),
// the proxy logs in again transparently and retries the request once.
//
// 3. SOURCE FILTER
// Because the proxy grants an authenticated session, it must only ever answer
// the Supervisor. See ALLOWED_SOURCES.
//
// 4. METRICS (optional)
// With METRICS_PORT set, a second listener serves ONLY WG-Easy's
// /metrics/prometheus and /metrics/json on that port, for a Prometheus server
// on the LAN. Enabling them, and their bearer token, is done in the WG-Easy UI.

import http from 'node:http';
import { existsSync } from 'node:fs';
import { BASE, UPSTREAM_HOST, UPSTREAM_PORT, SESSION_COOKIE, UpstreamSession, withSessionCookie, log } from './lib.mjs';

const LISTEN_PORT = parseInt(process.env.INGRESS_PORT || '8099', 10);
const METRICS_PORT = parseInt(process.env.METRICS_PORT || '0', 10);

// Home Assistant Ingress always reaches the add-on from the Supervisor, whose
// address on the internal `hassio` network is fixed: 172.30.32.2. The add-on
// runs with host_network, so this port listens on every host interface (LAN,
// wg0, ...). The X-Ingress-Path header alone is NOT a barrier - any client can
// send it - so connections are filtered by SOURCE ADDRESS: only the Supervisor
// (and the container's own loopback, for local diagnostics) may talk to the web
// UI. A TCP source address cannot be spoofed across a completed handshake.
// Override with INGRESS_ALLOWED_SOURCES (comma-separated) only if your
// Supervisor network differs.
const ALLOWED_SOURCES = new Set(
  (process.env.INGRESS_ALLOWED_SOURCES || '172.30.32.2,127.0.0.1,::1')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean),
);

function normaliseAddress(addr) {
  if (!addr) return '';
  // IPv4 clients on a dual-stack socket appear as ::ffff:a.b.c.d
  return addr.startsWith('::ffff:') ? addr.slice(7) : addr;
}

function sourceAllowed(socket) {
  return ALLOWED_SOURCES.has(normaliseAddress(socket && socket.remoteAddress));
}

const TEXT_TYPE = /(?:^text\/|application\/(?:json|javascript|xml|xhtml\+xml|ecmascript)|application\/x-javascript|\+json)/i;

const session = new UpstreamSession('ingress-proxy');

function stripIngressPath(url, ingressPath) {
  if (ingressPath && url.startsWith(ingressPath)) {
    const rest = url.slice(ingressPath.length);
    return rest === '' ? '/' : (rest.startsWith('/') ? rest : '/' + rest);
  }
  return url;
}

function rewriteLocation(loc, ingressPath) {
  if (!loc || !ingressPath) return loc;
  if (loc.startsWith(BASE)) return ingressPath + loc.slice(BASE.length);
  if (loc.startsWith('/')) return ingressPath + loc;
  return loc;
}

// Forward cookies other than WG-Easy's session (which stays inside the proxy),
// with their Path moved under the ingress entry point.
function browserCookies(value, ingressPath) {
  const list = Array.isArray(value) ? value : [value];
  return list
    .filter((c) => !c.startsWith(`${SESSION_COOKIE}=`))
    .map((c) => (ingressPath ? c.replace(/;\s*Path=\/(?!api\/hassio_ingress)/i, `; Path=${ingressPath}/`) : c));
}

function upstreamHeaders(req, sessionPair) {
  const headers = { ...req.headers };
  delete headers['accept-encoding']; // keep bodies uncompressed so we can rewrite
  delete headers['authorization']; // the managed session is the only credential
  headers.host = `${UPSTREAM_HOST}:${UPSTREAM_PORT}`;
  if (sessionPair) headers.cookie = withSessionCookie(req.headers.cookie, sessionPair);
  return headers;
}

// True when WG-Easy answered "not logged in": a 401 from the API, or a redirect
// of a page to the login screen.
function needsLogin(pres) {
  if (pres.statusCode === 401) return true;
  const loc = pres.headers.location || '';
  return pres.statusCode >= 300 && pres.statusCode < 400 && /\/login(?:[?#]|$)/.test(loc);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

function upstreamRequest(options, body) {
  return new Promise((resolve, reject) => {
    const preq = http.request(options, resolve);
    preq.on('error', reject);
    preq.end(body);
  });
}

const STARTING_PAGE = `<!doctype html><html><head><meta charset="utf-8">
<meta http-equiv="refresh" content="3"><title>WG-Easy</title>
<style>body{font-family:system-ui,sans-serif;display:grid;place-items:center;height:90vh;margin:0;color:#444}
@media(prefers-color-scheme:dark){body{background:#111;color:#ccc}}</style></head>
<body><p>WG-Easy is starting&hellip; this page reloads by itself.</p></body></html>\n`;

function sendStarting(res, detail) {
  res.writeHead(503, { 'content-type': 'text/html; charset=utf-8', 'retry-after': '3', 'cache-control': 'no-store' });
  res.end(STARTING_PAGE);
  if (detail) log('ingress-proxy', 'upstream not ready:', detail);
}

async function handle(req, res) {
  const ingressPath = req.headers['x-ingress-path'] || '';
  // Refuse anything that did not come from the Supervisor (see ALLOWED_SOURCES)
  // or that lacks the Ingress header, so the web UI is never usable as a plain
  // LAN or VPN port.
  if (!sourceAllowed(req.socket) || !ingressPath) {
    res.writeHead(403, { 'content-type': 'text/plain' });
    res.end('This add-on web UI is only reachable through Home Assistant Ingress.\n');
    return;
  }
  const clean = stripIngressPath(req.url || '/', ingressPath);
  const upPath = BASE + (clean === '/' ? '/' : clean);
  const body = await readBody(req);

  let pres;
  for (let attempt = 0; attempt < 2; attempt++) {
    let sessionPair;
    try {
      sessionPair = await session.get();
    } catch (err) {
      sendStarting(res, err.message);
      return;
    }
    try {
      pres = await upstreamRequest(
        { host: UPSTREAM_HOST, port: UPSTREAM_PORT, method: req.method, path: upPath, headers: upstreamHeaders(req, sessionPair) },
        body,
      );
    } catch (err) {
      sendStarting(res, err.message);
      return;
    }
    if (attempt === 0 && needsLogin(pres)) {
      pres.resume(); // discard, log in again, retry once
      session.invalidate();
      continue;
    }
    break;
  }

  session.observe(pres.headers['set-cookie']);
  const out = { ...pres.headers };
  if (out.location) out.location = rewriteLocation(out.location, ingressPath);
  if (out['set-cookie']) {
    const kept = browserCookies(out['set-cookie'], ingressPath);
    if (kept.length) out['set-cookie'] = kept;
    else delete out['set-cookie'];
  }

  const ct = pres.headers['content-type'] || '';
  if (TEXT_TYPE.test(ct) || ct === '') {
    const chunks = [];
    pres.on('data', (c) => chunks.push(c));
    pres.on('end', () => {
      const buf = Buffer.from(Buffer.concat(chunks).toString('utf8').split(BASE).join(ingressPath), 'utf8');
      out['content-length'] = String(buf.length);
      delete out['transfer-encoding'];
      res.writeHead(pres.statusCode || 502, out);
      res.end(buf);
    });
  } else {
    res.writeHead(pres.statusCode || 502, out);
    pres.pipe(res);
  }
}

// Health endpoint for the Dockerfile HEALTHCHECK (loopback only): healthy
// when WG-Easy answers and the WireGuard interface exists.
async function health(res) {
  let ok = false;
  try {
    const r = await fetch(`http://${UPSTREAM_HOST}:${UPSTREAM_PORT}${BASE}/`, {
      redirect: 'manual',
      signal: AbortSignal.timeout(5000),
    });
    ok = r.status < 500 && existsSync('/sys/class/net/wg0');
  } catch {
    ok = false;
  }
  res.writeHead(ok ? 200 : 503, { 'content-type': 'text/plain' });
  res.end(ok ? 'ok\n' : 'unhealthy\n');
}

const server = http.createServer((req, res) => {
  if (req.url === '/_addon/health' && ['127.0.0.1', '::1'].includes(normaliseAddress(req.socket.remoteAddress))) {
    health(res);
    return;
  }
  handle(req, res).catch((err) => {
    log('ingress-proxy', 'ERROR:', err && err.message ? err.message : err);
    if (!res.headersSent) res.writeHead(502, { 'content-type': 'text/plain' });
    res.end('ingress proxy error\n');
  });
});

// WebSocket / HTTP upgrade passthrough (wg-easy live updates).
server.on('upgrade', async (req, socket, head) => {
  const ingressPath = req.headers['x-ingress-path'] || '';
  if (!sourceAllowed(socket) || !ingressPath) {
    socket.destroy();
    return;
  }
  let sessionPair;
  try {
    sessionPair = await session.get();
  } catch {
    socket.destroy();
    return;
  }
  const clean = stripIngressPath(req.url || '/', ingressPath);
  const preq = http.request({
    host: UPSTREAM_HOST,
    port: UPSTREAM_PORT,
    method: req.method,
    path: BASE + clean,
    headers: upstreamHeaders(req, sessionPair),
  });
  preq.on('upgrade', (pres, psocket, phead) => {
    let resp = `HTTP/1.1 101 Switching Protocols\r\n`;
    for (const [k, v] of Object.entries(pres.headers)) resp += `${k}: ${v}\r\n`;
    resp += '\r\n';
    socket.write(resp);
    if (phead && phead.length) psocket.unshift(phead);
    psocket.pipe(socket);
    socket.pipe(psocket);
  });
  preq.on('error', () => socket.destroy());
  if (head && head.length) preq.write(head);
  preq.end();
});

server.listen(LISTEN_PORT, '0.0.0.0', () => {
  log('ingress-proxy', `listening on 0.0.0.0:${LISTEN_PORT} -> ${UPSTREAM_HOST}:${UPSTREAM_PORT}${BASE}`);
  log('ingress-proxy', `accepting connections only from: ${[...ALLOWED_SOURCES].join(', ')}`);
  log('ingress-proxy', 'automatic login: enabled (Home Assistant authenticates the user)');
});

// ---- optional metrics listener ---------------------------------------------
// No session is injected here: WG-Easy itself protects these routes with the
// bearer token configured in its UI (Admin > Metrics).
if (METRICS_PORT > 0) {
  const METRICS_PATHS = new Set(['/metrics/prometheus', '/metrics/json']);
  http
    .createServer((req, res) => {
      const path = (req.url || '/').split('?')[0];
      if (req.method !== 'GET' || !METRICS_PATHS.has(path)) {
        res.writeHead(404, { 'content-type': 'text/plain' });
        res.end('Only /metrics/prometheus and /metrics/json are served on this port.\n');
        return;
      }
      const headers = { host: `${UPSTREAM_HOST}:${UPSTREAM_PORT}` };
      if (req.headers.authorization) headers.authorization = req.headers.authorization;
      const preq = http.request(
        { host: UPSTREAM_HOST, port: UPSTREAM_PORT, method: 'GET', path: BASE + path, headers },
        (pres) => {
          res.writeHead(pres.statusCode || 502, { 'content-type': pres.headers['content-type'] || 'text/plain' });
          pres.pipe(res);
        },
      );
      preq.on('error', (err) => {
        res.writeHead(502, { 'content-type': 'text/plain' });
        res.end('metrics: upstream error: ' + err.message + '\n');
      });
      preq.end();
    })
    .listen(METRICS_PORT, '0.0.0.0', () => {
      log('ingress-proxy', `metrics listener on 0.0.0.0:${METRICS_PORT} (/metrics/prometheus, /metrics/json)`);
    });
}
