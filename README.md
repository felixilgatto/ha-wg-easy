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

## Requirements

Home Assistant OS or Supervised on a 64-bit system (`aarch64` or `amd64`), no other WireGuard server
on the same host (such as the WireGuard add-on), and a router on which you can forward a UDP port.

## Install

1. Click the button above, or add the repository by hand:
   **Settings → Add-ons → Add-on Store → ⋮ → Repositories** →
   `https://github.com/felixilgatto/ha-wg-easy`
2. Install **WG-Easy VPN**. It builds on your device, which takes a few minutes.
3. Start it, then click **Open Web UI**. Turn on **Show in sidebar** on the same page to keep a
   **WG-Easy** entry in the sidebar.
4. On your router, forward **UDP port 51820** to the machine running Home Assistant.

That's it. Create a client in the panel and scan its QR code with the WireGuard app.

By default VPN clients reach Home Assistant only. Add your LAN range (e.g. `192.168.1.0/24`) to the
`allowed_ips` option to let them reach the rest of your network.

## Documentation

The full documentation is in [`wg-easy/DOCS.md`](wg-easy/DOCS.md), also shown in the add-on's
**Documentation** tab: options, reaching your network, Home Assistant entities, data and backups,
security model, limitations and troubleshooting.

## Development

- `tests/smoke.sh` runs the add-on image end to end in plain Docker. It covers persistence, automatic
  login, MQTT entities, overrides, metrics, backups and corruption recovery.
- `.devcontainer.json` and `.vscode/tasks.json` are the official Home Assistant app devcontainer, with a
  real Supervisor and Home Assistant
  ([guide](https://contributors.home-assistant.io/apps/guides/testing/)).
- CI runs the official app linter, ShellCheck, an amd64 + aarch64 build and the smoke test.

## Versions

The add-on has its own [semantic version](https://semver.org), independent of WG-Easy's, starting at
`1.0.0`. Each release notes the WG-Easy version it bundles in the
[changelog](wg-easy/CHANGELOG.md), and the add-on logs both at start-up. Versions up to `15.5.0`
followed WG-Easy's numbering.

- **major**: a change you must act on (removed option, new requirement, data migration you have to
  check);
- **minor**: new features, or a new WG-Easy minor/major version;
- **patch**: fixes, security updates, new WG-Easy patch version.

## Credits and licence

This add-on packages the official [WG-Easy](https://github.com/wg-easy/wg-easy) image (the exact
version is pinned in `wg-easy/Dockerfile`) and adds the Home Assistant integration around it. WG-Easy
is licensed separately; see its repository. This repository is under the licence in `LICENSE`.
