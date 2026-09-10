output "pool_id" {
  value = cloudflare_load_balancer_pool.application.id
}

output "canonical_hostname" {
  value = var.canonical_hostname
}

output "alias_hostnames" {
  value = sort(tolist(var.alias_hostnames))
}

output "origins" {
  value = [for origin in cloudflare_load_balancer_pool.application.origins : {
    name        = origin.name
    address     = origin.address
    enabled     = origin.enabled
    disabled_at = try(origin.disabled_at, null)
  }]
}

output "drain_seconds" {
  value = var.drain_seconds
}
