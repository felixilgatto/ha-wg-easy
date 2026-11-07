# WG-Easy VPN

## Getting started

1. Start the add-on. On its first start it detects your public IP address and sets WG-Easy up: there
   is no setup wizard and no password to choose.
2. Click **Open Web UI**; it opens already logged in. Turn on **Show in sidebar** to keep a
   **WG-Easy** entry in the sidebar.
3. On your router, forward **UDP port 51820** (or the `port` you chose) to the machine running Home
   Assistant.
4. In the panel, create a client and scan its QR code with the WireGuard app.

If your public IP address is not fixed, set a dynamic-DNS name as the host: in the panel
(**Administration → Config**) or with the `host` option.

Everything else (DNS, MTU, keepalive, allowed IPs per client, expiry dates, hooks, extra users,
metrics) is set in the panel, exactly as in a standalone WG-Easy.

## Options

Every option is optional.

### `host`

Public IP address or DNS name that clients connect to. When empty, the address detected on the first
start is used and you can change it in the panel. When filled in, it replaces the panel's value on
every start.

### `port`

UDP port WireGuard listens on (default `51820`). It is applied on every start. The public port
written into client configs follows it, unless you changed that one in the panel (for a router that
maps a different external port).

### `allowed_ips`

Extra address ranges VPN clients may reach, comma-separated, e.g. `192.168.1.0/24`. The tunnel and
this Home Assistant host are always included, so **empty means "Home Assistant only"**.

The add-on enforces this on the server, for all clients, with a firewall rule that drops anything
else. A client cannot get around it by editing its own config. It is also the default routing of new
clients. Existing clients keep the routing they were created with, so edit or recreate them after
widening it.

Opening your LAN gives every connected device access to every machine on it. The add-on prints a
warning at each start while it is open.

### `disable_ipv6`

IPv6 inside the tunnel (default: disabled). IPv4 is enough to reach a home network.

### `home_assistant_entities`

Publish Home Assistant entities through MQTT when a broker is available (default: on). See below.

### `dns`, `mtu`, `persistent_keepalive`

Optional overrides of the panel's values, applied on every start when filled in: DNS servers of new
clients (comma-separated), MTU of the interface and of new clients, and keepalive of new clients (in
seconds, `0` = off).

### `ipv4_cidr`, `ipv6_cidr`

Tunnel address ranges, used **only on the first installation**. To change them later, use the panel
(**Administration → Interface**), which also renumbers existing clients.

### `metrics_port`

When set, WG-Easy's `/metrics/prometheus` and `/metrics/json` are served on that port of your network,
and nothing else is. Enable the metrics, and set a bearer token, in the panel
(**Administration → Metrics**). Without a token anyone on your network can read them.

## Home Assistant entities

Install the official **Mosquitto broker** add-on and set up the **MQTT** integration. On its next
start this add-on picks up the broker by itself.

| Device | Entity | Type |
|---|---|---|
| WG-Easy VPN | Clients, Connected clients | sensor |
| WG-Easy VPN | Restart interface | button |
| each client | Enabled | switch: turns the client on or off |
| each client | Connected | binary sensor: handshake in the last 3 minutes |
| each client | Received, Sent | sensor, bytes (long-term statistics) |
| each client | Last handshake | sensor, timestamp |
| each client | Endpoint, IPv4 address, Expires | diagnostic sensors |

Clients added, renamed or deleted in the panel are reflected within seconds.

## Data, updates and backups

- Everything (server keys, clients, users, settings) is stored in the add-on's persistent `/data`
  folder. It survives restarts, add-on updates and Home Assistant OS updates.
- Home Assistant backups include it, without stopping the VPN. Just before a backup, a consistent copy
  of the database is written, so a restore never depends on a half-written file.
- Before every start, a verified snapshot of the database is kept in `/data/backups` (the 10 newest).
  It is taken before WG-Easy's own migrations run, so an upgrade can always be rolled back.
- If the database is ever damaged, it is moved to `/data/backups/corrupt-<date>/` and the newest valid
  snapshot is restored. Without any valid snapshot the add-on refuses to start rather than create an
  empty database, because an empty database would get new server keys and break every client.
- Stopping the add-on shuts WG-Easy down cleanly: the database is closed and the tunnel is removed.

## Security model

- The panel is only reachable through Home Assistant Ingress. The add-on accepts web connections only
  from the Supervisor, so the port is useless from your network or from the VPN, even with forged
  headers.
- Only Home Assistant administrators can open the panel. That panel controls who can enter your
  network, so it must not be opened up to other users.
- WG-Easy's own admin account is managed by the add-on with a random password stored in `/data`. It is
  re-applied automatically if it stops working, for example after it was changed or 2FA was enabled
  in the panel.
- VPN clients only reach what `allowed_ips` permits, enforced on the server.

## Limitations

- **One-time links** cannot be opened from outside: the interface is only reachable through Home
  Assistant. Share the QR code or the config file instead.
- **AmneziaWG** needs a kernel module that Home Assistant OS does not ship.
- **OAuth / SSO** logins are not used: Home Assistant does the authentication.
- **Port forwarding** must be done on your router. Behind a carrier-grade NAT, incoming VPN connections
  cannot work.
- **Versions before 15.4.6** did not store data persistently. Clients created with them have to be
  recreated once.

## Troubleshooting

The **Log** tab tells you what happened at start-up:

- `First start: public address detected as …`: the host written into client configs.
- `Forwarding filter: VPN clients may be forwarded only to: …`: what clients can reach.
- `---- network state ----`: whether `wg0` is up and whether the NAT rule sits on the right network
  interface.
- `No MQTT broker available`: install Mosquitto to get entities.

**Clients connect but nothing answers.** Check the router's port forwarding (UDP), and that your WAN
address is your public address (no carrier-grade NAT).

**Home Assistant is reachable but other machines are not.** That is the default. Add your LAN range
to `allowed_ips`, then edit or recreate the client so it routes that range.

## How it works

- **Ingress.** WG-Easy cannot run under Home Assistant's changing Ingress path. It runs under a fixed
  internal path, and a small proxy translates paths, redirects and cookies. The same proxy holds the
  WG-Easy session and injects it into every request, which is what removes the second login.
- **Network.** The add-on uses the host network, so `wg0` and its firewall rules live on the Home
  Assistant host. `iptables` runs on the nftables backend, which is the one the Home Assistant OS
  kernel provides. WG-Easy's NAT rule is pointed at the real LAN interface on every start; WG-Easy
  assumes `eth0`, which is wrong on most Home Assistant hosts.
- **Database.** Before WG-Easy starts, the add-on checks and snapshots its SQLite database, runs
  WG-Easy's migrations, and writes the values it manages (LAN device, allowed IPs, and the overrides
  you filled in).
