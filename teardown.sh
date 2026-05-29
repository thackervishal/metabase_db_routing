#!/usr/bin/env bash
set -euo pipefail

echo "Tearing down Docker Compose stack (removing volumes)..."
docker compose down -v

if [[ -f .demo-state ]]; then
  rm .demo-state
  echo "Removed .demo-state"
fi

echo "Teardown complete."
