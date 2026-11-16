#!/usr/bin/env bash
# Sobe ou atualiza o checkin-discord-bot-v1 na droplet.
# Usa o compose.yml da raiz do bot (mesmo volume do deploy atual)
# e troca o build local pela imagem publicada no GHCR.
set -euo pipefail

if ! command -v flock >/dev/null 2>&1; then
  echo "[deploy] flock não encontrado. Na droplet ele vem do pacote util-linux." >&2
  exit 1
fi

LOCK_FILE="${DEPLOY_LOCK_FILE:-/tmp/checkin-discord-bot-deploy.lock}"
exec 9>"${LOCK_FILE}"
if ! flock -w 300 9; then
  echo "[deploy] Outro deploy ainda está rodando depois de 5 minutos" >&2
  exit 1
fi

read_env() {
  local file="$1"
  local key="$2"
  local line=""

  [[ -f "$file" ]] || return 0
  line="$(grep -E "^[[:space:]]*${key}=" "$file" | tail -n 1 || true)"
  [[ -n "$line" ]] || return 0

  line="${line#*=}"
  line="${line%$'\r'}"

  if [[ "$line" =~ ^\".*\"$ ]] || [[ "$line" =~ ^\'.*\'$ ]]; then
    line="${line:1:${#line}-2}"
  fi

  printf '%s' "$line"
}

if [[ -z "${BOT_DIR:-}" && -n "${COMPOSE_CWD:-}" ]]; then
  if [[ "$(basename "$COMPOSE_CWD")" == "deploy" ]]; then
    BOT_DIR="$(dirname "$COMPOSE_CWD")"
  else
    BOT_DIR="$COMPOSE_CWD"
  fi
fi

BOT_DIR="${BOT_DIR:-/opt/checkin-discord-bot-v1}"
BOT_ENV_FILE="${BOT_ENV_FILE:-${BOT_DIR}/.env}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVERRIDE_FILE="${COMPOSE_OVERRIDE:-${SCRIPT_DIR}/../deploy/checkin-image.override.yml}"
BASE_COMPOSE="${BOT_DIR}/compose.yml"
COMPOSE_SERVICE="${COMPOSE_SERVICE:-app}"
PROJECT_NAME="$(basename "$BOT_DIR")"

if ! docker info >/dev/null 2>&1; then
  echo "[deploy] Este usuário não alcança o Docker. O serviço precisa do grupo docker." >&2
  exit 1
fi

if [[ -n "${GHCR_TOKEN:-}" && -n "${GHCR_USERNAME:-}" ]]; then
  echo "[deploy] Login no GHCR como ${GHCR_USERNAME}"
  printf '%s' "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USERNAME" --password-stdin
fi

if [[ -n "${IMAGE:-}" ]]; then
  if [[ -n "${DOCKER_IMAGE:-}" && "$DOCKER_IMAGE" != "$IMAGE" ]]; then
    echo "[deploy] Imagem do webhook: ${IMAGE}"
    echo "[deploy] DOCKER_IMAGE anterior: ${DOCKER_IMAGE}"
  fi
  DOCKER_IMAGE="$IMAGE"
fi

if [[ -z "${DOCKER_IMAGE:-}" && -n "${PACKAGE_OWNER:-}" && -n "${PACKAGE_NAME:-}" && -n "${IMAGE_TAG:-}" ]]; then
  owner="$(printf '%s' "$PACKAGE_OWNER" | tr '[:upper:]' '[:lower:]')"
  name="$(printf '%s' "$PACKAGE_NAME" | tr '[:upper:]' '[:lower:]')"
  DOCKER_IMAGE="ghcr.io/${owner}/${name}:${IMAGE_TAG}"
fi

export DOCKER_IMAGE

if [[ ! -f "$BASE_COMPOSE" ]]; then
  echo "[deploy] compose.yml não encontrado em ${BASE_COMPOSE}" >&2
  exit 1
fi

if [[ ! -f "$OVERRIDE_FILE" ]]; then
  echo "[deploy] Override da imagem não encontrado em ${OVERRIDE_FILE}" >&2
  exit 1
fi

if [[ ! -f "$BOT_ENV_FILE" ]]; then
  echo "[deploy] Falta o .env do bot em ${BOT_ENV_FILE}" >&2
  exit 1
fi

if [[ -z "${DOCKER_IMAGE:-}" ]]; then
  echo "[deploy] Defina DOCKER_IMAGE ou IMAGE com a imagem do GHCR" >&2
  exit 1
fi

DB_PASSWORD="$(read_env "$BOT_ENV_FILE" DB_PASSWORD)"
DB_HOST="$(read_env "$BOT_ENV_FILE" DB_HOST)"
DB_DATABASE="$(read_env "$BOT_ENV_FILE" DB_DATABASE)"
DATABASE_URL="$(read_env "$BOT_ENV_FILE" DATABASE_URL)"
TOKEN_BOT="$(read_env "$BOT_ENV_FILE" TOKEN_BOT)"
DB_DATABASE="${DB_DATABASE:-checkindb}"

if [[ -z "$TOKEN_BOT" ]]; then
  echo "[deploy] TOKEN_BOT vazio em ${BOT_ENV_FILE}" >&2
  exit 1
fi

if [[ -z "$DB_PASSWORD" ]]; then
  echo "[deploy] DB_PASSWORD vazio em ${BOT_ENV_FILE}. O MariaDB usa essa senha." >&2
  exit 1
fi

if [[ -z "$DATABASE_URL" || "$DATABASE_URL" == *'${'* ]]; then
  echo "[deploy] DATABASE_URL precisa estar escrita por extenso, sem \${...}." >&2
  echo "[deploy] Exemplo: mysql://root:SENHA@db:3306/${DB_DATABASE}" >&2
  exit 1
fi

if [[ "$DB_HOST" != "db" ]]; then
  echo "[deploy] DB_HOST no container precisa ser db (serviço do compose). Valor atual: ${DB_HOST:-vazio}" >&2
  exit 1
fi

if [[ ! "$DB_DATABASE" =~ ^[A-Za-z0-9_]+$ ]]; then
  echo "[deploy] DB_DATABASE inválido: ${DB_DATABASE}" >&2
  exit 1
fi

export DB_PASSWORD

compose=(
  docker compose
  --project-name "$PROJECT_NAME"
  --project-directory "$BOT_DIR"
  -f "$BASE_COMPOSE"
  -f "$OVERRIDE_FILE"
  --profile prod
)

echo "[deploy] Projeto ${PROJECT_NAME}"
echo "[deploy] Imagem ${DOCKER_IMAGE}"
echo "[deploy] Compose ${BASE_COMPOSE}"

if docker ps -a --format '{{.Names}}' | grep -qx 'checkin-webhook'; then
  echo "[deploy] Parando o webhook Go antigo (checkin-webhook)"
  docker stop checkin-webhook >/dev/null
fi

echo "[deploy] Subindo MariaDB sem recriar o volume"
"${compose[@]}" up -d --no-recreate db

echo "[deploy] Aguardando MariaDB ficar healthy"
db_health=""
for _ in $(seq 1 36); do
  db_id="$("${compose[@]}" ps -q db || true)"
  if [[ -n "$db_id" ]]; then
    db_health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$db_id" || true)"
    if [[ "$db_health" == "healthy" ]]; then
      break
    fi
  fi
  sleep 5
done

if [[ "$db_health" != "healthy" ]]; then
  echo "[deploy] MariaDB não ficou healthy a tempo" >&2
  "${compose[@]}" logs --tail 50 db >&2 || true
  exit 1
fi

echo "[deploy] Garantindo o banco ${DB_DATABASE}"
if ! "${compose[@]}" exec -T db \
  mariadb --user=root --password="$DB_PASSWORD" \
  --execute="CREATE DATABASE IF NOT EXISTS \`${DB_DATABASE}\`;"; then
  echo "[deploy] Não consegui entrar no MariaDB com a DB_PASSWORD deste .env." >&2
  echo "[deploy] Se o volume já existia, a senha tem que ser a mesma da primeira subida." >&2
  exit 1
fi

echo "[deploy] Baixando ${COMPOSE_SERVICE}"
"${compose[@]}" pull "$COMPOSE_SERVICE"

echo "[deploy] Recriando só o ${COMPOSE_SERVICE}"
"${compose[@]}" up -d --no-deps "$COMPOSE_SERVICE"

echo "[deploy] Aguardando o bot permanecer no ar"
app_id="$("${compose[@]}" ps -q "$COMPOSE_SERVICE")"
if [[ -z "$app_id" ]]; then
  echo "[deploy] Container do app não foi criado" >&2
  exit 1
fi

restarts_at_start="$(docker inspect -f '{{.RestartCount}}' "$app_id")"
for _ in $(seq 1 18); do
  sleep 5
  status="$(docker inspect -f '{{.State.Status}}' "$app_id" || true)"
  restarts="$(docker inspect -f '{{.RestartCount}}' "$app_id" || echo "$restarts_at_start")"
  if [[ "$status" != "running" || "$restarts" != "$restarts_at_start" ]]; then
    echo "[deploy] O bot não permaneceu no ar (status=${status:-desconhecido})" >&2
    docker logs --tail 80 "$app_id" >&2 || true
    exit 1
  fi
done

echo "[deploy] Bot no ar com ${DOCKER_IMAGE}"
