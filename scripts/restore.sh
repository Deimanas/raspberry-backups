#!/usr/bin/env bash
set -euo pipefail

readonly EXIT_OK=0
readonly EXIT_CONFIG=10
readonly EXIT_INPUT=11
readonly EXIT_RUNTIME=30

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ENV_FILE:-${ROOT_DIR}/.env}"

# Default reikšmės jeigu .env nėra
BACKUP_BASE_DIR="${BACKUP_BASE_DIR:-${ROOT_DIR}/backups}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-}"
POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"
POSTGRES_DB="${POSTGRES_DB:-postgres}"

if [[ "${1:-}" == "--env-file" ]]; then
  ENV_FILE="${2:-}"
  shift 2
fi

if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

if [[ $# -lt 2 ]]; then
  cat <<USAGE
Naudojimas:
  $0 <backup_timestamp> <target_container> [--db-only|--volume-only]

Pvz:
  $0 2026-01-05_12-00 wordpress_app
  $0 2026-01-05_12-00 mariadb --db-only
USAGE
  exit "${EXIT_INPUT}"
fi

BACKUP_TS="$1"
TARGET_CONTAINER="$2"
MODE="full"
[[ "${3:-}" == "--db-only" ]] && MODE="db"
[[ "${3:-}" == "--volume-only" ]] && MODE="volume"

RUN_DIR="${BACKUP_BASE_DIR}/${BACKUP_TS}"
CONTAINER_DIR="${RUN_DIR}/containers/${TARGET_CONTAINER}"
DB_MYSQL_FILE="${RUN_DIR}/databases/${TARGET_CONTAINER}-mysql.sql"
DB_PG_FILE="${RUN_DIR}/databases/${TARGET_CONTAINER}-postgres.dump"

if [[ ! -d "${RUN_DIR}" ]]; then
  echo "KLAIDA: backup katalogas nerastas: ${RUN_DIR}"
  exit "${EXIT_INPUT}"
fi

log() { echo "[$(date +'%F %T')] $*"; }

restore_volumes() {
  if [[ ! -d "${CONTAINER_DIR}" ]]; then
    log "Volume backup nerastas: ${CONTAINER_DIR}"
    return 0
  fi

  mapfile -t archives < <(find "${CONTAINER_DIR}" -maxdepth 1 -type f \( -name 'volume-*.tar.gz' -o -name 'volume-*.tar.zst' \))
  if (( ${#archives[@]} == 0 )); then
    log "Volume archyvų nerasta ${TARGET_CONTAINER} konteineriui"
    return 0
  fi

  log "Stabdomas konteineris: ${TARGET_CONTAINER}"
  docker stop "${TARGET_CONTAINER}" >/dev/null || true

  local archive vol_name
  for archive in "${archives[@]}"; do
    vol_name=$(basename "${archive}")
    vol_name="${vol_name#volume-}"
    vol_name="${vol_name%.tar.gz}"
    vol_name="${vol_name%.tar.zst}"

    log "Atkuriamas volume ${vol_name} iš ${archive}"
    if [[ "${archive}" == *.tar.zst ]]; then
      docker run --rm -v "${vol_name}:/target" -v "${CONTAINER_DIR}:/backup:ro" alpine sh -c "apk add --no-cache zstd >/dev/null && tar --zstd -xf /backup/$(basename "${archive}") -C /target"
    else
      docker run --rm -v "${vol_name}:/target" -v "${CONTAINER_DIR}:/backup:ro" alpine sh -c "tar -xzf /backup/$(basename "${archive}") -C /target"
    fi
  done

  log "Paleidžiamas konteineris: ${TARGET_CONTAINER}"
  docker start "${TARGET_CONTAINER}" >/dev/null
}

restore_mysql() {
  [[ -f "${DB_MYSQL_FILE}" ]] || { log "MySQL dump failas nerastas: ${DB_MYSQL_FILE}"; return 0; }

  local env_dump db_user db_pass
  env_dump=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${TARGET_CONTAINER}" || true)
  db_user=$(awk -F= '/^(MYSQL_USER|MARIADB_USER)=/{print $2; exit}' <<<"${env_dump}" || true)
  db_user="${db_user:-${MYSQL_USER:-root}}"
  db_pass=$(awk -F= '/^(MYSQL_PASSWORD|MYSQL_ROOT_PASSWORD|MARIADB_PASSWORD|MARIADB_ROOT_PASSWORD)=/{print $2; exit}' <<<"${env_dump}" || true)
  db_pass="${db_pass:-${MYSQL_PASSWORD:-}}"

  local pass_arg=()
  [[ -n "${db_pass}" ]] && pass_arg=(-p"${db_pass}")

  log "Atkuriamas MySQL/MariaDB dump į ${TARGET_CONTAINER}"
  docker exec -i "${TARGET_CONTAINER}" sh -c "mysql -u '${db_user}' ${pass_arg[*]-}" < "${DB_MYSQL_FILE}"
}

restore_postgres() {
  [[ -f "${DB_PG_FILE}" ]] || { log "Postgres dump failas nerastas: ${DB_PG_FILE}"; return 0; }

  local env_dump db_user db_pass db_name
  env_dump=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${TARGET_CONTAINER}" || true)
  db_user=$(awk -F= '/^POSTGRES_USER=/{print $2; exit}' <<<"${env_dump}" || true)
  db_user="${db_user:-${POSTGRES_USER:-postgres}}"
  db_pass=$(awk -F= '/^POSTGRES_PASSWORD=/{print $2; exit}' <<<"${env_dump}" || true)
  db_pass="${db_pass:-${POSTGRES_PASSWORD:-}}"
  db_name=$(awk -F= '/^POSTGRES_DB=/{print $2; exit}' <<<"${env_dump}" || true)
  db_name="${db_name:-${POSTGRES_DB:-postgres}}"

  log "Atkuriamas PostgreSQL dump į ${TARGET_CONTAINER}/${db_name}"
  docker exec -e "PGPASSWORD=${db_pass}" -i "${TARGET_CONTAINER}" pg_restore -U "${db_user}" -d "${db_name}" --clean --if-exists < "${DB_PG_FILE}"
}

detect_db_type() {
  local image
  image=$(docker inspect -f '{{.Config.Image}}' "${TARGET_CONTAINER}" | tr '[:upper:]' '[:lower:]')
  if [[ "${image}" == *mariadb* || "${image}" == *mysql* ]]; then
    echo mysql
  elif [[ "${image}" == *postgres* ]]; then
    echo postgres
  else
    echo none
  fi
}

if [[ "${MODE}" == "full" || "${MODE}" == "volume" ]]; then
  restore_volumes
fi

if [[ "${MODE}" == "full" || "${MODE}" == "db" ]]; then
  db_type="$(detect_db_type)"
  case "${db_type}" in
    mysql) restore_mysql ;;
    postgres) restore_postgres ;;
    none) log "DB tipas neaptiktas, DB restore praleidžiamas" ;;
  esac
fi

log "Restore baigtas sėkmingai"
exit "${EXIT_OK}"
