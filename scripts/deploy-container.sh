#!/usr/bin/env bash
set -euo pipefail

compose_args=()
if [[ -n "${COMPOSE_FILE:-}" ]]; then
  compose_args=(-f "${COMPOSE_FILE}")
fi

if [[ -n "${COMPOSE_CWD:-}" ]]; then
  cd "${COMPOSE_CWD}"
fi

if [[ -n "${COMPOSE_SERVICE:-}" ]]; then
  echo "[deploy] Pulling service ${COMPOSE_SERVICE} via docker compose"
  docker compose "${compose_args[@]}" pull "${COMPOSE_SERVICE}"

  echo "[deploy] Recreating service ${COMPOSE_SERVICE}"
  docker compose "${compose_args[@]}" up -d --force-recreate "${COMPOSE_SERVICE}"

  echo "[deploy] Deploy complete for service ${COMPOSE_SERVICE}"
  exit 0
fi

if [[ -z "${IMAGE:-}" ]]; then
  echo "IMAGE is required when COMPOSE_SERVICE is not set" >&2
  exit 1
fi

echo "[deploy] Pulling ${IMAGE}"
if [[ -n "${DOCKER_PLATFORM:-}" ]]; then
  echo "[deploy] Using platform ${DOCKER_PLATFORM}"
  docker pull --platform "${DOCKER_PLATFORM}" "${IMAGE}"
else
  docker pull "${IMAGE}"
fi

if [[ ${#compose_args[@]} -gt 0 ]] || [[ -f compose.yml ]] || [[ -f docker-compose.yml ]]; then
  echo "[deploy] Updating stack with docker compose"
  docker compose "${compose_args[@]}" up -d
elif [[ -n "${CONTAINER_NAME:-}" ]]; then
  echo "[deploy] Restarting container ${CONTAINER_NAME}"
  docker restart "${CONTAINER_NAME}"
else
  echo "Set COMPOSE_SERVICE, COMPOSE_FILE, or CONTAINER_NAME to redeploy after pull" >&2
  exit 1
fi

echo "[deploy] Deploy complete for ${IMAGE}"
