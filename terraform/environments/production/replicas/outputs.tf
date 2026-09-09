output "replica_count" {
  description = "Number of managed replicas."
  value       = length(local.replica_inventory)
}

output "replica_names" {
  description = "Stable replica names in deployment order."
  value       = sort(keys(local.replica_inventory))
}

output "replica_ipv4" {
  description = "Public IPv4 addresses in the same order as replica_names."
  value       = [for name in sort(keys(local.replica_inventory)) : local.replica_inventory[name].ipv4]
}
