# Caddy with the rate-limit module, which the stock image does not have.
# Built by `docker compose` (deploy/compose.yaml).

ARG CADDY_VERSION=2

FROM caddy:${CADDY_VERSION}-builder AS build
RUN xcaddy build --with github.com/mholt/caddy-ratelimit

FROM caddy:${CADDY_VERSION}
COPY --from=build /usr/bin/caddy /usr/bin/caddy
COPY Caddyfile /etc/caddy/Caddyfile
