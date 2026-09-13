# ShiftBoard -- production environment composition.
#
# Identical module set to envs/dev. Every difference is a value, not a
# structural change, which is what makes the two environments genuinely
# comparable and lets a dev-tested change be trusted in prod.
#
# What prod turns on and why:
#   * AKS Standard tier            -- buys the API server uptime SLA
#   * Three availability zones     -- survives a single-zone failure
#   * On-demand nodes, min 3       -- Spot eviction is unacceptable here
#   * Private API server           -- not reachable from the internet
#   * SQL GP_Gen5_2, zone redundant, Geo backups -- restorable cross-region
#   * ACR Premium + geo-replication -- private endpoints and a warm second region
#   * Service Bus Premium          -- resource isolation and private endpoints
#   * Key Vault private + purge protection -- irreversible, as it should be
#   * Front Door + WAF             -- TLS and OWASP filtering at the edge
#   * 90-day log retention, 90-day SQL audit retention
#
# Cost is roughly 8-10x dev. Read docs/cost.md before applying.

locals {
  environment = "prod"
  name_prefix = "shiftboard-${local.environment}"

  # Compact form for globally-unique names with no hyphens allowed.
  compact_prefix = "shiftboard${local.environment}${var.name_suffix}"

  tags = {
    application = "shiftboard"
    environment = local.environment
    managed_by  = "terraform"
    criticality = "tier-2"
    data_class  = "confidential"
    repository  = "shiftboard"
    cost_centre = "engineering-production"
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

  # 90 days satisfies the usual audit baseline. Container stdout is pruned
  # sooner because it is high-volume and low long-term value.
  retention_in_days            = 90
  container_log_retention_days = 30
  daily_quota_gb               = 20

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
  sku_tier           = "Standard" # required for the API server uptime SLA

  admin_group_object_ids = var.aks_admin_group_object_ids
  local_account_disabled = true

  # Private API server. Reaching it needs a self-hosted pipeline agent or a
  # jumpbox inside the VNet -- deliberate friction on production access.
  private_cluster_enabled         = var.private_cluster_enabled
  api_server_authorized_ip_ranges = var.api_server_authorized_ip_ranges

  system_node_vm_size   = "Standard_D4s_v5"
  system_node_min_count = 3 # one per zone
  system_node_max_count = 6

  user_node_vm_size      = "Standard_D4s_v5"
  user_node_min_count    = 3
  user_node_max_count    = 12
  user_node_spot_enabled = false # eviction mid-request is not acceptable

  availability_zones = ["1", "2", "3"]

  # Must not overlap the VNet (10.20.0.0/16).
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
  sku                 = "Premium"

  kubelet_principal_id    = module.aks.kubelet_principal_id
  untagged_retention_days = 30

  # Premium-only. Geo-replication gives a warm registry in the DR region so
  # a failover does not depend on cross-region pulls.
  public_network_access_enabled = true
  zone_redundancy_enabled       = true
  geo_replication_locations     = ["northeurope"]
  content_trust_enabled         = true

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

  # Provisioned, not serverless: auto-pause would add cold-start latency to
  # the first request after an idle period.
  sku_name    = "GP_Gen5_2"
  max_size_gb = 128

  zone_redundant = true

  # Geo redundancy is what makes a cross-region restore possible at all.
  # Local backups cannot be restored into another region, which would make
  # the DR plan in docs/disaster-recovery.md fiction.
  backup_storage_redundancy    = "Geo"
  point_in_time_retention_days = 35 # the maximum
  enable_long_term_retention   = true
  audit_retention_days         = 90

  tags = local.tags
}

module "keyvault" {
  source = "../../modules/keyvault"

  vault_name          = "kv-${local.compact_prefix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  tenant_id           = var.tenant_id

  log_analytics_workspace_id = module.observability.workspace_id

  # Private endpoint only. Secret writes happen from a pipeline agent inside
  # the VNet, never from a laptop.
  public_network_access_enabled = false
  private_endpoint_subnet_id    = module.network.private_endpoint_subnet_id
  private_dns_zone_id           = module.network.private_dns_zone_ids["keyvault"]

  # Irreversible, and correct here: a deleted production secret must be
  # recoverable and must not be purgeable by a compromised identity.
  purge_protection_enabled   = true
  soft_delete_retention_days = 90

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
  sku                 = "Premium"
  capacity            = 1

  log_analytics_workspace_id = module.observability.workspace_id

  max_delivery_count = 5
  lock_duration      = "PT1M" # must exceed worst-case handler time
  message_ttl        = "P14D"

  # Premium-only. Producers and consumers reach the namespace over the
  # private endpoint subnet.
  public_network_access_enabled = false

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

# Front Door + WAF, prod only. TLS terminates at the edge with a managed
# certificate and the OWASP rule set filters traffic before it reaches a pod.
module "frontdoor" {
  source = "../../modules/frontdoor"
  count  = var.enable_front_door ? 1 : 0

  name_prefix         = local.name_prefix
  resource_group_name = azurerm_resource_group.this.name

  log_analytics_workspace_id = module.observability.workspace_id

  sku_name        = "Standard_AzureFrontDoor"
  origin_hostname = var.ingress_hostname

  # Start in Detection, review the WAF log for false positives against real
  # traffic, then switch to Prevention. Going straight to Prevention is how
  # you block your own users on day one.
  waf_enabled = true
  waf_mode    = "Detection"

  tags = local.tags
}
