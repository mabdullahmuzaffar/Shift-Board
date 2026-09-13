output "vnet_id" {
  description = "Resource id of the virtual network."
  value       = azurerm_virtual_network.this.id
}

output "vnet_name" {
  description = "Name of the virtual network."
  value       = azurerm_virtual_network.this.name
}

output "aks_subnet_id" {
  description = "Subnet id for AKS nodes."
  value       = azurerm_subnet.aks.id
}

output "private_endpoint_subnet_id" {
  description = "Subnet id for private endpoints."
  value       = azurerm_subnet.private_endpoints.id
}

output "private_dns_zone_ids" {
  description = "Map of private DNS zone ids keyed by service."
  value       = { for k, z in azurerm_private_dns_zone.this : k => z.id }
}

output "private_dns_zone_names" {
  description = "Map of private DNS zone names keyed by service."
  value       = { for k, z in azurerm_private_dns_zone.this : k => z.name }
}
