#!/usr/bin/env bash
set -Eeuo pipefail

# Run from any directory: ./scripts/test-upgrade.sh [--fresh | --upgrade BACKUP | --all BACKUP]
usage() { echo "Usage: $0 --fresh | --upgrade /path/to/backup.tar.gz | --all /path/to/backup.tar.gz"; exit 2; }
MODE=${1:---fresh}
BACKUP=${2:-}
case "$MODE" in --fresh) [[ $# -eq 1 || $# -eq 0 ]] || usage;; --upgrade|--all) [[ $# -eq 2 && -f "$BACKUP" ]] || usage; BACKUP=$(realpath "$BACKUP");; *) usage;; esac
for tool in docker curl tar mktemp grep awk; do command -v "$tool" >/dev/null || { echo "Missing $tool" >&2; exit 1; }; done
docker info >/dev/null 2>&1 || { echo 'Docker daemon unavailable' >&2; exit 1; }
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[[ -f "$ROOT/sparkyfitness/Dockerfile" && -f "$ROOT/sparkyfitness/config.yaml" ]] || { echo 'Repository structure not found' >&2; exit 1; }
VERSION=$(sed -n 's/^version: *"\([^"]*\)".*/\1/p' "$ROOT/sparkyfitness/config.yaml" | head -1)
[[ -n "$VERSION" ]] || { echo 'Unable to determine app version' >&2; exit 1; }
RUN_ID="sfcheck-$(date +%Y%m%d%H%M%S)-$$"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/${RUN_ID}.XXXXXX")
chmod 711 "$WORK"
IMAGE="ha-sparkyfitness:validation-${RUN_ID}"
REPORT="$ROOT/sparkyfitness-validation-${RUN_ID}.log"
: > "$REPORT"; chmod 600 "$REPORT"
exec > >(tee -a "$REPORT") 2>&1
containers=()
cleanup() {
  status=$?
  trap - EXIT
  if (( status != 0 )); then echo "FAIL (exit $status). Report: $REPORT"; else echo "PASS. Report: $REPORT"; fi
  for c in "${containers[@]}"; do docker rm -f "$c" >/dev/null 2>&1 || true; done
  # Contains potentially sensitive production data. Always remove temporary copies.
  # PostgreSQL files are owned by the container postgres user. Remove via Docker root.
  docker run --rm --network none --entrypoint /bin/sh -v "$WORK:/work" "$IMAGE" -c 'rm -rf /work/fresh /work/upgrade /work/archive' >/dev/null 2>&1 || true
  rm -rf -- "$WORK" || echo "WARNING: Could not fully remove $WORK" >&2
  docker image rm "$IMAGE" >/dev/null 2>&1 || true
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*" >&2; exit 1; }
wait_healthy() {
  local name=$1 i
  for i in $(seq 1 180); do
    if docker exec "$name" curl -fsS http://127.0.0.1/api/health >/dev/null 2>&1; then
      docker exec "$name" curl -fsS http://127.0.0.1/api/health
      pass "$name HTTP API health"
      return
    fi
    [[ $(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null) == true ]] || { docker logs --tail 120 "$name"; fail "$name exited"; }
    sleep 2
  done
  docker logs --tail 120 "$name"
  fail "$name health timeout"
}
start_app() {
  local name=$1 data=$2
  printf '{"frontend_url":"http://localhost","timezone":"Australia/Sydney","log_level":"ERROR","force_email_login":true}\n' > "$data/options.json"
  docker run -d --name "$name" --network none -v "$data:/data" "$IMAGE" >/dev/null
  containers+=("$name")
  # Network none deliberately blocks external access; loopback inside container still works.
  wait_healthy "$name"
  docker exec "$name" nginx -t
  pass "$name nginx config"
}

echo "SparkyFitness validation: $VERSION ($MODE)"
echo "Work directory: temporary, removed on exit"
[[ $(docker info --format '{{.OSType}}') == linux ]] || fail 'Requires Linux Docker'
docker build --pull --build-arg "BUILD_VERSION=$VERSION" --build-arg BUILD_ARCH=amd64 -t "$IMAGE" "$ROOT/sparkyfitness"
[[ $(docker image inspect "$IMAGE" --format '{{.Architecture}}') == amd64 ]] || fail 'Image is not amd64'
pass 'Docker build and amd64 image'
docker run --rm --entrypoint /bin/bash "$IMAGE" -n /run.sh
docker run --rm --entrypoint /bin/bash "$IMAGE" -n /backup.sh
pass 'Shell syntax'

if [[ "$MODE" == --fresh || "$MODE" == --all ]]; then
  mkdir -p "$WORK/fresh"; chmod 755 "$WORK/fresh"
  fresh="$RUN_ID-fresh"
  start_app "$fresh" "$WORK/fresh"
  docker exec "$fresh" /backup.sh
  docker exec "$fresh" /bin/sh -c 'find /data/backup -name "sparkyfitness-*.tar.gz" -type f | grep -q .' || fail 'Backup not generated'
  pass 'Fresh install and backup generation'
fi

if [[ "$MODE" == --upgrade || "$MODE" == --all ]]; then
  mkdir -p "$WORK/upgrade" "$WORK/archive"; chmod 755 "$WORK/upgrade"; chmod 700 "$WORK/archive"
  tar -tzf "$BACKUP" >/dev/null || fail 'Invalid backup archive'
  tar -xzf "$BACKUP" -C "$WORK/archive" --no-same-owner --no-same-permissions
  [[ -s "$WORK/archive/database.dump" && -f "$WORK/archive/secrets.tar.gz" ]] || fail 'Backup missing database or secrets'
  tar -xzf "$WORK/archive/secrets.tar.gz" -C "$WORK/upgrade" --no-same-owner --no-same-permissions
  [[ -s "$WORK/upgrade/secrets/db_password" ]] || fail 'Backup missing db_password'
  mkdir -p "$WORK/upgrade/postgresql" "$WORK/upgrade/uploads"
  if [[ -f "$WORK/archive/uploads.tar.gz" ]]; then tar -xzf "$WORK/archive/uploads.tar.gz" -C "$WORK/upgrade" --no-same-owner --no-same-permissions; fi
  # Bootstrap the database without starting the new backend, so migrations cannot run before the restore.
  cp "$WORK/archive/database.dump" "$WORK/upgrade/database.dump"
  init="$RUN_ID-init"
  docker run --name "$init" --network none -v "$WORK/upgrade:/data" --entrypoint /bin/bash "$IMAGE" -c '
    set -Eeuo pipefail
    mkdir -p /data/postgresql /run/postgresql
    chown -R postgres:postgres /data/postgresql /run/postgresql
    chmod 700 /data/postgresql
    cp /data/secrets/db_password /tmp/dbpw
    chown postgres:postgres /tmp/dbpw; chmod 600 /tmp/dbpw
    su-exec postgres initdb -D /data/postgresql --username=sparky --pwfile=/tmp/dbpw --auth-local=trust --auth-host=scram-sha-256 --encoding=UTF8 --locale=C >/dev/null
    rm -f /tmp/dbpw
    su-exec postgres pg_ctl -D /data/postgresql -o "-c listen_addresses=127.0.0.1" -w start >/dev/null
    su-exec postgres createdb -U sparky -O sparky sparkyfitness_db
    pg_restore -U sparky -d sparkyfitness_db --no-owner --no-acl /data/database.dump
    su-exec postgres pg_ctl -D /data/postgresql -m fast -w stop >/dev/null
  ' >/dev/null
  containers+=("$init")
  # Remove the stopped bootstrap container.
  docker rm "$init" >/dev/null; containers=("${containers[@]/$init/}")
  pass 'Production backup restored to isolated PostgreSQL'
  upgrade="$RUN_ID-upgrade"
  start_app "$upgrade" "$WORK/upgrade"
  docker exec "$upgrade" /backup.sh
  pass 'Upgrade migrations and post-upgrade backup'
fi
