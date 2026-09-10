output "pool_id" { value = module.load_balancer.pool_id }
output "canonical_hostname" { value = module.load_balancer.canonical_hostname }
output "alias_hostnames" { value = module.load_balancer.alias_hostnames }
output "origins" { value = module.load_balancer.origins }
output "drain_seconds" { value = module.load_balancer.drain_seconds }
