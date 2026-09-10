variable "cloudflare_account_id" {
  type      = string
  sensitive = true
}
variable "cloudflare_zone_id" {
  type      = string
  sensitive = true
}
variable "origins" {
  type = map(object({ address = string, enabled = bool }))
}
variable "session_ttl_seconds" {
  type    = number
  default = 1800
}
variable "drain_seconds" {
  type    = number
  default = 1800
}
