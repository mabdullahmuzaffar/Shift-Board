output "endpoint_hostname" {
  description = "Default Front Door hostname serving the application."
  value       = azurerm_cdn_frontdoor_endpoint.this.host_name
}

output "profile_id" {
  value = azurerm_cdn_frontdoor_profile.this.id
}

output "waf_policy_id" {
  value = var.waf_enabled ? azurerm_cdn_frontdoor_firewall_policy.this[0].id : null
}
