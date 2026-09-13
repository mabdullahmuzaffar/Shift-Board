output "id" {
  value       = azurerm_kubernetes_cluster.this.id
  description = "Cluster resource id."
}

output "name" {
  value       = azurerm_kubernetes_cluster.this.name
  description = "Cluster name."
}

output "oidc_issuer_url" {
  value       = azurerm_kubernetes_cluster.this.oidc_issuer_url
  description = "OIDC issuer URL used by federated identity credentials."
}

output "kubelet_principal_id" {
  value       = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
  description = "Kubelet identity principal id, for AcrPull."
}

output "node_resource_group" {
  value       = azurerm_kubernetes_cluster.this.node_resource_group
  description = "Azure-managed resource group holding nodes and load balancers."
}

output "kube_config_host" {
  value       = azurerm_kubernetes_cluster.this.kube_config[0].host
  description = "API server address."
  sensitive   = true
}
