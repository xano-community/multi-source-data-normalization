function "msdn_fetch_postgres" {
  description = "Postgres source adapter. Reads one customer row from the external Postgres database using Xano's NATIVE external-database connector (db.external.postgres.direct_query) — no hand-rolled HTTP, no baked-in mock data. Connection is taken from $env.POSTGRES_CONNECTION_STRING. Returns the raw row in its Postgres shape ({customer_id, email, full_name, company_name, account_status, created_at}) or null when no row matches. NOTE: native external-DB queries cannot be unit-test mocked the way api.request can, so this adapter is exercised live (credential-gated) and the normalization engine is tested directly with injected rows."

  input {
    text customer_id? { description = "Postgres customers.customer_id to look up (used by the single-customer endpoint)" }
    text email? { description = "Email to look up (used by the search endpoint)" }
  }

  stack {
    var $rows { value = [] }

    conditional {
      if (($input.customer_id ?? "") != "") {
        db.external.postgres.direct_query {
          connection_string = $env.POSTGRES_CONNECTION_STRING
          sql = "SELECT customer_id, email, full_name, company_name, account_status, created_at FROM customers WHERE customer_id = ? LIMIT 1"
          arg = [$input.customer_id]
          response_type = "list"
        } as $by_id
        var.update $rows { value = $by_id }
      }
      elseif (($input.email ?? "") != "") {
        db.external.postgres.direct_query {
          connection_string = $env.POSTGRES_CONNECTION_STRING
          sql = "SELECT customer_id, email, full_name, company_name, account_status, created_at FROM customers WHERE email = ?"
          arg = [$input.email]
          response_type = "list"
        } as $by_email
        var.update $rows { value = $by_email }
      }
    }
  }

  response = { rows: $rows, first: ($rows|first) }
  guid = "vFV3v5QG6l2B928wPniuOrHrKr0"
}
