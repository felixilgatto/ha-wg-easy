# WG-Easy VPN (Home Assistant add-on)

WireGuard VPN server built on [WG-Easy](https://github.com/wg-easy/wg-easy),
packaged as a Home Assistant OS add-on.

- The **WG-Easy web interface appears as a sidebar panel inside Home Assistant**
  (Ingress). No extra LAN port is opened for it.
- The **WireGuard UDP port is configurable** (default `51820`).
- By default VPN clients reach **only this Home Assistant host**. Add your LAN
  subnet to `allowed_ips` to let them reach the rest of your home LAN. The add-on
  enforces this on the server, so a client cannot widen it by editing its own config.

## Configuration

| Option | Description |
| --- | --- |
| `host` | **Required.** Public IP address or dynamic-DNS hostname that your VPN clients connect to. *First start only.* |
| `port` | UDP port the WireGuard server listens on and that clients use. Default `51820`. *First start only.* |
| `username` | Admin username for the web UI. Default `admin`. *First start only.* |
| `password` | Admin password for the web UI. Minimum 12 characters. *First start only* (see `reset_admin_password`). |
| `dns` | DNS server pushed to clients. Default `1.1.1.1`. *First start only.* |
| `allowed_ips` | What VPN clients may reach. Default `10.8.0.0/24` (the tunnel only; this Home Assistant host is added automatically). Add your LAN subnet, e.g. `10.8.0.0/24, 192.168.1.0/24`, to reach the whole LAN; a startup warning then says so. Enforced on the server for all clients. *Every start.* |
| `ipv4_cidr` | VPN-internal IPv4 subnet for clients. Default `10.8.0.0/24`. *First start only.* |
| `ipv6_cidr` | VPN-internal IPv6 subnet for clients. *First start only.* |
| `disable_ipv6` | Disable IPv6 inside the tunnel. Default `true`. IPv4 is enough to reach a home LAN. *Every start.* |
| `reset_admin_password` | While `true`, the admin password is reset to `password` and 2FA is cleared **on every start**. Set it to `true`, restart once, then set it back to `false`. |

See [DOCS.md](DOCS.md) for the full documentation, including the
**"first run only"** behaviour of these options, the Ingress design and
troubleshooting.
