#!/usr/bin/env bash
set -euo pipefail

MB_URL="http://localhost:3000"
ADMIN_EMAIL="admin@example.com"
ADMIN_PASSWORD="Metabase1!"
ALICE_EMAIL="alice@example.com"
ALICE_PASSWORD="Metabase1!"

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

api_as() {
  local token="$1" method="$2" path="$3" data="${4:-}"
  local args=(-s -w '\n%{http_code}' -X "$method" "$MB_URL$path" \
    -H "Content-Type: application/json" \
    -H "X-Metabase-Session: $token")
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

# Like api_as but never exits — always emits the response body so the caller
# can inspect errors without killing the script (exit inside $(...) kills the
# subshell before any || trap can catch it).
api_as_soft() {
  local token="$1" method="$2" path="$3" data="${4:-}"
  local args=(-s -w '\n%{http_code}' -X "$method" "$MB_URL$path" \
    -H "Content-Type: application/json" \
    -H "X-Metabase-Session: $token")
  [[ -n "$data" ]] && args+=(-d "$data")

  local raw body
  raw=$(curl "${args[@]}")
  body=$(sed '$d' <<<"$raw")
  echo "$body"
}

get_session() {
  local email="$1" password="$2"
  local token
  token=$(curl -sf -X POST "$MB_URL/api/session" \
    -H "Content-Type: application/json" \
    -d '{"username":"'"$email"'","password":"'"$password"'"}' \
    | jq -r '.id')
  if [[ -z "$token" || "$token" == "null" ]]; then
    echo "ERROR: Failed to get session for $email" >&2
    exit 1
  fi
  echo "$token"
}

print_results() {
  local response="$1"
  if echo "$response" | jq -e '.error' > /dev/null 2>&1; then
    echo "  (query returned error: $(echo "$response" | jq -r '.error'))"
  elif echo "$response" | jq -e 'type == "array"' > /dev/null 2>&1; then
    # /query/json returns a plain array of objects — print as a table
    echo "$response" | jq -r '
      (.[0] | keys_unsorted) as $cols |
      ($cols | join(" | ")),
      ($cols | map("---") | join(" | ")),
      (.[] | [.[$cols[]]] | map(tostring) | join(" | "))
    '
  elif echo "$response" | jq -e '.data.rows' > /dev/null 2>&1; then
    # Fallback: columnar format with named headers
    echo "$response" | jq -r '
      (.data.cols | map(.name)) as $cols |
      ($cols | join(" | ")),
      ($cols | map("---") | join(" | ")),
      (.data.rows[] | map(tostring) | join(" | "))
    '
  else
    echo "  (unexpected response format)"
    echo "$response" | jq '.' 2>/dev/null || echo "$response"
  fi
}

# ── load state ────────────────────────────────────────────────────────────────

if [[ ! -f .demo-state ]]; then
  echo "ERROR: .demo-state not found. Run ./setup.sh first." >&2
  exit 1
fi
# shellcheck source=/dev/null
source .demo-state

echo "  Loaded state: CARD_ID=$CARD_ID  ALICE_ID=$ALICE_ID"

# Authenticate once — the same session token is reused for all three queries.
# Routing is resolved from login_attributes at query time, not at login time,
# so a single session is enough to prove the point.
ALICE_TOKEN=$(get_session "$ALICE_EMAIL" "$ALICE_PASSWORD")
ADMIN_TOKEN=$(get_session "$ADMIN_EMAIL" "$ADMIN_PASSWORD")
echo "  Alice session token (reused for all queries): ${ALICE_TOKEN:0:8}…"

# ── STEP 1: baseline — alice has no routing attribute ─────────────────────────

echo ""
echo "──────────────────────────────────────────────────────────"
echo ">>> STEP 1: Alice has no 'tenant_db' attribute set."
echo "    Calling /api/card/$CARD_ID/query/json as Alice..."
echo "──────────────────────────────────────────────────────────"

echo "  curl -X POST $MB_URL/api/card/$CARD_ID/query/json \\"
echo "       -H 'X-Metabase-Session: ${ALICE_TOKEN:0:8}…'"
RESULT=$(api_as_soft "$ALICE_TOKEN" POST "/api/card/$CARD_ID/query/json")
echo ""
print_results "$RESULT"
echo ""
echo "  (Expected: routing error or empty — no destination to resolve to)"

# ── STEP 2: admin sets tenant_db = tenant-a ─────────────────

echo ""
echo "──────────────────────────────────────────────────────────"
echo ">>> STEP 2: Admin sets Alice's 'tenant_db' attribute to 'tenant-a'"
echo "    (Using PUT /api/user/$ALICE_ID)"
echo "──────────────────────────────────────────────────────────"

api_as "$ADMIN_TOKEN" PUT "/api/user/$ALICE_ID" \
  '{"login_attributes": {"tenant_db": "tenant-a"}}' > /dev/null

CONFIRM=$(api_as "$ADMIN_TOKEN" GET "/api/user/$ALICE_ID")
echo ""
echo "  Confirmed login_attributes on Alice:"
echo "$CONFIRM" | jq '.login_attributes'

# ── STEP 3: query the card as alice → should hit tenant A ─────────────────────

echo ""
echo "──────────────────────────────────────────────────────────"
echo ">>> STEP 3: Calling same card as Alice (attribute = tenant-a)..."
echo "──────────────────────────────────────────────────────────"

echo "  curl -X POST $MB_URL/api/card/$CARD_ID/query/json \\"
echo "       -H 'X-Metabase-Session: ${ALICE_TOKEN:0:8}…'"
RESULT=$(api_as "$ALICE_TOKEN" POST "/api/card/$CARD_ID/query/json")
echo ""
print_results "$RESULT"
echo ""
echo "  (Expected: *** TENANT A ***)"

# ── STEP 4: admin switches attribute to tenant-b ──────────────────────────────

echo ""
echo "──────────────────────────────────────────────────────────"
echo ">>> STEP 4: Admin switches Alice's attribute to 'tenant-b'"
echo "    (Same API call, different value for user attribute for db routing )"
echo "──────────────────────────────────────────────────────────"

api_as "$ADMIN_TOKEN" PUT "/api/user/$ALICE_ID" \
  '{"login_attributes": {"tenant_db": "tenant-b"}}' > /dev/null

CONFIRM=$(api_as "$ADMIN_TOKEN" GET "/api/user/$ALICE_ID")
echo ""
echo "  Confirmed login_attributes on Alice:"
echo "$CONFIRM" | jq '.login_attributes'

# ── STEP 5: query the same card as alice → should now hit tenant B ────────────

echo ""
echo "──────────────────────────────────────────────────────────"
echo ">>> STEP 5: Calling SAME card, SAME endpoint, SAME user — attribute changed..."
echo "──────────────────────────────────────────────────────────"

echo "  curl -X POST $MB_URL/api/card/$CARD_ID/query/json \\"
echo "       -H 'X-Metabase-Session: ${ALICE_TOKEN:0:8}…'"
RESULT=$(api_as "$ALICE_TOKEN" POST "/api/card/$CARD_ID/query/json")
echo ""
print_results "$RESULT"
echo ""
echo "  (Expected: === TENANT B ===)"

# ── STEP 6: conclusion ────────────────────────────────────────────────────────

echo ""
echo "============================================================"
echo "  PROOF SUMMARY"
echo "  Same card. Same API endpoint. Same user."
echo "  Only the user attribute value changed."
echo "  The query processor routed to a different database."
echo "  User Attribute for DB routing was used for queries run via API"
echo "============================================================"

# ── CLEANUP: restore alice to no attribute so the demo is rerunnable ──────────

echo ""
echo "──────────────────────────────────────────────────────────"
echo ">>> CLEANUP: Removing Alice's 'tenant_db' attribute..."
echo "──────────────────────────────────────────────────────────"

ADMIN_TOKEN=$(get_session "$ADMIN_EMAIL" "$ADMIN_PASSWORD")
api_as "$ADMIN_TOKEN" PUT "/api/user/$ALICE_ID" \
  '{"login_attributes": {}}' > /dev/null
echo "  Alice's login_attributes cleared. Demo is ready to rerun."
