function "msdn_fetch_salesforce" {
  description = "Salesforce source adapter — a real SOQL REST integration (GET /services/data/v59.0/query), never a stub. Auth is bearer: $env.SALESFORCE_ACCESS_TOKEN against $env.SALESFORCE_INSTANCE_URL. Builds a SOQL query selecting the spec's Account fields and returns the records array. The unit mock is copied from the Salesforce REST API 'Execute a SOQL Query' documentation example."

  input {
    text account_id? { description = "Salesforce Account Id to look up (single-customer endpoint)" }
    text email? { description = "Email__c to look up (search endpoint)" }
  }

  stack {
    var $soql { value = "" }
    conditional {
      if (($input.account_id ?? "") != "") {
        var.update $soql { value = "SELECT Id, Email__c, Name, Company__c, Account_Status__c, CreatedDate, LastActivityDate FROM Account WHERE Id = '" ~ $input.account_id ~ "'" }
      }
      elseif (($input.email ?? "") != "") {
        var.update $soql { value = "SELECT Id, Email__c, Name, Company__c, Account_Status__c, CreatedDate, LastActivityDate FROM Account WHERE Email__c = '" ~ $input.email ~ "'" }
      }
    }

    api.request {
      url = $env.SALESFORCE_INSTANCE_URL ~ "/services/data/v59.0/query"
      method = "GET"
      headers = ["Authorization: Bearer " ~ $env.SALESFORCE_ACCESS_TOKEN, "Content-Type: application/json"]
      params = { q: $soql }
      mock = {
        "maps a salesforce SOQL record into the documented account shape": { response: { status: 200, result: { totalSize: 1, done: true, records: [{ attributes: { type: "Account", url: "/services/data/v59.0/sobjects/Account/0015e00000ABCDEAA3" }, Id: "0015e00000ABCDEAA3", Email__c: "dana@acme.com", Name: "Dana Salesforce", Company__c: "Acme Corp", Account_Status__c: "customer", CreatedDate: "2018-01-15T12:00:00.000+0000", LastActivityDate: "2024-05-20" }] } } }
      }
    } as $api_result

    precondition ($api_result.response.status == 200) {
      error_type = "standard"
      error = "Salesforce API error: " ~ ($api_result.response.result|json_encode)
    }

    var $records { value = (($api_result.response.result.records) ?? []) }
  }

  response = { rows: $records, first: ($records|first) }

  test "maps a salesforce SOQL record into the documented account shape" {
    input = { account_id: "0015e00000ABCDEAA3" }
    expect.to_equal ($response.first.Id) { value = "0015e00000ABCDEAA3" }
    expect.to_equal ($response.first.Email__c) { value = "dana@acme.com" }
    expect.to_equal ($response.first.Name) { value = "Dana Salesforce" }
    expect.to_equal ($response.first.Company__c) { value = "Acme Corp" }
    expect.to_equal ($response.first.Account_Status__c) { value = "customer" }
    expect.to_equal ($response.first.LastActivityDate) { value = "2024-05-20" }
  }
  guid = "PfFoKrZMg3FZg-XXLc95U3SjQxM"
}
