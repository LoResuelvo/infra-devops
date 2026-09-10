resource "cloudflare_load_balancer_monitor" "gateway" {
  account_id       = var.account_id
  description      = "${var.environment} gateway readiness"
  type             = "https"
  method           = "GET"
  path             = "/__gateway_ready"
  expected_codes   = "200"
  follow_redirects = false
  header           = { Host = [var.api_hostname] }
}

resource "cloudflare_load_balancer_pool" "application" {
  account_id      = var.account_id
  name            = "loresuelvo-${var.environment}"
  description     = "${var.environment} application nodes"
  monitor         = cloudflare_load_balancer_monitor.gateway.id
  check_regions   = ["ENAM"]
  minimum_origins = 1
  origin_steering = { policy = "random" }
  origins = [for name in sort(keys(var.origins)) : {
    name    = name
    address = var.origins[name].address
    enabled = var.origins[name].enabled
    weight  = 1
    header  = { host = [var.api_hostname] }
  }]
}

resource "cloudflare_load_balancer" "application" {
  zone_id              = var.zone_id
  name                 = var.canonical_hostname
  description          = "${var.environment} application gateway"
  default_pools        = [cloudflare_load_balancer_pool.application.id]
  fallback_pool        = cloudflare_load_balancer_pool.application.id
  proxied              = true
  steering_policy      = "random"
  session_affinity     = "cookie"
  session_affinity_ttl = var.session_ttl_seconds
  session_affinity_attributes = {
    drain_duration         = var.drain_seconds
    samesite               = "Auto"
    secure                 = "Always"
    zero_downtime_failover = "sticky"
  }
}

resource "cloudflare_dns_record" "alias" {
  for_each = var.alias_hostnames

  zone_id = var.zone_id
  name    = each.value
  type    = "CNAME"
  content = var.canonical_hostname
  ttl     = 1
  proxied = true
}
