variable "instance_name" {
  description = "Stable name of the application replica."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9._-]{0,254}$", var.instance_name))
    error_message = "The instance name must start with an alphanumeric character and contain only letters, digits, dots, underscores, or hyphens."
  }
}

variable "region" {
  description = "OVH Public Cloud region."
  type        = string
}

variable "image_name" {
  description = "OpenStack image used for the replica."
  type        = string
}

variable "flavor_name" {
  description = "OpenStack flavor used for the replica."
  type        = string
}

variable "public_network_id" {
  description = "UUID of the public OpenStack network."
  type        = string
}

variable "operator_ssh_public_key" {
  description = "Public key used by the ubuntu administrative user."
  type        = string
}
