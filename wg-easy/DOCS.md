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
- The add-on runs `iptables`/`ip6tables` on the **nftables** backend
  (`xtables-nft-multi`). Home Assistant OS's kernel does not expose the *legacy*
  netfilter `nat` table to add-ons, which made the NAT rules that `wg-quick`
  installs fail (`can't initialize iptables table 'nat'` / `modprobe: FATAL:
  Module ip_tables not found`). The nftables backend is the one HAOS provides.
  This mirrors the official HAOS WireGuard add-on
  ([`hassio-addons/addon-wireguard`](https://github.com/hassio-addons/addon-wireguard)).
- Only `NET_ADMIN` is requested. `SYS_MODULE` is not: HAOS ships no loadable
  netfilter modules, so loading a module is impossible and unnecessary.

### Reaching the rest of the LAN (IPv4 forwarding)

A VPN client reaching the **Home Assistant host's own LAN address** needs no
routing: the packet is delivered locally. Reaching **any other machine** on the
home LAN requires the kernel to **forward** the packet from the tunnel interface
(`wg0`) to the LAN interface, which only happens when `net.ipv4.ip_forward=1`.

`net.ipv4.ip_forward` is a per-network-namespace sysctl. The add-on runs with
`host_network: true`, so it shares the host's network namespace and, at startup,
runs `sysctl -w net.ipv4.ip_forward=1` before WG-Easy starts. It is idempotent
and the effective value is logged.

Two things are worth knowing:

- **On Home Assistant OS the value is normally already `1`.** HAOS relies on the
  Docker daemon to enable IPv4 forwarding at boot, so the add-on's write is
  usually a no-op. If forwarding really is the problem, the log line
  `[add-on] IPv4 forwarding: net.ipv4.ip_forward=0 (effective)` will show it.
- **The Supervisor mounts `/proc/sys` read-only inside add-on containers.** If
  the value were `0`, the add-on could not change it (the write fails with
  `Read-only file system`) and the log says so. In that case the value must be
  set on the host; this is the situation the official community WireGuard
  add-on documents under *"IP forwarding is disabled on the host system!"*.

### What the startup log tells you

The launcher logs a `---- network state ----` block a few seconds after start.
It contains everything needed to diagnose "the HA host is reachable but other
LAN machines are not":

```
[add-on] ---- network state ----
[add-on]   net.ipv4.ip_forward = 1
[add-on]   wg0 = 10.8.0.1/24
[add-on]   LAN device (default route) = end0
[add-on]   NAT MASQUERADE: -A POSTROUTING -s 10.8.0.0/24 -o end0 -j MASQUERADE
[add-on]   FORWARD policy = DROP
[add-on]   FORWARD rules:
[add-on]     -P FORWARD DROP
[add-on]     -A FORWARD -j DOCKER-USER
[add-on]     -A FORWARD -j DOCKER-FORWARD
[add-on]     -A FORWARD -i wg0 -j ACCEPT
[add-on]     -A FORWARD -o wg0 -j ACCEPT
[add-on] ---- end network state ----
```

Interpretation:

- `net.ipv4.ip_forward` must be `1`.
- The `NAT MASQUERADE` rule's `-o <device>` must be the **same** device as the
  `LAN device (default route)`. If they differ, the log prints a `NOTE`.
  WG-Easy stores this device in its database and defaults it to `eth0`; on a host
  whose LAN interface is named differently (for example `end0` on a Raspberry
  Pi), **change it in the WG-Easy web UI** under the interface settings. Without
  a matching MASQUERADE rule, replies from other LAN hosts are not routed back
  through the tunnel, which produces exactly the "HA host works, other hosts
  don't" symptom.
- The `FORWARD` chain has `-i wg0 -j ACCEPT` and `-o wg0 -j ACCEPT` rules (Docker
  sets the policy to `DROP`), so forwarded tunnel traffic is allowed.

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
  default because IPv4 is enough to reach a home LAN and it keeps the first-run
  config minimal. The add-on runs iptables on the nftables backend, which HAOS
  supports, so setting `disable_ipv6: false` is possible too.
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

The container image was built and run on an x86_64 host: `iptables`/`ip6tables`
report the `nf_tables` backend, the WireGuard interface came up
(`wg-quick up wg0` → *"Wireguard Interface wg0 started successfully"*) with the
`POSTROUTING ... MASQUERADE` rule installed, the web UI answered through an
Ingress-style prefixed proxy (and refused requests without the Ingress header), a
client was created, and a real WireGuard handshake with a second container was
observed, with the client able to reach a host on the LAN behind the server. See
the repository README for the raw evidence.

For `15.4.2` the launcher was additionally built and run on x86_64 Docker: the
forwarding call runs before WG-Easy and is idempotent, the `---- network state
----` block is emitted with the effective `net.ipv4.ip_forward`, the `wg0`
address, the LAN device, the `nat POSTROUTING` MASQUERADE rule and the `FORWARD`
rules, and `wg0` comes up with the MASQUERADE/FORWARD rules installed. On the
test host the LAN device (`ens18`) differs from the device WG-Easy stored
(`eth0`), and the log correctly flagged it.

> **The Home Assistant OS proof is the owner's device.** The local host kernel
> exposes both netfilter backends and its `/proc/sys` is writable on the host, so
> it cannot reproduce the HAOS-only behaviour (read-only `/proc/sys`, forwarding
> already enabled by Docker). After updating, the add-on log on HAOS must show:
>
> - no `Module ip_tables not found` / `can't initialize iptables table 'nat'`;
> - a successful `wg-quick up wg0`;
> - `[add-on] IPv4 forwarding: net.ipv4.ip_forward=1 (effective)`;
> - a `---- network state ----` block whose MASQUERADE `-o` device matches the
>   `LAN device (default route)` (no `NOTE` line).
