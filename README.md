# ha-wg-easy

A Home Assistant OS add-on repository that embeds
[WG-Easy](https://github.com/wg-easy/wg-easy) (WireGuard + web UI).

The add-on gives you:

- the **WG-Easy web interface as a sidebar panel inside Home Assistant**
  (Ingress — no extra LAN port);
- a **configurable WireGuard UDP port** (default `51820`);
- VPN clients routed into your **whole home LAN**.

## Add it to Home Assistant

**Settings → Add-ons → Add-on Store → ⋮ → Repositories** and add:

```
https://github.com/felixilgatto/ha-wg-easy
```

Then install **WG-Easy VPN** from the store. Full instructions, options and the
Ingress design notes are in [`wg-easy/DOCS.md`](wg-easy/DOCS.md).

## Add-ons

| Add-on | Version | Description |
| --- | --- | --- |
| [wg-easy](wg-easy) | 15.4.3 | WireGuard VPN + WG-Easy web UI as an Ingress panel |

## Design notes (short version)

Home Assistant Ingress serves add-on UIs under a dynamic path prefix
(`/api/hassio_ingress/<token>/`). WG-Easy 15.x cannot run from a sub-path
(absolute asset URLs, absolute middleware redirects —
[wg-easy#1802](https://github.com/wg-easy/wg-easy/issues/1802)). Instead of
exposing a LAN port, the add-on runs WG-Easy under a **fixed internal base**
(`/_haingress`) and ships a small **reverse proxy** that translates between that
fixed base and the dynamic Ingress prefix on every request and response. See
[`wg-easy/DOCS.md`](wg-easy/DOCS.md).

## LAN access on Home Assistant OS (the `15.4.3` fix)

`15.4.2` made the MASQUERADE-vs-LAN-device mismatch **visible** in the log. The
remaining defect was that WG-Easy's MASQUERADE rule targets a hardcoded `eth0`:

```
iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o eth0 -j MASQUERADE
```

`eth0` is seeded in WG-Easy's first database migration, so on any host whose LAN
interface is named otherwise (`end0` on a Raspberry Pi, `ens18` on a VM) the rule
never matches, replies from other LAN hosts are dropped, and **only the Home
Assistant host itself is reachable** over the VPN (it needs no masquerading).
That is exactly the reported symptom: `http://192.168.0.15:8123` (the HA host)
works while `http://192.168.0.200:8006` (another LAN machine) does not. Changing
the device once in the web UI is not durable — a reinstall re-seeds `eth0`.

`15.4.3` fixes this **in the add-on, every start, with no web-UI step**:

- The launcher detects the LAN device itself — the **default route** device
  (`ip -o route show default`), i.e. where traffic to the internet and the rest
  of the LAN leaves.
- **Before** WG-Easy starts, it runs WG-Easy's own database migrations and sets
  `interfaces_table.device` for `wg0` to that device (`fix-lan-device.mjs`).
  Because WG-Easy reads this row at startup to write `wg0.conf` and run
  `wg-quick up wg0`, the PostUp hook that ends up installed carries the **real**
  device on the first run — no restart, no manual step.
- It is idempotent and handles both cases: a fresh install (the script creates
  and seeds the database) and an existing one (migrations are recorded, the
  `UPDATE` rewrites the same value). A reinstall therefore cannot reintroduce
  the defect.
- If the device cannot be determined (no default route), the add-on logs a
  `WARNING` and keeps WG-Easy's stored value rather than crash.
- The `---- network state ----` block now prints an `OK:` line when the
  installed MASQUERADE `-o` device matches the default-route device, so one log
  line confirms success.

## LAN access on Home Assistant OS (the `15.4.2` fix)

`15.4.1` fixed the NAT rules failing to install (legacy vs. nft `nat` table).
`15.4.2` addresses the *next* thing that stops VPN clients reaching other LAN
machines: the packet has to be **forwarded** from the tunnel to the LAN, and the
return traffic has to be **NATed** on the right interface.

- The launcher now runs `sysctl -w net.ipv4.ip_forward=1` before WG-Easy starts.
  `net.ipv4.ip_forward` is per-network-namespace and the add-on uses
  `host_network: true`, so this sets the value on the Home Assistant host.
  It is idempotent and the effective value is logged.
- The launcher now logs a `---- network state ----` block: the effective
  `net.ipv4.ip_forward`, the `wg0` address, the LAN device, the
  `nat POSTROUTING MASQUERADE` rule and the `FORWARD` rules. If the MASQUERADE
  rule targets a different device than the default-route device it prints a
  `NOTE`.

Two findings from testing worth stating plainly:

- **On Home Assistant OS `net.ipv4.ip_forward` is normally already `1`** — HAOS
  relies on the Docker daemon to enable IPv4 forwarding at boot — and the
  Supervisor mounts `/proc/sys` **read-only** inside add-on containers, so the
  add-on *cannot* change the value if it is `0` (the write fails with
  `Read-only file system`). The new log line makes the true value visible.
- **WG-Easy defaults its MASQUERADE device to `eth0`.** On a host whose LAN
  interface is named otherwise (e.g. `end0` on a Raspberry Pi, `ens18` here) the
  MASQUERADE rule never matches and replies from other LAN hosts are dropped —
  the exact "HA host reachable, other hosts not" symptom. `15.4.2` only *logged*
  this; `15.4.3` (above) fixes it automatically.

## LAN access on Home Assistant OS (the `15.4.1` fix)

Home Assistant OS's kernel does **not** expose the *legacy* netfilter `nat`
table to add-ons, so `wg-quick`'s NAT rules failed there:

```
iptables v1.8.13 (legacy): can't initialize iptables table `nat': Table does not exist
modprobe: FATAL: Module ip_tables not found in directory /lib/modules/6.18.39-haos-raspi
```

`15.4.1` points the generic `iptables`/`ip6tables` commands at the **nftables**
backend (`xtables-nft-multi`), which HAOS *does* provide. This is the same
technique the official HAOS WireGuard add-on uses
([`hassio-addons/addon-wireguard`](https://github.com/hassio-addons/addon-wireguard),
`wireguard/Dockerfile`). `SYS_MODULE` was dropped as dead weight (there is no
netfilter module to load).

## What was verified locally

Built and run on an x86_64 host with Docker:

- image builds from the pinned `ghcr.io/wg-easy/wg-easy:15.4.0`;
- inside the built image `iptables --version` / `ip6tables --version` report the
  **`nf_tables`** backend and the `MASQUERADE` / `FORWARD` rules install;
- the full launcher runs: `wg0` comes up inside the container (`wg show`,
  `wg-quick up wg0` → *"Wireguard Interface wg0 started successfully"*) and the
  `POSTROUTING ... MASQUERADE` rule is present;
- the web UI loads through a proxy that mimics Home Assistant Ingress
  (request forwarded with a stripped `/api/hassio_ingress/<token>/` prefix and an
  `X-Ingress-Path` header) — assets, login and the SPA work;
- a direct request to the proxy port **without** the `X-Ingress-Path` header is
  refused (`403`), so the UI is not usable as a plain LAN port;
- a client config was created through the UI/API and a **real WireGuard
  handshake** with a second container was observed on the server, with the
  client able to ping both the tunnel address and a host on the LAN behind the
  server.

For `15.4.2` specifically, on x86_64 Docker:

- `bash -n` and `shellcheck` are clean;
- the launcher logs `IPv4 forwarding: net.ipv4.ip_forward=<v> (before)` and
  `... (effective)` **before** WG-Easy starts, and the call is idempotent (on a
  host where the value is already `1` nothing is written);
- the `---- network state ----` block is emitted after `wg0` comes up, showing
  the effective `net.ipv4.ip_forward`, the `wg0` address, the LAN device, the
  `nat POSTROUTING` MASQUERADE rule and the `FORWARD` policy/rules;
- the MASQUERADE-vs-LAN-device mismatch detector fires correctly: on the test
  host WG-Easy stored `eth0` while the default-route device was `ens18`, and the
  log printed the `NOTE`;
- the read-only-`/proc/sys` failure path of the forwarding call was reproduced
  directly (a container write returns `Read-only file system`, exit 1, and the
  effective value is unchanged).

For `15.4.3` specifically, on x86_64 Docker with `--network host` (so the
container sees the host's default-route device, as `host_network: true` does on
HAOS), against both an empty `/etc/wireguard` and an existing database:

- `bash -n` and `node --check` are clean and the image builds;
- the launcher logged `LAN device (default route) = ens18` and
  `WG-Easy masquerade device set to 'ens18' before startup`;
- on the **fresh** database, `fix-lan-device.mjs` created and migrated it and set
  `interfaces_table.device = 'ens18'` (1 row updated), and the first-run setup
  still ran (`Creating initial user`, `Setting initial host and port`);
- the generated `wg0.conf` carried
  `PostUp = iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o ens18 -j MASQUERADE`
  (and the matching `PostDown`) — the **real** device, not `eth0`;
- `wg-quick up wg0` installed `-A POSTROUTING -s 10.8.0.0/24 -o ens18 -j
  MASQUERADE` and the log printed the `OK:` line;
- a **restart** with the existing database kept `device = ens18`, logged
  `Existing database found` and printed `OK:` again — idempotent, no loop;
- with `--network none` (no default route) the `WARNING: could not determine the
  LAN device` fallback fired and WG-Easy's stored `eth0` was left in place.

### What is NOT verified here (the real proof is the Pi)

The local host kernel exposes **both** the legacy and the nft netfilter `nat`
tables, its `/proc/sys` is writable on the host, and its LAN interface is named
`ens18` — none of which matches Home Assistant OS (read-only `/proc/sys`,
forwarding already enabled by Docker) or the owner's Raspberry Pi (`end0`). So
the HAOS-only behaviour and the Pi's exact interface name cannot be reproduced
here. The change is proven by reading the pinned image's own code (WG-Easy
substitutes `{{device}}` from `interfaces_table.device`, read at startup before
`wg-quick up`), plus the local run above — but **the end-to-end proof is the
owner's Home Assistant OS device**. On the Pi, after updating to `15.4.3`, the
add-on log must show:

- **no** `modprobe: FATAL: Module ip_tables not found` and **no**
  `can't initialize iptables table 'nat'`;
- `wg-quick up wg0` completing **without** the
  `Error: Command failed: wg-quick up wg0 (code 3)` rollback;
- `[add-on] IPv4 forwarding: net.ipv4.ip_forward=1 (effective)`;
- `[add-on] LAN device (default route) = end0` and
  `WG-Easy masquerade device set to 'end0' before startup`;
- a `---- network state ----` block whose MASQUERADE `-o` device equals the
  `LAN device (default route)`, with the `OK:` line (**no** `NOTE` line);
- the WireGuard peer then able to reach `http://192.168.0.200:8006` (the Proxmox
  host), not just `http://192.168.0.15:8123`.

Raw output of the local verification is in the task report that accompanied this
repository.

## License

Add-on packaging: MIT. Upstream WG-Easy: AGPL-3.0.
