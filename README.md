# Multi-Source Data Normalization API

A Xano module that centralizes customer data normalization across three inconsistent enterprise
systems — an external **Postgres** database, an external **Snowflake** warehouse, and **Salesforce**
— and merges them into one canonical customer schema with deterministic priority rules, conflict
detection, and a 0–100 data-quality score. Xano is the normalization layer: it reads each system in
place and produces a single trustworthy record without replacing any source.

> **Testing guarantee.** Salesforce and Snowflake are real REST/SQL-API adapters but are exercised
> here against **doc-derived mocks** (no live credentials in the build), so their guarantee is
> "correct against the documented contract." The external **Postgres** adapter uses Xano's native
> `db.external.postgres.direct_query` connector and is credential-gated. The **normalization engine**
> — the field mapping, priority rules, conflict detection, and scoring that are the actual value of
> this module — is unit-tested exhaustively and proven end-to-end by a workflow test. See
> [Endpoint reference](#10-endpoint-reference) and the test report for exactly what is mocked vs. real.

---

## 1. What this template demonstrates

- Reading the **same customer** from three systems that model it differently (snake_case Postgres
  columns, SCREAMING_CASE Snowflake columns, Salesforce `__c` custom fields).
- Mapping every source into **one canonical schema** with explicit, documented field mappings.
- Applying a fixed **source priority order** so each canonical field has a single deterministic winner.
- Detecting **conflicts** when sources disagree on `email`, `status`, or `company`, persisting them,
  and exposing a **manual resolution** flow.
- Scoring each record's completeness/agreement with a **0–100 data-quality score**.
- Logging every source read (`source_records`), every conflict (`normalization_conflicts`), and every
  API call (`api_request_logs`) so the normalization is fully auditable.

It demonstrates that Xano can be the central normalization brain over heterogeneous systems **without
becoming the system of record** — the sources stay authoritative; Xano reconciles them on read.

## 2. Required environment variables

All eleven are required. Set them on the Xano workspace (Settings → Environment Variables).

| Variable | Used for |
|---|---|
| `POSTGRES_CONNECTION_STRING` | Connection string for the external Postgres database (native `db.external.postgres` connector). |
| `SNOWFLAKE_ACCOUNT` | Snowflake SQL API host base URL, e.g. `https://<org>-<account>.snowflakecomputing.com`. |
| `SNOWFLAKE_USERNAME` | The Snowflake user that owns the access token; stamped on the request so the call is attributable. |
| `SNOWFLAKE_PASSWORD` | **Used as the bearer / Programmatic Access Token (PAT)** for the SQL API — Snowflake's SQL API auth is bearer-token, not raw user/password. |
| `SNOWFLAKE_DATABASE` | Database used as session context for the SQL statement. |
| `SNOWFLAKE_SCHEMA` | Schema used as session context. |
| `SNOWFLAKE_WAREHOUSE` | Warehouse used to run the statement. |
| `SNOWFLAKE_ROLE` | Role assumed for the statement. |
| `SALESFORCE_INSTANCE_URL` | Salesforce instance URL, e.g. `https://yourco.my.salesforce.com`. |
| `SALESFORCE_ACCESS_TOKEN` | OAuth bearer token for the Salesforce REST API. |
| `API_AUTH_SECRET` | Shared secret. **Every endpoint requires it** in the `X-API-Secret` request header. |

> On Snowflake auth: the SQL API v2 authenticates with a bearer token (a Programmatic Access Token).
> We keep the conventional variable names — `SNOWFLAKE_PASSWORD` carries the PAT (the bearer value),
> `SNOWFLAKE_USERNAME` is the owning user, and `SNOWFLAKE_ACCOUNT` / `DATABASE` / `SCHEMA` /
> `WAREHOUSE` / `ROLE` are the host and session context. Generating a PAT may require a network
> policy on the Snowflake user/account first.

## 3. Required Postgres schema

A `customers` table queried by customer_id or email:

| Column | Type | Maps to canonical |
|---|---|---|
| customer_id | text/varchar (unique) | source_ids.postgres_customer_id |
| email | text | email |
| full_name | text | name |
| company_name | text | company |
| account_status | text | status |
| created_at | timestamp/text (ISO-8601) | created_at |

The Postgres adapter runs (parameterized):

```sql
SELECT customer_id, email, full_name, company_name, account_status, created_at
FROM customers WHERE customer_id = ?   -- or: WHERE email = ?
```

## 4. Required Snowflake schema

A CUSTOMERS table (queried via the SQL API v2) with these columns:

| Column | Type | Maps to canonical |
|---|---|---|
| CUSTOMER_KEY | TEXT | source_ids.snowflake_customer_key |
| CUSTOMER_EMAIL | TEXT | email |
| CUSTOMER_NAME | TEXT | name |
| COMPANY | TEXT | company |
| CUSTOMER_STATUS | TEXT | status |
| FIRST_SEEN_DATE | TEXT/TIMESTAMP (ISO-8601) | created_at |
| LIFETIME_VALUE | NUMBER/REAL | lifetime_value |
| LAST_ACTIVITY_AT | TEXT/TIMESTAMP (ISO-8601) | last_activity_at |

## 5. Required Salesforce fields

Queried from the `Account` object via SOQL (`/services/data/v59.0/query`):

| Field | Maps to canonical |
|---|---|
| `Id` | `source_ids.salesforce_account_id` |
| `Email__c` | `email` |
| `Name` | `name` |
| `Company__c` | `company` |
| `Account_Status__c` | `status` |
| `CreatedDate` | `created_at` |
| `LastActivityDate` | `last_activity_at` |

## 6. Canonical schema

Every normalized customer response has exactly this shape:

```json
{
  "canonical_customer_id": "",
  "source_ids": {
    "postgres_customer_id": "",
    "snowflake_customer_key": "",
    "salesforce_account_id": ""
  },
  "email": "",
  "name": "",
  "company": "",
  "status": "",
  "created_at": "",
  "lifetime_value": 0,
  "last_activity_at": "",
  "data_quality_score": 0,
  "conflicts": [],
  "sources_used": []
}
```

## 7. Source priority rules

For each canonical field there is one deterministic winner. When the highest-priority source has no
value for a field, the next non-empty source is used.

1. **Salesforce wins `name`, `company`, and `status`.**
2. **Postgres wins `email`.**
3. **Snowflake wins `lifetime_value` and `last_activity_at`.**
4. **Earliest available value wins `created_at`** (the chronologically earliest non-empty source date).

## 8. Conflict rules

A conflict is created when **two or more sources return different non-empty values** for any of:

- `email`
- `status`
- `company`

Each conflict records which sources disagreed, their values, and the value the priority rules chose.
Conflicts are returned inline on the canonical object (`conflicts[]`) and persisted to
`normalization_conflicts` as `open` for manual resolution.

## 9. Data quality scoring

The score starts at **100** and is reduced by:

| Condition | Penalty |
|---|---|
| Missing `email` | −20 |
| Missing `name` | −15 |
| Missing `company` | −15 |
| Missing `status` | −10 |
| Missing `created_at` | −10 |
| Each conflict | −10 |

The final score is clamped to a minimum of **0** (it never goes negative). Resolving a conflict adds
its 10 points back (clamped to a maximum of 100).

## 10. Endpoint reference

Every endpoint requires the `X-API-Secret: <API_AUTH_SECRET>` header. Paths are relative to the API
group base `…/api:msdn-data-normalization`.

| Method | Path | Description |
|---|---|---|
| GET | `/normalized/customers/{customer_id}` | Query all three sources for the customer, normalize, apply priority, detect conflicts, compute the data-quality score, persist, and return the canonical object. |
| GET | `/normalized/customers/search` | Required query param `email`. Search all three sources by email; return an array of canonical customer objects. |
| GET | `/normalization/conflicts` | Return unresolved (`open`) conflicts from `normalization_conflicts`. |
| POST | `/normalization/conflicts/{conflict_id}/resolve` | Required body: `resolved_value`, `resolved_by`, `resolution_note`. Mark the conflict resolved, save a `manual_resolutions` row, and update the related normalized customer. |

## 11. Example requests

```bash
# 1) Normalize a single customer (by id)
curl -s "https://YOUR.xano.io/api:msdn-data-normalization/normalized/customers/CUST-1001" \
  -H "X-API-Secret: $API_AUTH_SECRET"

# 2) Search by email
curl -s "https://YOUR.xano.io/api:msdn-data-normalization/normalized/customers/search?email=dana@acme.com" \
  -H "X-API-Secret: $API_AUTH_SECRET"

# 3) List open conflicts
curl -s "https://YOUR.xano.io/api:msdn-data-normalization/normalization/conflicts" \
  -H "X-API-Secret: $API_AUTH_SECRET"

# 4) Resolve a conflict
curl -s -X POST "https://YOUR.xano.io/api:msdn-data-normalization/normalization/conflicts/42/resolve" \
  -H "X-API-Secret: $API_AUTH_SECRET" \
  -H "Content-Type: application/json" \
  -d '{"resolved_value":"dana@acme.com","resolved_by":"data-steward","resolution_note":"Confirmed with customer"}'
```

## 12. Example responses

`GET /normalized/customers/{customer_id}` — Salesforce wins name/company/status, Postgres wins email,
Snowflake wins lifetime_value/last_activity_at, and the two emails disagree (one conflict → −10):

```json
{
  "canonical_customer_id": "CUST-1001",
  "source_ids": {
    "postgres_customer_id": "CUST-1001",
    "snowflake_customer_key": "SNOW-900",
    "salesforce_account_id": "0015e00000ABCDEAA3"
  },
  "email": "dana@acme.com",
  "name": "Dana Salesforce",
  "company": "Acme Corp",
  "status": "customer",
  "created_at": "2018-01-15T12:00:00.000+0000",
  "lifetime_value": 5200.75,
  "last_activity_at": "2024-06-01T00:00:00Z",
  "data_quality_score": 90,
  "conflicts": [
    {
      "field": "email",
      "chosen_value": "dana@acme.com",
      "values": [
        { "source": "postgres", "value": "dana@acme.com" },
        { "source": "salesforce", "value": "dana@salesforce-old.com" }
      ]
    }
  ],
  "sources_used": ["postgres", "snowflake", "salesforce"]
}
```

`POST /normalization/conflicts/{conflict_id}/resolve`:

```json
{
  "conflict": {
    "id": 42,
    "canonical_customer_id": "CUST-1001",
    "field": "email",
    "status": "resolved",
    "resolved_value": "dana@acme.com",
    "resolved_by": "data-steward",
    "resolution_note": "Confirmed with customer"
  },
  "normalized": {
    "canonical_customer_id": "CUST-1001",
    "email": "dana@acme.com",
    "data_quality_score": 100,
    "conflicts": []
  }
}
```

## 13. How Xano centralizes normalization without replacing source systems

Each source system stays authoritative for its own data. Xano does not copy or own customer records —
it **reads each system in place** (Postgres via the native external-database connector; Snowflake via
its SQL API; Salesforce via its REST API), then applies one set of mapping, priority, conflict, and
scoring rules to produce a single canonical view on demand. The canonical record, the per-source read
log, and the conflict log are stored for auditability and manual resolution, but the **sources remain
the system of record**. Teams get one trustworthy customer object and a clear, inspectable account of
how it was assembled — without a migration, a new master-data platform, or write-back into the source
systems. Change a priority rule or add a source, and every consumer benefits immediately, because the
normalization logic lives in exactly one place.
