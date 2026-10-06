variable "account_id" { type = string }
variable "name" {
  description = "Tunnel name, e.g. urbalurba-eu"
  type        = string
}
variable "domain" {
  description = "Zone the tunnel serves. Routes: <domain> and *.<domain>"
  type        = string
}
variable "service_url" { type = string }
variable "zone" {
  description = "Cloudflare zone containing the domain (defaults to the domain itself)"
  type        = string
}
