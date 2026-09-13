variable "registry_name" {
  description = "Globally unique ACR name (alphanumeric only, 5-50 chars)."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9]{5,50}$", var.registry_name))
    error_message = "ACR names must be 5-50 alphanumeric characters with no hyphens."
  }
}

variable "resource_group_name" { type = string }
variable "location" { type = string }

variable "sku" {
  description = "Basic, Standard or Premium. Private endpoints and geo-replication need Premium."
  type        = string
  default     = "Standard"

  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.sku)
    error_message = "sku must be Basic, Standard or Premium."
  }
}

variable "kubelet_principal_id" {
  description = "AKS kubelet identity principal id, granted AcrPull. Null skips the assignment."
  type        = string
  default     = null
}

variable "public_network_access_enabled" {
  description = "Premium only. Set false to force pulls over a private endpoint."
  type        = bool
  default     = true
}

variable "zone_redundancy_enabled" {
  type    = bool
  default = false
}

variable "geo_replication_locations" {
  description = "Premium only. Extra regions to replicate images to."
  type        = list(string)
  default     = []
}

variable "untagged_retention_days" {
  description = "Days before untagged manifests are purged. Keeps storage cost bounded."
  type        = number
  default     = 14
}

variable "content_trust_enabled" {
  type    = bool
  default = false
}

variable "tags" {
  type    = map(string)
  default = {}
}
