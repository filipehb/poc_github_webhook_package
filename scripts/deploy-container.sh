#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${IMAGE:-}" ]]; then
  echo "IMAGE is required" >&2
  exit 1
fi

echo "Pulling ${IMAGE}"
if [[ -n "${DOCKER_PLATFORM:-}" ]]; then
  echo "Using platform ${DOCKER_PLATFORM}"
  docker pull --platform "${DOCKER_PLATFORM}" "${IMAGE}"
else
  docker pull "${IMAGE}"
fi

if [[ -n "${COMPOSE_FILE:-}" ]]; then
  echo "Updating stack with ${COMPOSE_FILE}"
  docker compose -f "${COMPOSE_FILE}" up -d
elif [[ -n "${CONTAINER_NAME:-}" ]]; then
  echo "Restarting container ${CONTAINER_NAME}"
  docker restart "${CONTAINER_NAME}"
else
  echo "Set COMPOSE_FILE or CONTAINER_NAME to redeploy after pull" >&2
  exit 1
fi

echo "Deploy complete for ${IMAGE}"
