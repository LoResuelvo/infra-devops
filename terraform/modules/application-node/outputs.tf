output "id" {
  description = "OpenStack ID of the replica."
  value       = openstack_compute_instance_v2.instance.id
}

output "name" {
  description = "Stable name of the replica."
  value       = openstack_compute_instance_v2.instance.name
}

output "ipv4" {
  description = "Public IPv4 assigned to the replica."
  value       = openstack_compute_instance_v2.instance.access_ip_v4
}

output "user_data" {
  description = "Rendered cloud-init used by schema and policy tests."
  value       = openstack_compute_instance_v2.instance.user_data
}
