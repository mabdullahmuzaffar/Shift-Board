variable "name_prefix" {
  type        = string
  description = "Short identifier used in resource names."
}

variable "location" {
  type        = string
  description = "Azure region."
}

variable "resource_group_name" {
  type        = string
  description = "Resource group for the identities."
}

variable "oidc_issuer_url" {
  type        = string
  description = "AKS cluster OIDC issuer URL, from the aks module."
}

variable "workloads" {
  description = <<-EOT
    Workloads that need an Azure identity, keyed by logical name. Each entry
    binds one managed identity to one Kubernetes service account.
  EOT
  type = map(object({
    namespace       = string
    service_account = string
  }))
}

variable "tags" {
  type    = map(string)
  default = {}
}
