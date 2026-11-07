# WG-Easy for Home Assistant

Run [WG-Easy](https://github.com/wg-easy/wg-easy), a WireGuard VPN server with a web interface, as a
Home Assistant add-on. Install it, start it, and it works: the WG-Easy interface opens in your Home
Assistant sidebar, already logged in, with every WG-Easy feature available.

[![Open your Home Assistant instance and add this repository.](https://my.home-assistant.io/badges/supervisor_add_addon_repository.svg)](https://my.home-assistant.io/redirect/supervisor_add_addon_repository/?repository_url=https%3A%2F%2Fgithub.com%2Ffelixilgatto%2Fha-wg-easy)

## What you get

- **Zero configuration.** No option is required. Your public address is detected on the first start
  and WG-Easy is set up for you: no setup wizard, no password to invent.
- **No second login.** Home Assistant already knows who you are. The panel is reserved for Home
  Assistant administrators and opens WG-Easy directly.
- **Everything WG-Easy does**, in its own interface: clients, QR codes, expiry dates, per-client
  settings, hooks, users, metrics, and so on.
- **Data that survives.** Clients and keys are kept across restarts, add-on updates and Home Assistant
  OS updates. They are included in Home Assistant backups, snapshotted before every start, and
  restored automatically if the database is ever damaged.
- **Home Assistant entities** for each VPN client (connected, traffic, last handshake, an on/off
  switch, …) when the Mosquitto broker add-on is installed. Nothing to configure.
- **Safe defaults.** VPN clients reach Home Assistant only, unless you open your local network. That
  limit is enforced on the server, so editing a client config does not get around it.

## Install

1. Click the button above, or add the repository by hand:
   **Settings → Add-ons → Add-on Store → ⋮ → Repositories** →
   `https://github.com/felixilgatto/ha-wg-easy`
2. Install **WG-Easy VPN**. It builds on your device, which takes a few minutes.
3. Start it, then click **Open Web UI**. Turn on **Show in sidebar** on the same page to keep a
   **WG-Easy** entry in the sidebar.
4. On your router, forward **UDP port 51820** to the machine running Home Assistant.

That's it. Create a client in the panel and scan its QR code with the WireGuard app.

If your public IP address changes, set a dynamic-DNS name in the panel (**Administration → Config →
Host**) or in the `host` option.

## Options

All options are optional. Settings you can change in the WG-Easy panel stay there, as with a
standalone WG-Easy. The settings marked *override* replace the panel's value on every start, but
only when you fill them in.

| Option | Default | What it does |
|---|---|---|
| `host` | detected | *Override.* Public IP or DNS name written into client configs. |
| `port` | `51820` | UDP port WireGuard listens on. Forward it on your router. |
| `allowed_ips` | empty | Extra ranges VPN clients may reach, e.g. your LAN `192.168.1.0/24`. See below. |
| `disable_ipv6` | `true` | IPv6 inside the tunnel. IPv4 is enough to reach a home network. |
| `home_assistant_entities` | `true` | Publish entities through MQTT when a broker is available. |
| `dns` | — | *Override.* DNS servers for new clients, comma-separated. |
| `mtu` | — | *Override.* MTU of the interface and of new clients. |
| `persistent_keepalive` | — | *Override.* Keepalive interval, in seconds, for new clients. |
| `ipv4_cidr` / `ipv6_cidr` | — | Tunnel ranges. **First installation only**: afterwards change them in the panel, which renumbers existing clients. |
| `metrics_port` | — | Serves WG-Easy's Prometheus/JSON metrics on this port of your network. Enable them, and set their token, in the panel. |

## Reaching your local network

By default a VPN client reaches **Home Assistant only**. To let clients reach the rest of your network,
add its range to `allowed_ips`:

```yaml
allowed_ips: "192.168.1.0/24"
```

A connected device then reaches *every* machine on that network (cameras, NAS, admin interfaces) for
as long as its tunnel is up. A lost phone keeps that reach until you disable its client. The add-on
prints a warning at every start while the network is open, so this is never silent.

Clients created before a change keep the routing they were created with: edit them in the panel or
recreate them. The server-side limit itself applies to all clients right away.

## Home Assistant entities

With the official **Mosquitto broker** add-on installed (and the MQTT integration set up), the add-on
creates:

- a **WG-Easy VPN** device: number of clients, connected clients, and a *Restart interface* button;
- one device per VPN client: *Enabled* switch, *Connected*, *Received*, *Sent*, *Last handshake*,
  plus diagnostic *Endpoint*, *IPv4 address* and *Expires*.

Clients you add, rename or delete in the panel follow automatically. Use them in automations: for
example, get a notification when a client connects, or switch a guest's access off at night.

## Limitations

These come from WG-Easy itself or from Home Assistant OS, and cannot be lifted by the add-on:

- **One-time links do not work.** WG-Easy's "one-time link" lets someone download a config from a
  URL, but the interface is only reachable through Home Assistant, so the link cannot be opened from
  outside. Share the QR code or the downloaded config file instead.
- **No AmneziaWG.** WG-Easy's experimental AmneziaWG mode needs a kernel module that Home Assistant OS
  does not ship.
- **OAuth / SSO logins are not used.** Home Assistant does the authentication.
- **The panel's admin password is managed by the add-on.** If you change it or enable 2FA in the
  panel, the add-on resets it on the next login so the panel keeps opening. Access control is Home
  Assistant's: only its administrators can open the panel.
- **Port forwarding is up to you.** The add-on cannot configure your router. Behind a carrier-grade NAT
  (the WAN address on your router differs from your public IP), incoming VPN connections cannot work.
- **Data from versions before 15.4.6 is not recoverable.** Those versions did not store data
  persistently. Clients created before updating have to be recreated once.

## Development

- `tests/smoke.sh` runs the add-on image end to end in plain Docker. It covers persistence, automatic
  login, MQTT entities, overrides, metrics, backups and corruption recovery.
- `.devcontainer.json` and `.vscode/tasks.json` are the official Home Assistant app devcontainer, with a
  real Supervisor and Home Assistant
  ([guide](https://contributors.home-assistant.io/apps/guides/testing/)).
- CI runs the official app linter, ShellCheck, an amd64 + aarch64 build and the smoke test.

## Credits and licence

This add-on packages the official [WG-Easy](https://github.com/wg-easy/wg-easy) image (the exact
version is pinned in `wg-easy/Dockerfile`) and adds the Home Assistant integration around it. WG-Easy
is licensed separately; see its repository. This repository is under the licence in `LICENSE`.
