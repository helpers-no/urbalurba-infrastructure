terraform {
  required_version = ">= 1.8.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }

  # The tunnel secret ends up in state. Keep state out of git, and turn on OpenTofu state encryption
  # (https://opentofu.org/docs/language/state/encryption/) before using a shared backend.
}

# Auth: export CLOUDFLARE_API_TOKEN=...  (permissions: Account > Cloudflare Tunnel: Edit, Zone > DNS: Edit, Zone > Zone: Read)
provider "cloudflare" {}
