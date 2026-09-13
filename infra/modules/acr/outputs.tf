output "id" {
  value       = azurerm_container_registry.this.id
  description = "ACR resource id."
}

output "login_server" {
  value       = azurerm_container_registry.this.login_server
  description = "Registry hostname used in image references."
}

output "name" {
  value       = azurerm_container_registry.this.name
  description = "Registry name."
}
