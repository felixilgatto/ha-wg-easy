# Changelog

## 15.4.2

- **Add-on now enables IPv4 forwarding itself, and logs the routing state at
  startup.** A packet addressed to the Home Assistant host itself is delivered
  locally and needs no routing, but a packet addressed to *another* host on the
  home LAN must be **forwarded** from the tunnel interface (`wg0`) to the LAN
  interface — the kernel only does that when `net.ipv4.ip_forward=1`. The
  launcher now runs `sysctl -w net.ipv4.ip_forward=1` **before** WG-Easy starts.
  Because the add-on runs with `host_network: true` it shares the host's network
  namespace, so this sets the value on the Home Assistant host; `NET_ADMIN`
  (already requested) is the capability that write needs. The write is
  idempotent: if the value is already `1` nothing is changed. The effective
  value is logged either way.

  > **Reality check (important):** on Home Assistant OS the value is normally
  > **already `1`**, because HAOS relies on the Docker daemon to enable IPv4
  > forwarding at boot. The Supervisor also mounts `/proc/sys` **read-only**
  > inside add-on containers, so if the value were `0` the add-on could not
  > change it — the log will say so explicitly. See DOCS.md.

- **Startup now dumps the exact state that decides whether LAN routing works**,
  so one look at the add-on log answers the question: the effective
  `net.ipv4.ip_forward`, the `wg0` address, the LAN (default-route) device, the
  `nat POSTROUTING MASQUERADE` rule WG-Easy installs, and the `FORWARD` policy
  and rules. If the MASQUERADE rule targets a different device than the
  default-route device, the log prints a `NOTE` — a mismatched device is a
  second, independent cause of "the Home Assistant host is reachable over the
  VPN but other LAN machines are not" (without NAT, replies from other LAN hosts
  are dropped).
- Still embeds WG-Easy `15.4.0` (`ghcr.io/wg-easy/wg-easy:15.4.0`). Ingress-only
  UI, configurable UDP port, pinned image tag, persistence and first-run
  semantics are unchanged.

> Verified locally on x86_64 Docker (not Home Assistant OS): the launcher is
> syntactically sound, the forwarding call is present and idempotent, the
> network-state block prints, and `wg0` comes up with the MASQUERADE/FORWARD
> rules installed. The local host kernel exposes both netfilter backends and its
> `/proc/sys` is writable, so it cannot reproduce the HAOS-only behaviour. **The
> Home Assistant OS proof is the owner's Raspberry Pi** — see README.md.

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
