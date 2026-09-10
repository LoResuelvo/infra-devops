mock_provider "cloudflare" {}

run "staging_pool_and_alias" {
  command = plan
  variables {
    cloudflare_account_id = "11111111111111111111111111111111"
    cloudflare_zone_id    = "22222222222222222222222222222222"
    origins = {
      staging-primary    = { address = "192.0.2.1", enabled = true }
      staging-replica-01 = { address = "192.0.2.2", enabled = false }
    }
  }
  assert {
    condition     = output.canonical_hostname == "test.loresuelvo.com.ar"
    error_message = "Staging must keep its canonical hostname."
  }
  assert {
    condition     = output.alias_hostnames == tolist(["api-test.loresuelvo.com.ar"])
    error_message = "Staging API alias is missing."
  }
  assert {
    condition     = output.origins[0].enabled && !output.origins[1].enabled
    error_message = "Origin enabled state must be preserved."
  }
}
