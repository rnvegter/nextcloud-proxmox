FROM caddy:2-builder AS builder
# For option A (port forward) with real client IPs, add:
#   --with github.com/WeidiDeng/caddy-cloudflare-ip
RUN xcaddy build --with github.com/caddy-dns/cloudflare

FROM caddy:2
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
