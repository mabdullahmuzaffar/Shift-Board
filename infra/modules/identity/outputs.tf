output "identities" {
  description = "Managed identity details keyed by workload name."
  value = {
    for k, id in azurerm_user_assigned_identity.this : k => {
      id           = id.id
      client_id    = id.client_id
      principal_id = id.principal_id
      name         = id.name
    }
  }
}

output "client_ids" {
  description = "Client ids keyed by workload, for the azure.workload.identity/client-id annotation."
  value       = { for k, id in azurerm_user_assigned_identity.this : k => id.client_id }
}
