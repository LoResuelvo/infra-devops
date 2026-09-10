module "load_balancer" {
  source = "../../../modules/cloudflare-load-balancer"

  account_id          = var.cloudflare_account_id
  zone_id             = var.cloudflare_zone_id
  environment         = "staging"
  canonical_hostname  = "test.loresuelvo.com.ar"
  api_hostname        = "api-test.loresuelvo.com.ar"
  alias_hostnames     = ["api-test.loresuelvo.com.ar"]
  origins             = var.origins
  session_ttl_seconds = var.session_ttl_seconds
  drain_seconds       = var.drain_seconds
}
