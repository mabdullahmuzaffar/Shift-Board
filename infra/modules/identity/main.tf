# One user-assigned managed identity per workload, federated to a specific
# Kubernetes service account. This is the core security decision of the whole
# project: no pod ever holds a password, connection string or client secret.
#
# The trust chain is:
#   ServiceAccount token (projected into the pod, 1h TTL, audience-scoped)
#     -> federated credential on the UAMI (matches issuer + subject exactly)
#       -> Entra ID access token for Azure SQL / Key Vault / Service Bus
#
# Because the subject is `system:serviceaccount:<ns>:<name>`, an identity is
# usable only by pods running under that exact service account in that exact
# namespace. Moving a pod to another namespace silently breaks its access,
# which is the intended blast-radius control.

resource "azurerm_user_assigned_identity" "this" {
  for_each = var.workloads

  name                = "id-${var.name_prefix}-${each.key}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_federated_identity_credential" "this" {
  for_each = var.workloads

  name                = "fic-${each.key}"
  resource_group_name = var.resource_group_name
  parent_id           = azurerm_user_assigned_identity.this[each.key].id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = var.oidc_issuer_url
  subject             = "system:serviceaccount:${each.value.namespace}:${each.value.service_account}"
}
