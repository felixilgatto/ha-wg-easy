# WG-Easy VPN

WireGuard VPN server with the [WG-Easy](https://github.com/wg-easy/wg-easy) web interface, inside
Home Assistant.

- **Works as installed**: no option to fill in, no setup wizard, no second login.
- **The full WG-Easy interface** as a sidebar panel, reserved for Home Assistant administrators.
- **Your data survives** restarts and updates, is part of Home Assistant backups, and is restored
  automatically if the database is damaged.
- **Entities for every VPN client** (connected, traffic, on/off switch, …) through MQTT, when the
  Mosquitto broker add-on is installed.
- **VPN clients reach Home Assistant only** by default, enforced on the server. Add your LAN to
  `allowed_ips` to open it.

Needs a 64-bit system and no other WireGuard server (such as the WireGuard add-on) on the same
host. After installing, forward **UDP port 51820** on your router to Home Assistant. See the
**Documentation** tab for options, entities and limitations.
