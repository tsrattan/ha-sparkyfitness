ARG BUILD_VERSION=dev
ARG BUILD_ARCH=amd64

FROM codewithcj/sparkyfitness@sha256:3772cc463673e2cbb463711688329cc375523591544e83c7d6318b7fbae0eeb5 AS frontend

FROM codewithcj/sparkyfitness_server@sha256:819e47fde1f685f19b9bdf5366a4ea44af34ab9f48d6ff898bb04bd0e1184dff

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
COPY rootfs/backup.sh /backup.sh

RUN chmod 0755 /run.sh /backup.sh && \
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
