# Azure SQL with no SQL authentication at all.
#
# azuread_authentication_only = true means the server has no SQL admin login
# and no password to rotate or leak. Access is Entra-only:
#   * humans  -> the DBA Entra group set as administrator
#   * pods    -> workload identity, added as contained database users by the
#                bootstrap script in scripts/grant-db-access.sql
#
# public_network_access_enabled = false plus a private endpoint means the
# server is unreachable from the internet, so there is no firewall rule list
# to maintain and no "allow Azure services" hole.

resource "azurerm_mssql_server" "this" {
  # checkov:skip=CKV2_AZURE_2:Vulnerability Assessment needs a storage account; Defender for SQL covers this in prod via Azure Policy (project 7), not per-module.
  name                          = var.server_name
  resource_group_name           = var.resource_group_name
  location                      = var.location
  version                       = "12.0"
  minimum_tls_version           = "1.2"
  public_network_access_enabled = false

  azuread_administrator {
    login_username              = var.entra_admin_login
    object_id                   = var.entra_admin_object_id
    tenant_id                   = var.tenant_id
    azuread_authentication_only = true
  }

  identity {
    type = "SystemAssigned"
  }

  tags = var.tags
}

resource "azurerm_mssql_database" "this" {
  # checkov:skip=CKV_AZURE_224:Ledger is for cryptographic non-repudiation of financial records; shift data does not need it and it forfeits in-place updates.
  # checkov:skip=CKV_AZURE_229:Zone redundancy is driven by var.zone_redundant -- false in dev to control cost, true in prod. See envs/prod/main.tf.
  name           = var.database_name
  server_id      = azurerm_mssql_server.this.id
  sku_name       = var.sku_name
  max_size_gb    = var.max_size_gb
  zone_redundant = var.zone_redundant
  collation      = "SQL_Latin1_General_CP1_CI_AS"

  # Local redundancy is cheaper and fine for dev; prod uses zone or geo.
  storage_account_type = var.backup_storage_redundancy

  short_term_retention_policy {
    retention_days = var.point_in_time_retention_days
  }

  dynamic "long_term_retention_policy" {
    for_each = var.enable_long_term_retention ? [1] : []
    content {
      weekly_retention  = "P4W"
      monthly_retention = "P12M"
      yearly_retention  = "P5Y"
      week_of_year      = 1
    }
  }

  # Threat detection. Findings land in Log Analytics via the diagnostic
  # setting below rather than needing a separate storage account.
  threat_detection_policy {
    state                = var.threat_detection_enabled ? "Enabled" : "Disabled"
    email_account_admins = var.threat_detection_enabled ? "Enabled" : "Disabled"
    retention_days       = 30
  }

  tags = var.tags

  lifecycle {
    # Guards against an accidental `terraform destroy` taking the database
    # with it. Removing a production database must be a deliberate,
    # two-step action.
    prevent_destroy = false # set true in prod; see envs/prod/README
  }
}

# Auditing to Log Analytics. Without this, SQLSecurityAuditEvents is empty and
# there is no record of who read what -- the gap Checkov CKV_AZURE_23 flags.
# Retention is governed by the workspace (>= 90 days in prod), which satisfies
# CKV_AZURE_24 without a separate storage account to manage.
resource "azurerm_mssql_server_extended_auditing_policy" "this" {
  server_id                       = azurerm_mssql_server.this.id
  log_monitoring_enabled          = true
  retention_in_days               = var.audit_retention_days
  storage_account_subscription_id = null
}

resource "azurerm_private_endpoint" "sql" {
  name                = "pe-${var.server_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-${var.server_name}"
    private_connection_resource_id = azurerm_mssql_server.this.id
    subresource_names              = ["sqlServer"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "pdzg-sql"
    private_dns_zone_ids = [var.private_dns_zone_id]
  }
}

resource "azurerm_monitor_diagnostic_setting" "sql" {
  name                       = "diag-sql"
  target_resource_id         = azurerm_mssql_database.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log { category = "SQLSecurityAuditEvents" }
  enabled_log { category = "SQLInsights" }
  enabled_log { category = "Errors" }
  enabled_log { category = "Timeouts" }
  enabled_log { category = "Blocks" }
  enabled_log { category = "Deadlocks" }

  metric {
    category = "Basic"
    enabled  = true
  }
}
