// Ingress reverse proxy for the WG-Easy add-on.
//
// Home Assistant Ingress forwards requests to this port *after* stripping the
// `/api/hassio_ingress/<token>/` prefix, and sets the header
// `X-Ingress-Path: /api/hassio_ingress/<token>`.
//
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

import http from 'node:http';

const LISTEN_PORT = parseInt(process.env.INGRESS_PORT || '8099', 10);
const UPSTREAM_HOST = process.env.WEB_HOST || '127.0.0.1';
const UPSTREAM_PORT = parseInt(process.env.WEB_PORT || '51821', 10);
const BASE = process.env.APP_BASE || '/_haingress';

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

function rewriteCookies(value, ingressPath) {
  if (!ingressPath) return value;
  const list = Array.isArray(value) ? value : [value];
  return list.map((c) =>
    // Path=/... -> Path=<ingressPath>/...  (idempotent: skip if already prefixed)
    c.replace(/;\s*Path=\/(?!api\/hassio_ingress)/i, `; Path=${ingressPath}/`)
  );
}

function upstreamHeaders(req) {
  const headers = { ...req.headers };
  delete headers['accept-encoding']; // keep bodies uncompressed so we can rewrite
  headers.host = `${UPSTREAM_HOST}:${UPSTREAM_PORT}`;
  return headers;
}

const server = http.createServer((req, res) => {
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

  const preq = http.request(
    { host: UPSTREAM_HOST, port: UPSTREAM_PORT, method: req.method, path: upPath, headers: upstreamHeaders(req) },
    (pres) => {
      const out = { ...pres.headers };
      if (out.location) out.location = rewriteLocation(out.location, ingressPath);
      if (out['set-cookie']) out['set-cookie'] = rewriteCookies(out['set-cookie'], ingressPath);

      const ct = pres.headers['content-type'] || '';
      const rewritable = ingressPath && (TEXT_TYPE.test(ct) || ct === '');

      if (rewritable) {
        const chunks = [];
        pres.on('data', (c) => chunks.push(c));
        pres.on('end', () => {
          let body = Buffer.concat(chunks).toString('utf8');
          body = body.split(BASE).join(ingressPath);
          const buf = Buffer.from(body, 'utf8');
          delete out['content-length'];
          out['content-length'] = String(Buffer.byteLength(buf));
          res.writeHead(pres.statusCode || 502, out);
          res.end(buf);
        });
      } else {
        res.writeHead(pres.statusCode || 502, out);
        pres.pipe(res);
      }
    }
  );

  preq.on('error', (err) => {
    res.writeHead(502, { 'content-type': 'text/plain' });
    res.end('ingress proxy: upstream error: ' + err.message);
  });
  req.pipe(preq);
});

// WebSocket / HTTP upgrade passthrough (wg-easy live updates).
server.on('upgrade', (req, socket, head) => {
  const ingressPath = req.headers['x-ingress-path'] || '';
  if (!sourceAllowed(socket) || !ingressPath) {
    socket.destroy();
    return;
  }
  const clean = stripIngressPath(req.url || '/', ingressPath);
  const preq = http.request({
    host: UPSTREAM_HOST,
    port: UPSTREAM_PORT,
    method: req.method,
    path: BASE + clean,
    headers: upstreamHeaders(req),
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
  console.log(`[ingress-proxy] listening on 0.0.0.0:${LISTEN_PORT} -> ${UPSTREAM_HOST}:${UPSTREAM_PORT}${BASE}`);
  console.log(`[ingress-proxy] accepting connections only from: ${[...ALLOWED_SOURCES].join(', ')}`);
});
