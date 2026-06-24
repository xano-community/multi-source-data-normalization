function "msdn_persist" {
  description = "Persist the result of a normalization run. Logs every source read into source_records (one row per source, whether or not it matched), upserts the canonical record into normalized_customers keyed by canonical_customer_id, and inserts one open normalization_conflicts row per detected conflict (skipping conflicts already on file for the same customer+field so re-running is idempotent). Returns the saved normalized_customers row."

  input {
    text canonical_customer_id { description = "Stable identity for this customer" }
    json canonical { description = "The canonical object produced by msdn_normalize" }
    json postgres_raw? { description = "Raw Postgres row (or null) for the source_records log" }
    json snowflake_raw? { description = "Raw Snowflake row (or null) for the source_records log" }
    json salesforce_raw? { description = "Raw Salesforce row (or null) for the source_records log" }
  }

  stack {
    var $cid { value = $input.canonical_customer_id }
    var $canon { value = $input.canonical }

    // ---- Log each source read. ----
    var $pg_raw { value = ($input.postgres_raw ?? null) }
    db.add "source_records" {
      data = {
        customer_id: $cid,
        source: "postgres",
        found: ($pg_raw != null),
        raw: $pg_raw,
        mapped: { source_id: ($canon.source_ids.postgres_customer_id) }
      }
    } as $sr_pg

    var $sn_raw { value = ($input.snowflake_raw ?? null) }
    db.add "source_records" {
      data = {
        customer_id: $cid,
        source: "snowflake",
        found: ($sn_raw != null),
        raw: $sn_raw,
        mapped: { source_id: ($canon.source_ids.snowflake_customer_key) }
      }
    } as $sr_sn

    var $sf_raw { value = ($input.salesforce_raw ?? null) }
    db.add "source_records" {
      data = {
        customer_id: $cid,
        source: "salesforce",
        found: ($sf_raw != null),
        raw: $sf_raw,
        mapped: { source_id: ($canon.source_ids.salesforce_account_id) }
      }
    } as $sr_sf

    // ---- Upsert the canonical record. ----
    db.add_or_edit "normalized_customers" {
      field_name = "canonical_customer_id"
      field_value = $cid
      data = {
        canonical_customer_id: $cid,
        source_ids: ($canon.source_ids),
        email: ($canon.email),
        name: ($canon.name),
        company: ($canon.company),
        status: ($canon.status),
        created_at_source: ($canon.created_at),
        lifetime_value: ($canon.lifetime_value),
        last_activity_at: ($canon.last_activity_at),
        data_quality_score: ($canon.data_quality_score),
        conflicts: ($canon.conflicts),
        sources_used: ($canon.sources_used),
        canonical: $canon,
        updated_at: now
      }
    } as $saved

    // ---- Persist conflicts (idempotent: skip a field already open for this customer). ----
    foreach ($canon.conflicts) {
      each as $c {
        db.query "normalization_conflicts" {
          where = $db.normalization_conflicts.canonical_customer_id == $cid && $db.normalization_conflicts.field == $c.field && $db.normalization_conflicts.status == "open"
          return = {type: "exists"}
        } as $already

        conditional {
          if ($already == false) {
            db.add "normalization_conflicts" {
              data = {
                canonical_customer_id: $cid,
                field: ($c.field),
                values: ($c.values),
                chosen_value: ($c.chosen_value),
                status: "open"
              }
            } as $new_conflict
          }
        }
      }
    }
  }

  response = $saved
  guid = "iTxkdUtGy1vBcp2kPK43bUNCejY"
}
