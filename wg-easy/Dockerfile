ARG BUILD_VERSION
ARG BUILD_ARCH

# Pinned to the exact upstream release. See README.md for why 15.4.0.
FROM ghcr.io/wg-easy/wg-easy:15.4.0

# jq is needed to read /data/options.json (this image has no bashio).
RUN apk add --no-cache jq

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
