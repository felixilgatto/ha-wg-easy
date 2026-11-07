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

> **Fill in `host`, `port`, `username`, `password`, `dns` and the two CIDRs before the first start.**
> WG-Easy stores these the first time it runs; changing them in the add-on options afterwards has no
> effect, so change them in the WG-Easy panel instead. `allowed_ips`, `disable_ipv6` and
> `reset_admin_password` are different: they are applied on **every** start.

## Options

| Option | Default | Applied | What it does |
|---|---|---|---|
| `host` | — | first start | **Required.** Public IP address or hostname your clients connect to. |
| `port` | `51820` | first start | UDP port of the tunnel. Forward this on your router. |
| `username` | `admin` | first start | Login for the WG-Easy panel. |
| `password` | — | first start | **Required.** Twelve characters or more. |
| `dns` | `1.1.1.1` | first start | DNS server pushed to clients. |
| `allowed_ips` | `10.8.0.0/24` | every start | What clients may reach. See below. |
| `ipv4_cidr` | `10.8.0.0/24` | first start | Address range of the tunnel itself. |
| `ipv6_cidr` | `fdcc:…` | first start | Unused while IPv6 is disabled. |
| `disable_ipv6` | `true` | every start | Keep disabled unless you know your network handles IPv6. |
| `reset_admin_password` | `false` | every start | See below. |

**`reset_admin_password`:** while it is `true`, the admin password is reset to `password` and two-factor
authentication is cleared **on every start**. Set it to `true`, restart once, then set it back to
`false`. Otherwise every restart undoes any password or 2FA you set in the panel.

The tunnel range and the address of this Home Assistant host are added to `allowed_ips` automatically,
so Home Assistant is reachable without you typing its address. If the add-on cannot find the host's
address within 30 seconds of starting (no network yet), it logs a `WARNING` and skips it. Restart the
add-on once the network is up.

## Reaching your local network

By default a VPN client can reach **Home Assistant only**. To let clients reach the rest of your local
network, add your subnet to the same option:

```yaml
allowed_ips: "10.8.0.0/24, 192.168.0.0/24"
```

`allowed_ips` is enforced **on the server**: the add-on installs a firewall rule that drops any
traffic from a VPN client to an address outside these ranges. Editing the client's own WireGuard
config does not get around it. The rule follows the option on every restart and applies to all
clients, old and new.

**Opening your network is a real privilege, and worth a moment's thought.** A connected device then
reaches *every* machine on that network — cameras, servers and administration interfaces included —
for as long as the tunnel is up. A lost or compromised phone keeps that reach until you revoke its
client.

The add-on prints a clear warning at startup as soon as `allowed_ips` goes beyond the tunnel and Home
Assistant, so this is never opened silently.

`allowed_ips` also becomes the routing setting in **new** client configs. A client created before you
widened it still routes only the old ranges: edit it in the WG-Easy panel, or delete and recreate it.

## Notes

- The web interface is served through Home Assistant's ingress. The internal port (`8099`) only
  accepts connections from the Home Assistant Supervisor, so other machines on your network or VPN
  cannot open it directly.
- The WireGuard UDP port must be forwarded on your router. The add-on cannot do that for you.
- If your connection is behind a carrier-grade NAT, port forwarding cannot work, regardless of this
  add-on. Compare your router's WAN address with the address seen from the internet.
- Keep your client configurations private: they contain a private key.

Full documentation — how the ingress proxy and network setup work, how to read the startup log, and
troubleshooting when other machines on your network are unreachable — is in
[`wg-easy/DOCS.md`](wg-easy/DOCS.md).

## Credits and licence

This add-on packages the official [WG-Easy](https://github.com/wg-easy/wg-easy) image — the exact
version is pinned in the `Dockerfile` — and adds the Home Assistant integration around it: the ingress
panel, the options above, and automatic detection of the network interface to use.

- Add-on packaging (this repository): [MIT](LICENSE).
- WG-Easy, which the add-on builds and runs: [AGPL-3.0](https://github.com/wg-easy/wg-easy/blob/master/LICENSE).
  If you modify and redistribute the add-on, the AGPL terms apply to the WG-Easy part.
