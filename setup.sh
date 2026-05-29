#!/usr/bin/env bash
set -euo pipefail

MB_URL="http://localhost:3000"
ADMIN_EMAIL="admin@example.com"
ADMIN_PASSWORD="Metabase1!"

# ── preflight ─────────────────────────────────────────────────────────────────

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required but was not found in PATH." >&2
  echo "" >&2
  echo "Install it for your platform:" >&2
  echo "  macOS   : brew install jq" >&2
  echo "  Ubuntu  : sudo apt-get install -y jq" >&2
  echo "  Windows : winget install jqlang.jq  (or: choco install jq)" >&2
  echo "            then re-run in Git Bash or WSL" >&2
  echo "  Other   : https://jqlang.github.io/jq/download/" >&2
  exit 1
fi

if ! command -v curl &>/dev/null; then
  echo "ERROR: curl is required but was not found in PATH." >&2
  exit 1
fi

# ── helpers ────────────────────────────────────────────────────────────────────

api() {
  local method="$1" path="$2" data="${3:-}"
  local args=(-s -w '\n%{http_code}' -X "$method" "$MB_URL$path" \
    -H "Content-Type: application/json")
  [[ -n "${ADMIN_TOKEN:-}" ]] && args+=(-H "X-Metabase-Session: $ADMIN_TOKEN")
  [[ -n "$data" ]] && args+=(-d "$data")

  local raw http_code body
  raw=$(curl "${args[@]}")
  http_code=$(tail -n1 <<<"$raw")
  body=$(sed '$d' <<<"$raw")

  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    echo "ERROR: $method $path returned HTTP $http_code" >&2
    echo "$body" >&2
    exit 1
  fi
  echo "$body"
}

# ── STEP 1: wait for Metabase ──────────────────────────────────────────────────

echo "──────────────────────────────────────────────────────────"
echo "STEP 1: Waiting for Metabase to become healthy..."
echo "──────────────────────────────────────────────────────────"

until curl -sf "$MB_URL/api/health" | grep -q '"status":"ok"'; do
  echo "  Metabase not ready yet — retrying in 5s..."
  sleep 5
done
echo "  Metabase is healthy."

# ── STEP 2: complete first-run setup if needed ────────────────────────────────

echo ""
echo "──────────────────────────────────────────────────────────"
echo "STEP 2: Checking Metabase setup status..."
echo "──────────────────────────────────────────────────────────"

SETUP_TOKEN=$(curl -sf "$MB_URL/api/session/properties" | jq -r '.["setup-token"] // empty')

if [[ -n "$SETUP_TOKEN" ]]; then
  echo "  First-run setup token found — completing initial setup..."
  SETUP_HTTP=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$MB_URL/api/setup" \
    -H "Content-Type: application/json" \
    -d '{
      "token": "'"$SETUP_TOKEN"'",
      "user": {
        "first_name": "Admin",
        "last_name": "User",
        "email": "'"$ADMIN_EMAIL"'",
        "password": "'"$ADMIN_PASSWORD"'",
        "site_name": "DB Routing Demo"
      },
      "prefs": {
        "site_name": "DB Routing Demo",
        "allow_tracking": false
      }
    }')
  if [[ "$SETUP_HTTP" -lt 200 || "$SETUP_HTTP" -ge 300 ]]; then
    echo "ERROR: First-run setup failed (HTTP $SETUP_HTTP)" >&2
    exit 1
  fi
  echo "  Setup complete."
else
  echo "  Metabase already configured — skipping setup."
fi

# ── STEP 3: authenticate as admin ─────────────────────────────────────────────

echo ""
echo "──────────────────────────────────────────────────────────"
echo "STEP 3: Authenticating as admin..."
echo "──────────────────────────────────────────────────────────"

ADMIN_TOKEN=$(curl -sf -X POST "$MB_URL/api/session" \
  -H "Content-Type: application/json" \
  -d '{"username":"'"$ADMIN_EMAIL"'","password":"'"$ADMIN_PASSWORD"'"}' \
  | jq -r '.id')

if [[ -z "$ADMIN_TOKEN" || "$ADMIN_TOKEN" == "null" ]]; then
  echo "ERROR: Failed to get admin session token." >&2
  exit 1
fi
echo "  Admin token acquired."

# ── STEP 4: connect pg-tenant-a as the primary router DB ─────────────────────

echo ""
echo "──────────────────────────────────────────────────────────"
echo "STEP 4: Connecting pg-tenant-a as 'Primary (Router DB)'..."
echo "──────────────────────────────────────────────────────────"

DB_RESPONSE=$(api POST /api/database '{
  "engine": "postgres",
  "name": "Primary (Router DB)",
  "details": {
    "host": "pg-tenant-a",
    "port": 5432,
    "dbname": "tenantdb",
    "user": "postgres",
    "password": "postgres"
  }
}')
PRIMARY_DB_ID=$(echo "$DB_RESPONSE" | jq -r '.id')
echo "  Primary DB registered. ID = $PRIMARY_DB_ID"

# ── STEP 5: wait for initial sync ─────────────────────────────────────────────

echo ""
echo "──────────────────────────────────────────────────────────"
echo "STEP 5: Waiting for database sync to complete..."
echo "──────────────────────────────────────────────────────────"

