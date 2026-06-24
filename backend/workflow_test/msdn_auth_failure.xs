// Auth / validation failure path: calling a protected endpoint without the X-API-Secret header
// must be denied (403) AND must leave an audit trail. This proves the governed-failure behavior:
// the request is rejected, and the rejection is logged to api_request_logs with authorized=false.
//
// On the throwaway test workspace API_AUTH_SECRET is unset, so the guard fails closed: the
// conflicts endpoint logs the denied attempt, then raises accessdenied. We assert both halves.
workflow_test "msdn_auth_failure_is_denied_and_logged" {
  tags = ["normalization", "module", "auth", "e2e"]

  stack {
    // Baseline: how many unauthorized log rows exist for this endpoint before the call.
    db.query "api_request_logs" {
      where = $db.api_request_logs.endpoint == "normalization/conflicts" && $db.api_request_logs.authorized == false
      return = {type: "count"}
    } as $denied_before

    // Call the protected endpoint with NO X-API-Secret header — must throw (403). On the throwaway
    // workspace API_AUTH_SECRET is unset, so the guard fails closed with that specific message; the
    // exception matcher does a substring check against the raised error text.
    expect.to_throw {
      stack {
        api.call "normalization/conflicts" verb=GET {
          api_group = "DataNormalization"
        } as $resp
      }

      exception = "API_AUTH_SECRET"
    }

    // The denied attempt must have been written to api_request_logs (authorized=false) before the throw.
    db.query "api_request_logs" {
      where = $db.api_request_logs.endpoint == "normalization/conflicts" && $db.api_request_logs.authorized == false
      return = {type: "count"}
    } as $denied_after

    expect.to_be_greater_than ($denied_after) { value = $denied_before }

    // And the most recent unauthorized row for this endpoint carries the auth error detail.
    db.query "api_request_logs" {
      where = $db.api_request_logs.endpoint == "normalization/conflicts" && $db.api_request_logs.authorized == false
      sort = {created_at: "desc"}
      return = {type: "single"}
    } as $last_denied

    expect.to_not_be_null ($last_denied)
    expect.to_be_false ($last_denied.authorized)
  }
  guid = "Wf8kQ2mTn4pLrS6vXc1bYhJd0aZe3guN"
}
