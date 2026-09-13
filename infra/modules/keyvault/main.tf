# Key Vault holds the handful of secrets that genuinely cannot be replaced by
# a managed identity: third-party API keys, the demo worker id, and any
# webhook signing secret. Database and Service Bus access use workload
# identity instead, so the vault stays nearly empty by design.
#
# RBAC authorisation rather than access policies: access policies cannot be
# scoped per-secret and are awkward to audit.

resource "azurerm_key_vault" "this" {
  # checkov:skip=CKV_AZURE_42:Recoverability is driven by var.purge_protection_enabled -- true in prod, false in dev so the environment can actually be torn down. Purge protection is irreversible once set.
  # checkov:skip=CKV_AZURE_110:Purge protection is irreversible once enabled, so dev leaves it off to allow teardown. var.purge_protection_enabled is true in prod.
  # checkov:skip=CKV_AZURE_109:Network ACLs are present; default_action follows var.public_network_access_enabled, which prod sets to false alongside a private endpoint.
  # checkov:skip=CKV_AZURE_189:Public access is driven by var.public_network_access_enabled; prod sets it false and provisions a private endpoint below.
  name                = var.vault_name
  location            = var.location
  resource_group_name = var.resource_group_name
  tenant_id           = var.tenant_id
  sku_name            = var.sku_name

  rbac_authorization_enabled = true

  purge_protection_enabled   = var.purge_protection_enabled
  soft_delete_retention_days = var.soft_delete_retention_days

  public_network_access_enabled = var.public_network_access_enabled

  network_acls {
    bypass         = "AzureServices"
    default_action = var.public_network_access_enabled ? "Allow" : "Deny"
    ip_rules       = var.allowed_ip_rules
  }

  tags = var.tags
}

# External Secrets Operator reads secrets and projects them as Kubernetes
# Secrets. Scoped to "Secrets User" -- read-only, secrets only, no keys or
# certificates.
resource "azurerm_role_assignment" "secrets_readers" {
  for_each = var.secret_reader_principal_ids

  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = each.value
}

# The pipeline needs to write secrets during bootstrap.
resource "azurerm_role_assignment" "secrets_officers" {
  for_each = var.secret_officer_principal_ids

  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = each.value
}

resource "azurerm_private_endpoint" "kv" {
  count = var.public_network_access_enabled ? 0 : 1

  name                = "pe-${var.vault_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-${var.vault_name}"
    private_connection_resource_id = azurerm_key_vault.this.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "pdzg-kv"
    private_dns_zone_ids = [var.private_dns_zone_id]
  }
}

resource "azurerm_monitor_diagnostic_setting" "kv" {
  name                       = "diag-kv"
  target_resource_id         = azurerm_key_vault.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log { category = "AuditEvent" }
  enabled_log { category = "AzurePolicyEvaluationDetails" }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}
