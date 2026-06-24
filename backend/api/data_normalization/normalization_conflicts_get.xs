// GET /normalization/conflicts
// Return unresolved conflicts from normalization_conflicts.
query "normalization/conflicts" verb=GET {
  api_group = "DataNormalization"
  description = "List open (unresolved) normalization conflicts. Requires the X-API-Secret header (API_AUTH_SECRET)."

  input {
    int page?=1 filters=min:1
    int per_page?=50 filters=min:1|max:200
  }

  stack {
    // Auth gate: read the X-API-Secret header and check it via the guard (which RETURNS a
    // verdict, it does not throw). Log every attempt — authorized or not — then 403 on failure.
    var $secret { value = ($env.$http_headers|get:"x-api-secret") }
    function.run "msdn_require_auth" {
      input = { provided_secret: $secret }
    } as $auth_ok

    conditional {
      if ($auth_ok.authorized == false) {
        db.add "api_request_logs" {
          data = {
            endpoint: "normalization/conflicts",
            method: "GET",
            authorized: false,
            detail: { error: ($auth_ok.error) }
          }
        } as $denied_log
      }
    }
    precondition ($auth_ok.authorized == true) {
      error_type = "accessdenied"
      error = ($auth_ok.error)
    }

    db.query "normalization_conflicts" {
      where = $db.normalization_conflicts.status == "open"
      sort = {created_at: "desc"}
      return = {type: "list", paging: {page: $input.page, per_page: $input.per_page, totals: true}}
    } as $conflicts

    db.add "api_request_logs" {
      data = {
        endpoint: "normalization/conflicts",
        method: "GET",
        authorized: true,
        detail: { returned: ($conflicts.itemsReceived) }
      }
    } as $log
  }

  response = $conflicts
  guid = "cTvM4OSwINP6aEo3M14MWLrotKM"
}
