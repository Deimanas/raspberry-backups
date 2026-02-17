#!/usr/bin/env bash
set -euo pipefail

# Exit codes
readonly EXIT_OK=0
readonly EXIT_CONFIG=10
readonly EXIT_DISK=20
readonly EXIT_RUNTIME=30
readonly EXIT_DOCKER=40

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ENV_FILE:-${ROOT_DIR}/.env}"
DRY_RUN=false
FORCE_WEEKLY=false

# Default reikšmės (naudojamos jeigu .env nėra)
BACKUP_BASE_DIR="${BACKUP_BASE_DIR:-/backups}"
LOG_DIR="${LOG_DIR:-${ROOT_DIR}/logs}"
RETENTION_DAILY_DAYS="${RETENTION_DAILY_DAYS:-7}"
RETENTION_WEEKLY_WEEKS="${RETENTION_WEEKLY_WEEKS:-4}"
MIN_FREE_MB="${MIN_FREE_MB:-2048}"
COMPRESSION="${COMPRESSION:-gzip}"
STOP_CONTAINERS="${STOP_CONTAINERS:-true}"
DB_DUMP_TIMEOUT="${DB_DUMP_TIMEOUT:-300}"
VOLUME_BACKUP_TIMEOUT="${VOLUME_BACKUP_TIMEOUT:-1800}"
EXCLUDE_CONTAINERS="${EXCLUDE_CONTAINERS:-}"
EXCLUDE_VOLUMES="${EXCLUDE_VOLUMES:-}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-}"
MYSQL_DATABASE="${MYSQL_DATABASE:-}"
POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"
POSTGRES_DB="${POSTGRES_DB:-postgres}"
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
DISCORD_NOTIFY_ON_SUCCESS="${DISCORD_NOTIFY_ON_SUCCESS:-false}"
DISCORD_NOTIFY_ON_ERROR="${DISCORD_NOTIFY_ON_ERROR:-true}"
SERVER_NAME="${SERVER_NAME:-docker-host}"

if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
  shift
fi
if [[ "${1:-}" == "--force-weekly" ]]; then
  FORCE_WEEKLY=true
  shift
fi

if [[ "${1:-}" == "--env-file" ]]; then
  ENV_FILE="${2:-}"
  shift 2
fi

if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
else
  echo "[WARN] ENV failas nerastas (${ENV_FILE}), naudojamos numatytos reikšmės ir esami shell ENV." >&2
fi

if [[ "${COMPRESSION}" != "gzip" && "${COMPRESSION}" != "zstd" ]]; then
  echo "KLAIDA: COMPRESSION turi būti 'gzip' arba 'zstd' (dabar: ${COMPRESSION})" >&2
  exit "${EXIT_CONFIG}"
fi

mkdir -p "${BACKUP_BASE_DIR}" "${LOG_DIR}"

RUN_TS="$(date +%F_%H-%M)"
RUN_START_EPOCH="$(date +%s)"
RUN_DIR="${BACKUP_BASE_DIR}/${RUN_TS}"
CURRENT_LINK="${BACKUP_BASE_DIR}/latest"
LOG_FILE="${LOG_DIR}/backup-${RUN_TS}.log"
META_FILE="${RUN_DIR}/metadata.env"

COLOR_RESET='\033[0m'
COLOR_INFO='\033[1;34m'
COLOR_OK='\033[1;32m'
COLOR_WARN='\033[1;33m'
COLOR_ERR='\033[1;31m'

log() {
  local level="$1"
  local color="$2"
  shift 2
  local msg="$*"
  local line="[$(date +'%F %T')] [$level] ${msg}"
  echo -e "${color}${line}${COLOR_RESET}" | tee -a "${LOG_FILE}"
}

log_info() { log INFO "${COLOR_INFO}" "$*"; }
log_ok() { log SUCCESS "${COLOR_OK}" "$*"; }
log_warn() { log WARN "${COLOR_WARN}" "$*"; }
log_err() { log ERROR "${COLOR_ERR}" "$*"; }

run_cmd() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_warn "DRY-RUN: $*"
    return 0
  fi
  "$@"
}

discord_notify() {
  local status="$1"
  local message="$2"
  if [[ -z "${DISCORD_WEBHOOK_URL:-}" ]]; then
    return 0
  fi

  local send=false
  if [[ "${status}" == "success" && "${DISCORD_NOTIFY_ON_SUCCESS:-false}" == "true" ]]; then
    send=true
  fi
  if [[ "${status}" == "error" && "${DISCORD_NOTIFY_ON_ERROR:-true}" == "true" ]]; then
    send=true
  fi

  if [[ "${send}" != "true" ]]; then
    return 0
  fi

  local payload
  payload=$(printf '{"content":"[%s] %s"}' "${SERVER_NAME:-docker-host}" "${message}")
  curl -sS -X POST -H 'Content-Type: application/json' -d "${payload}" "${DISCORD_WEBHOOK_URL}" >/dev/null || true
}

