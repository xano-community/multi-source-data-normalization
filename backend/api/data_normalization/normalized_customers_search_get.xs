// GET /normalized/customers/search?email=...
// Search all three sources by email and return an array of canonical customer objects.
query "normalized/customers/search" verb=GET {
  api_group = "DataNormalization"
  description = "Search Postgres, Snowflake, and Salesforce by email and return an array of normalized canonical customer objects. Requires the X-API-Secret header (API_AUTH_SECRET)."

  input {
    text email { description = "Email address to search for across all three sources (required)" }
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
            endpoint: "normalized/customers/search",
            method: "GET",
            authorized: false,
            email: $input.email,
            detail: { error: ($auth_ok.error) }
          }
        } as $denied_log
      }
    }
    precondition ($auth_ok.authorized == true) {
      error_type = "accessdenied"
      error = ($auth_ok.error)
    }

    function.run "msdn_fetch_postgres" {
      input = { email: $input.email }
    } as $pg

    function.run "msdn_fetch_snowflake" {
      input = { email: $input.email }
    } as $sn

    function.run "msdn_fetch_salesforce" {
      input = { email: $input.email }
    } as $sf

    var $results { value = [] }

    // Identity is anchored on Postgres rows (one per customer_id). Each is merged with the
    // email-matched Snowflake / Salesforce record, normalized, and persisted.
    conditional {
      if ((($pg.rows ?? [])|count) > 0) {
        foreach ($pg.rows) {
          each as $pgrow {
            var $cid { value = (($pgrow|get:"customer_id") ?? $input.email) }
            function.run "msdn_normalize" {
              input = {
                canonical_customer_id: $cid,
                postgres: $pgrow,
                snowflake: ($sn.first),
                salesforce: ($sf.first)
              }
            } as $canon

            function.run "msdn_persist" {
              input = {
                canonical_customer_id: $cid,
                canonical: $canon,
                postgres_raw: $pgrow,
                snowflake_raw: ($sn.first),
                salesforce_raw: ($sf.first)
              }
            } as $saved

            var.update $results { value = ($results|push:$canon) }
          }
        }
      }
    }

    // No Postgres match but the other sources returned something: still emit one canonical.
    conditional {
      if (((($pg.rows ?? [])|count) == 0) && ((($sn.first) != null) || (($sf.first) != null))) {
        var $cid2 { value = $input.email }
        function.run "msdn_normalize" {
          input = {
            canonical_customer_id: $cid2,
            postgres: null,
            snowflake: ($sn.first),
            salesforce: ($sf.first)
          }
        } as $canon2

        function.run "msdn_persist" {
          input = {
            canonical_customer_id: $cid2,
            canonical: $canon2,
            postgres_raw: null,
            snowflake_raw: ($sn.first),
            salesforce_raw: ($sf.first)
          }
        } as $saved2

        var.update $results { value = ($results|push:$canon2) }
      }
    }

    db.add "api_request_logs" {
      data = {
        endpoint: "normalized/customers/search",
        method: "GET",
        authorized: true,
        email: $input.email,
        detail: { matches: ($results|count) }
      }
    } as $log
  }

  response = $results
  guid = "li9WSnnuNuTAWgqqQV_2l4iN_Ug"
}
