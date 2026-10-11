# Changelog

## 15.4.0
- Initial release. Embeds WG-Easy `15.4.0` (`ghcr.io/wg-easy/wg-easy:15.4.0`).
- Web UI exposed as a Home Assistant sidebar panel via Ingress, using an
  in-container reverse proxy that bridges the dynamic Ingress path prefix and
  WG-Easy's fixed internal base path.
- WireGuard UDP port configurable via add-on options.
- Persistent `/etc/wireguard` volume so keys, clients and the WG-Easy database
  survive Home Assistant OS updates.
