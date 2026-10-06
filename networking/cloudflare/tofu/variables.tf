variable "account_id" {
  description = "Cloudflare account ID"
  type        = string
  default     = "97e30a13fdbed4f09e53db9aba18d144"
}

variable "service_url" {
  description = "Origin every hostname routes to (Traefik inside the cluster)"
  type        = string
  default     = "http://traefik.kube-system.svc.cluster.local:80"
}

variable "tunnels" {
  description = "One entry per tunnel, keyed by tunnel name. env is test or prod. Example: -var 'tunnels={\"urbalurba-eu\":{domain=\"urbalurba.eu\",env=\"test\"}}'"
  type = map(object({
    domain = string
    env    = string
    zone   = optional(string) # Cloudflare zone if domain is a subdomain, e.g. domain=app.example.com zone=example.com
  }))
  default = {}
}

variable "write_key_files" {
  description = "Write out/<name>.key (ENV, TUNNEL_NAME, TUNNEL_ID, ACCOUNT_ID, TUNNEL_SECRET) for the ops agent"
  type        = bool
  default     = true
}

variable "out_dir" {
  description = "Directory the generated <name>.key files are written into. Defaults to the module's own out/ directory (null is not a literal here — see main.tf's coalesce, which resolves it against path.module) — override when the module source path isn't host-persistent (e.g. baked into a container image)."
  type        = string
  default     = null
}
