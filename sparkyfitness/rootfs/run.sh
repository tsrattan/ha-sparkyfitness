#!/usr/bin/env bash
set -Eeuo pipefail

log() {
    echo "[ha-sparkyfitness] $*"
}

OPTIONS_FILE="/data/options.json"
PGDATA="/data/postgresql"
SECRET_DIR="/data/secrets"

DB_NAME="sparkyfitness_db"
DB_USER="sparky"
APP_DB_USER="sparky_app"

get_option() {
    local key="$1"

    if [ -f "${OPTIONS_FILE}" ]; then
        jq -r --arg key "${key}" \
          'if has($key) and .[$key] != null then .[$key] else "" end' \
          "${OPTIONS_FILE}" 2>/dev/null || true
    fi
}

FRONTEND_URL="$(get_option frontend_url)"
TZ_VALUE="$(get_option timezone)"
LOG_LEVEL="$(get_option log_level)"
NGINX_RATE_LIMIT_VALUE="$(get_option nginx_rate_limit)"

[ -n "${FRONTEND_URL}" ] || FRONTEND_URL="http://172.16.0.6:3005"
[ -n "${TZ_VALUE}" ] || TZ_VALUE="Etc/UTC"
[ -n "${LOG_LEVEL}" ] || LOG_LEVEL="ERROR"
[ -n "${NGINX_RATE_LIMIT_VALUE}" ] || NGINX_RATE_LIMIT_VALUE="5r/s"

# Origin values should not end with /
FRONTEND_URL="${FRONTEND_URL%/}"

log "Frontend URL: ${FRONTEND_URL}"
log "Timezone: ${TZ_VALUE}"
log "Log level: ${LOG_LEVEL}"

mkdir -p \
    "${PGDATA}" \
    "${SECRET_DIR}" \
    /data/uploads \
    /data/backup

chmod 700 "${SECRET_DIR}"

# -------------------------------------------------------------------
# Secrets
# -------------------------------------------------------------------

SECRET_FILES=(
    db_password
    app_db_password
    api_encryption_key
    better_auth_secret
)

if [ -s "${PGDATA}/PG_VERSION" ]; then
    for secret in "${SECRET_FILES[@]}"; do
        if [ ! -s "${SECRET_DIR}/${secret}" ]; then
            log "ERROR: PostgreSQL already exists but secret '${secret}' is missing."
            log "Refusing to generate replacement credentials."
            exit 1
        fi
    done
else
    if [ ! -s "${SECRET_DIR}/db_password" ]; then
        openssl rand -hex 32 > "${SECRET_DIR}/db_password"
    fi

    if [ ! -s "${SECRET_DIR}/app_db_password" ]; then
        openssl rand -hex 32 > "${SECRET_DIR}/app_db_password"
    fi

    if [ ! -s "${SECRET_DIR}/api_encryption_key" ]; then
        openssl rand -hex 32 > "${SECRET_DIR}/api_encryption_key"
    fi

    if [ ! -s "${SECRET_DIR}/better_auth_secret" ]; then
        openssl rand -base64 32 | tr -d '\n' > "${SECRET_DIR}/better_auth_secret"
        printf '\n' >> "${SECRET_DIR}/better_auth_secret"
    fi
fi

