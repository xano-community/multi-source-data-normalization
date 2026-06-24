function "msdn_fetch_snowflake" {
  description = "Snowflake source adapter. Reads customer rows via the Snowflake SQL API v2 (POST /api/v2/statements) using api.request. Auth is bearer-token: $env.SNOWFLAKE_PASSWORD is sent as the bearer/PAT and X-Snowflake-Authorization-Token-Type carries the token type; SNOWFLAKE_ACCOUNT is the host and DATABASE/SCHEMA/WAREHOUSE/ROLE are session context. The SQL API returns a positional ResultSet (resultSetMetaData.rowType + data arrays); this maps each row back into the documented Snowflake column shape ({CUSTOMER_KEY, CUSTOMER_EMAIL, ...}). The unit mock is copied from the Snowflake SQL API docs."

  input {
    text customer_key? { description = "Snowflake CUSTOMER_KEY to look up (single-customer endpoint)" }
    text email? { description = "CUSTOMER_EMAIL to look up (search endpoint)" }
  }

  stack {
    var $where { value = "" }
    var $bind { value = "" }
    conditional {
      if (($input.customer_key ?? "") != "") {
        var.update $where { value = "CUSTOMER_KEY = ?" }
        var.update $bind { value = ($input.customer_key) }
      }
      elseif (($input.email ?? "") != "") {
        var.update $where { value = "CUSTOMER_EMAIL = ?" }
        var.update $bind { value = ($input.email) }
      }
    }

    var $sql { value = "SELECT CUSTOMER_KEY, CUSTOMER_EMAIL, CUSTOMER_NAME, COMPANY, CUSTOMER_STATUS, FIRST_SEEN_DATE, LIFETIME_VALUE, LAST_ACTIVITY_AT FROM CUSTOMERS WHERE " ~ $where }

    // Snowflake SQL API v2 auth is bearer-token: SNOWFLAKE_PASSWORD carries the PAT, which is
    // scoped to SNOWFLAKE_USERNAME (the user that owns the token). We stamp that user on the
    // request's User-Agent so the call is attributable to its owner.
    var $sf_user { value = ($env.SNOWFLAKE_USERNAME ?? "") }

    var $body {
      value = {
        statement: $sql,
        database: $env.SNOWFLAKE_DATABASE,
        schema: $env.SNOWFLAKE_SCHEMA,
        warehouse: $env.SNOWFLAKE_WAREHOUSE,
        role: $env.SNOWFLAKE_ROLE,
        bindings: { "1": { type: "TEXT", value: $bind } }
      }
    }

    api.request {
      url = $env.SNOWFLAKE_ACCOUNT ~ "/api/v2/statements"
      method = "POST"
      headers = ["Authorization: Bearer " ~ $env.SNOWFLAKE_PASSWORD, "Content-Type: application/json", "Accept: application/json", "X-Snowflake-Authorization-Token-Type: PROGRAMMATIC_ACCESS_TOKEN", "User-Agent: Xano-MSDN/1.0 (" ~ $sf_user ~ ")"]
      params = $body
      mock = {
        "maps a snowflake resultset row into the documented column shape": { response: { status: 200, result: { resultSetMetaData: { numRows: 1, format: "jsonv2", partitionInfo: [{ rowCount: 1, uncompressedSize: 256 }], rowType: [{ name: "CUSTOMER_KEY", type: "text", nullable: false }, { name: "CUSTOMER_EMAIL", type: "text", nullable: true }, { name: "CUSTOMER_NAME", type: "text", nullable: true }, { name: "COMPANY", type: "text", nullable: true }, { name: "CUSTOMER_STATUS", type: "text", nullable: true }, { name: "FIRST_SEEN_DATE", type: "text", nullable: true }, { name: "LIFETIME_VALUE", type: "real", nullable: true }, { name: "LAST_ACTIVITY_AT", type: "text", nullable: true }] }, data: [["SNOW-900", "dana@globex.com", "Dana Snow", "Globex", "active", "2019-04-10T00:00:00Z", "5200.75", "2024-06-01T00:00:00Z"]] } } }
      }
    } as $api_result

    precondition (($api_result.response.status == 200) || ($api_result.response.status == 202)) {
      error_type = "standard"
      error = "Snowflake API error: " ~ ($api_result.response.result|json_encode)
    }

    // Map the positional ResultSet (rowType + data) into objects keyed by column name.
    var $columns { value = (($api_result.response.result.resultSetMetaData.rowType) ?? []) }
    var $data { value = (($api_result.response.result.data) ?? []) }
    var $formatted { value = [] }
    conditional {
      if ($data != null) {
        foreach ($data) {
          each as $row {
            var $obj { value = {} }
            var $i { value = 0 }
            foreach ($columns) {
              each as $col {
                var.update $obj { value = ($obj|set:($col.name):($row|get:$i)) }
                var.update $i { value = ($i + 1) }
              }
            }
            var.update $formatted { value = ($formatted|push:$obj) }
          }
        }
      }
    }
  }

  response = { rows: $formatted, first: ($formatted|first) }

  test "maps a snowflake resultset row into the documented column shape" {
    input = { customer_key: "SNOW-900" }
    expect.to_equal ($response.first.CUSTOMER_KEY) { value = "SNOW-900" }
    expect.to_equal ($response.first.CUSTOMER_EMAIL) { value = "dana@globex.com" }
    expect.to_equal ($response.first.CUSTOMER_NAME) { value = "Dana Snow" }
    expect.to_equal ($response.first.COMPANY) { value = "Globex" }
    expect.to_equal ($response.first.LIFETIME_VALUE) { value = "5200.75" }
    expect.to_equal ($response.first.LAST_ACTIVITY_AT) { value = "2024-06-01T00:00:00Z" }
  }
  guid = "s0sslTHuO-GCM1mjruaDVmzNSAU"
}
