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
| [wg-easy](wg-easy) | 15.4.1 | WireGuard VPN + WG-Easy web UI as an Ingress panel |

## Design notes (short version)

Home Assistant Ingress serves add-on UIs under a dynamic path prefix
(`/api/hassio_ingress/<token>/`). WG-Easy 15.x cannot run from a sub-path
(absolute asset URLs, absolute middleware redirects —
[wg-easy#1802](https://github.com/wg-easy/wg-easy/issues/1802)). Instead of
exposing a LAN port, the add-on runs WG-Easy under a **fixed internal base**
(`/_haingress`) and ships a small **reverse proxy** that translates between that
fixed base and the dynamic Ingress prefix on every request and response. See
[`wg-easy/DOCS.md`](wg-easy/DOCS.md).

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

### What is NOT verified here (the real proof is the Pi)

The local host kernel exposes **both** the legacy and the nft netfilter `nat`
tables, so it cannot reproduce the HAOS-only failure. The fix is proven correct
by reasoning + the official add-on's precedent + the local backend switch — but
**the end-to-end proof is the owner's Home Assistant OS device**. On the Pi,
after updating to `15.4.1`, the add-on log must show:

- **no** `modprobe: FATAL: Module ip_tables not found` and **no**
  `can't initialize iptables table 'nat'`;
- `wg-quick up wg0` completing **without** the
  `Error: Command failed: wg-quick up wg0 (code 3)` rollback;
- the WireGuard peer then able to ping a device on the home LAN.

Raw output of the local verification is in the task report that accompanied this
repository.

## License

Add-on packaging: MIT. Upstream WG-Easy: AGPL-3.0.
