function "msdn_normalize" {
  description = "The normalization engine. Pure transform: takes the raw record from each source (Postgres / Snowflake / Salesforce shapes, any of which may be null when that source had no match), maps every field to the canonical schema, applies the source priority rules, detects email/status/company conflicts, and computes the 0-100 data quality score. No database writes — adapters fetch, this decides. Pass an empty object or null for a source that returned nothing."

  input {
    text canonical_customer_id { description = "The stable identity to stamp on the canonical record (normally the requested customer_id)" }
    json postgres? { description = "Raw Postgres row: {customer_id, email, full_name, company_name, account_status, created_at} or null" }
    json snowflake? { description = "Raw Snowflake row: {CUSTOMER_KEY, CUSTOMER_EMAIL, CUSTOMER_NAME, COMPANY, CUSTOMER_STATUS, FIRST_SEEN_DATE, LIFETIME_VALUE, LAST_ACTIVITY_AT} or null" }
    json salesforce? { description = "Raw Salesforce row: {Id, Email__c, Name, Company__c, Account_Status__c, CreatedDate, LastActivityDate} or null" }
  }

  stack {
    // Normalize the three inputs to plain objects (treat null/missing as {}).
    var $pg { value = ($input.postgres ?? {}) }
    var $sf { value = ($input.salesforce ?? {}) }
    var $sn { value = ($input.snowflake ?? {}) }

    // ---- Map each source into canonical field names (exact mappings per spec). ----
    // Empty string for any absent value so the priority/conflict logic only sees "" or a real value.
    var $p {
      value = {
        present: false,
        email: (($pg|get:"email") ?? ""),
        name: (($pg|get:"full_name") ?? ""),
        company: (($pg|get:"company_name") ?? ""),
        status: (($pg|get:"account_status") ?? ""),
        created_at: (($pg|get:"created_at") ?? ""),
        source_id: (($pg|get:"customer_id") ?? "")
      }
    }
    var $s {
      value = {
        present: false,
        email: (($sf|get:"Email__c") ?? ""),
        name: (($sf|get:"Name") ?? ""),
        company: (($sf|get:"Company__c") ?? ""),
        status: (($sf|get:"Account_Status__c") ?? ""),
        created_at: (($sf|get:"CreatedDate") ?? ""),
        last_activity_at: (($sf|get:"LastActivityDate") ?? ""),
        source_id: (($sf|get:"Id") ?? "")
      }
    }
    // Snowflake's SQL API returns every cell as a string (jsonv2), so LIFETIME_VALUE arrives as e.g.
    // "5200.75"; it is coerced with |to_decimal below for the numeric canonical lifetime_value field.
    var $w {
      value = {
        present: false,
        email: (($sn|get:"CUSTOMER_EMAIL") ?? ""),
        name: (($sn|get:"CUSTOMER_NAME") ?? ""),
        company: (($sn|get:"COMPANY") ?? ""),
        status: (($sn|get:"CUSTOMER_STATUS") ?? ""),
        created_at: (($sn|get:"FIRST_SEEN_DATE") ?? ""),
        lifetime_value: ((($sn|get:"LIFETIME_VALUE") ?? 0)|to_decimal),
        last_activity_at: (($sn|get:"LAST_ACTIVITY_AT") ?? ""),
        source_id: (($sn|get:"CUSTOMER_KEY") ?? "")
      }
    }

    // A source "returned a record" if its raw object had any key.
    var $p_present { value = (($pg|keys|count) > 0) }
    var $s_present { value = (($sf|keys|count) > 0) }
    var $w_present { value = (($sn|keys|count) > 0) }
    conditional {
      if ($p_present == true) {
        var.update $p { value = ($p|set:"present":true) }
      }
    }
    conditional {
      if ($s_present == true) {
        var.update $s { value = ($s|set:"present":true) }
      }
    }
    conditional {
      if ($w_present == true) {
        var.update $w { value = ($w|set:"present":true) }
      }
    }

    var $sources_used { value = [] }
    conditional {
      if ($p_present == true) {
        var.update $sources_used { value = ($sources_used|push:"postgres") }
      }
    }
    conditional {
      if ($w_present == true) {
        var.update $sources_used { value = ($sources_used|push:"snowflake") }
      }
    }
    conditional {
      if ($s_present == true) {
        var.update $sources_used { value = ($sources_used|push:"salesforce") }
      }
    }

    // ---- Priority resolution (exact order per spec). ----
    // name / company / status: Salesforce wins, then any other non-empty (postgres, then snowflake).
    var $name { value = "" }
    conditional {
      if ($s.name != "") {
        var.update $name { value = $s.name }
      }
      elseif ($p.name != "") {
        var.update $name { value = $p.name }
      }
      elseif ($w.name != "") {
        var.update $name { value = $w.name }
      }
    }

    var $company { value = "" }
    conditional {
      if ($s.company != "") {
        var.update $company { value = $s.company }
      }
      elseif ($p.company != "") {
        var.update $company { value = $p.company }
      }
      elseif ($w.company != "") {
        var.update $company { value = $w.company }
      }
    }

    var $status { value = "" }
    conditional {
      if ($s.status != "") {
        var.update $status { value = $s.status }
      }
      elseif ($p.status != "") {
        var.update $status { value = $p.status }
      }
      elseif ($w.status != "") {
        var.update $status { value = $w.status }
      }
    }

    // email: Postgres wins, then salesforce, then snowflake.
    var $email { value = "" }
    conditional {
      if ($p.email != "") {
        var.update $email { value = $p.email }
      }
      elseif ($s.email != "") {
        var.update $email { value = $s.email }
      }
      elseif ($w.email != "") {
        var.update $email { value = $w.email }
      }
    }

    // lifetime_value: Snowflake wins (only snowflake supplies it); default 0.
    var $lifetime_value { value = 0 }
    conditional {
      if ($w.present == true) {
        var.update $lifetime_value { value = ($w.lifetime_value ?? 0) }
      }
    }

    // last_activity_at: Snowflake wins, then salesforce.
    var $last_activity_at { value = "" }
    conditional {
      if ($w.last_activity_at != "") {
        var.update $last_activity_at { value = $w.last_activity_at }
      }
      elseif ($s.last_activity_at != "") {
        var.update $last_activity_at { value = $s.last_activity_at }
      }
    }

    // created_at: earliest available (lexicographically smallest non-empty ISO-8601 value).
    var $created_candidates { value = [] }
    conditional {
      if ($p.created_at != "") {
        var.update $created_candidates { value = ($created_candidates|push:$p.created_at) }
      }
    }
    conditional {
      if ($w.created_at != "") {
        var.update $created_candidates { value = ($created_candidates|push:$w.created_at) }
      }
    }
    conditional {
      if ($s.created_at != "") {
        var.update $created_candidates { value = ($created_candidates|push:$s.created_at) }
      }
    }
    // Earliest = lexicographically smallest ISO-8601 string. Compare manually (scalar sort is
    // unreliable here), keeping the smallest seen.
    var $created_at { value = "" }
    foreach ($created_candidates) {
      each as $cand {
        conditional {
          if (($created_at == "") || ($cand < $created_at)) {
            var.update $created_at { value = $cand }
          }
        }
      }
    }

    // ---- Conflict detection (email, status, company): >=2 sources with different non-empty values. ----
    var $conflicts { value = [] }

    // email conflict
    var $email_vals { value = [] }
    conditional {
      if ($p.email != "") {
        var.update $email_vals { value = ($email_vals|push:{source: "postgres", value: $p.email}) }
      }
    }
    conditional {
      if ($s.email != "") {
        var.update $email_vals { value = ($email_vals|push:{source: "salesforce", value: $s.email}) }
      }
    }
    conditional {
      if ($w.email != "") {
        var.update $email_vals { value = ($email_vals|push:{source: "snowflake", value: $w.email}) }
      }
    }
    var $email_distinct { value = ($email_vals|map:($$|get:"value")|unique) }
    conditional {
      if (($email_distinct|count) >= 2) {
        var.update $conflicts { value = ($conflicts|push:{field: "email", chosen_value: $email, values: $email_vals}) }
      }
    }

    // status conflict
    var $status_vals { value = [] }
    conditional {
      if ($p.status != "") {
        var.update $status_vals { value = ($status_vals|push:{source: "postgres", value: $p.status}) }
      }
    }
    conditional {
      if ($s.status != "") {
        var.update $status_vals { value = ($status_vals|push:{source: "salesforce", value: $s.status}) }
      }
    }
    conditional {
      if ($w.status != "") {
        var.update $status_vals { value = ($status_vals|push:{source: "snowflake", value: $w.status}) }
      }
    }
    var $status_distinct { value = ($status_vals|map:($$|get:"value")|unique) }
    conditional {
      if (($status_distinct|count) >= 2) {
        var.update $conflicts { value = ($conflicts|push:{field: "status", chosen_value: $status, values: $status_vals}) }
      }
    }

    // company conflict
    var $company_vals { value = [] }
    conditional {
      if ($p.company != "") {
        var.update $company_vals { value = ($company_vals|push:{source: "postgres", value: $p.company}) }
      }
    }
    conditional {
      if ($s.company != "") {
        var.update $company_vals { value = ($company_vals|push:{source: "salesforce", value: $s.company}) }
      }
    }
    conditional {
      if ($w.company != "") {
        var.update $company_vals { value = ($company_vals|push:{source: "snowflake", value: $w.company}) }
      }
    }
    var $company_distinct { value = ($company_vals|map:($$|get:"value")|unique) }
    conditional {
      if (($company_distinct|count) >= 2) {
        var.update $conflicts { value = ($conflicts|push:{field: "company", chosen_value: $company, values: $company_vals}) }
      }
    }

    // ---- Data quality score (0..100). ----
    var $score { value = 100 }
    conditional {
      if ($email == "") {
        var.update $score { value = ($score - 20) }
      }
    }
    conditional {
      if ($name == "") {
        var.update $score { value = ($score - 15) }
      }
    }
    conditional {
      if ($company == "") {
        var.update $score { value = ($score - 15) }
      }
    }
    conditional {
      if ($status == "") {
        var.update $score { value = ($score - 10) }
      }
    }
    conditional {
      if ($created_at == "") {
        var.update $score { value = ($score - 10) }
      }
    }
    var.update $score { value = ($score - (($conflicts|count) * 10)) }
    conditional {
      if ($score < 0) {
        var.update $score { value = 0 }
      }
    }

    // ---- Assemble the canonical object (exact shape per spec). ----
    var $canonical {
      value = {
        canonical_customer_id: $input.canonical_customer_id,
        source_ids: {
          postgres_customer_id: $p.source_id,
          snowflake_customer_key: $w.source_id,
          salesforce_account_id: $s.source_id
        },
        email: $email,
        name: $name,
        company: $company,
        status: $status,
        created_at: $created_at,
        lifetime_value: $lifetime_value,
        last_activity_at: $last_activity_at,
        data_quality_score: $score,
        conflicts: $conflicts,
        sources_used: $sources_used
      }
    }
  }

  response = $canonical

  // ---------- Field mapping ----------
  test "maps every postgres field into the canonical schema" {
    input = {
      canonical_customer_id: "cust-1",
      postgres: { customer_id: "PG-1", email: "a@pg.com", full_name: "Ada PG", company_name: "PG Co", account_status: "active", created_at: "2020-01-01T00:00:00Z" }
    }
    expect.to_equal ($response.source_ids.postgres_customer_id) { value = "PG-1" }
    expect.to_equal ($response.email) { value = "a@pg.com" }
    expect.to_equal ($response.name) { value = "Ada PG" }
    expect.to_equal ($response.company) { value = "PG Co" }
    expect.to_equal ($response.status) { value = "active" }
    expect.to_equal ($response.created_at) { value = "2020-01-01T00:00:00Z" }
    expect.to_contain ($response.sources_used) { value = "postgres" }
  }

  test "maps every snowflake field and coerces the string-typed LIFETIME_VALUE to a number" {
    input = {
      canonical_customer_id: "cust-2",
      snowflake: { CUSTOMER_KEY: "SN-1", CUSTOMER_EMAIL: "b@sn.com", CUSTOMER_NAME: "Bo SN", COMPANY: "SN Co", CUSTOMER_STATUS: "trial", FIRST_SEEN_DATE: "2019-06-15T00:00:00Z", LIFETIME_VALUE: "4200.5", LAST_ACTIVITY_AT: "2024-02-01T00:00:00Z" }
    }
    expect.to_equal ($response.source_ids.snowflake_customer_key) { value = "SN-1" }
    expect.to_equal ($response.email) { value = "b@sn.com" }
    expect.to_equal ($response.name) { value = "Bo SN" }
    expect.to_equal ($response.company) { value = "SN Co" }
    expect.to_equal ($response.status) { value = "trial" }
    expect.to_equal ($response.created_at) { value = "2019-06-15T00:00:00Z" }
    expect.to_equal ($response.lifetime_value) { value = 4200.5 }
    expect.to_equal ($response.last_activity_at) { value = "2024-02-01T00:00:00Z" }
  }

  test "maps every salesforce field into the canonical schema" {
    input = {
      canonical_customer_id: "cust-3",
      salesforce: { Id: "SF-1", Email__c: "c@sf.com", Name: "Cy SF", Company__c: "SF Co", Account_Status__c: "customer", CreatedDate: "2018-03-03T00:00:00Z", LastActivityDate: "2024-05-05T00:00:00Z" }
    }
    expect.to_equal ($response.source_ids.salesforce_account_id) { value = "SF-1" }
    expect.to_equal ($response.email) { value = "c@sf.com" }
    expect.to_equal ($response.name) { value = "Cy SF" }
    expect.to_equal ($response.company) { value = "SF Co" }
    expect.to_equal ($response.status) { value = "customer" }
    expect.to_equal ($response.created_at) { value = "2018-03-03T00:00:00Z" }
    expect.to_equal ($response.last_activity_at) { value = "2024-05-05T00:00:00Z" }
  }

  // ---------- Priority rules ----------
  test "salesforce wins name, company, and status over postgres and snowflake" {
    input = {
      canonical_customer_id: "p-1",
      postgres: { full_name: "PG Name", company_name: "PG Co", account_status: "pg_status" },
      snowflake: { CUSTOMER_NAME: "SN Name", COMPANY: "SN Co", CUSTOMER_STATUS: "sn_status" },
      salesforce: { Name: "SF Name", Company__c: "SF Co", Account_Status__c: "sf_status" }
    }
    expect.to_equal ($response.name) { value = "SF Name" }
    expect.to_equal ($response.company) { value = "SF Co" }
    expect.to_equal ($response.status) { value = "sf_status" }
  }

  test "postgres wins email over salesforce and snowflake" {
    input = {
      canonical_customer_id: "p-2",
      postgres: { email: "win@pg.com" },
      snowflake: { CUSTOMER_EMAIL: "lose@sn.com" },
      salesforce: { Email__c: "lose@sf.com" }
    }
    expect.to_equal ($response.email) { value = "win@pg.com" }
  }

  test "snowflake wins lifetime_value and last_activity_at" {
    input = {
      canonical_customer_id: "p-3",
      snowflake: { LIFETIME_VALUE: 999.99, LAST_ACTIVITY_AT: "2025-01-01T00:00:00Z" },
      salesforce: { LastActivityDate: "2000-01-01T00:00:00Z" }
    }
    expect.to_equal ($response.lifetime_value) { value = 999.99 }
    expect.to_equal ($response.last_activity_at) { value = "2025-01-01T00:00:00Z" }
  }

  test "earliest available value wins created_at" {
    input = {
      canonical_customer_id: "p-4",
      postgres: { created_at: "2021-12-31T00:00:00Z" },
      snowflake: { FIRST_SEEN_DATE: "2017-01-01T00:00:00Z" },
      salesforce: { CreatedDate: "2019-06-06T00:00:00Z" }
    }
    expect.to_equal ($response.created_at) { value = "2017-01-01T00:00:00Z" }
  }

  test "falls back to next non-empty source when the priority winner is empty" {
    input = {
      canonical_customer_id: "p-5",
      postgres: { full_name: "PG Name", email: "" },
      snowflake: { CUSTOMER_NAME: "SN Name", CUSTOMER_EMAIL: "fallback@sn.com" }
    }
    expect.to_equal ($response.name) { value = "PG Name" }
    expect.to_equal ($response.email) { value = "fallback@sn.com" }
  }

  // ---------- Conflict detection ----------
  test "flags an email conflict when two sources disagree" {
    input = {
      canonical_customer_id: "c-1",
      postgres: { email: "a@pg.com", full_name: "Same", company_name: "Same Co", account_status: "active", created_at: "2020-01-01T00:00:00Z" },
      salesforce: { Email__c: "a@sf.com", Name: "Same", Company__c: "Same Co", Account_Status__c: "active", CreatedDate: "2020-01-01T00:00:00Z" }
    }
    expect.to_equal ($response.email) { value = "a@pg.com" }
    expect.to_equal ($response.data_quality_score) { value = 90 }
  }

  test "flags status and company conflicts together" {
    input = {
      canonical_customer_id: "c-2",
      postgres: { email: "same@x.com", full_name: "N", company_name: "PG Co", account_status: "active", created_at: "2020-01-01T00:00:00Z" },
      snowflake: { CUSTOMER_EMAIL: "same@x.com", COMPANY: "SN Co", CUSTOMER_STATUS: "churned", FIRST_SEEN_DATE: "2020-01-01T00:00:00Z" }
    }
    expect.to_equal ($response.data_quality_score) { value = 80 }
  }

  test "no conflict when only one source supplies a non-empty value" {
    input = {
      canonical_customer_id: "c-3",
      postgres: { email: "solo@pg.com", full_name: "N", company_name: "Co", account_status: "active", created_at: "2020-01-01T00:00:00Z" },
      salesforce: { Name: "N", Company__c: "Co", Account_Status__c: "active", CreatedDate: "2020-01-01T00:00:00Z" }
    }
    expect.to_be_empty ($response.conflicts)
  }

  test "no conflict when both sources agree on the value" {
    input = {
      canonical_customer_id: "c-4",
      postgres: { email: "agree@x.com", full_name: "N", company_name: "Acme", account_status: "active", created_at: "2020-01-01T00:00:00Z" },
      salesforce: { Email__c: "agree@x.com", Name: "N", Company__c: "Acme", Account_Status__c: "active", CreatedDate: "2020-01-01T00:00:00Z" }
    }
    expect.to_be_empty ($response.conflicts)
  }

  // ---------- Data quality scoring ----------
  test "perfect record with no conflicts scores 100" {
    input = {
      canonical_customer_id: "s-1",
      postgres: { customer_id: "PG", email: "f@x.com", full_name: "Full Name", company_name: "Acme", account_status: "active", created_at: "2020-01-01T00:00:00Z" }
    }
    expect.to_equal ($response.data_quality_score) { value = 100 }
  }

  test "missing email deducts 20" {
    input = {
      canonical_customer_id: "s-2",
      postgres: { customer_id: "PG", full_name: "Full Name", company_name: "Acme", account_status: "active", created_at: "2020-01-01T00:00:00Z" }
    }
    expect.to_equal ($response.data_quality_score) { value = 80 }
  }

  test "missing name deducts 15" {
    input = {
      canonical_customer_id: "s-3",
      postgres: { customer_id: "PG", email: "f@x.com", company_name: "Acme", account_status: "active", created_at: "2020-01-01T00:00:00Z" }
    }
    expect.to_equal ($response.data_quality_score) { value = 85 }
  }

  test "missing company deducts 15" {
    input = {
      canonical_customer_id: "s-4",
      postgres: { customer_id: "PG", email: "f@x.com", full_name: "Full Name", account_status: "active", created_at: "2020-01-01T00:00:00Z" }
    }
    expect.to_equal ($response.data_quality_score) { value = 85 }
  }

  test "missing status deducts 10" {
    input = {
      canonical_customer_id: "s-5",
      postgres: { customer_id: "PG", email: "f@x.com", full_name: "Full Name", company_name: "Acme", created_at: "2020-01-01T00:00:00Z" }
    }
    expect.to_equal ($response.data_quality_score) { value = 90 }
  }

  test "missing created_at deducts 10" {
    input = {
      canonical_customer_id: "s-6",
      postgres: { customer_id: "PG", email: "f@x.com", full_name: "Full Name", company_name: "Acme", account_status: "active" }
    }
    expect.to_equal ($response.data_quality_score) { value = 90 }
  }

  test "one conflict deducts 10 (full data, single email conflict -> 90)" {
    input = {
      canonical_customer_id: "s-7",
      postgres: { customer_id: "PG", email: "a@pg.com", full_name: "Full Name", company_name: "Acme", account_status: "active", created_at: "2020-01-01T00:00:00Z" },
      salesforce: { Id: "SF", Email__c: "a@sf.com", Name: "Full Name", Company__c: "Acme", Account_Status__c: "active", CreatedDate: "2020-01-01T00:00:00Z" }
    }
    expect.to_equal ($response.data_quality_score) { value = 90 }
  }

  test "stacks three conflicts plus two missing fields (100 -15 name -10 created -30 conflicts = 45) and never goes negative" {
    input = {
      canonical_customer_id: "s-8",
      postgres: { customer_id: "PG", email: "a@pg.com", company_name: "PG Co", account_status: "pg" },
      snowflake: { CUSTOMER_KEY: "SN", CUSTOMER_EMAIL: "b@sn.com", COMPANY: "SN Co", CUSTOMER_STATUS: "sn" },
      salesforce: { Id: "SF", Email__c: "c@sf.com", Company__c: "SF Co", Account_Status__c: "sf" }
    }
    expect.to_equal ($response.data_quality_score) { value = 45 }
    expect.to_be_greater_than ($response.data_quality_score) { value = -1 }
  }

  test "all sources empty: every field missing deducts to 30, no conflicts, score stays clamped at/above 0" {
    input = { canonical_customer_id: "s-9" }
    expect.to_equal ($response.data_quality_score) { value = 30 }
    expect.to_be_empty ($response.sources_used)
    expect.to_be_greater_than ($response.data_quality_score) { value = -1 }
  }

  // The min-0 clamp is defensive: with these rules the lowest reachable score is 45 (3 conflicts
  // need 3 present fields, leaving only name+created_at deductible). This asserts the clamp guard
  // holds for the worst realistic input — the score is non-negative and bottoms out at 45, not below.
  test "min-0 clamp holds: worst realistic input bottoms out at 45 and is never below 0" {
    input = {
      canonical_customer_id: "s-10",
      postgres: { customer_id: "PG", email: "x@pg.com", company_name: "PG Co", account_status: "pg" },
      snowflake: { CUSTOMER_KEY: "SN", CUSTOMER_EMAIL: "y@sn.com", COMPANY: "SN Co", CUSTOMER_STATUS: "sn" },
      salesforce: { Id: "SF", Email__c: "z@sf.com", Company__c: "SF Co", Account_Status__c: "sf" }
    }
    expect.to_equal ($response.data_quality_score) { value = 45 }
    expect.to_be_within ($response.data_quality_score) {
      min = 0
      max = 100
    }
  }
  guid = "9aJrvCSwNRhox-e7j5SZQk3CvKs"
}
