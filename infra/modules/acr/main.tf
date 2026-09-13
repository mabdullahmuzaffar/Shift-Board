resource "azurerm_container_registry" "this" {
  # All five findings below are Premium-tier features already exposed as
  # variables. dev runs Standard to keep the environment affordable; prod
  # sets sku = "Premium" and turns them on. See envs/*/main.tf.
  # checkov:skip=CKV_AZURE_233:Zone redundancy is Premium-only, driven by var.zone_redundancy_enabled.
  # checkov:skip=CKV_AZURE_237:Dedicated data endpoints are Premium-only and only needed with private endpoints.
  # checkov:skip=CKV_AZURE_165:Geo-replication is Premium-only, driven by var.geo_replication_locations. Single-region until roadmap project 10.
  # checkov:skip=CKV_AZURE_166:Image quarantine is a preview Premium feature; gating is done in the pipeline with a Trivy hard-fail before push instead.
  # checkov:skip=CKV_AZURE_139:Public networking is driven by var.public_network_access_enabled; Standard has no private endpoint support.
  name                = var.registry_name
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = var.sku

  # Admin user disabled: pulls use the kubelet's managed identity via AcrPull,
  # pushes use the pipeline's federated service connection. No static
  # registry credentials exist to leak.
  admin_enabled = false

  # Premium-only features are gated so the module works on Standard in dev.
  public_network_access_enabled = var.sku == "Premium" ? var.public_network_access_enabled : true
  zone_redundancy_enabled       = var.sku == "Premium" ? var.zone_redundancy_enabled : false

  dynamic "retention_policy_in_days" {
    for_each = var.sku == "Premium" ? [1] : []
    content {
      days    = var.untagged_retention_days
      enabled = true
    }
  }

  dynamic "trust_policy" {
    for_each = var.sku == "Premium" && var.content_trust_enabled ? [1] : []
    content {
      enabled = true
    }
  }

  dynamic "georeplications" {
    for_each = var.sku == "Premium" ? var.geo_replication_locations : []
    content {
      location                = georeplications.value
      zone_redundancy_enabled = var.zone_redundancy_enabled
      tags                    = var.tags
    }
  }

  tags = var.tags
}

# Lets every node in the cluster pull without an imagePullSecret.
resource "azurerm_role_assignment" "kubelet_acr_pull" {
  count = var.kubelet_principal_id == null ? 0 : 1

  scope                            = azurerm_container_registry.this.id
  role_definition_name             = "AcrPull"
  principal_id                     = var.kubelet_principal_id
  skip_service_principal_aad_check = true
}
