variable "primary_instance" {
  description = "Existing primary VM, referenced only for inventory outputs."
  type = object({
    name = string
    ipv4 = string
  })
  sensitive = true

  validation {
    condition     = length(trimspace(var.primary_instance.name)) > 0 && can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}$", var.primary_instance.ipv4)) && can(cidrhost("${var.primary_instance.ipv4}/32", 0))
    error_message = "The primary instance requires a name and a valid IPv4 address."
  }
}

variable "replica_count" {
  description = "Total number of application replicas managed by this root."
  type        = number
  default     = 0

  validation {
    condition     = var.replica_count >= 0 && var.replica_count <= 99 && floor(var.replica_count) == var.replica_count
    error_message = "replica_count must be a whole number between 0 and 99."
  }
}

variable "public_network_id" {
  description = "UUID of the OVH public network."
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$", var.public_network_id))
    error_message = "The public network ID must be a valid UUID."
  }
}

variable "operator_ssh_public_key" {
  description = "Public key registered in OpenStack for ubuntu administration."
  type        = string

  validation {
    condition     = can(regex("^(ssh-(rsa|ed25519)|ecdsa-sha2-nistp(256|384|521)) ", trimspace(var.operator_ssh_public_key)))
    error_message = "The operator key must be an SSH public key."
  }
}
