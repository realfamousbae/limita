# The landing page: static files served by Caddy on Railway's $PORT.
FROM caddy:2-alpine
COPY Caddyfile /etc/caddy/Caddyfile
COPY . /srv
RUN rm -f /srv/Dockerfile /srv/Caddyfile
