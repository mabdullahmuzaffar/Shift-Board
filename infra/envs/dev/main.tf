# ShiftBoard -- dev environment composition.
#
# Cost posture: this environment is deliberately cheap, and every saving is a
# conscious choice rather than a default:
#   * AKS Free tier (no uptime SLA), Spot application nodes, min 1 node
#   * Azure SQL serverless GP_S_Gen5_1, which auto-pauses when idle
#   * ACR Standard, Service Bus Standard
#   * No Front Door, no WAF
#   * Public API server and public Key Vault so kubectl and the CLI work
#     without a jumpbox
#
# Everything security-relevant that costs nothing is still on: workload
# identity, Entra-only SQL auth, no local accounts, private endpoints for
# SQL, diagnostic settings, a spend budget.
#
# envs/prod shares the same modules and flips the expensive switches. That is
# the point of the module layer -- the environments differ by values, not by
# copied configuration.

locals {
  environment = "dev"
  name_prefix = "shiftboard-${local.environment}"

  # Compact form for globally-unique names with no hyphens allowed.
  compact_prefix = "shiftboard${local.environment}${var.name_suffix}"

  tags = {
    application = "shiftboard"
    environment = local.environment
    managed_by  = "terraform"
    repository  = "shiftboard"
    cost_centre = "engineering-learning"
  }

  # Workloads needing an Azure identity, and the service account each is
  # bound to. These names must match the Helm chart service accounts exactly
  # or the federated credential will not match and token exchange fails.
  workloads = {
    shift-api = {
      namespace       = "shiftboard"
      service_account = "shift-api"
    }
    roster-worker = {
      namespace       = "shiftboard"
      service_account = "roster-worker"
    }
    external-secrets = {
      namespace       = "external-secrets"
      service_account = "external-secrets"
    }
  }
}

resource "azurerm_resource_group" "this" {
  name     = "rg-${local.name_prefix}"
  location = var.location
  tags     = local.tags
}

module "observability" {
  source = "../../modules/observability"

  name_prefix         = local.name_prefix
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name

  retention_in_days            = 30
  container_log_retention_days = 30
  daily_quota_gb               = 2 # hard cap: a log storm cannot run up the bill

  oncall_emails = var.oncall_emails

  tags = local.tags
}

module "network" {
  source = "../../modules/network"

  name_prefix         = local.name_prefix
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name

  vnet_cidr                    = "10.10.0.0/16"
  aks_subnet_cidr              = "10.10.0.0/22" # nodes only, thanks to CNI overlay
  private_endpoint_subnet_cidr = "10.10.4.0/24"

  tags = local.tags
}

module "aks" {
  source = "../../modules/aks"

  name_prefix         = local.name_prefix
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  aks_subnet_id       = module.network.aks_subnet_id

  log_analytics_workspace_id = module.observability.workspace_id

  kubernetes_version = "1.31"
  sku_tier           = "Free" # no uptime SLA; acceptable for dev

  admin_group_object_ids = var.aks_admin_group_object_ids
  local_account_disabled = true

  # Public API server in dev so kubectl works from a laptop. Narrow the
  # allowlist to your own egress IP with -var to tighten it.
  private_cluster_enabled         = false
  api_server_authorized_ip_ranges = []

  system_node_vm_size   = "Standard_D2s_v5"
  system_node_min_count = 1
  system_node_max_count = 2

  user_node_vm_size      = "Standard_D2s_v5"
  user_node_min_count    = 1
  user_node_max_count    = 3
  user_node_spot_enabled = true # ~70% cheaper; pods must tolerate eviction

  availability_zones = ["1"] # single zone keeps dev cost down

  # Must not overlap the VNet (10.10.0.0/16).
  pod_cidr       = "10.244.0.0/16"
  service_cidr   = "10.0.16.0/20"
  dns_service_ip = "10.0.16.10"

  tags = local.tags
}

# Depends on the AKS OIDC issuer, so it must come after the cluster.
module "identity" {
  source = "../../modules/identity"

  name_prefix         = local.name_prefix
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  oidc_issuer_url     = module.aks.oidc_issuer_url
  workloads           = local.workloads

  tags = local.tags
}

module "acr" {
  source = "../../modules/acr"

  registry_name       = "cr${local.compact_prefix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  sku                 = "Standard"

  kubelet_principal_id    = module.aks.kubelet_principal_id
  untagged_retention_days = 7 # dev churns images fast; purge aggressively

  tags = local.tags
}

module "sql" {
  source = "../../modules/sql"

  server_name         = "sql-${local.name_prefix}-${var.name_suffix}"
  database_name       = "shiftboard"
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  tenant_id           = var.tenant_id

  entra_admin_login     = var.sql_admin_group_name
  entra_admin_object_id = var.sql_admin_group_object_id

  private_endpoint_subnet_id = module.network.private_endpoint_subnet_id
  private_dns_zone_id        = module.network.private_dns_zone_ids["sql"]
  log_analytics_workspace_id = module.observability.workspace_id

  # Serverless: auto-pauses after an hour idle, so an unused dev database
  # costs storage only.
  sku_name    = "GP_S_Gen5_1"
  max_size_gb = 32

  zone_redundant               = false
  backup_storage_redundancy    = "Local"
  point_in_time_retention_days = 7
  enable_long_term_retention   = false
  audit_retention_days         = 0 # governed by the Log Analytics workspace

  tags = local.tags
}

module "keyvault" {
  source = "../../modules/keyvault"

  vault_name          = "kv-${local.compact_prefix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  tenant_id           = var.tenant_id

  log_analytics_workspace_id = module.observability.workspace_id

  # Public in dev so `az keyvault secret set` works from a laptop.
  public_network_access_enabled = true

  # Irreversible once enabled, so dev leaves it off to allow clean teardown.
  purge_protection_enabled   = false
  soft_delete_retention_days = 7

  secret_reader_principal_ids = {
    external-secrets = module.identity.identities["external-secrets"].principal_id
  }

  secret_officer_principal_ids = var.pipeline_principal_ids

  tags = local.tags
}

module "servicebus" {
  source = "../../modules/servicebus"

  namespace_name      = "sb-${local.name_prefix}-${var.name_suffix}"
  queue_name          = "roster-events"
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  sku                 = "Standard"

  log_analytics_workspace_id = module.observability.workspace_id

  max_delivery_count = 5
  lock_duration      = "PT1M" # must exceed worst-case handler time
  message_ttl        = "P7D"

  # Least privilege: the API can only send, the worker can only receive.
  sender_principal_ids = {
    shift-api = module.identity.identities["shift-api"].principal_id
  }

  receiver_principal_ids = {
    roster-worker = module.identity.identities["roster-worker"].principal_id
  }

  tags = local.tags
}

# Metric alerts and the spend budget. Separate module so it can reference
# resource ids produced by the modules above without provisioning a second
# Log Analytics workspace.
module "alerts" {
  source = "../../modules/alerts"

  name_prefix         = local.name_prefix
  resource_group_name = azurerm_resource_group.this.name
  resource_group_id   = azurerm_resource_group.this.id
  action_group_id     = module.observability.action_group_id

  oncall_emails         = var.oncall_emails
  monthly_budget_amount = var.monthly_budget_amount

  servicebus_namespace_id = module.servicebus.namespace_id
  sql_database_id         = module.sql.database_id
  dead_letter_threshold   = 0

  tags = local.tags
}
