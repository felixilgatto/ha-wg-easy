# Changelog

The add-on uses its own [semantic version](https://semver.org) from 1.0.0 on. Each entry names the
WG-Easy version it bundles. Versions up to 15.5.0 followed WG-Easy's numbering.

## 1.0.1

Bundles **WG-Easy 15.5.0**.

- **No longer breaks another WireGuard server on the same host.** At start-up the add-on removed any
  existing `wg0` interface, assuming a previous run had left it behind. With `host_network`, that could
  be the WireGuard add-on's tunnel. Now it removes `wg0` only when it runs this add-on's own server
  key. Otherwise it refuses to start, says why in the log, and leaves the other VPN alone.
- Documentation: requirements (installation type, 64-bit, no other WireGuard server), re-importing
  client configs after changing `host` or `port`, how public-address detection works, entity IDs and
  an automation example, what uninstalling deletes, and moving to a new machine. The repository README
  now links to the add-on documentation instead of repeating it.

## 1.0.0

Bundles **WG-Easy 15.5.0**.

- **New versioning.** The add-on now has its own semantic version, independent of WG-Easy's, so a
  fix to the add-on no longer has to look like a WG-Easy release. The bundled WG-Easy version is
  in each changelog entry, in the start-up log, and in the software version of the *WG-Easy VPN*
  device in Home Assistant.
  > Home Assistant only notifies updates to a *higher* version, so 15.5.0 → 1.0.0 shows no update
  > notification. Open the add-on page and click **Update**. Data is kept as usual.
- **Security: `mqtt` 5.15.2 → 5.16.1**, the library behind the Home Assistant entities. 5.15.2 has
  six advisories (four high) through which a malicious or misbehaving broker can crash the client
  or corrupt its state. Exposure was limited: the add-on speaks MQTT 3.1.1, most advisories need
  MQTT 5, and the broker is normally the local Mosquitto add-on.

## 15.5.0

- **WG-Easy 15.5.0** (was 15.4.0). It includes Node.js security fixes, see the
  [WG-Easy release notes](https://github.com/wg-easy/wg-easy/releases/tag/v15.5.0). It also adds
  AmneziaWG 3.1 support (still opt-in upstream, not enabled by the add-on) and a configurable
  interface name (left at `wg0`).
- **No more "There is an update available!" banner** in the panel. It told you to update WG-Easy's
  container, which is not possible in an add-on: the WG-Easy version is pinned by the add-on and new
  versions arrive as add-on updates. The add-on now sets WG-Easy's `DISABLE_VERSION_CHECK`.
- Upgrading keeps everything. WG-Easy's two new database migrations (new columns, and hooks using
  `{{interface}}` instead of a hard-coded `wg0`) run after the usual pre-start snapshot.

> Verified in Docker: an add-on started with 15.4.6 and then updated to 15.5.0 on the same `/data`
> kept its clients and server key, applied the migrations, kept the masquerade on the real LAN
> device, and reported `updateAvailable: false`. `tests/smoke.sh` passes on the 15.5.0 image.

## 15.4.6

The add-on now works as installed, keeps its data, and integrates with Home Assistant.

### Data safety (fixes data loss on updates and restarts)

- **Data is now persistent.** WG-Easy keeps everything (server keys, clients, users, settings) in
  `/etc/wireguard`. That folder lived inside the container, which the Supervisor recreates on every
  start, restart and update, so the add-on silently started again from an empty database with new
  server keys, and every existing client broke. It now lives in `/data/wireguard`.
  > Data stored by earlier versions was inside the old container and cannot be recovered by this
  > update. Recreate your clients once after updating.
- **Verified database snapshot before every start**, so before any WG-Easy migration, in
  `/data/backups` (the 10 newest are kept).
- **Automatic recovery.** A database that fails SQLite's integrity check is moved to
  `/data/backups/corrupt-<date>/` and the newest valid snapshot is restored. With none, the add-on
  refuses to start instead of creating an empty database.
- **Included in Home Assistant backups**, without stopping the VPN. A `backup_pre` hook first writes a
  consistent copy of the database.
- **Clean shutdown.** `SIGTERM` is forwarded to WG-Easy, which closes the database and takes `wg0`
  down, instead of being killed after the stop timeout. A `wg0` left over by a killed run is removed
  at start.

### Works as installed

- **No option is required.** On the first start the public address is detected, and WG-Easy is
  configured with its admin account, host and port: no setup wizard.
- **No second login.** The ingress proxy logs the panel in with an add-on-managed admin account
  (random password in `/data`). It logs in again by itself after a logout, an expired session, or a
  password or 2FA change made in the panel.
- **The panel is restricted to Home Assistant administrators** (`panel_admin`), since it controls
  access to the network.
- A "starting…" page that reloads by itself is shown while WG-Easy boots.

### Options

- Removed `username`, `password` and `reset_admin_password` (the login is managed by the add-on).
- `host` is now optional (detected on the first start). When set, it is applied on every start.
- `port` is applied on every start. The public port follows it unless it was customised in the panel.
- `allowed_ips` now defaults to empty, which means "Home Assistant only". The tunnel range is always
  included; the old default `10.8.0.0/24` keeps working.
- New optional overrides, applied on every start when filled in: `dns`, `mtu`,
  `persistent_keepalive`.
- `ipv4_cidr` / `ipv6_cidr` are optional and used on the first installation only, as before. A note is
  logged if they differ from the live tunnel.
- New `metrics_port`: serves only WG-Easy's `/metrics/prometheus` and `/metrics/json` on that port.
- New `home_assistant_entities` (default on).
- Option names and descriptions in English and French.

### Home Assistant entities (MQTT discovery)

- With the Mosquitto broker add-on installed, the add-on gets the broker from the Supervisor
  (`services: mqtt:want`) and publishes a **WG-Easy VPN** device (clients, connected clients,
  *Restart interface* button) and one **VPN <client>** device per client (*Enabled* switch,
  *Connected*, *Received*, *Sent*, *Last handshake*, *Endpoint*, *IPv4 address*, *Expires*). Clients
  added, renamed or deleted in the panel follow automatically. Without a broker the add-on runs as
  before and says how to get entities.

### Reliability and tooling

- Docker `HEALTHCHECK` (WG-Easy answering and `wg0` present); the Supervisor restarts an unhealthy
  add-on. The launcher exits with an error if WG-Easy or the proxy dies.
- Image labels and `ADDON_VERSION` now carry the real version (the build arguments were not
  re-declared after `FROM`).
- Node helpers moved to `addon/` and resolved against WG-Easy's own modules; `mqtt` pinned through
  `package-lock.json`. `fix-lan-device.mjs` is replaced by `addon/prepare-db.mjs`.
- `tests/smoke.sh`: end-to-end test in Docker. Official app devcontainer (`.devcontainer.json`,
  `.vscode/tasks.json`). CI: official app linter, ShellCheck, amd64 + aarch64 build, smoke test.
- `config.yaml` passes the official app linter (default values removed, `watchdog` replaced by the
  `HEALTHCHECK`).

> Verified in Docker (`tests/smoke.sh`, 36 checks) and in the official devcontainer with a real
> Supervisor and Home Assistant 2026.11: zero-config install, real Ingress panel opened logged in,
> Mosquitto picked up automatically, entities created in Home Assistant, switch and button
> round-trips, Home Assistant backup + restore, and a real add-on update (15.4.6 → 15.4.7) keeping
> clients and server key. **Not verified on a Raspberry Pi / Home Assistant OS device**, nor with a
> real VPN client connecting from outside.

## 15.4.5

- **Security: the web UI port now accepts connections only from the Home
  Assistant Supervisor.** With `host_network: true` the Ingress proxy listens on
  every host interface, and its only check was the `X-Ingress-Path` header,
  which any client can send. Any machine on the LAN, and any VPN client, could
  open the WG-Easy login on `http://<ha-ip>:8099/` and try passwords against it.
  The proxy now also checks the source address and accepts only `172.30.32.2`
  (the Supervisor, where Ingress connects from) and the container's loopback.
  Everything else gets `403`, and WebSocket upgrades are closed. Override with
  `INGRESS_ALLOWED_SOURCES` if your Supervisor network differs.
- **Security: `allowed_ips` is now enforced on the server.** Until now it only
  set the AllowedIPs written into *new* client configs, and the server forwarded
  and NATed anything a client sent. A client that added `192.168.0.0/24` to its
  own config (or a stolen device whose config was edited) reached the whole LAN,
  and no warning was logged. The launcher now installs a `HA_WGEASY_CLIENTS`
  chain, jumped to first from `FORWARD` for traffic from `wg0`, that lets
  through only destinations in the effective `allowed_ips` and drops the rest.
  It is refilled on every start and applies to **all** clients, existing ones
  included. Allowed traffic continues to WG-Easy's own rules unchanged.
  **Behaviour change:** an existing client whose own config routes more than
  `allowed_ips` (for example one created before `15.4.4` with
  `0.0.0.0/0, ::/0`) loses that extra reach. Add the ranges it needs to
  `allowed_ips`.
- The tunnel subnet (`ipv4_cidr`) is now always part of the effective
  `allowed_ips`. If `ipv4_cidr` was changed but `allowed_ips` left at its
  shipped default `10.8.0.0/24`, the stale default is replaced by the real
  tunnel subnet. Before, clients were handed the old range and the LAN warning
  fired wrongly.
- At startup the launcher now waits up to 30 seconds for a default route and an
  IPv4 address, so this host's address is not skipped when the add-on starts
  before the network is up.
- Docs: README, the add-on store page and DOCS.md now agree. They state which
  options apply on every start, that `reset_admin_password` must be set back to
  `false`, the licences, and where the verification evidence lives. The store
  page no longer suggests `0.0.0.0/0, ::/0`.
- Still embeds WG-Easy `15.4.0` (`ghcr.io/wg-easy/wg-easy:15.4.0`).

> Verified locally on x86_64 Docker (not Home Assistant OS): a real WireGuard
> peer that routed an extra host in its own config was blocked from it by the
> new chain while still reaching the allowed host; a forged-header request from
> outside the container got `403`. See DOCS.md (*Verified*).

## 15.4.4

- **LAN access is now opt-in: by default a VPN client reaches only this Home
  Assistant host, not the rest of the LAN.** Which machines a client can reach
  is decided by the client's own **AllowedIPs** (what it routes into the tunnel),
  and WG-Easy copies a *default* AllowedIPs into every client it creates. That
  default was `["0.0.0.0/0","::/0"]`, i.e. every client could reach the whole LAN
  (cameras, NAS, the Proxmox web UI, ...). The default of the existing
  `allowed_ips` option is now the tunnel subnet only:

  ```yaml
  allowed_ips: "10.8.0.0/24"   # was: "0.0.0.0/0, ::/0"
  ```

  No new option was added — `allowed_ips` is the single knob. Because the owner's
  own LAN address is not known when the add-on is written, the launcher **derives
  this Home Assistant host's LAN address** from the LAN device it already detects
  (the default-route device) and **always includes `<host-ip>/32`** in the
  effective default, so Home Assistant stays reachable out of the box without the
  user typing their own address. With the default option a new client's generated
  config is e.g. `AllowedIPs = 10.8.0.0/24, 192.168.0.15/32` — Home Assistant and
  nothing else on the LAN.

- **Opening the LAN uses the same option.** To let clients reach the whole LAN,
  add your subnet to `allowed_ips`, e.g.
  `allowed_ips: "10.8.0.0/24, 192.168.0.0/24"`. The launcher then includes that
  subnet in the effective default.

- **A visible startup `WARNING` fires whenever the LAN is reachable**, i.e.
  whenever the effective AllowedIPs contain anything beyond the tunnel subnet and
  this Home Assistant host. It names the extra ranges and states that clients can
  then reach every machine on the LAN. Nothing silent. When the default is in
  effect the log instead prints `allowed_ips is restricted: ...`.

- The effective default is written into WG-Easy's database
  (`user_configs_table.default_allowed_ips`) **before WG-Easy starts, on every
  start** — the same moment and mechanism the launcher already uses for the
  masquerade device (`fix-lan-device.mjs`). On a fresh install `INIT_ALLOWED_IPS`
  is set to the same value so the first-run seed and the stored default cannot
  disagree.

- **Existing clients are unaffected.** The value is only the *default applied when
  a client is created*; clients that already exist keep their own stored
  AllowedIPs. To narrow or widen an existing client, edit it in the WG-Easy web UI
  or delete and recreate it (documented in DOCS.md). Note this also means the
  add-on owns the default: it is re-applied on every start, so change
  `allowed_ips`, not the web-UI default, to change it.

- **The server-side masquerade is unchanged and stays aligned to the real
  interface** (the `15.4.3` fix is untouched): forwarding and the MASQUERADE rule
  are always installed on the detected LAN device, whatever `allowed_ips` is — the
  barrier that decides which LAN machines a client can reach is the client's
  AllowedIPs, not the masquerade. Interface detection, the nftables backend switch
  (`15.4.1`) and the IPv4-forwarding handling (`15.4.2`) are unchanged, as are
  Ingress-only UI, no published LAN port, the configurable UDP port, the pinned
  image tag, `/etc/wireguard` persistence and first-run semantics. Still embeds
  WG-Easy `15.4.0` (`ghcr.io/wg-easy/wg-easy:15.4.0`).

> Verified locally on x86_64 Docker (not Home Assistant OS), with `--network
> host` so the container sees the host's default-route device as the add-on does
> on HAOS, driving the WG-Easy HTTP API to create a real client: with the default
> `allowed_ips` the launcher logged `Default AllowedIPs for new clients set to:
> 10.8.0.0/24, 192.168.0.36/32`, set
> `default_allowed_ips = ["10.8.0.0/24","192.168.0.36/32"]` and the created
> client generated `AllowedIPs = 10.8.0.0/24, 192.168.0.36/32` with no warning;
> with `allowed_ips: "10.8.0.0/24, 192.168.0.0/24"` the default gained
> `192.168.0.0/24`, the client generated it, and the launcher printed the LAN
> `WARNING:` block naming `192.168.0.0/24`; a restart with the existing database
> kept the same values and did not re-run first-run setup; and in every case the
> generated `wg0.conf` kept `-o ens18 -j MASQUERADE` (the real device). **The Home
> Assistant OS proof — and the Pi's real interface name (`end0`) — cannot be
> reproduced here**; see DOCS.md.

## 15.4.3

- **Fix: VPN clients can now reach other machines on the home LAN, not just the
  Home Assistant host — automatically, with no web-UI step and no way for a
  reinstall to reintroduce the problem.** WG-Easy installs
  `iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o <device> -j MASQUERADE` to
  NAT tunnel traffic onto the LAN, but it **hardcodes `<device>` as `eth0`** in
  its first database migration
  (`server/database/migrations/0001_classy_the_stranger.sql`). On any host whose
  LAN interface is named differently (`end0` on a Raspberry Pi, `ens18` on many
  VMs) the rule never matches, replies from other LAN hosts are dropped, and
  only the Home Assistant host itself (which needs no masquerading) is reachable
  over the VPN. Editing the device in the WG-Easy web UI fixes one install but a
  **reinstall re-seeds the database with `eth0`**.

  The launcher now detects the LAN device itself (the **default route** device —
  where traffic to the internet and the rest of the LAN leaves) and, **before
  WG-Easy starts**, runs WG-Easy's own database migrations and sets
  `interfaces_table.device` for `wg0` to that device (`fix-lan-device.mjs`).
  Because this happens before `node server/index.mjs`, the `wg0.conf` and the
  `wg-quick up` PostUp hook WG-Easy generates carry the **real** device on the
  very first run. The step is idempotent (migrations are recorded; the `UPDATE`
  writes the same value every start) and works on a fresh install (it creates
  and seeds the database) as well as on an existing one. If the device cannot be
  determined, the add-on logs a `WARNING` and keeps WG-Easy's stored value
  instead of crashing.

- The `---- network state ----` log block now also prints an `OK:` line when the
  installed MASQUERADE `-o` device matches the default-route (LAN) device, so a
  single log line confirms it worked. The `NOTE` line for a mismatch is kept.
- First-run semantics are preserved: the first-run check uses the database's
  state *before* the new step runs, so a fresh install still creates the initial
  admin user and host/port from the add-on options.
- Still embeds WG-Easy `15.4.0` (`ghcr.io/wg-easy/wg-easy:15.4.0`). Ingress-only
  UI, no published LAN port, configurable UDP port, pinned image tag,
  `/etc/wireguard` persistence and first-run semantics are unchanged. The
  nftables (`15.4.1`) and IPv4-forwarding (`15.4.2`) fixes are untouched.

> Verified locally on x86_64 Docker (not Home Assistant OS), with `--network
> host` so the container sees the host's default-route device as the add-on does
> on HAOS: on an empty `/etc/wireguard` the launcher logged
> `LAN device (default route) = ens18`, `fix-lan-device.mjs` created and
> migrated the database and set `device = ens18`, the generated `wg0.conf`
> carried `PostUp = ... -o ens18 -j MASQUERADE`, `wg-quick up wg0` installed the
> matching rule and the log printed the `OK:` line; the first-run admin user was
> still created; and a restart with the existing database kept `device = ens18`
> and printed `OK:` again (idempotent, no loop). With no default route the
> `WARNING` fallback fired and WG-Easy's stored `eth0` was left in place. **The
> Home Assistant OS proof — and the Pi's real interface name (`end0`) — cannot
> be reproduced here**; see DOCS.md (*Verified*).

## 15.4.2

- **Add-on now enables IPv4 forwarding itself, and logs the routing state at
  startup.** A packet addressed to the Home Assistant host itself is delivered
  locally and needs no routing, but a packet addressed to *another* host on the
  home LAN must be **forwarded** from the tunnel interface (`wg0`) to the LAN
  interface — the kernel only does that when `net.ipv4.ip_forward=1`. The
  launcher now runs `sysctl -w net.ipv4.ip_forward=1` **before** WG-Easy starts.
  Because the add-on runs with `host_network: true` it shares the host's network
  namespace, so this sets the value on the Home Assistant host; `NET_ADMIN`
  (already requested) is the capability that write needs. The write is
  idempotent: if the value is already `1` nothing is changed. The effective
  value is logged either way.

  > **Reality check (important):** on Home Assistant OS the value is normally
  > **already `1`**, because HAOS relies on the Docker daemon to enable IPv4
  > forwarding at boot. The Supervisor also mounts `/proc/sys` **read-only**
  > inside add-on containers, so if the value were `0` the add-on could not
  > change it — the log will say so explicitly. See DOCS.md.

- **Startup now dumps the exact state that decides whether LAN routing works**,
  so one look at the add-on log answers the question: the effective
  `net.ipv4.ip_forward`, the `wg0` address, the LAN (default-route) device, the
  `nat POSTROUTING MASQUERADE` rule WG-Easy installs, and the `FORWARD` policy
  and rules. If the MASQUERADE rule targets a different device than the
  default-route device, the log prints a `NOTE` — a mismatched device is a
  second, independent cause of "the Home Assistant host is reachable over the
  VPN but other LAN machines are not" (without NAT, replies from other LAN hosts
  are dropped).
