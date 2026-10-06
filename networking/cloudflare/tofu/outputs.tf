output "tunnel_ids" {
  value = { for k, m in module.tunnel : k => m.tunnel_id }
}

output "hostnames" {
  value = { for k, m in module.tunnel : k => m.hostnames }
}

output "account_id" {
  value = var.account_id
}
