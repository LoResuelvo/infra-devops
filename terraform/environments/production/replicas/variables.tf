variable "environment" {
  description = "Environment represented by this root."
  type        = string

  validation {
    condition     = var.environment == "production"
    error_message = "This root only accepts environment = production."
  }
}

variable "primary_instance" {
  description = "Existing primary VM, referenced only for inventory outputs."
  type = object({
    name = string
    ipv4 = string
  })

  validation {
    condition     = length(trimspace(var.primary_instance.name)) > 0 && can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}$", var.primary_instance.ipv4)) && can(cidrhost("${var.primary_instance.ipv4}/32", 0))
    error_message = "The primary instance requires a name and a valid IPv4 address."
  }
}

variable "replicas" {
  description = "Replica names keyed by stable Terraform identity. Empty by default."
  type        = map(object({}))
  default     = {}

  validation {
    condition     = alltrue([for name in keys(var.replicas) : can(regex("^[a-zA-Z0-9][a-zA-Z0-9._-]{0,254}$", name))])
    error_message = "Every replica key must be a valid OpenStack instance name."
  }
}

variable "region" {
  description = "OVH Public Cloud region."
  type        = string

  validation {
    condition     = length(trimspace(var.region)) > 0
    error_message = "The region must not be empty."
  }
}

variable "image_name" {
  description = "OpenStack image name."
  type        = string
}

variable "flavor_name" {
  description = "OpenStack flavor name."
  type        = string
}

variable "public_network_id" {
  description = "UUID of the OVH public network."
  type        = string

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
