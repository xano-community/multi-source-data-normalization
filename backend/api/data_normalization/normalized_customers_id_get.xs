// GET /normalized/customers/{customer_id}
// Query all three sources for this customer, normalize, apply priority, detect conflicts,
// compute the data-quality score, persist, and return the canonical object.
query "normalized/customers/{customer_id}" verb=GET {
  api_group = "DataNormalization"
  description = "Fetch a customer from Postgres, Snowflake, and Salesforce, merge into the canonical schema, persist, and return it. Requires the X-API-Secret header (API_AUTH_SECRET)."

  input {
    text customer_id { description = "Canonical/Postgres customer id to resolve. Also used as the Snowflake CUSTOMER_KEY and Salesforce Account Id lookup key." }
  }

  stack {
    // Auth gate: guard RETURNS a verdict (no throw); log the attempt, then 403 on failure.
    var $secret { value = ($env.$http_headers|get:"x-api-secret") }
    function.run "msdn_require_auth" {
      input = { provided_secret: $secret }
    } as $auth_ok

    conditional {
      if ($auth_ok.authorized == false) {
        db.add "api_request_logs" {
          data = {
            endpoint: "normalized/customers/{customer_id}",
            method: "GET",
            authorized: false,
            customer_id: $input.customer_id,
            detail: { error: ($auth_ok.error) }
          }
        } as $denied_log
      }
    }
    precondition ($auth_ok.authorized == true) {
      error_type = "accessdenied"
      error = ($auth_ok.error)
    }

    // --- Source reads (each adapter is a thin wrapper; Postgres is native, the others are api.request). ---
    function.run "msdn_fetch_postgres" {
      input = { customer_id: $input.customer_id }
    } as $pg

    function.run "msdn_fetch_snowflake" {
      input = { customer_key: $input.customer_id }
    } as $sn

    function.run "msdn_fetch_salesforce" {
      input = { account_id: $input.customer_id }
    } as $sf

    // --- Normalize (pure engine). ---
    function.run "msdn_normalize" {
      input = {
        canonical_customer_id: $input.customer_id,
        postgres: ($pg.first),
        snowflake: ($sn.first),
        salesforce: ($sf.first)
      }
    } as $canonical

    // --- Persist source reads, canonical record, and conflicts. ---
    function.run "msdn_persist" {
      input = {
        canonical_customer_id: $input.customer_id,
        canonical: $canonical,
        postgres_raw: ($pg.first),
        snowflake_raw: ($sn.first),
        salesforce_raw: ($sf.first)
      }
    } as $saved

    db.add "api_request_logs" {
      data = {
        endpoint: "normalized/customers/{customer_id}",
        method: "GET",
        authorized: true,
        customer_id: $input.customer_id,
        detail: { sources_used: ($canonical.sources_used), data_quality_score: ($canonical.data_quality_score), conflicts: ($canonical.conflicts|count) }
      }
    } as $log
  }

  response = $canonical
  guid = "cLEK7HJ_oOoJW1GaDodcH4rpZI4"
}
