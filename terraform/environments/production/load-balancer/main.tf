module "load_balancer" {
  source = "../../../modules/cloudflare-load-balancer"

  account_id          = var.cloudflare_account_id
  zone_id             = var.cloudflare_zone_id
  environment         = "production"
  canonical_hostname  = "loresuelvo.com.ar"
  api_hostname        = "api.loresuelvo.com.ar"
  alias_hostnames     = ["api.loresuelvo.com.ar", "www.loresuelvo.com.ar"]
  origins             = var.origins
  session_ttl_seconds = var.session_ttl_seconds
  drain_seconds       = var.drain_seconds
}
