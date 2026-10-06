module "tunnel" {
  source   = "./modules/tunnel"
  for_each = var.tunnels

  account_id  = var.account_id
  name        = each.key
  domain      = each.value.domain
  zone        = coalesce(each.value.zone, each.value.domain)
  service_url = var.service_url
}

locals {
  # var.out_dir can't default to "${path.module}/out" directly — a variable's
  # default must be a literal, path.module isn't available at that point. Resolve
  # it here instead, where path.module is valid.
  out_dir = coalesce(var.out_dir, "${path.module}/out")
}

# Same five fields and exact names as bus issue #1876 asks for. TUNNEL_SECRET is the token's "s" field, verbatim.
resource "local_sensitive_file" "key" {
  for_each = var.write_key_files ? var.tunnels : {}

  filename        = "${local.out_dir}/${each.key}.key"
  file_permission = "0600"
  content         = <<-EOT
    ENV=${each.value.env}
    TUNNEL_NAME=${each.key}
    TUNNEL_ID=${module.tunnel[each.key].tunnel_id}
    ACCOUNT_ID=${var.account_id}
    TUNNEL_SECRET=${jsondecode(base64decode(module.tunnel[each.key].token)).s}
  EOT
}
