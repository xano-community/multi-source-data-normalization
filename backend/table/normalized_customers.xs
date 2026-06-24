table "normalized_customers" {
  auth = false

  schema {
    int id
    timestamp created_at?=now
    timestamp updated_at?
    text canonical_customer_id { description = "Stable identity for this customer across all sources (defaults to the requested customer_id)" }
    json source_ids { description = "{postgres_customer_id, snowflake_customer_key, salesforce_account_id}" }
    text email?
    text name?
    text company?
    text status?
    text created_at_source? { description = "Earliest non-empty created_at across the sources (string, source-provided)" }
    decimal lifetime_value?=0
    text last_activity_at?
    int data_quality_score?=0
    json conflicts? { description = "Array of conflict descriptors detected for this customer at normalization time" }
    json sources_used? { description = "Array of source names that returned a record" }
    json canonical? { description = "The full canonical object as last computed" }
  }

  index = [
    {type: "primary", field: [{name: "id"}]}
    {type: "btree|unique", field: [{name: "canonical_customer_id"}]}
    {type: "btree", field: [{name: "email"}]}
  ]
  guid = "tMFWt2k515IuaSl2zI3upMLMxLY"
}
