// POST /normalization/conflicts/{conflict_id}/resolve
// Mark a conflict resolved, record the manual resolution, and update the normalized record.
query "normalization/conflicts/{conflict_id}/resolve" verb=POST {
  api_group = "DataNormalization"
  description = "Resolve a normalization conflict with a human-chosen value. Marks it resolved, writes a manual_resolutions audit row, and updates the related normalized customer. Requires the X-API-Secret header (API_AUTH_SECRET)."

  input {
    int conflict_id { description = "normalization_conflicts.id to resolve" }
    text resolved_value { description = "The value the human chose for the conflicted field (required)" }
    text resolved_by { description = "Who resolved it (required)" }
    text resolution_note { description = "Why / how it was resolved (required)" }
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
            endpoint: "normalization/conflicts/{conflict_id}/resolve",
            method: "POST",
            authorized: false,
            customer_id: ($input.conflict_id|to_text),
            detail: { error: ($auth_ok.error) }
          }
        } as $denied_log
      }
    }
    precondition ($auth_ok.authorized == true) {
      error_type = "accessdenied"
      error = ($auth_ok.error)
    }

    function.run "msdn_resolve_conflict" {
      input = {
        conflict_id: $input.conflict_id,
        resolved_value: $input.resolved_value,
        resolved_by: $input.resolved_by,
        resolution_note: $input.resolution_note
      }
    } as $result

    db.add "api_request_logs" {
      data = {
        endpoint: "normalization/conflicts/{conflict_id}/resolve",
        method: "POST",
        authorized: true,
        detail: { conflict_id: $input.conflict_id, resolved_by: $input.resolved_by }
      }
    } as $log
  }

  response = $result
  guid = "R-aDNH3BbGnt0NEGiYB8qQ-GFjQ"
}
