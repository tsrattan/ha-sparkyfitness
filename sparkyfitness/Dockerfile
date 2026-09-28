ARG BUILD_VERSION=dev
ARG BUILD_ARCH=amd64

FROM codewithcj/sparkyfitness@sha256:f11e754934baefa14dae64540a5e79fc14189542fac8e2968ec9cdbf350f5911 AS frontend

FROM codewithcj/sparkyfitness_server@sha256:0859618c5f13df0977cbe4bb1df19ef3b01def15da167e3c400fae809795f56e

ARG BUILD_VERSION
ARG BUILD_ARCH

RUN apk add --no-cache \
      bash \
      curl \
      gettext-envsubst \
      jq \
      nginx \
      openssl \
      postgresql18 \
      postgresql18-client \
      su-exec \
      tzdata

# Copy the official SparkyFitness frontend and its nginx configuration.
COPY --from=frontend /usr/share/nginx/html /usr/share/nginx/html
COPY --from=frontend /etc/nginx/nginx.conf /etc/nginx/nginx.conf
COPY --from=frontend /etc/nginx/mime.types /etc/nginx/mime.types
COPY --from=frontend /etc/nginx/templates/default.conf.template /etc/nginx/templates/default.conf.template

COPY rootfs/run.sh /run.sh

RUN chmod 0755 /run.sh && \
    mkdir -p \
      /etc/nginx/conf.d \
      /run/nginx \
      /var/cache/nginx/client-body \
      /var/cache/nginx/proxy \
      /var/cache/nginx/fastcgi \
      /var/cache/nginx/uwsgi \
      /var/cache/nginx/scgi

LABEL \
    io.hass.version="${BUILD_VERSION}" \
    io.hass.type="app" \
    io.hass.arch="${BUILD_ARCH}"

WORKDIR /app/SparkyFitnessServer

ENTRYPOINT ["/run.sh"]
CMD []
