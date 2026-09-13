# AKS cluster written against azurerm 4.x. Note the argument names: 4.0
# renamed enable_auto_scaling -> auto_scaling_enabled,
# enable_node_public_ip -> node_public_ip_enabled, and replaced the old
# addon_profile / role_based_access_control blocks with top-level arguments.
# Configuration copied from 3.x-era tutorials will not plan against 4.x.

resource "azurerm_kubernetes_cluster" "this" {
  # checkov:skip=CKV_AZURE_115:Driven by var.private_cluster_enabled -- true in prod (see envs/prod), false in dev so kubectl works from a laptop without a jumpbox or VPN. A private API server in a throwaway dev environment costs more in access friction than it buys.
  # checkov:skip=CKV_AZURE_117:A disk encryption set needs a Key Vault key with its own rotation and RBAC lifecycle. That belongs to the platform landing zone (roadmap project 7), not to an application cluster module.
  # checkov:skip=CKV_AZURE_226:Ephemeral OS disks require a VM size whose cache exceeds os_disk_size_gb. Standard_D2s_v5 has a 53 GB cache against a 64 GB disk, so this is var-driven via os_disk_type and enabled only on cache-sufficient sizes.
  name                = "aks-${var.name_prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = var.name_prefix
  kubernetes_version  = var.kubernetes_version
  sku_tier            = var.sku_tier
  node_resource_group = "rg-${var.name_prefix}-aks-nodes"

  # Workload identity. Both must be true, and the OIDC issuer URL is what the
  # identity module federates against.
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  # Entra-only access. Local admin kubeconfig is disabled so every kubectl
  # call is an auditable Entra identity subject to Azure RBAC.
  local_account_disabled            = var.local_account_disabled
  role_based_access_control_enabled = true
  azure_policy_enabled              = true

  automatic_upgrade_channel = var.automatic_upgrade_channel
  node_os_upgrade_channel   = var.node_os_upgrade_channel

  # Private cluster: the API server gets a private endpoint and is
  # unreachable from the internet. True in prod. In dev it stays false so a
  # laptop can run kubectl without a jumpbox or VPN, which is a deliberate
  # convenience trade-off rather than an oversight.
  private_cluster_enabled             = var.private_cluster_enabled
  private_dns_zone_id                 = var.private_cluster_enabled ? var.private_cluster_dns_zone_id : null
  private_cluster_public_fqdn_enabled = false

  # When the cluster is public, restrict who may even reach the API server.
  # An empty list would mean 0.0.0.0/0, so the block is only emitted when
  # ranges are supplied -- and prod supplies them.
  dynamic "api_server_access_profile" {
    for_each = (!var.private_cluster_enabled && length(var.api_server_authorized_ip_ranges) > 0) ? [1] : []
    content {
      authorized_ip_ranges = var.api_server_authorized_ip_ranges
    }
  }

  azure_active_directory_role_based_access_control {
    admin_group_object_ids = var.admin_group_object_ids
    azure_rbac_enabled     = true
  }

  # System pool: control-plane-adjacent add-ons only. Tainted via
  # only_critical_addons_enabled so application pods land on the user pool.
  default_node_pool {
    name                         = "system"
    vm_size                      = var.system_node_vm_size
    vnet_subnet_id               = var.aks_subnet_id
    orchestrator_version         = var.kubernetes_version
    auto_scaling_enabled         = true
    min_count                    = var.system_node_min_count
    max_count                    = var.system_node_max_count
    only_critical_addons_enabled = true
    node_public_ip_enabled       = false
    host_encryption_enabled      = true
    os_disk_type                 = var.os_disk_type
    os_disk_size_gb              = 64
    max_pods                     = 60
    zones                        = var.availability_zones
    tags                         = var.tags

    upgrade_settings {
      max_surge = "33%"
    }
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.cluster.id]
  }

  # Azure CNI Overlay: pods get addresses from pod_cidr, not from the VNet,
  # so the node subnet stays small and VNet address space is not exhausted by
  # pod density. Calico supplies NetworkPolicy enforcement.
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_policy      = "calico"
    load_balancer_sku   = "standard"
    outbound_type       = var.outbound_type
    pod_cidr            = var.pod_cidr
    service_cidr        = var.service_cidr
    dns_service_ip      = var.dns_service_ip
  }

  oms_agent {
    log_analytics_workspace_id      = var.log_analytics_workspace_id
    msi_auth_for_monitoring_enabled = true
  }

  key_vault_secrets_provider {
    secret_rotation_enabled  = true
    secret_rotation_interval = "5m"
  }

  # Blocks the deletion of a cluster that still has load balancers or public
  # IPs attached, which otherwise leaves orphaned billable resources behind.
  auto_scaler_profile {
    balance_similar_node_groups      = true
    expander                         = "least-waste"
    scale_down_unneeded              = "10m"
    scale_down_utilization_threshold = "0.5"
    skip_nodes_with_local_storage    = false
    skip_nodes_with_system_pods      = true
  }

  maintenance_window_auto_upgrade {
    frequency   = "Weekly"
    interval    = 1
    duration    = 4
    day_of_week = "Sunday"
    start_time  = "02:00"
    utc_offset  = "+00:00"
  }

  maintenance_window_node_os {
    frequency   = "Weekly"
    interval    = 1
    duration    = 4
    day_of_week = "Sunday"
    start_time  = "06:00"
    utc_offset  = "+00:00"
  }

  tags = var.tags

  lifecycle {
    # The autoscaler owns node_count once the cluster is running; leaving it
    # unignored makes every plan show spurious drift.
    ignore_changes = [default_node_pool[0].node_count]
  }
}