on_error() {
  local line="$1"
  local code="$2"
  log_err "Backup nutrūko. Eilutė: ${line}, kodas: ${code}"
  discord_notify error "Backup klaida (${RUN_TS}), code=${code}, line=${line}. Žr. ${LOG_FILE}"
  exit "${EXIT_RUNTIME}"
}
trap 'on_error ${LINENO} $?' ERR

log_info "Backup pradėtas. RUN_DIR=${RUN_DIR}, DRY_RUN=${DRY_RUN}"
mkdir -p "${RUN_DIR}" "${RUN_DIR}/containers" "${RUN_DIR}/databases"

free_mb=$(df -Pm "${BACKUP_BASE_DIR}" | awk 'NR==2 {print $4}')
if (( free_mb < MIN_FREE_MB )); then
  log_err "Per mažai laisvos vietos: ${free_mb}MB < ${MIN_FREE_MB}MB"
  discord_notify error "Backup nepradėtas: trūksta vietos (${free_mb}MB < ${MIN_FREE_MB}MB)."
  exit "${EXIT_DISK}"
fi

if ! command -v docker >/dev/null 2>&1; then
  log_err "docker komanda nerasta"
  exit "${EXIT_DOCKER}"
fi

mapfile -t containers < <(docker ps --format '{{.Names}}')
if (( ${#containers[@]} == 0 )); then
  log_warn "Aktyvių containerių nerasta."
fi

IFS=',' read -r -a excluded_containers <<<"${EXCLUDE_CONTAINERS:-}"
IFS=',' read -r -a excluded_volumes <<<"${EXCLUDE_VOLUMES:-}"

is_excluded() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    item="${item// /}"
    [[ -z "${item}" ]] && continue
    [[ "${needle}" == "${item}" ]] && return 0
  done
  return 1
}

compress_ext="tar.gz"
compress_args=(-czf)
if [[ "${COMPRESSION}" == "zstd" ]]; then
  compress_ext="tar.zst"
  compress_args=(--zstd -cf)
fi

backup_container_volumes() {
  local container="$1"
  local cdir="${RUN_DIR}/containers/${container}"
  mkdir -p "${cdir}"

  mapfile -t vols < <(docker inspect -f '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}} {{.Destination}}{{println}}{{end}}{{end}}' "${container}" | awk 'NF')
  if (( ${#vols[@]} == 0 )); then
    log_warn "${container}: volume mountų nerasta, praleidžiama."
    return 0
  fi

  if [[ "${STOP_CONTAINERS}" == "true" ]]; then
    log_info "${container}: stabdomas prieš volume backup"
    run_cmd docker stop "${container}" >/dev/null
  fi

  local vol_line vol_name vol_dest archive
  for vol_line in "${vols[@]}"; do
    vol_name="$(awk '{print $1}' <<<"${vol_line}")"
    vol_dest="$(awk '{print $2}' <<<"${vol_line}")"

    if is_excluded "${vol_name}" "${excluded_volumes[@]}"; then
      log_warn "${container}: volume ${vol_name} excluded"
      continue
    fi

    archive="${cdir}/volume-${vol_name}.${compress_ext}"
    log_info "${container}: backup volume ${vol_name} (${vol_dest}) -> ${archive}"
    run_cmd timeout "${VOLUME_BACKUP_TIMEOUT}" docker run --rm \
      -v "${vol_name}:/source:ro" \
      -v "${cdir}:/dest" \
      alpine sh -c "tar ${compress_args[*]} /dest/volume-${vol_name}.${compress_ext} -C /source ."
  done

  if [[ "${STOP_CONTAINERS}" == "true" ]]; then
    log_info "${container}: paleidžiamas po volume backup"
    run_cmd docker start "${container}" >/dev/null
  fi
}

detect_db_type() {
  local container="$1"
  local image
  image=$(docker inspect -f '{{.Config.Image}}' "${container}" | tr '[:upper:]' '[:lower:]')

  if [[ "${image}" == *mariadb* || "${image}" == *mysql* ]]; then
    echo mysql
    return 0
  fi
  if [[ "${image}" == *postgres* ]]; then
    echo postgres
    return 0
  fi

  local env_dump
  env_dump=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${container}" || true)
  if grep -Eq 'MYSQL_|MARIADB_' <<<"${env_dump}"; then
    echo mysql
    return 0
  fi
  if grep -q 'POSTGRES_' <<<"${env_dump}"; then
    echo postgres
    return 0
  fi

  echo none
}

db_dump_mysql() {
  local container="$1"
  local out_file="$2"
  local env_dump db_user db_pass db_name
  env_dump=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${container}")

  db_user=$(awk -F= '/^(MYSQL_USER|MARIADB_USER)=/{print $2; exit}' <<<"${env_dump}" || true)
  db_user="${db_user:-${MYSQL_USER:-root}}"

  db_pass=$(awk -F= '/^(MYSQL_PASSWORD|MYSQL_ROOT_PASSWORD|MARIADB_PASSWORD|MARIADB_ROOT_PASSWORD)=/{print $2; exit}' <<<"${env_dump}" || true)
  db_pass="${db_pass:-${MYSQL_PASSWORD:-}}"

  db_name=$(awk -F= '/^(MYSQL_DATABASE|MARIADB_DATABASE)=/{print $2; exit}' <<<"${env_dump}" || true)
  db_name="${db_name:-${MYSQL_DATABASE:-}}"

  local db_clause="--all-databases"
  if [[ -n "${db_name}" ]]; then
    db_clause="--databases ${db_name}"
  fi

  local pass_arg=()
  if [[ -n "${db_pass}" ]]; then
    pass_arg=(-p"${db_pass}")
  fi

  log_info "${container}: kuriamas MySQL/MariaDB dump -> ${out_file}"
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_warn "DRY-RUN: docker exec ${container} mysqldump ..."
    return 0
  fi

  timeout "${DB_DUMP_TIMEOUT}" docker exec "${container}" sh -c \
    "mysqldump -u '${db_user}' ${pass_arg[*]-} --single-transaction --quick --routines --events ${db_clause}" > "${out_file}"
}

db_dump_postgres() {
  local container="$1"
  local out_file="$2"
  local env_dump db_user db_pass db_name
  env_dump=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${container}")

  db_user=$(awk -F= '/^POSTGRES_USER=/{print $2; exit}' <<<"${env_dump}" || true)
  db_user="${db_user:-${POSTGRES_USER:-postgres}}"

  db_pass=$(awk -F= '/^POSTGRES_PASSWORD=/{print $2; exit}' <<<"${env_dump}" || true)
  db_pass="${db_pass:-${POSTGRES_PASSWORD:-}}"

  db_name=$(awk -F= '/^POSTGRES_DB=/{print $2; exit}' <<<"${env_dump}" || true)
  db_name="${db_name:-${POSTGRES_DB:-postgres}}"

  log_info "${container}: kuriamas PostgreSQL dump -> ${out_file}"
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_warn "DRY-RUN: docker exec ${container} pg_dump ..."
    return 0
  fi

  timeout "${DB_DUMP_TIMEOUT}" docker exec -e "PGPASSWORD=${db_pass}" "${container}" \
    pg_dump -U "${db_user}" -d "${db_name}" -Fc > "${out_file}"
}

for container in "${containers[@]}"; do
  if is_excluded "${container}" "${excluded_containers[@]}"; then
    log_warn "${container}: container excluded"
    continue
  fi

  log_info "Apdorojamas container: ${container}"
  backup_container_volumes "${container}"

  db_type="$(detect_db_type "${container}")"
  case "${db_type}" in
    mysql)
      db_dump_mysql "${container}" "${RUN_DIR}/databases/${container}-mysql.sql"
      ;;
    postgres)
      db_dump_postgres "${container}" "${RUN_DIR}/databases/${container}-postgres.dump"
      ;;
    none)
      log_info "${container}: DB tipo neaptikta"
      ;;
  esac

  log_ok "${container}: backup completed"
done

ln -sfn "${RUN_DIR}" "${CURRENT_LINK}"

is_weekly=false
if [[ "${FORCE_WEEKLY}" == "true" || "$(date +%u)" == "7" ]]; then
  is_weekly=true
fi

find "${BACKUP_BASE_DIR}" -mindepth 1 -maxdepth 1 -type d -name '20??-??-??_??-??' -mtime "+${RETENTION_DAILY_DAYS}" -print0 | while IFS= read -r -d '' old; do
  if [[ "${is_weekly}" == "true" ]]; then
    week_dir="${BACKUP_BASE_DIR}/weekly"
    mkdir -p "${week_dir}"
    bname="$(basename "${old}")"
    if [[ ! -d "${week_dir}/${bname}" ]]; then
      log_info "Perkeliama į weekly: ${old}"
      run_cmd mv "${old}" "${week_dir}/${bname}"
    fi
  else
    log_info "Šalinamas pasenęs daily backup: ${old}"
    run_cmd rm -rf "${old}"
  fi
done

mkdir -p "${BACKUP_BASE_DIR}/weekly"
find "${BACKUP_BASE_DIR}/weekly" -mindepth 1 -maxdepth 1 -type d -mtime "+$((RETENTION_WEEKLY_WEEKS * 7))" -print0 | while IFS= read -r -d '' old_weekly; do
  log_info "Šalinamas pasenęs weekly backup: ${old_weekly}"
  run_cmd rm -rf "${old_weekly}"
done

RUN_END_EPOCH="$(date +%s)"
DURATION="$((RUN_END_EPOCH - RUN_START_EPOCH))"

{
  echo "RUN_TS=${RUN_TS}"
  echo "RUN_DIR=${RUN_DIR}"
  echo "DURATION=${DURATION}"
  echo "SERVER_NAME=${SERVER_NAME:-docker-host}"
  echo "DRY_RUN=${DRY_RUN}"
} > "${META_FILE}"

log_ok "Backup baigtas sėkmingai per ${DURATION}s"
discord_notify success "Backup sėkmingas (${RUN_TS}) per ${DURATION}s."
exit "${EXIT_OK}"