chmod 600 "${SECRET_DIR}"/*

DB_PASSWORD="$(cat "${SECRET_DIR}/db_password")"
APP_DB_PASSWORD="$(cat "${SECRET_DIR}/app_db_password")"
API_ENCRYPTION_KEY="$(cat "${SECRET_DIR}/api_encryption_key")"
BETTER_AUTH_SECRET_VALUE="$(cat "${SECRET_DIR}/better_auth_secret")"

# -------------------------------------------------------------------
# PostgreSQL initialization
# -------------------------------------------------------------------

chown -R postgres:postgres "${PGDATA}"
chmod 700 "${PGDATA}"

if [ ! -s "${PGDATA}/PG_VERSION" ]; then
    log "Initializing PostgreSQL 18..."

    PWFILE="$(mktemp)"
    printf '%s\n' "${DB_PASSWORD}" > "${PWFILE}"
    chown postgres:postgres "${PWFILE}"
    chmod 600 "${PWFILE}"

    su-exec postgres initdb \
        -D "${PGDATA}" \
        --username="${DB_USER}" \
        --pwfile="${PWFILE}" \
        --auth-local=trust \
        --auth-host=scram-sha-256 \
        --encoding=UTF8 \
        --locale=C

    rm -f "${PWFILE}"
fi

# PostgreSQL needs its runtime socket directory on every container start.
install -d -m 2775 -o postgres -g postgres /run/postgresql

log "Starting PostgreSQL..."

su-exec postgres postgres \
    -D "${PGDATA}" \
    -c listen_addresses=127.0.0.1 \
    -c port=5432 &

PG_PID=$!

DB_READY=false

for i in $(seq 1 60); do
    if pg_isready \
        -h 127.0.0.1 \
        -p 5432 \
        -U "${DB_USER}" >/dev/null 2>&1; then
        DB_READY=true
        break
    fi

    if ! kill -0 "${PG_PID}" 2>/dev/null; then
        log "ERROR: PostgreSQL exited during startup."
        wait "${PG_PID}" || true
        exit 1
    fi

    sleep 1
done

if [ "${DB_READY}" != "true" ]; then
    log "ERROR: PostgreSQL did not become ready."
    exit 1
fi

log "PostgreSQL is ready."

# Create SparkyFitness database on first run.
if ! PGPASSWORD="${DB_PASSWORD}" \
    psql \
      -h 127.0.0.1 \
      -p 5432 \
      -U "${DB_USER}" \
      -d postgres \
      -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" \
      | grep -qx '1'; then

    log "Creating database ${DB_NAME}..."

    PGPASSWORD="${DB_PASSWORD}" \
      createdb \
        -h 127.0.0.1 \
        -p 5432 \
        -U "${DB_USER}" \
        -O "${DB_USER}" \
        "${DB_NAME}"
fi

# -------------------------------------------------------------------
# SparkyFitness environment
# -------------------------------------------------------------------

export TZ="${TZ_VALUE}"
export NODE_ENV="production"

export SPARKY_FITNESS_DB_HOST="127.0.0.1"
export SPARKY_FITNESS_DB_PORT="5432"
export SPARKY_FITNESS_DB_NAME="${DB_NAME}"
export SPARKY_FITNESS_DB_USER="${DB_USER}"
export SPARKY_FITNESS_DB_PASSWORD="${DB_PASSWORD}"

export SPARKY_FITNESS_APP_DB_USER="${APP_DB_USER}"
export SPARKY_FITNESS_APP_DB_PASSWORD="${APP_DB_PASSWORD}"

export SPARKY_FITNESS_API_ENCRYPTION_KEY="${API_ENCRYPTION_KEY}"
export BETTER_AUTH_SECRET="${BETTER_AUTH_SECRET_VALUE}"

export SPARKY_FITNESS_FRONTEND_URL="${FRONTEND_URL}"
export BETTER_AUTH_URL="${FRONTEND_URL}"

export SPARKY_FITNESS_SERVER_PORT="3010"
export SPARKY_FITNESS_LOG_LEVEL="${LOG_LEVEL}"

export SPARKY_FITNESS_CUSTOM_UPLOADS_DIRECTORY="/data/uploads"
export SPARKY_FITNESS_CUSTOM_BACKUP_DIRECTORY="/data/backup"

export SPARKY_FITNESS_FORCE_EMAIL_LOGIN="true"
export SPARKY_FITNESS_PUBLIC_API_DOCS="false"

# nginx talks to the backend inside this same container.
export SPARKY_FITNESS_SERVER_HOST="127.0.0.1"
export NGINX_RATE_LIMIT="${NGINX_RATE_LIMIT_VALUE}"
export NGINX_LISTEN_PORT="80"
export NGINX_ACCESS_LOG="/dev/stdout"
export NGINX_ERROR_LOG="/dev/stderr"
export NGINX_DUMP_CONFIG="false"

# -------------------------------------------------------------------
# Backend
# -------------------------------------------------------------------

log "Starting SparkyFitness backend..."

(
    cd /app/SparkyFitnessServer
    exec ./node_modules/.bin/tsx index.ts
) &

SERVER_PID=$!

SERVER_READY=false

for i in $(seq 1 120); do
    if curl -fsS \
        http://127.0.0.1:3010/api/health \
        >/dev/null 2>&1; then
        SERVER_READY=true
        break
    fi

    if ! kill -0 "${SERVER_PID}" 2>/dev/null; then
        log "ERROR: SparkyFitness backend exited during startup."
        wait "${SERVER_PID}" || true
        exit 1
    fi

    sleep 1
done

if [ "${SERVER_READY}" != "true" ]; then
    log "ERROR: SparkyFitness backend did not become healthy."
    exit 1
fi

log "SparkyFitness backend is healthy."

# -------------------------------------------------------------------
# nginx frontend
# -------------------------------------------------------------------

mkdir -p \
    /etc/nginx/conf.d \
    /run/nginx \
    /var/cache/nginx/client-body \
    /var/cache/nginx/proxy \
    /var/cache/nginx/fastcgi \
    /var/cache/nginx/uwsgi \
    /var/cache/nginx/scgi

envsubst \
    '$SPARKY_FITNESS_SERVER_HOST $SPARKY_FITNESS_SERVER_PORT $NGINX_RATE_LIMIT $SPARKY_FITNESS_FRONTEND_URL $NGINX_LISTEN_PORT $NGINX_ACCESS_LOG $NGINX_ERROR_LOG' \
    < /etc/nginx/templates/default.conf.template \
    > /etc/nginx/conf.d/default.conf

log "Validating nginx configuration..."
nginx -t

log "Starting SparkyFitness frontend..."
nginx -g 'daemon off;' &

NGINX_PID=$!

cleanup() {
    log "Stopping SparkyFitness..."

    kill -TERM "${NGINX_PID:-}" 2>/dev/null || true
    kill -TERM "${SERVER_PID:-}" 2>/dev/null || true
    kill -TERM "${PG_PID:-}" 2>/dev/null || true

    wait "${NGINX_PID:-}" 2>/dev/null || true
    wait "${SERVER_PID:-}" 2>/dev/null || true
    wait "${PG_PID:-}" 2>/dev/null || true
}

trap 'cleanup; exit 0' SIGTERM SIGINT

log "SparkyFitness is ready."
log "Web UI: ${FRONTEND_URL}"

set +e
wait -n "${PG_PID}" "${SERVER_PID}" "${NGINX_PID}"
EXIT_CODE=$?
set -e

log "A SparkyFitness service exited unexpectedly."

cleanup

if [ "${EXIT_CODE}" -eq 0 ]; then
    EXIT_CODE=1
fi

exit "${EXIT_CODE}"
