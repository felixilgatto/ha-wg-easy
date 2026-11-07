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
cookies all pointing back at the Ingress entry point.

### Who can reach the Ingress port

Because the add-on uses `host_network: true`, the proxy's port (`8099`) listens
on every host interface — the LAN, `wg0`, the Supervisor network. The
`X-Ingress-Path` header is not a barrier on its own: any client can send it.
The proxy therefore also checks the **source address** of every connection and
accepts only the Supervisor (`172.30.32.2`, the fixed address Home Assistant
Ingress connects from) and the container's own loopback. Anything else gets a
`403` (or, for a WebSocket upgrade, a closed connection). The startup log shows
the accepted sources:

```
[ingress-proxy] accepting connections only from: 172.30.32.2, 127.0.0.1, ::1
```

If your Supervisor network is not the default one, set
`INGRESS_ALLOWED_SOURCES` (comma-separated) in the container environment.

WG-Easy itself runs with `INSECURE=true` (no TLS of its own) and listens only on
`127.0.0.1`; Home Assistant terminates TLS and has already authenticated the
user.

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
[add-on]   OK: MASQUERADE '-o end0' matches the LAN device,
[add-on]   so VPN clients can reach other machines on the home LAN.
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
  `LAN device (default route)`. The add-on now **sets this automatically** (see
  *The masquerade device* below), so the log should print an `OK` line. If it
  prints a `NOTE` instead, the two devices differ and the add-on could not fix
  it — without a matching MASQUERADE rule, replies from other LAN hosts are not
  routed back through the tunnel, which produces exactly the "HA host works,
  other hosts don't" symptom.
- The `FORWARD` chain starts with `-i wg0 -j HA_WGEASY_CLIENTS` (the
  `allowed_ips` filter, see *LAN access* below), followed by WG-Easy's
  `-i wg0 -j ACCEPT` and `-o wg0 -j ACCEPT` rules (Docker sets the policy to
  `DROP`). Traffic to a destination in `allowed_ips` passes; anything else from
  a client is dropped.
- The log line `Forwarding filter: VPN clients may be forwarded only to: ...`
  lists the ranges the filter allows. If it printed `WARNING: could not install
  the IPv4 forwarding filter` instead, `allowed_ips` is **not** enforced on the
  server.

### The masquerade device

WG-Easy installs this rule to let VPN clients reach the rest of the home LAN:

```
iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o <device> -j MASQUERADE
```

It stores `<device>` in its database and **seeds it as `eth0`** in its first
migration. On any host whose LAN interface has a different name — `end0` on a
Raspberry Pi, `ens18` on many VMs — the rule never matches, replies from other
LAN machines are dropped, and only the Home Assistant host itself is reachable
over the VPN (it needs no masquerading). Correcting the field once in the web UI
is not enough: **a reinstall re-seeds the database with `eth0`**.

The add-on therefore detects the LAN device itself and writes it into the
WG-Easy database **before WG-Easy starts**, every start:

- The device of the **default route** is the right notion of "the LAN
  interface": it is where traffic to the internet and the rest of the LAN
  leaves. It is read with `ip -o route show default`.
- The launcher runs `fix-lan-device.mjs`, which runs WG-Easy's own database
  migrations and then sets `interfaces_table.device` for `wg0` to that device.
  Because this happens before `node server/index.mjs`, the `wg0.conf` and the
  `wg-quick up` PostUp hook that WG-Easy generates carry the real device on the
  very first run — no restart and no manual step are needed.
- The step is idempotent: migrations are recorded (re-running is a no-op) and
  the `UPDATE` writes the same value on every later start. A fresh install and
  an existing database both end up correct.
- If the device cannot be determined (no default route yet), the add-on logs a
  `WARNING` and keeps WG-Easy's stored value — current behaviour, no crash.

Nothing in the web UI needs changing, and a reinstall cannot reintroduce the
defect.

## LAN access: what clients may reach (`allowed_ips`)

`allowed_ips` decides which destinations a VPN client can reach. It does two
things:

1. **It is enforced on the server.** At every start the launcher fills a
   dedicated netfilter chain, `HA_WGEASY_CLIENTS`, and jumps to it first from
   `FORWARD` for traffic arriving on `wg0`:

   ```
   -A FORWARD -i wg0 -j HA_WGEASY_CLIENTS
   -A HA_WGEASY_CLIENTS -d 10.8.0.0/24 -j RETURN
   -A HA_WGEASY_CLIENTS -d 192.168.0.15/32 -j RETURN
   -A HA_WGEASY_CLIENTS -j DROP
   ```

   Traffic to an allowed range returns to `FORWARD` and continues through the
   rules that were already there (Docker's chains, WG-Easy's own accepts).
   Everything else from a client is dropped. This applies to **every** client,
   whatever its own config says: a client's AllowedIPs only decide what the
   client routes into the tunnel, and the client controls that file, so they are
   not a security boundary. The chain is flushed and refilled on every start, so
   a change to `allowed_ips` takes effect at the next restart. Packets addressed
   to this Home Assistant host itself are not forwarded (they go through
   `INPUT`), so Home Assistant is always reachable from the tunnel.
