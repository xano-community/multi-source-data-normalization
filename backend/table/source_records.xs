table "source_records" {
  auth = false

  schema {
    int id
    timestamp created_at?=now
    text customer_id { description = "The requested canonical customer id this read was performed for" }
    enum source {
      values = ["postgres", "snowflake", "salesforce"]
    }
    bool found?=false { description = "Whether the source returned a record" }
    json raw? { description = "The raw record returned by the source (null when not found)" }
    json mapped? { description = "The record mapped into canonical field names" }
  }

  index = [
    {type: "primary", field: [{name: "id"}]}
    {type: "btree", field: [{name: "customer_id"}]}
    {type: "btree", field: [{name: "source"}]}
  ]
  guid = "rnBC8ZH5KHOyYTMaa0Y_Y7sQYSE"
}
