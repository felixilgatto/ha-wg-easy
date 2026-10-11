# WG-Easy for Home Assistant

Run [WG-Easy](https://github.com/wg-easy/wg-easy) — a WireGuard VPN server with a web interface — as a
Home Assistant add-on. The interface appears as a panel **inside** Home Assistant, so nothing extra is
exposed on your network.

[![Open your Home Assistant instance and add this repository.](https://my.home-assistant.io/badges/supervisor_add_addon_repository.svg)](https://my.home-assistant.io/redirect/supervisor_add_addon_repository/?repository_url=https%3A%2F%2Fgithub.com%2Ffelixilgatto%2Fha-wg-easy)

## What you get

- A WireGuard VPN server, with the WG-Easy interface in your Home Assistant sidebar
- No additional port for the web interface: it is reached through Home Assistant itself
- VPN clients that reach Home Assistant by default, and your whole local network if you ask for it
- A configurable UDP port for the tunnel

## Install

1. Click the button at the top of this page, or add the repository by hand:
   Settings → Add-ons → Add-on Store → ⋮ → **Repositories** →
   `https://github.com/felixilgatto/ha-wg-easy`
2. Install **WG-Easy VPN**. It builds on your device, which takes a few minutes.
3. Fill in the options — at minimum `host` and `password` (see below).
4. Start the add-on and open the **WG-Easy** panel.
5. On your router, forward the **UDP** port you chose (default `51820`) to the machine running Home
   Assistant.

> **Fill in the options before the first start.** WG-Easy stores its configuration the first time it
> runs, so changing these options afterwards has no effect. Later changes are made in the WG-Easy
> panel itself.

## Options

| Option | Default | What it does |
|---|---|---|
| `host` | — | **Required.** Public IP address or hostname your clients connect to. |
| `port` | `51820` | UDP port of the tunnel. Forward this on your router. |
| `username` | `admin` | Login for the WG-Easy panel. |
| `password` | — | **Required.** Twelve characters or more. |
| `dns` | `1.1.1.1` | DNS server pushed to clients. |
| `allowed_ips` | `10.8.0.0/24` | What new clients are allowed to route. See below. |
| `ipv4_cidr` | `10.8.0.0/24` | Address range of the tunnel itself. |
| `ipv6_cidr` | `fdcc:…` | Unused while IPv6 is disabled. |
| `disable_ipv6` | `true` | Keep disabled unless you know your network handles IPv6. |
| `reset_admin_password` | `false` | Set to `true` once to re-apply `password` after changing it. |

The address of this Home Assistant host is **always added automatically** to `allowed_ips`, so Home
Assistant is reachable without you typing its address.

## Reaching your local network

By default a VPN client reaches **Home Assistant only**. To let clients reach the rest of your local
network, add your subnet to the same option:

```yaml
allowed_ips: "10.8.0.0/24, 192.168.0.0/24"
```

**This is a real privilege, and worth a moment's thought.** A connected device then reaches *every*
machine on that network — cameras, servers and administration interfaces included — for as long as
the tunnel is up. A lost or compromised phone keeps that reach until you revoke its client.

The add-on prints a clear warning at startup as soon as the allowed addresses go beyond Home
Assistant, so this is never opened silently. By default nothing warns, because nothing else is
reachable.

Clients created **before** a change keep their own setting: adjust an existing client in the WG-Easy
panel, or delete it and create a new one.

## Notes

- The web interface is served through Home Assistant's ingress. It is not reachable directly from your
  network, and no port is published for it.
- The WireGuard UDP port must be forwarded on your router. The add-on cannot do that for you.
- If your connection is behind a carrier-grade NAT, port forwarding cannot work, regardless of this
  add-on. Compare your router's WAN address with the address seen from the internet.
- Keep your client configurations private: they contain a private key.

## Credits and licence

This add-on packages the official [WG-Easy](https://github.com/wg-easy/wg-easy) image — the exact
version is pinned in the `Dockerfile` — and adds the Home Assistant integration around it: the ingress
panel, the options above, and automatic detection of the network interface to use. WG-Easy is
licensed separately; see its repository.
