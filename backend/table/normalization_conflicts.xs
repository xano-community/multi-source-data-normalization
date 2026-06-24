table "normalization_conflicts" {
  auth = false

  schema {
    int id
    timestamp created_at?=now
    text canonical_customer_id { description = "The customer this conflict belongs to" }
    enum field {
      values = ["email", "status", "company"]
    }
    json values { description = "Per-source non-empty values that disagreed, e.g. [{source, value}, ...]" }
    text chosen_value? { description = "The value the priority rules selected for the canonical record" }
    enum status?="open" {
      values = ["open", "resolved"]
    }
    text resolved_value?
    text resolved_by?
    text resolution_note?
    timestamp resolved_at?
  }

  index = [
    {type: "primary", field: [{name: "id"}]}
    {type: "btree", field: [{name: "canonical_customer_id"}]}
    {type: "btree", field: [{name: "status"}]}
  ]
  guid = "5YElOrscIbdXi2cYXUwJ9qx_i3s"
}
