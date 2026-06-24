table "api_request_logs" {
  auth = false

  schema {
    int id
    timestamp created_at?=now
    text endpoint { description = "The endpoint path that was invoked" }
    text method?
    bool authorized?=false { description = "Whether the API_AUTH_SECRET check passed" }
    text customer_id? { description = "Customer id (path param) when applicable" }
    text email? { description = "Email query param when applicable" }
    json detail? { description = "Endpoint-specific result summary" }
  }

  index = [
    {type: "primary", field: [{name: "id"}]}
    {type: "btree", field: [{name: "endpoint"}]}
  ]
  guid = "wMA0v9Md4YP5dNiN-lAZcIV8Mxw"
}
