terraform {
  required_providers {
    cloudflare = { source = "cloudflare/cloudflare" }
  }
}

locals {
  hostnames = [var.domain, "*.${var.domain}"]
}

data "cloudflare_zone" "this" {
  filter = { name = var.zone }
}

# Remotely managed (config_src = cloudflare): routes live in Cloudflare, cloudflared only needs the token.
resource "cloudflare_zero_trust_tunnel_cloudflared" "this" {
  account_id = var.account_id
  name       = var.name
  config_src = "cloudflare"
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "this" {
  account_id = var.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.this.id

  config = {
    ingress = concat(
      [for h in local.hostnames : { hostname = h, service = var.service_url }],
      [{ service = "http_status:404" }] # required catch-all, must be last
    )
  }
}

# Does not replace an existing record: if @ already has an A record this errors, by design.
resource "cloudflare_dns_record" "this" {
  for_each = toset(local.hostnames)

  zone_id = data.cloudflare_zone.this.zone_id
  name    = each.value
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.this.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
}

data "cloudflare_zero_trust_tunnel_cloudflared_token" "this" {
  account_id = var.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.this.id
}