2. **It is the default AllowedIPs for new clients.** The launcher writes it to
   WG-Easy's `user_configs_table.default_allowed_ips`, which WG-Easy copies into
   a client's config when the client is created. Clients that already exist keep
   their own stored AllowedIPs: after widening `allowed_ips`, edit an existing
   client in the web UI (or recreate it) so it routes the new range.

The effective value is always:

- the **tunnel subnet** (`ipv4_cidr`), so clients can reach each other and the
  server's tunnel address;
- this host's own LAN address (`<host-ip>/32`), derived from the detected LAN
  device, so Home Assistant is reachable without you typing its address;
- every other entry of the `allowed_ips` option.

If you changed `ipv4_cidr` but left `allowed_ips` at its shipped default
(`10.8.0.0/24`), the old default is replaced by the real tunnel subnet and the
log says so. No warning fires, and clients are not given a stale range.

The host address needs a default route and an IPv4 address on that device. The
launcher waits up to 30 seconds for both at startup. If they never appear it
logs `WARNING: could not determine ...` and leaves the host address out: new
clients then cannot reach Home Assistant until you restart the add-on with the
network up.

- **Default (`allowed_ips: "10.8.0.0/24"`):** clients reach **this Home
  Assistant host and the tunnel, nothing else**. The log prints
  `allowed_ips is restricted: ...`.
- **Open the LAN (`allowed_ips: "10.8.0.0/24, 192.168.0.0/24"`):** clients may
  reach every machine on that subnet (cameras, NAS, the Proxmox web UI, ...).
  The add-on logs a **startup WARNING** naming the extra ranges, so opening the
  LAN is never silent.

The MASQUERADE rule and IPv4 forwarding are always installed on the real
interface (see above), whatever `allowed_ips` is. They make LAN routing
*possible*; the `HA_WGEASY_CLIENTS` filter decides what is *allowed*.

## Options and the "first run only" caveat

WG-Easy 15.x stores its configuration (host, port, DNS, allowed IPs, clients,
users) in a SQLite database at `/etc/wireguard/wg-easy.db`, on a persistent
volume. It reads the `INIT_*` environment variables **only when the database
does not yet exist** (the very first start).

Consequently:

- On the **first start**, all options are applied: `host`, `port`, `username`,
  `password`, `dns`, `ipv4_cidr`, `ipv6_cidr`.
- `allowed_ips` is applied on **every** start: the server-side filter is
  refilled for all clients, and the default for new clients is rewritten in
  WG-Easy's database (see *LAN access* above). Existing clients' own configs
  are not changed.
- `disable_ipv6` (default `true`) is read on **every** start and simply enables
  or disables IPv6 in the generated WireGuard config. It is left `true` by
  default because IPv4 is enough to reach a home LAN and it keeps the first-run
  config minimal. The add-on runs iptables on the nftables backend, which HAOS
  supports, so setting `disable_ipv6: false` is possible too.
- On **later starts**, the stored `host`, `port`, `dns` and CIDRs are kept. To
  change them afterwards, edit them in the WG-Easy web UI (Settings). Changing
  the add-on options for these fields will have no effect.
- The admin **password** can be re-applied from the option with
  `reset_admin_password: true`. While the option is `true`, the password is
  reset and 2FA is cleared on **every** start, so set it back to `false` after
  one restart.

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
observed, with the client able to reach a host on the LAN behind the server.
For `15.4.1` the `iptables`/`ip6tables` backend switch was checked in the
built image, and the read-only-`/proc/sys` failure path of the forwarding call
was reproduced directly (a container write returns `Read-only file system`,
exit 1, and the effective value is unchanged).

For `15.4.2` the launcher was additionally built and run on x86_64 Docker: the
forwarding call runs before WG-Easy and is idempotent, the `---- network state
----` block is emitted with the effective `net.ipv4.ip_forward`, the `wg0`
address, the LAN device, the `nat POSTROUTING` MASQUERADE rule and the `FORWARD`
rules, and `wg0` comes up with the MASQUERADE/FORWARD rules installed. On the
test host the LAN device (`ens18`) differs from the device WG-Easy stored
(`eth0`), and the log correctly flagged it.

For `15.4.3` the built image was run on x86_64 Docker (with `--network host`, so
the container sees the host's default-route device, as `host_network: true`
does on HAOS) against both an empty `/etc/wireguard` and an existing database:

- the launcher logged `LAN device (default route) = ens18` and
  `WG-Easy masquerade device set to 'ens18' before startup`;
- `fix-lan-device.mjs` created and migrated a fresh database and set
  `interfaces_table.device` to `ens18` (one row updated);
- the generated `/etc/wireguard/wg0.conf` carried
  `PostUp = iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o ens18 -j MASQUERADE`
  (and the matching `PostDown`), i.e. the real device, not `eth0`;
