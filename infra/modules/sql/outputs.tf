output "server_id" {
  value = azurerm_mssql_server.this.id
}

output "server_fqdn" {
  description = "Resolves to the private endpoint address inside the VNet."
  value       = azurerm_mssql_server.this.fully_qualified_domain_name
}

output "database_name" {
  value = azurerm_mssql_database.this.name
}

output "database_id" {
  value = azurerm_mssql_database.this.id
}
