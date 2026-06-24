// End-to-end outcome test: normalize a customer present in all three sources with a deliberate
// email conflict, persist it, then resolve the conflict and verify the side effects.
workflow_test "msdn_normalize_and_resolve_conflict" {
  tags = ["normalization", "module", "e2e"]

  stack {
    // 1) Normalize a customer present in Postgres + Snowflake + Salesforce, with email disagreeing.
    //    Priority: Salesforce wins name/company/status; Postgres wins email; Snowflake wins LTV/last_activity.
    function.call "msdn_normalize" {
      input = {
        canonical_customer_id: "WF-CUST-1",
        postgres: { customer_id: "WF-CUST-1", email: "primary@pg.com", full_name: "PG Name", company_name: "Acme Corp", account_status: "active", created_at: "2021-01-01T00:00:00Z" },
        snowflake: { CUSTOMER_KEY: "SNOW-WF-1", CUSTOMER_EMAIL: "primary@pg.com", CUSTOMER_NAME: "SN Name", COMPANY: "Acme Corp", CUSTOMER_STATUS: "active", FIRST_SEEN_DATE: "2018-01-01T00:00:00Z", LIFETIME_VALUE: 7500, LAST_ACTIVITY_AT: "2024-06-10T00:00:00Z" },
        salesforce: { Id: "SF-WF-1", Email__c: "different@sf.com", Name: "SF Name", Company__c: "Acme Corp", Account_Status__c: "active", CreatedDate: "2019-01-01T00:00:00Z", LastActivityDate: "2024-05-01T00:00:00Z" }
      }
    } as $canonical

    // Priority assertions. company and status agree across sources (no conflict); only email disagrees.
    expect.to_equal ($canonical.name) { value = "SF Name" }
    expect.to_equal ($canonical.company) { value = "Acme Corp" }
    expect.to_equal ($canonical.status) { value = "active" }
    expect.to_equal ($canonical.email) { value = "primary@pg.com" }
    expect.to_equal ($canonical.lifetime_value) { value = 7500 }
    expect.to_equal ($canonical.last_activity_at) { value = "2024-06-10T00:00:00Z" }
    expect.to_equal ($canonical.created_at) { value = "2018-01-01T00:00:00Z" }
    expect.to_equal ($canonical.source_ids.salesforce_account_id) { value = "SF-WF-1" }

    // One email conflict -> all fields present, so score is 100 - 10 = 90.
    expect.to_equal ($canonical.data_quality_score) { value = 90 }

    // 2) Persist the run (source_records + normalized_customers + normalization_conflicts).
    function.call "msdn_persist" {
      input = {
        canonical_customer_id: "WF-CUST-1",
        canonical: $canonical,
        postgres_raw: { customer_id: "WF-CUST-1", email: "primary@pg.com" },
        snowflake_raw: { CUSTOMER_KEY: "SNOW-WF-1", CUSTOMER_EMAIL: "primary@pg.com" },
        salesforce_raw: { Id: "SF-WF-1", Email__c: "different@sf.com" }
      }
    } as $saved

    expect.to_equal ($saved.canonical_customer_id) { value = "WF-CUST-1" }
    expect.to_equal ($saved.data_quality_score) { value = 90 }

    // The email conflict was persisted as an open row.
    db.query "normalization_conflicts" {
      where = $db.normalization_conflicts.canonical_customer_id == "WF-CUST-1" && $db.normalization_conflicts.field == "email" && $db.normalization_conflicts.status == "open"
      return = {type: "single"}
    } as $conflict_row

    expect.to_not_be_null ($conflict_row)
    expect.to_equal ($conflict_row.field) { value = "email" }
    expect.to_equal ($conflict_row.chosen_value) { value = "primary@pg.com" }

    // 3) Resolve the conflict via the resolve function.
    function.call "msdn_resolve_conflict" {
      input = {
        conflict_id: ($conflict_row.id),
        resolved_value: "canonical@chosen.com",
        resolved_by: "data-steward",
        resolution_note: "Manually confirmed the correct address with the customer."
      }
    } as $resolution

    expect.to_equal ($resolution.conflict.status) { value = "resolved" }
    expect.to_equal ($resolution.conflict.resolved_value) { value = "canonical@chosen.com" }
    expect.to_equal ($resolution.normalized.email) { value = "canonical@chosen.com" }

    // Resolving removed the conflict and added back the 10-pt penalty -> 100.
    expect.to_equal ($resolution.normalized.data_quality_score) { value = 100 }

    // The conflict is now marked resolved in the table.
    db.get "normalization_conflicts" {
      field_name = "id"
      field_value = ($conflict_row.id)
    } as $after

    expect.to_equal ($after.status) { value = "resolved" }

    // A manual_resolutions audit row was written for this conflict.
    db.query "manual_resolutions" {
      where = $db.manual_resolutions.conflict_id == ($conflict_row.id)
      return = {type: "single"}
    } as $audit

    expect.to_not_be_null ($audit)
    expect.to_equal ($audit.resolved_by) { value = "data-steward" }
    expect.to_equal ($audit.resolved_value) { value = "canonical@chosen.com" }

    // No open conflicts remain for this customer.
    db.query "normalization_conflicts" {
      where = $db.normalization_conflicts.canonical_customer_id == "WF-CUST-1" && $db.normalization_conflicts.status == "open"
      return = {type: "count"}
    } as $remaining_open

    expect.to_equal ($remaining_open) { value = 0 }
  }
  guid = "Vap_mScJdJjGGfG8AXk0YFfTehQ"
}
