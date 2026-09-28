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

PG_PID=""
SERVER_PID=""
NGINX_PID=""
CLEANED_UP=0
EXIT_RECORDED=0
EXIT_LOG="/data/last_exit.log"

cleanup() {
    if [ "${CLEANED_UP}" = "1" ]; then
        return
    fi

    CLEANED_UP=1
    set +e

    log "Stopping SparkyFitness services..."

    # Stop accepting web requests first.
    if [ -n "${NGINX_PID}" ] && kill -0 "${NGINX_PID}" 2>/dev/null; then
        kill -QUIT "${NGINX_PID}" 2>/dev/null || true

        for _ in $(seq 1 10); do
            kill -0 "${NGINX_PID}" 2>/dev/null || break
            sleep 1
        done

        kill -TERM "${NGINX_PID}" 2>/dev/null || true
    fi

    # Stop the backend before PostgreSQL.
    if [ -n "${SERVER_PID}" ] && kill -0 "${SERVER_PID}" 2>/dev/null; then
        kill -TERM "${SERVER_PID}" 2>/dev/null || true

        for _ in $(seq 1 15); do
            kill -0 "${SERVER_PID}" 2>/dev/null || break
            sleep 1
        done

        if kill -0 "${SERVER_PID}" 2>/dev/null; then
            log "Backend did not stop in time; killing it."
            kill -KILL "${SERVER_PID}" 2>/dev/null || true
        fi
    fi

    # Explicit fast PostgreSQL shutdown so updates/restarts do not leave
    # the database requiring crash recovery.
    if [ -n "${PG_PID}" ] && kill -0 "${PG_PID}" 2>/dev/null; then
        log "Stopping PostgreSQL cleanly..."

        su-exec postgres pg_ctl             -D "${PGDATA}"             -m fast             -w             -t 30             stop || kill -INT "${PG_PID}" 2>/dev/null || true
    fi

    log "Shutdown complete."
}

record_exit() {
    local reason="${1:-unknown}"
    local detail="${2:-}"
    local tmp="${EXIT_LOG}.tmp"

    {
        printf 'timestamp=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf 'reason=%s\n' "${reason}"
        printf 'detail=%s\n' "${detail}"

        if [ -n "${PG_PID}" ]; then
            if kill -0 "${PG_PID}" 2>/dev/null; then
                printf 'postgresql_pid=%s state=running\n' "${PG_PID}"
            else
                printf 'postgresql_pid=%s state=stopped\n' "${PG_PID}"
            fi
        else
            printf 'postgresql_pid=not_started\n'
        fi

        if [ -n "${SERVER_PID}" ]; then
            if kill -0 "${SERVER_PID}" 2>/dev/null; then
                printf 'backend_pid=%s state=running\n' "${SERVER_PID}"
            else
                printf 'backend_pid=%s state=stopped\n' "${SERVER_PID}"
            fi
        else
            printf 'backend_pid=not_started\n'
        fi

        if [ -n "${NGINX_PID}" ]; then
            if kill -0 "${NGINX_PID}" 2>/dev/null; then
                printf 'nginx_pid=%s state=running\n' "${NGINX_PID}"
            else
                printf 'nginx_pid=%s state=stopped\n' "${NGINX_PID}"
            fi
        else
            printf 'nginx_pid=not_started\n'
        fi
    } > "${tmp}"

    mv "${tmp}" "${EXIT_LOG}"
    EXIT_RECORDED=1
}

on_sigterm() {
    record_exit "external_stop" "signal=SIGTERM"
    exit 0
}

on_sigint() {
    record_exit "external_stop" "signal=SIGINT"
    exit 0
}

on_exit() {
    local status=$?

    # Prevent recursion when this function exits.
    trap - EXIT

    # Catch startup/script failures which did not reach the process
    # supervision section.
    if [ "${EXIT_RECORDED}" = "0" ]; then
        if [ "${status}" -eq 0 ]; then
            record_exit "script_exit" "exit_code=${status}"
        else
            record_exit "script_error" "exit_code=${status}"
        fi
    fi

    cleanup
    exit "${status}"
}

trap on_exit EXIT
trap on_sigterm SIGTERM
trap on_sigint SIGINT

get_option() {
    local key="$1"

    if [ -f "${OPTIONS_FILE}" ]; then
        jq -r --arg key "${key}" \
          'if has($key) and .[$key] != null then .[$key] else "" end' \
          "${OPTIONS_FILE}" 2>/dev/null || true
    fi
}

FRONTEND_URL="$(get_option frontend_url)"
EXTRA_TRUSTED_ORIGINS="$(get_option extra_trusted_origins)"
TZ_VALUE="$(get_option timezone)"
LOG_LEVEL="$(get_option log_level)"
NGINX_RATE_LIMIT_VALUE="$(get_option nginx_rate_limit)"
FORCE_EMAIL_LOGIN="$(get_option force_email_login)"
REAL_IP_HEADER="$(get_option real_ip_header)"

if [ -z "${FRONTEND_URL}" ]; then
    log "ERROR: frontend_url is not configured."
    log "Set Frontend URL in the Home Assistant App configuration."
    log "Example: https://fitness.example.com"
    exit 1
fi

case "${FRONTEND_URL}" in
    http://*|https://*)
        ;;
    *)
        log "ERROR: frontend_url must start with http:// or https://"
        exit 1
        ;;
