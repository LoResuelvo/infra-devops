mock_provider "cloudflare" {}

run "gateway_pool_contract" {
  command = plan
  variables {
    account_id         = "11111111111111111111111111111111"
    zone_id            = "22222222222222222222222222222222"
    environment        = "staging"
    canonical_hostname = "test.loresuelvo.com.ar"
    api_hostname       = "api-test.loresuelvo.com.ar"
    alias_hostnames    = ["api-test.loresuelvo.com.ar"]
    origins = {
      primary = { address = "192.0.2.1", enabled = true }
      replica = { address = "192.0.2.2", enabled = false }
    }
  }
  assert {
    condition     = cloudflare_load_balancer_monitor.gateway.type == "https" && cloudflare_load_balancer_monitor.gateway.path == "/__gateway_ready" && cloudflare_load_balancer_monitor.gateway.expected_codes == "200" && cloudflare_load_balancer_monitor.gateway.header.Host[0] == "api-test.loresuelvo.com.ar"
    error_message = "The monitor must probe gateway readiness over HTTPS with the API Host."
  }
  assert {
    condition     = cloudflare_load_balancer_pool.application.check_regions[0] == "ENAM" && cloudflare_load_balancer_pool.application.origin_steering.policy == "random" && cloudflare_load_balancer_pool.application.origins[0].weight == 1 && cloudflare_load_balancer_pool.application.origins[1].weight == 1
    error_message = "The pool must use ENAM checks and equal-weight random origins."
  }
  assert {
    condition     = cloudflare_load_balancer.application.session_affinity == "cookie" && cloudflare_load_balancer.application.session_affinity_ttl == 1800 && cloudflare_load_balancer.application.session_affinity_attributes.drain_duration == 1800
    error_message = "Cookie affinity and drain must default to 1800 seconds."
  }
  assert {
    condition     = cloudflare_dns_record.alias["api-test.loresuelvo.com.ar"].content == "test.loresuelvo.com.ar"
    error_message = "Aliases must be CNAMEs to the canonical load balancer."
  }
}
