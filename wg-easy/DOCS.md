# WG-Easy VPN add-on — documentation

This add-on runs [WG-Easy](https://github.com/wg-easy/wg-easy) — WireGuard plus
a web management UI — inside Home Assistant OS.

## How it works

Home Assistant OS cannot run arbitrary containers, only add-ons managed by the
Supervisor. This add-on embeds WG-Easy and adds two things on top of the
upstream image:

1. **A launcher** (`run.sh`) that translates add-on options into WG-Easy's
   environment variables and starts it.
2. **A small reverse proxy** (`ingress-proxy.mjs`) that makes the WG-Easy web UI
   work behind Home Assistant **Ingress**.

### Why a reverse proxy for Ingress (the path-prefix problem)

Home Assistant Ingress serves an add-on's web UI under a *dynamic* path such as
`/api/hassio_ingress/<token>/`. It strips that prefix before forwarding the
request to the add-on and sets the header `X-Ingress-Path` to the prefix.

WG-Easy 15.x **cannot be served from a sub-path**: its web assets are referenced
with absolute paths (`/_nuxt/...`), its API client uses a base URL baked in at
start-up, and its middleware redirects are absolute (`/setup/1`). Upstream
maintainers confirmed this is not supported and not fixable with a plain proxy
([wg-easy#1802](https://github.com/wg-easy/wg-easy/issues/1802)).

The add-on therefore does **not** fall back to publishing a LAN port. Instead:

- WG-Easy is started with a **fixed** internal base path: `NUXT_APP_BASE_URL=/_haingress`.
- The reverse proxy, which is the only thing listening on the Ingress port,
  rewrites every request/response between that fixed base and the dynamic
  Ingress path:
  - requests: `X-Ingress-Path` + stripped path → `/_haingress` + path;
  - responses: `/_haingress` → `X-Ingress-Path`, including HTML/JS/CSS/JSON
    bodies, `Location` redirect headers and `Set-Cookie` paths.

This keeps absolute asset URLs, the SPA's runtime API calls, redirects and
cookies all pointing back at the Ingress entry point. The web UI is never
exposed on a host port.

### Networking

- `host_network: true` — the WireGuard interface (`wg0`) is created directly on
  the Home Assistant host, so VPN clients are routed into your real LAN exactly
  as with the official WireGuard add-on.
- The WireGuard UDP port (`port` option, default `51820`) is opened on the host.
  This is the port you forward on your router.

## Options and the "first run only" caveat

WG-Easy 15.x stores its configuration (host, port, DNS, allowed IPs, clients,
users) in a SQLite database at `/etc/wireguard/wg-easy.db`, on a persistent
volume. It reads the `INIT_*` environment variables **only when the database
does not yet exist** (the very first start).

Consequently:

- On the **first start**, all options are applied: `host`, `port`, `username`,
  `password`, `dns`, `allowed_ips`, `ipv4_cidr`, `ipv6_cidr`.
- `disable_ipv6` (default `true`) is read on **every** start and simply enables
  or disables IPv6 in the generated WireGuard config. It is left `true` by
  default because some kernels (including the verification host) lack the
  `ip6_tables` NAT table, which makes `wg-quick up` fail otherwise. IPv4 is
  enough to reach a home LAN.
- On **later starts**, the stored configuration is kept. To change `host`,
  `port`, `dns` or `allowed_ips` afterwards, edit them in the WG-Easy web UI
  (Settings). Changing the add-on options for these fields will have no effect.
- The admin **password** can be re-applied from the option by setting
  `reset_admin_password: true` once (it is reset on the next start, then set it
  back to `false`). This also clears 2FA.

> The password must be **at least 12 characters**, otherwise WG-Easy rejects it.

## Installing

1. In Home Assistant go to **Settings → Add-ons → Add-on Store**.
2. Top-right menu → **Repositories**, add
   `https://github.com/felixilgatto/ha-wg-easy`, and close.
3. The **WG-Easy VPN** add-on appears at the bottom of the store. Open it and
   click **Install** (this builds the image on your device — it takes a few
   minutes).
4. Open the **Configuration** tab and set at least `host` (your public IP or
   DDNS name) and `password`.
5. Start the add-on, then open the **WG-Easy** panel in the sidebar.

## Router

You must forward the WireGuard **UDP** port (`port`, default `51820`) on your
router to the IP of your Home Assistant host. Nothing else needs forwarding —
the web UI is reached only through Home Assistant. If your public IP is dynamic,
use a dynamic-DNS hostname and put it in the `host` option.

## Where data lives

- `/etc/wireguard` (persistent add-on volume): server keys, `wg0.conf` and the
  WG-Easy database (`wg-easy.db`). This survives Home Assistant OS updates.
- `/data/options.json`: your add-on options (managed by Home Assistant).

## Verified

The container image was built and run on an x86_64 host: the WireGuard
interface came up, the web UI answered through an Ingress-style prefixed proxy
(and refused requests without the Ingress header), a client was created, and a
real WireGuard handshake with a second container was observed, with the client
able to reach a host on the LAN behind the server. See the repository README for
the raw evidence.
