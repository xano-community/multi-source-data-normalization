function "msdn_require_auth" {
  description = "Auth guard for every endpoint. Compares the secret the caller supplied (the X-API-Secret request header) against $env.API_AUTH_SECRET and RETURNS a verdict {authorized, error} — it does not throw. Returning (rather than throwing) lets the calling endpoint log the unauthorized attempt to api_request_logs before raising its own 403, and avoids throwing across a function.run boundary (where an outer try_catch can't read the message). When API_AUTH_SECRET is unset the gate fails closed (authorized:false): the secret must be configured in production. authorized:true only when the env secret is set AND the provided secret matches it exactly."

  input {
    text provided_secret? { description = "The secret supplied by the caller (endpoints pass the X-API-Secret header value)" }
  }

  stack {
    var $expected { value = ($env.API_AUTH_SECRET ?? "") }
    var $given { value = ($input.provided_secret ?? "") }

    var $result { value = { authorized: false, error: "" } }

    conditional {
      if ($expected == "") {
        var.update $result { value = { authorized: false, error: "API_AUTH_SECRET is not configured on this workspace" } }
      }
      elseif ($given == "") {
        var.update $result { value = { authorized: false, error: "Missing API secret (X-API-Secret header)" } }
      }
      elseif ($given == $expected) {
        var.update $result { value = { authorized: true, error: "" } }
      }
      else {
        var.update $result { value = { authorized: false, error: "Invalid API secret" } }
      }
    }
  }

  response = $result

  test "fails closed (authorized:false) when no env secret is configured and the provided secret is empty" {
    input = { provided_secret: "" }
    expect.to_be_false ($response.authorized)
  }

  test "rejects a non-empty wrong secret (authorized:false)" {
    input = { provided_secret: "not-the-secret" }
    expect.to_be_false ($response.authorized)
  }
  guid = "PBMv7qTf0r1jVI_oXi0SV8NgLG4"
}
