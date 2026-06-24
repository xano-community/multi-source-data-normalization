table "manual_resolutions" {
  auth = false

  schema {
    int id
    timestamp created_at?=now
    int conflict_id { table = "normalization_conflicts" }
    text canonical_customer_id?
    enum field? {
      values = ["email", "status", "company"]
    }
    text resolved_value
    text resolved_by
    text resolution_note
  }

  index = [
    {type: "primary", field: [{name: "id"}]}
    {type: "btree", field: [{name: "conflict_id"}]}
  ]
  guid = "Xkq2vQCf9vkF8daHL3hisn6jRvA"
}
