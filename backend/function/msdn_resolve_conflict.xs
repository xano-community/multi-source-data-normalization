function "msdn_resolve_conflict" {
  description = "Manually resolve one normalization conflict. Marks the normalization_conflicts row resolved (stamping resolved_value/resolved_by/resolution_note/resolved_at), records a manual_resolutions audit row, and updates the related normalized_customers record: sets the conflicted field to the human-chosen value, drops that conflict from the stored conflicts array, and adds back the 10-point conflict penalty (clamped to 100). Returns {conflict, normalized}."

  input {
    int conflict_id { description = "normalization_conflicts.id to resolve" }
    text resolved_value { description = "The value the human chose for the conflicted field" }
    text resolved_by { description = "Who resolved it" }
    text resolution_note { description = "Why / how it was resolved" }
  }

  stack {
    db.get "normalization_conflicts" {
      field_name = "id"
      field_value = $input.conflict_id
    } as $conflict

    precondition ($conflict != null) {
      error_type = "notfound"
      error = "Conflict not found"
    }

    precondition ($conflict.status == "open") {
      error_type = "inputerror"
      error = "Conflict is already resolved"
    }

    // Mark the conflict resolved.
    db.edit "normalization_conflicts" {
      field_name = "id"
      field_value = $input.conflict_id
      data = {
        status: "resolved",
        resolved_value: $input.resolved_value,
        resolved_by: $input.resolved_by,
        resolution_note: $input.resolution_note,
        resolved_at: now
      }
    } as $updated_conflict

    // Audit row.
    db.add "manual_resolutions" {
      data = {
        conflict_id: $input.conflict_id,
        canonical_customer_id: ($conflict.canonical_customer_id),
        field: ($conflict.field),
        resolved_value: $input.resolved_value,
        resolved_by: $input.resolved_by,
        resolution_note: $input.resolution_note
      }
    } as $resolution

    // Update the related normalized customer record.
    db.get "normalized_customers" {
      field_name = "canonical_customer_id"
      field_value = ($conflict.canonical_customer_id)
    } as $nc

    var $normalized { value = null }
    conditional {
      if ($nc != null) {
        var $field { value = ($conflict.field) }

        // Remaining conflicts = stored conflicts minus the one we just resolved.
        var $remaining { value = (($nc.conflicts ?? [])|filter:($$|get:"field") != $field) }

        // Re-add the 10-pt penalty for this now-resolved conflict, clamped to 100.
        var $new_score { value = (($nc.data_quality_score ?? 0) + 10) }
        conditional {
          if ($new_score > 100) {
            var.update $new_score { value = 100 }
          }
        }

        // Rebuild the canonical snapshot with the chosen value + updated conflicts/score.
        var $new_canon { value = ($nc.canonical ?? {}) }
        var.update $new_canon { value = ($new_canon|set:$field:$input.resolved_value) }
        var.update $new_canon { value = ($new_canon|set:"conflicts":$remaining) }
        var.update $new_canon { value = ($new_canon|set:"data_quality_score":$new_score) }

        var $update_data {
          value = {
            conflicts: $remaining,
            data_quality_score: $new_score,
            canonical: $new_canon,
            updated_at: now
          }
        }
        var.update $update_data { value = ($update_data|set:$field:$input.resolved_value) }

        db.patch "normalized_customers" {
          field_name = "canonical_customer_id"
          field_value = ($conflict.canonical_customer_id)
          data = $update_data
        } as $nc_updated
        var.update $normalized { value = $nc_updated }
      }
    }
  }

  response = { conflict: $updated_conflict, normalized: $normalized }
  guid = "-6htAXreAxgFdsT8BQkxM9lY9P8"
}