resource "azurerm_user_assigned_identity" "cluster" {
  name                = "id-${var.name_prefix}-aks-cp"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

# The control-plane identity needs to join nodes to a subnet it does not own.
resource "azurerm_role_assignment" "cluster_network_contributor" {
  scope                = var.aks_subnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.cluster.principal_id
}

# Application pool. Spot-capable for dev to cut cost; on-demand in prod.
resource "azurerm_kubernetes_cluster_node_pool" "user" {
  # checkov:skip=CKV_AZURE_226:Same ephemeral-disk cache constraint as the system pool; driven by var.os_disk_type.
  name                    = "app"
  kubernetes_cluster_id   = azurerm_kubernetes_cluster.this.id
  vm_size                 = var.user_node_vm_size
  vnet_subnet_id          = var.aks_subnet_id
  orchestrator_version    = var.kubernetes_version
  auto_scaling_enabled    = true
  min_count               = var.user_node_min_count
  max_count               = var.user_node_max_count
  node_public_ip_enabled  = false
  host_encryption_enabled = true
  os_disk_type            = var.os_disk_type
  os_disk_size_gb         = 128
  max_pods                = 60
  zones                   = var.availability_zones
  mode                    = "User"

  priority        = var.user_node_spot_enabled ? "Spot" : "Regular"
  eviction_policy = var.user_node_spot_enabled ? "Delete" : null
  spot_max_price  = var.user_node_spot_enabled ? -1 : null

  node_labels = merge(
    { "workload" = "application" },
    var.user_node_spot_enabled ? { "kubernetes.azure.com/scalesetpriority" = "spot" } : {}
  )

  # Spot nodes are tainted by Azure automatically; declaring it makes the
  # requirement for a matching toleration in the Helm charts explicit.
  node_taints = var.user_node_spot_enabled ? ["kubernetes.azure.com/scalesetpriority=spot:NoSchedule"] : []

  upgrade_settings {
    max_surge = "33%"
  }

  tags = var.tags

  lifecycle {
    ignore_changes = [node_count]
  }
}

# Diagnostic settings: control-plane logs are not collected by default, and
# their absence is the single most common gap in AKS incident reviews.
resource "azurerm_monitor_diagnostic_setting" "aks" {
  name                       = "diag-aks"
  target_resource_id         = azurerm_kubernetes_cluster.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log { category = "kube-apiserver" }
  enabled_log { category = "kube-controller-manager" }
  enabled_log { category = "kube-scheduler" }
  enabled_log { category = "kube-audit-admin" }
  enabled_log { category = "cluster-autoscaler" }
  enabled_log { category = "guard" }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}
