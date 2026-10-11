ARG BUILD_VERSION
ARG BUILD_ARCH

# Pinned to the exact upstream release. See README.md for why 15.4.0.
FROM ghcr.io/wg-easy/wg-easy:15.4.0

# jq is needed to read /data/options.json (this image has no bashio).
RUN apk add --no-cache jq

# ---- Make iptables use the nftables backend --------------------------------
# Home Assistant OS's kernel does not expose the *legacy* netfilter `nat` table
# to add-ons, so `wg-quick up wg0` fails when it tries to install the NAT rules
# that let VPN clients reach the home LAN:
#
#   iptables v1.8.13 (legacy): can't initialize iptables table `nat':
#   Table does not exist (do you need to insmod?)
#   modprobe: FATAL: Module ip_tables not found in directory
#   /lib/modules/6.18.39-haos-raspi
#
# The kernel *does* provide the nft `nat` table. This image already ships the
# nftables-backed xtables binaries (`/usr/sbin/iptables-nft` ->
# `xtables-nft-multi`); the generic `iptables`/`ip6tables` commands just point
# at the legacy backend by default via update-alternatives.
#
# This is exactly the technique the proven-working official HAOS WireGuard
# add-on uses: hassio-addons/addon-wireguard, `wireguard/Dockerfile` (lines 22-23)
# symlinks `iptables`/`ip6tables` to `xtables-nft-multi`. We register the nft
# alternative instead of symlinking so that the whole command family
# (save/restore too) stays consistent; a higher priority makes auto mode select
# it. NOTE: `update-alternatives --set` alone fails here
# ("alternative ... not registered"), so we `--install` first.
#
# The trailing version checks fail the build if the switch did not take effect.
RUN set -eux; \
    update-alternatives --install /usr/sbin/iptables iptables /usr/sbin/iptables-nft 30 \
        --slave /usr/sbin/iptables-restore iptables-restore /usr/sbin/iptables-nft-restore \
        --slave /usr/sbin/iptables-save iptables-save /usr/sbin/iptables-nft-save; \
    update-alternatives --install /usr/sbin/ip6tables ip6tables /usr/sbin/ip6tables-nft 30 \
        --slave /usr/sbin/ip6tables-restore ip6tables-restore /usr/sbin/ip6tables-nft-restore \
        --slave /usr/sbin/ip6tables-save ip6tables-save /usr/sbin/ip6tables-nft-save; \
    iptables --version | grep -q 'nf_tables'; \
    ip6tables --version | grep -q 'nf_tables'

COPY run.sh /run.sh
COPY ingress-proxy.mjs /ingress-proxy.mjs
RUN chmod a+x /run.sh

LABEL \
  io.hass.version="${BUILD_VERSION}" \
  io.hass.type="addon" \
  io.hass.arch="${BUILD_ARCH}"

# Replace the upstream entrypoint (a thin node wrapper) with our launcher,
# which starts wg-easy *and* the ingress reverse proxy.
ENTRYPOINT []
CMD ["/run.sh"]
