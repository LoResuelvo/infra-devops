output "replica_ids" {
  description = "OpenStack IDs keyed by stable replica name."
  value       = { for name, replica in local.replica_inventory : name => replica.id }
}

output "replica_ipv4" {
  description = "Public IPv4 addresses keyed by stable replica name."
  value       = { for name, replica in local.replica_inventory : name => replica.ipv4 }
}

output "replicas" {
  description = "Replica inventory keyed by stable name."
  value       = local.replica_inventory
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
