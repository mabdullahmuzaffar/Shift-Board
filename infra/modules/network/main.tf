# Hub-less single-VNet layout sized for one environment. Subnets are separated
# so NSGs and service endpoints can differ per tier, and so the AKS node
# subnet can be swapped for a larger prefix later without renumbering
# everything else.

resource "azurerm_virtual_network" "this" {
  name                = "vnet-${var.name_prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = [var.vnet_cidr]
  tags                = var.tags
}

# AKS nodes. With Azure CNI Overlay the pods live in their own overlay CIDR,
# so this subnet only needs one address per node, not one per pod. That is the
# whole reason for choosing overlay: a /22 here supports far more pods than
# the same prefix would in classic Azure CNI.
resource "azurerm_subnet" "aks" {
  name                 = "snet-aks-nodes"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.aks_subnet_cidr]
}

# Private Endpoints for Azure SQL and Key Vault.
resource "azurerm_subnet" "private_endpoints" {
  name                 = "snet-private-endpoints"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.private_endpoint_subnet_cidr]

  private_endpoint_network_policies = "Enabled"
}

# Private endpoints do not enforce NSGs on their own NIC by default, but
# attaching one to the subnet documents and constrains lateral movement into
# the data tier -- only the AKS subnet may reach it.
resource "azurerm_network_security_group" "private_endpoints" {
  name                = "nsg-${var.name_prefix}-pe"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_network_security_rule" "pe_allow_from_aks" {
  name                        = "allow-from-aks-subnet"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_ranges     = ["1433", "443", "5671", "5672"]
  source_address_prefix       = var.aks_subnet_cidr
  destination_address_prefix  = var.private_endpoint_subnet_cidr
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.private_endpoints.name
}

resource "azurerm_network_security_rule" "pe_deny_all_inbound" {
  name                        = "deny-all-inbound"
  priority                    = 4096
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.private_endpoints.name
}

resource "azurerm_subnet_network_security_group_association" "private_endpoints" {
  subnet_id                 = azurerm_subnet.private_endpoints.id
  network_security_group_id = azurerm_network_security_group.private_endpoints.id
}

resource "azurerm_network_security_group" "aks" {
  name                = "nsg-${var.name_prefix}-aks"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

# AKS manages most node-subnet rules itself; this rule exists so the default
# deny-all posture is explicit rather than implied, which is what a reviewer
# or a Checkov policy will look for.
resource "azurerm_network_security_rule" "deny_inbound_internet" {
  name                        = "deny-inbound-internet"
  priority                    = 4000
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "Internet"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.aks.name
}

resource "azurerm_subnet_network_security_group_association" "aks" {
  subnet_id                 = azurerm_subnet.aks.id
  network_security_group_id = azurerm_network_security_group.aks.id
}

# ---------------------------------------------------------------- private DNS
# Without these zones the private endpoints resolve to public IPs and the
# whole point of private networking is lost.
locals {
  private_dns_zones = {
    sql        = "privatelink.database.windows.net"
    keyvault   = "privatelink.vaultcore.azure.net"
    servicebus = "privatelink.servicebus.windows.net"
  }
}

resource "azurerm_private_dns_zone" "this" {
  for_each            = local.private_dns_zones
  name                = each.value
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "this" {
  for_each              = local.private_dns_zones
  name                  = "link-${each.key}-${var.name_prefix}"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.this[each.key].name
  virtual_network_id    = azurerm_virtual_network.this.id
  registration_enabled  = false
  tags                  = var.tags
}
