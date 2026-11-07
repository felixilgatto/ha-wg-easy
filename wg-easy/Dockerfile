ARG BUILD_VERSION
ARG BUILD_ARCH

# Pinned to an exact upstream release for reproducible builds. The add-on's
# database preparation (addon/prepare-db.mjs) depends on this version's schema
# and on its migrations; see CHANGELOG.md before bumping.
FROM ghcr.io/wg-easy/wg-easy:15.4.0

# Build args declared before FROM are not visible after it; re-declare them so
# the labels and ADDON_VERSION below actually get a value.
ARG BUILD_VERSION
ARG BUILD_ARCH
ENV ADDON_VERSION="${BUILD_VERSION}"

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
# The trailing checks fail the build if the switch did not take effect. They
# resolve the command links instead of running `iptables --version`: the nft
# backend opens a netlink socket even for --version, which fails when the image
# is cross-built under QEMU ("Failed to initialize nft: Protocol not supported").
RUN set -eux; \
    update-alternatives --install /usr/sbin/iptables iptables /usr/sbin/iptables-nft 30 \
        --slave /usr/sbin/iptables-restore iptables-restore /usr/sbin/iptables-nft-restore \
        --slave /usr/sbin/iptables-save iptables-save /usr/sbin/iptables-nft-save; \
    update-alternatives --install /usr/sbin/ip6tables ip6tables /usr/sbin/ip6tables-nft 30 \
        --slave /usr/sbin/ip6tables-restore ip6tables-restore /usr/sbin/ip6tables-nft-restore \
        --slave /usr/sbin/ip6tables-save ip6tables-save /usr/sbin/ip6tables-nft-save; \
    readlink -f /usr/sbin/iptables | grep -q 'xtables-nft-multi$'; \
    readlink -f /usr/sbin/ip6tables | grep -q 'xtables-nft-multi$'

# ---- Persistent storage ------------------------------------------------------
# Only /data survives the container being recreated (which Supervisor does on
# every start, restart and update). WG-Easy keeps its whole state in
# /etc/wireguard, so point that at /data/wireguard. run.sh creates the target.
RUN rm -rf /etc/wireguard && ln -s /data/wireguard /etc/wireguard

# ---- Add-on layer --------------------------------------------------------------
# The add-on's Node scripts live in /app/server/addon so that they resolve
# WG-Easy's own modules (@libsql/client, drizzle) from /app/server/node_modules,
# i.e. the exact driver and SQLite build the app uses. Their only extra
# dependency (mqtt, for Home Assistant entities) is pinned by package-lock.json.
COPY addon/package.json addon/package-lock.json /app/server/addon/
RUN cd /app/server/addon && npm ci --omit=dev --ignore-scripts --no-audit --no-fund \
    && npm cache clean --force
COPY addon/*.mjs /app/server/addon/
COPY run.sh /run.sh
RUN chmod a+x /run.sh \
    && node --check /app/server/addon/ingress-proxy.mjs \
    && node --check /app/server/addon/ha-bridge.mjs

# The Supervisor restarts the add-on when it turns unhealthy: WG-Easy must
# answer behind the proxy and the WireGuard interface must exist.
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:8099/_addon/health || exit 1

LABEL \
  io.hass.version="${BUILD_VERSION}" \
  io.hass.type="addon" \
  io.hass.arch="${BUILD_ARCH}"

# Replace the upstream entrypoint (a thin node wrapper) with our launcher,
# which starts wg-easy *and* the ingress reverse proxy.
ENTRYPOINT []
CMD ["/run.sh"]
