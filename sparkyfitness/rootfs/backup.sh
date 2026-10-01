#!/usr/bin/env bash
set -Eeuo pipefail

BACKUP_DIR="/data/backup"
SECRET_DIR="/data/secrets"
DB_NAME="sparkyfitness_db"
DB_USER="sparky"

STAMP="$(date '+%Y%m%d-%H%M%S')"
TMP_DIR="${BACKUP_DIR}/.backup-${STAMP}-$$"
BACKUP_FILE="${BACKUP_DIR}/sparkyfitness-${STAMP}.tar.gz"

log() {
    echo "[ha-sparkyfitness-backup] $*"
}

cleanup() {
    rm -rf "${TMP_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "${BACKUP_DIR}" "${TMP_DIR}"
chmod 700 "${BACKUP_DIR}" "${TMP_DIR}"

if [ ! -s "${SECRET_DIR}/db_password" ]; then
    log "ERROR: Database password is missing."
    exit 1
fi

log "Creating PostgreSQL backup..."

export PGPASSWORD
PGPASSWORD="$(cat "${SECRET_DIR}/db_password")"

pg_dump \
    -h 127.0.0.1 \
    -p 5432 \
    -U "${DB_USER}" \
    -d "${DB_NAME}" \
    --format=custom \
    --file="${TMP_DIR}/database.dump"

unset PGPASSWORD

log "Backing up uploads..."

if [ -d /data/uploads ]; then
    tar -C /data -czf "${TMP_DIR}/uploads.tar.gz" uploads
fi

log "Backing up persistent secrets..."

tar -C /data -czf "${TMP_DIR}/secrets.tar.gz" secrets

if [ -f /data/options.json ]; then
    cp /data/options.json "${TMP_DIR}/options.json"
fi

cat > "${TMP_DIR}/metadata.txt" <<META
created=$(date -Iseconds)
database=${DB_NAME}
postgres_version=$(postgres --version)
app=ha-sparkyfitness
META

log "Creating backup bundle..."

tar -C "${TMP_DIR}" -czf "${BACKUP_FILE}.tmp" .
mv "${BACKUP_FILE}.tmp" "${BACKUP_FILE}"
chmod 600 "${BACKUP_FILE}"

log "Backup complete:"
log "${BACKUP_FILE}"

ls -lh "${BACKUP_FILE}"
