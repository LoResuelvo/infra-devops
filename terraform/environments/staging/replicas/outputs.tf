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

output "deployment_hosts" {
  description = "Primary VM followed by replicas, for deployment inventory generation."
  value = concat(
    [{
      role = "primary"
      name = var.primary_instance.name
      ipv4 = var.primary_instance.ipv4
    }],
    [for name in sort(keys(local.replica_inventory)) : {
      role = "replica"
      name = local.replica_inventory[name].name
      ipv4 = local.replica_inventory[name].ipv4
    }]
  )
}
