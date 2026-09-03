variable "region" {
  description = "OVH Public Cloud region in which resources will be created."
  type        = string
  default     = "BHS5"

  validation {
    condition     = length(trimspace(var.region)) > 0
    error_message = "The region must not be empty."
  }
}

variable "instance_name" {
  description = "Name assigned to the ephemeral compute instance."
  type        = string
  default     = "loresuelvo-iac-test"

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9._-]{0,254}$", var.instance_name))
    error_message = "The instance name must start with an alphanumeric character and contain only letters, digits, dots, underscores, or hyphens."
  }
}

variable "flavor_name" {
  description = "OpenStack flavor used by the instance."
  type        = string
  default     = "d2-4"

  validation {
    condition     = length(trimspace(var.flavor_name)) > 0
    error_message = "The flavor name must not be empty."
  }
}

variable "image_name" {
  description = "OpenStack image name used to locate the most recent matching image."
  type        = string
  default     = "Ubuntu 24.04"

  validation {
    condition     = length(trimspace(var.image_name)) > 0
    error_message = "The image name must not be empty."
  }
}

variable "public_network_id" {
  description = "UUID of the OVH public network connected to the instance."
  type        = string
  default     = "d7eaf2f8-d9d8-465b-9244-fd4736660570"

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.public_network_id))
    error_message = "The public network ID must be a valid UUID."
  }
}

variable "ssh_public_key_path" {
  description = "Absolute local path to the SSH public key registered in OpenStack."
  type        = string
  default     = "/home/user/.ssh/loresuelvo_terraform.pub"

  validation {
    condition     = startswith(var.ssh_public_key_path, "/") && endswith(var.ssh_public_key_path, ".pub")
    error_message = "The SSH public key path must be an absolute path ending in .pub."
  }
}
