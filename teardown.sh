#!/usr/bin/env bash
set -euo pipefail

echo "Tearing down Docker Compose stack (removing volumes)..."
docker compose down -v --remove-orphans

# Double-check: list any volumes this project still owns (should be empty)
LEFTOVER=$(docker compose config --volumes 2>/dev/null | while read -r vol; do
  docker volume ls --format '{{.Name}}' | grep -F "_${vol}" || true
done)
if [[ -n "$LEFTOVER" ]]; then
  echo "WARNING: some volumes were not removed — cleaning up manually:"
  echo "$LEFTOVER" | xargs docker volume rm
else
  echo "All volumes removed."
fi

if [[ -f .demo-state ]]; then
  rm .demo-state
  echo "Removed .demo-state"
fi

echo "Teardown complete. Stack is clean and ready to restart."
