# Metabase Database Routing — Local Demo

This demo proves that Metabase's database routing is handled entirely by the
**query processor**, not by the delivery mechanism. Whether a query originates
from the UI or from a direct API call, the routing decision is made server-side
based on the user's `login_attributes` — no JWT tokens or SSO setup required.

---

## What the Demo Proves

1. A single saved question (card) is created against one "primary" (router) database.
2. Two real Postgres databases contain **identical schemas but distinct data** (Tenant A vs Tenant B).
3. A test user (`alice@example.com`) queries the same card endpoint with **no attribute** → error/empty.
4. An admin sets `alice.login_attributes.tenant_db = "tenant-a"` via a plain REST API call.
5. Alice re-queries the same card → gets **Tenant A data**.
6. Admin changes the attribute to `"tenant-b"` — same API call, different value.
7. Alice re-queries the same card → gets **Tenant B data**.

Same card. Same endpoint. Same user. Only the attribute changed.
The query processor resolved the routing — not the frontend, not JWT, not SSO.

---

## Prerequisites

| Tool | Notes |
|------|-------|
| Docker + Docker Compose v2 | `docker compose` (v2 syntax) |
| `jq` | See install instructions below |
| `curl` | Pre-installed on macOS and most Linux distros; included with Git for Windows |
| Metabase Pro or Enterprise license token | Required for the DB routing feature |
| Ports 3000, 5433, 5434 free on localhost | Used by Metabase and the two tenant DBs |

### Installing jq

