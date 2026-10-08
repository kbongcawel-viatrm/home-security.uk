FROM docker.io/library/caddy:builder-alpine AS builder

RUN xcaddy build \
    --with github.com/hslatman/caddy-crowdsec-bouncer/http

FROM docker.io/library/caddy:alpine

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