esac

[ -n "${TZ_VALUE}" ] || TZ_VALUE="Etc/UTC"
[ -n "${LOG_LEVEL}" ] || LOG_LEVEL="ERROR"
[ -n "${NGINX_RATE_LIMIT_VALUE}" ] || NGINX_RATE_LIMIT_VALUE="5r/s"
[ -n "${FORCE_EMAIL_LOGIN}" ] || FORCE_EMAIL_LOGIN="true"

# Remove trailing slash from the primary origin.
FRONTEND_URL="${FRONTEND_URL%/}"

# The primary frontend must always be trusted by Better Auth.
TRUSTED_ORIGINS="${FRONTEND_URL}"

# Additional comma-separated origins can be supplied for LAN access,
# reverse proxies, alternate hostnames, etc.
if [ -n "${EXTRA_TRUSTED_ORIGINS}" ]; then
    TRUSTED_ORIGINS="${TRUSTED_ORIGINS},${EXTRA_TRUSTED_ORIGINS}"
fi

log "Frontend URL: ${FRONTEND_URL}"
log "Trusted origins: ${TRUSTED_ORIGINS}"
log "Timezone: ${TZ_VALUE}"
log "Log level: ${LOG_LEVEL}"
log "Force email login: ${FORCE_EMAIL_LOGIN}"
if [ -n "${REAL_IP_HEADER}" ]; then
    log "Real IP header: ${REAL_IP_HEADER}"
else
    log "Real IP header: not configured"
fi

mkdir -p \
    "${PGDATA}" \
    "${SECRET_DIR}" \
    /data/uploads \
    /data/backup

chmod 700 "${SECRET_DIR}"

if [ -s "${EXIT_LOG}" ]; then
    log "Previous exit diagnostic:"
    while IFS= read -r line; do
        log "  ${line}"
    done < "${EXIT_LOG}"
fi

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
export SPARKY_FITNESS_EXTRA_TRUSTED_ORIGINS="${TRUSTED_ORIGINS}"
export SPARKY_FITNESS_FORCE_EMAIL_LOGIN="${FORCE_EMAIL_LOGIN}"

if [ -n "${REAL_IP_HEADER}" ]; then
    export SPARKY_FITNESS_REAL_IP_HEADER="${REAL_IP_HEADER}"
else
    unset SPARKY_FITNESS_REAL_IP_HEADER 2>/dev/null || true
fi
export BETTER_AUTH_URL="${FRONTEND_URL}"

export SPARKY_FITNESS_SERVER_PORT="3010"
export SPARKY_FITNESS_LOG_LEVEL="${LOG_LEVEL}"

export SPARKY_FITNESS_CUSTOM_UPLOADS_DIRECTORY="/data/uploads"
export SPARKY_FITNESS_CUSTOM_BACKUP_DIRECTORY="/data/backup"

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

for i in $(seq 1 300); do
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

# Newer SparkyFitness nginx templates require the container DNS resolver.
NGINX_RESOLVER="$(
    awk '$1 == "nameserver" { print $2; exit }' /etc/resolv.conf
)"

if [ -z "${NGINX_RESOLVER}" ]; then
    NGINX_RESOLVER="127.0.0.11"
fi

export NGINX_RESOLVER
log "Nginx resolver: ${NGINX_RESOLVER}"

envsubst \
    '$SPARKY_FITNESS_SERVER_HOST $SPARKY_FITNESS_SERVER_PORT $NGINX_RATE_LIMIT $SPARKY_FITNESS_FRONTEND_URL $NGINX_LISTEN_PORT $NGINX_ACCESS_LOG $NGINX_ERROR_LOG $NGINX_RESOLVER' \
    < /etc/nginx/templates/default.conf.template \
    > /etc/nginx/conf.d/default.conf

log "Validating nginx configuration..."
nginx -t

log "Starting SparkyFitness frontend..."
nginx -g 'daemon off;' &

NGINX_PID=$!


log "SparkyFitness is ready."
log "Web UI: ${FRONTEND_URL}"

set +e
EXITED_PID=""

wait -n -p EXITED_PID "${PG_PID}" "${SERVER_PID}" "${NGINX_PID}"
CHILD_STATUS=$?

set -e

case "${EXITED_PID:-}" in
    "${PG_PID}")
        EXITED_PROCESS="postgresql"
        ;;
    "${SERVER_PID}")
        EXITED_PROCESS="backend"
        ;;
    "${NGINX_PID}")
        EXITED_PROCESS="nginx"
        ;;
    *)
        EXITED_PROCESS="unknown"
        ;;
esac

record_exit \
    "child_exit" \
    "process=${EXITED_PROCESS} pid=${EXITED_PID:-unknown} exit_code=${CHILD_STATUS}"

log "ERROR: Managed process exited unexpectedly."
log "Process: ${EXITED_PROCESS}"
log "PID: ${EXITED_PID:-unknown}"
log "Exit code: ${CHILD_STATUS}"
log "Diagnostic saved to ${EXIT_LOG}"

# Even if a child exits with status 0, this is unexpected for a
# long-running App, so report failure to Supervisor.
APP_STATUS="${CHILD_STATUS}"
if [ "${APP_STATUS}" -eq 0 ]; then
    APP_STATUS=1
fi

exit "${APP_STATUS}"