- `wg-quick up wg0` installed `-A POSTROUTING -s 10.8.0.0/24 -o ens18 -j
  MASQUERADE` and the log printed the `OK:` line;
- on the **fresh** database the first-run setup still ran
  (`Creating initial user`, `Setting initial host and port`), so the
  "first run only" semantics are intact;
- a **restart** with the existing database logged
  `Existing database found: keeping stored WG-Easy configuration`, kept
  `device = ens18` and printed `OK:` again — idempotent, no restart loop;
- with `--network none` (no default route) the launcher logged the `WARNING:
  could not determine the LAN device` message and continued, leaving WG-Easy's
  stored device (`eth0`) in place.

For `15.4.4` the same built image was run on x86_64 Docker (`--network host`)
and driven through the WG-Easy HTTP API (`POST /api/auth/password` then
`POST /api/client`) to create a real client, for the default `allowed_ips` and
for an opened LAN:

- with the default `allowed_ips: "10.8.0.0/24"` the launcher derived this host's
  address from the LAN device (`ens18` → `192.168.0.36`) and set
  `user_configs_table.default_allowed_ips = ["10.8.0.0/24","192.168.0.36/32"]`;
  the client then generated `AllowedIPs = 10.8.0.0/24, 192.168.0.36/32`, and the
  log printed `allowed_ips is restricted: new VPN clients reach this Home
  Assistant host ... only` — no warning;
- with `allowed_ips: "10.8.0.0/24, 192.168.0.0/24"` the default became
  `["10.8.0.0/24","192.168.0.0/24","192.168.0.36/32"]`, the client generated
  `AllowedIPs = 10.8.0.0/24, 192.168.0.0/24, 192.168.0.36/32`, and the launcher
  printed the `WARNING: VPN clients can reach MORE than this Home Assistant host`
  block naming the extra range `192.168.0.0/24`;
- on a **restart** with the existing database the launcher logged
  `Existing database found: keeping stored WG-Easy configuration`, rewrote the
  same default and did not re-run first-run setup — idempotent;
- in every case the generated `wg0.conf` kept
  `PostUp = iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o ens18 -j
  MASQUERADE`, i.e. the masquerade stays aligned with the real interface whatever
  `allowed_ips` is.

For `15.4.5` the built image was run on x86_64 Docker in an isolated container
network (`--cap-add NET_ADMIN`):

- with `allowed_ips: "10.8.0.0/24, <A>/32"` the launcher installed
  `-A FORWARD -i wg0 -j HA_WGEASY_CLIENTS` ahead of WG-Easy's own
  `-i wg0 -j ACCEPT`, with `RETURN` rules for `10.8.0.0/24`, `<A>/32` and the
  host's `/32`, then `DROP`;
- a real WireGuard peer whose own config routed both `<A>` and a second host
  `<B>` reached the server's tunnel address and `<A>`, while its traffic to
  `<B>` was dropped by the chain (packet counters confirmed it);
- a restart left exactly one jump rule and one copy of the chain (idempotent);
- a request to the proxy from outside the container, with a forged
  `X-Ingress-Path` header, got `403`, and a forged WebSocket upgrade was
  closed. The same request from the container's loopback was served;
- with `ipv4_cidr: "10.9.0.0/24"` and `allowed_ips` left at its default, the
  effective value became `10.9.0.0/24, <host>/32` and no LAN warning fired.

> **The Home Assistant OS proof is the owner's device.** The local host kernel
> exposes both netfilter backends, its `/proc/sys` is writable on the host, and
> its LAN device name (`ens18`) is not the Pi's (`end0`), so the local host
> cannot reproduce the HAOS-only behaviour (read-only `/proc/sys`, forwarding
> already enabled by Docker) nor the Pi's exact interface name. After updating,
> the add-on log on HAOS must show:
>
> - no `Module ip_tables not found` / `can't initialize iptables table 'nat'`;
> - a successful `wg-quick up wg0`;
> - `[add-on] IPv4 forwarding: net.ipv4.ip_forward=1 (effective)`;
> - `[add-on] LAN device (default route) = end0` and
>   `WG-Easy masquerade device set to 'end0' before startup`;
> - a `---- network state ----` block whose MASQUERADE `-o` device matches the
>   `LAN device (default route)`, with the `OK:` line (no `NOTE` line);
> - `[add-on] Default AllowedIPs for new clients set to: 10.8.0.0/24, <host-ip>/32`
>   followed by the `allowed_ips is restricted:` line — or the LAN `WARNING:`
>   block if you added your subnet to `allowed_ips`;
> - `[add-on] Forwarding filter: VPN clients may be forwarded only to: ...`
>   (and no `could not install the IPv4 forwarding filter` warning);
> - `[ingress-proxy] accepting connections only from: 172.30.32.2, ...`, with
>   the WG-Easy panel still opening from the Home Assistant sidebar.