| Platform | Command |
| -------- | ------- |
| macOS | `brew install jq` |
| Ubuntu / Debian | `sudo apt-get install -y jq` |
| Windows | `winget install jqlang.jq` or `choco install jq` |
| Other | [jqlang.github.io/jq/download](https://jqlang.github.io/jq/download/) |

### Windows users

The scripts are Bash scripts — they do **not** run in PowerShell or CMD.
Use one of the following:

- **Git Bash** (included with [Git for Windows](https://gitforwindows.org/)) — simplest option
- **WSL 2** (Windows Subsystem for Linux) — full Linux environment

Docker Desktop for Windows works fine with both. Make sure Docker Desktop is
running before you start.

---

## Setup

### 1. Add your license token

Copy the example file and fill in your token:

```bash
cp .env.example .env
```

Then edit `.env`:

```
MB_PREMIUM_EMBEDDING_TOKEN=your_actual_token_here
```

`.env` is gitignored and will never be committed.

### 2. Start the stack

```bash
docker compose up -d
```

This starts four containers:

| Container | Role | Port |
|-----------|------|------|
| `metabase` | Metabase Enterprise UI + API | 3000 |
| `mb-app-db` | Metabase's internal app database | — |
| `pg-tenant-a` | Tenant A's Postgres | 5433 |
| `pg-tenant-b` | Tenant B's Postgres | 5434 |

Both tenant databases are seeded automatically with an `orders` table on first start.

### 3. Run setup

```bash
./setup.sh
```

This script:
- Waits for Metabase to be healthy
- Completes first-run setup if needed
- Creates and connects the primary (router) database
- Enables database routing with `user_attribute = tenant_db`
- Registers `tenant-a` and `tenant-b` as routing destinations
- Creates `alice@example.com` as a test user
- Grants query access to the primary DB
- Creates a saved question (card) that queries `orders`
- Writes `.demo-state` so `demo.sh` can pick up the IDs

### 4. Run the demo

```bash
./demo.sh
```

Watch the output as Alice's routing attribute is changed and the query results
switch from Tenant A data to Tenant B data without touching the card, the
endpoint, or any JWT configuration.

---


## Expected test results
``` sh
 ./demo.sh 
  Loaded state: CARD_ID=133  ALICE_ID=2

──────────────────────────────────────────────────────────
>>> STEP 1: Alice has no 'tenant_db' attribute set.
    Calling /api/card/133/query/json as Alice...
──────────────────────────────────────────────────────────

  (query returned error: Required user attribute is missing. Cannot route to a Destination Database.)

  (Expected: routing error or empty — no destination to resolve to)

──────────────────────────────────────────────────────────
>>> STEP 2: Admin sets Alice's 'tenant_db' attribute to 'tenant-a'
    (Using PUT /api/user/2 — no JWT involved)
──────────────────────────────────────────────────────────

  Confirmed login_attributes on Alice:
{
  "tenant_db": "tenant-a"
}

──────────────────────────────────────────────────────────
>>> STEP 3: Calling same card as Alice (attribute = tenant-a)...
──────────────────────────────────────────────────────────

id | customer | amount | tenant_label
--- | --- | --- | ---
1 | Alice | 100 | *** TENANT A ***
2 | Bob | 200 | *** TENANT A ***
3 | Carol | 150 | *** TENANT A ***

  (Expected: *** TENANT A ***)

──────────────────────────────────────────────────────────
>>> STEP 4: Admin switches Alice's attribute to 'tenant-b'
    (Same API call, different value — still no JWT)
──────────────────────────────────────────────────────────

  Confirmed login_attributes on Alice:
{
  "tenant_db": "tenant-b"
}

──────────────────────────────────────────────────────────
>>> STEP 5: Calling SAME card, SAME endpoint, SAME user — attribute changed...
──────────────────────────────────────────────────────────

id | customer | amount | tenant_label
--- | --- | --- | ---
1 | Dave | 300 | === TENANT B ===
2 | Eve | 400 | === TENANT B ===
3 | Frank | 250 | === TENANT B ===

  (Expected: === TENANT B ===)

============================================================
  PROOF SUMMARY
  Same card. Same API endpoint. Same user.
  Only the user attribute value changed.
  The query processor routed to a different database.
  No JWT. No SSO. Attribute was set directly via Admin API.
============================================================

──────────────────────────────────────────────────────────
>>> CLEANUP: Removing Alice's 'tenant_db' attribute...
──────────────────────────────────────────────────────────
  Alice's login_attributes cleared. Demo is ready to rerun.
  ```





## Teardown

```bash
./teardown.sh
```

Stops all containers, removes their volumes (database data), and deletes `.demo-state`.

---

## File Layout

```
.
├── docker-compose.yml   # Four-container stack
├── seed-a.sql           # Tenant A schema + data (*** TENANT A ***)
├── seed-b.sql           # Tenant B schema + data (=== TENANT B ===)
├── setup.sh             # One-time configuration via Metabase REST API
├── demo.sh              # Five-step proof of routing behavior
├── teardown.sh          # docker compose down -v + state cleanup
├── .env.example         # Token template — copy to .env and fill in
├── .env                 # Your actual token (gitignored, never committed)
├── .demo-state          # IDs written by setup.sh (gitignored)
├── .gitignore
└── README.md
```

---

## Credentials

| Account | Email | Password |
|---------|-------|----------|
| Admin | admin@example.com | Metabase1! |
| Test user | alice@example.com | Metabase1! |
| Postgres (all DBs) | postgres | postgres |

---

## Troubleshooting

**`setup.sh` hangs on "Waiting for Metabase to become healthy"**
Metabase can take 2–3 minutes on first boot while it migrates the app DB.
Run `docker compose logs -f metabase` in a separate terminal to watch progress.

**"routing" API returns 404**
Database routing is a Metabase Enterprise/Pro feature. Verify your
`MB_PREMIUM_EMBEDDING_TOKEN` in `.env` (copied from `.env.example`) is valid
and matches a license that includes database routing.

**Tenant data doesn't switch after attribute change**
Sessions are cached. `demo.sh` always fetches a fresh session token for Alice
before each query, so this should not occur. If testing manually in the UI,
log out and back in after changing the attribute.

**Port conflicts**
If ports 3000, 5433, or 5434 are in use, stop the conflicting process or edit
the `ports:` mappings in `docker-compose.yml` (the host-side ports only —
leave the container-side ports unchanged so inter-container communication works).
