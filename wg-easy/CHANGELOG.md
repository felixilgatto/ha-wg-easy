# Changelog

## 15.4.1

- **Fix: VPN clients can now reach the home LAN on Home Assistant OS.** The NAT
  rules that `wg-quick` installs for LAN routing were failing on HAOS because the
  kernel does not expose the *legacy* netfilter `nat` table to add-ons:

  ```
  iptables v1.8.13 (legacy): can't initialize iptables table `nat':
  Table does not exist (do you need to insmod?)
  modprobe: FATAL: Module ip_tables not found in directory /lib/modules/6.18.39-haos-raspi
  ```

  which made `wg-quick up wg0` fail and roll the interface back
  (`Error: Command failed: wg-quick up wg0 (code 3)`). The image now points the
  generic `iptables`/`ip6tables` commands at the **nftables** backend
  (`xtables-nft-multi`), which HAOS's kernel *does* provide. This is the same
  technique the official HAOS WireGuard add-on
  ([`hassio-addons/addon-wireguard`](https://github.com/hassio-addons/addon-wireguard),
  `wireguard/Dockerfile`) uses.
- Removed `SYS_MODULE` from `privileged`. HAOS ships no loadable netfilter
  modules (see the `modprobe` error above), so the capability served no purpose.
  `NET_ADMIN` is unchanged.
- Still embeds WG-Easy `15.4.0` (`ghcr.io/wg-easy/wg-easy:15.4.0`).

> Verified locally on x86_64 Docker that `iptables`/`ip6tables` now report the
> `nf_tables` backend and that the full add-on starts, brings up `wg0` and
> installs the `MASQUERADE` rule. **The Home Assistant OS proof is the owner's
> Raspberry Pi** — the local host kernel exposes both netfilter backends, so it
> cannot reproduce the HAOS-only failure. See README.md.

## 15.4.0
- Initial release. Embeds WG-Easy `15.4.0` (`ghcr.io/wg-easy/wg-easy:15.4.0`).
- Web UI exposed as a Home Assistant sidebar panel via Ingress, using an
  in-container reverse proxy that bridges the dynamic Ingress path prefix and
  WG-Easy's fixed internal base path.
- WireGuard UDP port configurable via add-on options.
- Persistent `/etc/wireguard` volume so keys, clients and the WG-Easy database
  survive Home Assistant OS updates.