- Still embeds WG-Easy `15.4.0` (`ghcr.io/wg-easy/wg-easy:15.4.0`). Ingress-only
  UI, configurable UDP port, pinned image tag, persistence and first-run
  semantics are unchanged.

> Verified locally on x86_64 Docker (not Home Assistant OS): the launcher is
> syntactically sound, the forwarding call is present and idempotent, the
> network-state block prints, and `wg0` comes up with the MASQUERADE/FORWARD
> rules installed. The local host kernel exposes both netfilter backends and its
> `/proc/sys` is writable, so it cannot reproduce the HAOS-only behaviour. **The
> Home Assistant OS proof is the owner's Raspberry Pi** — see DOCS.md (*Verified*).

## 15.4.1

- **Fix: VPN clients can now reach the home LAN on Home Assistant OS.** The NAT
  rules that `wg-quick` installs for LAN routing were failing on HAOS because the
  kernel does not expose the *legacy* netfilter `nat` table to add-ons:

  ```
  iptables v1.8.13 (legacy): can't initialize iptables table `nat':
  Table does not exist (do you need to insmod?)
  modprobe: FATAL: Module ip_tables not found in directory /lib/modules/6.18.39-haos-raspi
  ```

  which made `wg-quick up wg0` fail and roll the interface back
  (`Error: Command failed: wg-quick up wg0 (code 3)`). The image now points the
  generic `iptables`/`ip6tables` commands at the **nftables** backend
  (`xtables-nft-multi`), which HAOS's kernel *does* provide. This is the same
  technique the official HAOS WireGuard add-on
  ([`hassio-addons/addon-wireguard`](https://github.com/hassio-addons/addon-wireguard),
  `wireguard/Dockerfile`) uses.
- Removed `SYS_MODULE` from `privileged`. HAOS ships no loadable netfilter
  modules (see the `modprobe` error above), so the capability served no purpose.
  `NET_ADMIN` is unchanged.
- Still embeds WG-Easy `15.4.0` (`ghcr.io/wg-easy/wg-easy:15.4.0`).

> Verified locally on x86_64 Docker that `iptables`/`ip6tables` now report the
> `nf_tables` backend and that the full add-on starts, brings up `wg0` and
> installs the `MASQUERADE` rule. **The Home Assistant OS proof is the owner's
> Raspberry Pi** — the local host kernel exposes both netfilter backends, so it
> cannot reproduce the HAOS-only failure. See DOCS.md (*Verified*).

## 15.4.0
- Initial release. Embeds WG-Easy `15.4.0` (`ghcr.io/wg-easy/wg-easy:15.4.0`).
- Web UI exposed as a Home Assistant sidebar panel via Ingress, using an
  in-container reverse proxy that bridges the dynamic Ingress path prefix and
  WG-Easy's fixed internal base path.
- WireGuard UDP port configurable via add-on options.
- Persistent `/etc/wireguard` volume so keys, clients and the WG-Easy database
  survive Home Assistant OS updates.
