output "resource_group_name" {
  value = azurerm_resource_group.this.name
}

output "aks_cluster_name" {
  description = "Use with: az aks get-credentials -g <rg> -n <name>"
  value       = module.aks.name
}

output "acr_login_server" {
  description = "Image registry host, consumed by the pipeline and Helm values."
  value       = module.acr.login_server
}

output "sql_server_fqdn" {
  description = "Resolves privately inside the VNet only."
  value       = module.sql.server_fqdn
}

output "sql_database_name" {
  value = module.sql.database_name
}

output "key_vault_name" {
  value = module.keyvault.name
}

output "key_vault_uri" {
  description = "SecretStore vaultUrl for External Secrets Operator."
  value       = module.keyvault.vault_uri
}

output "servicebus_namespace" {
  value = module.servicebus.namespace_name
}

output "servicebus_queue" {
  value = module.servicebus.queue_name
}

output "log_analytics_workspace_id" {
  value = module.observability.workspace_id
}

# These client ids go into the Helm values as the
# azure.workload.identity/client-id service account annotation. Without the
# exact value, token exchange fails with an opaque AADSTS700213.
output "workload_identity_client_ids" {
  description = "Managed identity client ids keyed by workload."
  value       = module.identity.client_ids
}

# Single blob the pipeline consumes to render Helm values, so the values file
# never contains hand-copied ids that drift from reality.
output "helm_values" {
  description = "Environment-specific values for the application Helm releases."
  value = {
    environment             = local.environment
    acrLoginServer          = module.acr.login_server
    sqlServerFqdn           = module.sql.server_fqdn
    sqlDatabaseName         = module.sql.database_name
    keyVaultName            = module.keyvault.name
    keyVaultUri             = module.keyvault.vault_uri
    serviceBusNamespace     = module.servicebus.namespace_name
    serviceBusQueue         = module.servicebus.queue_name
    tenantId                = var.tenant_id
    shiftApiClientId        = module.identity.client_ids["shift-api"]
    rosterWorkerClientId    = module.identity.client_ids["roster-worker"]
    externalSecretsClientId = module.identity.client_ids["external-secrets"]
  }
}

output "front_door_hostname" {
  description = "Public entry point for the application in prod."
  value       = var.enable_front_door ? module.frontdoor[0].endpoint_hostname : null
}
