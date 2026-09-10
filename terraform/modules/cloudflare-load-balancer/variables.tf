variable "account_id" {
  type      = string
  sensitive = true
}

variable "zone_id" {
  type      = string
  sensitive = true
}

variable "environment" {
  type = string

  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "environment must be staging or production."
  }
}

variable "canonical_hostname" {
  type = string
}

variable "api_hostname" {
  type = string
}

variable "alias_hostnames" {
  type = set(string)
}

variable "origins" {
  type = map(object({
    address = string
    enabled = bool
  }))

  validation {
    condition = length(var.origins) > 0 && alltrue([
      for name, origin in var.origins :
      can(regex("^[A-Za-z0-9_-]+$", name)) && can(cidrhost("${origin.address}/32", 0))
    ])
    error_message = "origins must contain at least one named IPv4 origin."
  }
}

variable "session_ttl_seconds" {
  type    = number
  default = 1800

  validation {
    condition     = var.session_ttl_seconds >= 1800 && var.session_ttl_seconds <= 604800
    error_message = "Cookie affinity TTL must be between 1800 and 604800 seconds."
  }
}

variable "drain_seconds" {
  type    = number
  default = 1800

  validation {
    condition     = var.drain_seconds >= 0 && floor(var.drain_seconds) == var.drain_seconds
    error_message = "drain_seconds must be a non-negative whole number."
  }
}
