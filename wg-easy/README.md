# WG-Easy VPN (Home Assistant add-on)

WireGuard VPN server built on [WG-Easy](https://github.com/wg-easy/wg-easy),
packaged as a Home Assistant OS add-on.

- The **WG-Easy web interface appears as a sidebar panel inside Home Assistant**
  (Ingress). No extra LAN port is opened for it.
- The **WireGuard UDP port is configurable** (default `51820`).
- VPN clients can be routed to your **whole home LAN**.

## Configuration

| Option | Description |
| --- | --- |
| `host` | **Required.** Public IP address or dynamic-DNS hostname that your VPN clients connect to. |
| `port` | UDP port the WireGuard server listens on and that clients use. Default `51820`. |
| `username` | Admin username for the web UI. Default `admin`. |
| `password` | Admin password for the web UI. Minimum 12 characters. |
| `dns` | DNS server pushed to clients. Default `1.1.1.1`. |
| `allowed_ips` | What clients route through the tunnel. `0.0.0.0/0, ::/0` = full tunnel (reach the whole LAN **and** the internet through your home). Set your LAN CIDR (e.g. `192.168.1.0/24`) for split tunnel. |
| `ipv4_cidr` | VPN-internal IPv4 subnet for clients. Default `10.8.0.0/24`. |
| `ipv6_cidr` | VPN-internal IPv6 subnet for clients. |
| `disable_ipv6` | Disable IPv6 inside the tunnel. Default `true` (recommended: some kernels lack the `ip6_tables` NAT table, which would make `wg-quick` fail). |
| `reset_admin_password` | When `true`, reset the web UI admin password from the `password` option on next start. |

See [DOCS.md](DOCS.md) for the full documentation, including the
**"first run only"** behaviour of these options and the Ingress design.
