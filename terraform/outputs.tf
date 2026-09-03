output "instance_id" {
  description = "OpenStack ID of the instance."
  value       = openstack_compute_instance_v2.instance.id
}

output "instance_name" {
  description = "Name of the instance."
  value       = openstack_compute_instance_v2.instance.name
}

output "public_ipv4" {
  description = "Public IPv4 address assigned to the instance."
  value       = openstack_compute_instance_v2.instance.access_ip_v4
}

output "ssh_command" {
  description = "Command used to connect to the instance as Ubuntu."
  value       = "ssh ubuntu@${openstack_compute_instance_v2.instance.access_ip_v4}"
}