until curl -sf "$MB_URL/api/database/$PRIMARY_DB_ID" \
  -H "X-Metabase-Session: $ADMIN_TOKEN" \
  | jq -e '.initial_sync_status == "complete"' > /dev/null 2>&1; do
  echo "  Sync not complete yet — retrying in 5s..."
  sleep 5
done
echo "  Database sync complete."

# ── STEP 6: enable database routing on primary DB ─────────────────────────────

echo ""
echo "──────────────────────────────────────────────────────────"
echo "STEP 6: Enabling database routing (user_attribute = tenant_db)..."
echo "──────────────────────────────────────────────────────────"

api PUT "/api/ee/database-routing/router-database/$PRIMARY_DB_ID" \
  '{"user_attribute": "tenant_db"}' > /dev/null
echo "  Routing enabled on DB $PRIMARY_DB_ID."

# ── STEP 7: register tenant-a as a destination ───────────────────────────────

echo ""
echo "──────────────────────────────────────────────────────────"
echo "STEP 7: Registering destination 'tenant-a' (pg-tenant-a)..."
echo "──────────────────────────────────────────────────────────"

api POST /api/ee/database-routing/destination-database \
  '{
    "router_database_id": '"$PRIMARY_DB_ID"',
    "destinations": [{
      "name": "tenant-a",
      "engine": "postgres",
      "details": {
        "host": "pg-tenant-a",
        "port": 5432,
        "dbname": "tenantdb",
        "user": "postgres",
        "password": "postgres"
      }
    }]
  }' > /dev/null
echo "  Destination 'tenant-a' registered."

# ── STEP 8: register tenant-b as a destination ───────────────────────────────

echo ""
echo "──────────────────────────────────────────────────────────"
echo "STEP 8: Registering destination 'tenant-b' (pg-tenant-b)..."
echo "──────────────────────────────────────────────────────────"

api POST /api/ee/database-routing/destination-database \
  '{
    "router_database_id": '"$PRIMARY_DB_ID"',
    "destinations": [{
      "name": "tenant-b",
      "engine": "postgres",
      "details": {
        "host": "pg-tenant-b",
        "port": 5432,
        "dbname": "tenantdb",
        "user": "postgres",
        "password": "postgres"
      }
    }]
  }' > /dev/null
echo "  Destination 'tenant-b' registered."

# ── STEP 9: create test user alice ────────────────────────────────────────────

echo ""
echo "──────────────────────────────────────────────────────────"
echo "STEP 9: Creating test user alice@example.com..."
echo "──────────────────────────────────────────────────────────"

USER_RESPONSE=$(api POST /api/user '{
  "first_name": "Alice",
  "last_name": "Tenant",
  "email": "alice@example.com",
  "password": "Metabase1!"
}')
ALICE_ID=$(echo "$USER_RESPONSE" | jq -r '.id')
echo "  Alice created. ID = $ALICE_ID"

# ── STEP 10: grant All Users unrestricted view-data on primary DB ─────────────

echo ""
echo "──────────────────────────────────────────────────────────"
echo "STEP 10: Granting All Users query access to primary DB..."
echo "──────────────────────────────────────────────────────────"

PERM_GRAPH=$(api GET /api/permissions/graph)

# All Users group is always ID 1 in Metabase
# Build updated graph: set view-data = unrestricted for All Users on primary DB
UPDATED_GRAPH=$(echo "$PERM_GRAPH" | jq --argjson db_id "$PRIMARY_DB_ID" '
  .groups["1"][$db_id | tostring] = {"view-data": "unrestricted", "create-queries": "query-builder-and-native"}
')

api PUT /api/permissions/graph "$UPDATED_GRAPH" > /dev/null
echo "  Permissions updated."

# ── STEP 11: create saved question (card) ─────────────────────────────────────

echo ""
echo "──────────────────────────────────────────────────────────"
echo "STEP 11: Creating saved question 'Orders - Routing Demo'..."
echo "──────────────────────────────────────────────────────────"

CARD_RESPONSE=$(api POST /api/card '{
  "name": "Orders - Routing Demo",
  "dataset_query": {
    "type": "native",
    "native": {"query": "SELECT * FROM orders ORDER BY id"},
    "database": '"$PRIMARY_DB_ID"'
  },
  "display": "table",
  "visualization_settings": {}
}')
CARD_ID=$(echo "$CARD_RESPONSE" | jq -r '.id')
echo "  Card created. ID = $CARD_ID"

# ── write state file ──────────────────────────────────────────────────────────

cat > .demo-state <<EOF
CARD_ID=$CARD_ID
ALICE_ID=$ALICE_ID
PRIMARY_DB_ID=$PRIMARY_DB_ID
EOF
echo ""
echo "  State saved to .demo-state"

# ── summary ───────────────────────────────────────────────────────────────────

echo ""
echo "============================================================"
echo "  Setup complete."
printf "  %-18s %s\n" "Primary DB ID :" "$PRIMARY_DB_ID"
printf "  %-18s %s\n" "Card ID :"       "$CARD_ID"
printf "  %-18s %s\n" "Alice user ID :" "$ALICE_ID"
printf "  %-18s %s\n" "Routing attr :"  "tenant_db"
printf "  %-18s %s\n" "Slugs :"         "tenant-a → pg-tenant-a | tenant-b → pg-tenant-b"
echo "============================================================"
