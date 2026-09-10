mock_provider "cloudflare" {}

run "production_pool_and_aliases" {
  command = plan
  variables {
    cloudflare_account_id = "11111111111111111111111111111111"
    cloudflare_zone_id    = "22222222222222222222222222222222"
    origins = {
      production-primary    = { address = "192.0.2.1", enabled = true }
      production-replica-01 = { address = "192.0.2.2", enabled = true }
    }
  }
  assert {
    condition     = output.canonical_hostname == "loresuelvo.com.ar"
    error_message = "Production must keep the apex hostname."
  }
  assert {
    condition     = output.alias_hostnames == tolist(["api.loresuelvo.com.ar", "www.loresuelvo.com.ar"])
    error_message = "Production API and www aliases are missing."
  }
  assert {
    condition     = alltrue([for origin in output.origins : origin.enabled])
    error_message = "Both production origins must be enabled."
  }
}
