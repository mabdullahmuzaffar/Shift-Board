variable "name_prefix" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "aks_subnet_id" { type = string }
variable "log_analytics_workspace_id" { type = string }

variable "kubernetes_version" {
  description = "AKS minor version. Pin it: letting Azure choose makes plans non-deterministic."
  type        = string
  default     = "1.31"
}

variable "sku_tier" {
  description = "Free, Standard or Premium. Standard buys the uptime SLA and is required for prod."
  type        = string
  default     = "Standard"

  validation {
    condition     = contains(["Free", "Standard", "Premium"], var.sku_tier)
    error_message = "sku_tier must be Free, Standard or Premium."
  }
}

variable "admin_group_object_ids" {
  description = "Entra group object ids granted cluster-admin through Azure RBAC."
  type        = list(string)
  default     = []
}

variable "local_account_disabled" {
  description = "Disable the local admin kubeconfig. Should be true everywhere except a throwaway lab."
  type        = bool
  default     = true
}

variable "system_node_vm_size" {
  type    = string
  default = "Standard_D2s_v5"
}

variable "system_node_min_count" {
  type    = number
  default = 1
}

variable "system_node_max_count" {
  type    = number
  default = 3
}

variable "user_node_vm_size" {
  type    = string
  default = "Standard_D2s_v5"
}

variable "user_node_min_count" {
  type    = number
  default = 1
}

variable "user_node_max_count" {
  type    = number
  default = 5
}

variable "user_node_spot_enabled" {
  description = "Run the application pool on Spot. Big cost saving, but nodes can be evicted with 30s notice."
  type        = bool
  default     = false
}

variable "availability_zones" {
  description = "Zones for node pools. Empty list means zonal placement is left to Azure."
  type        = list(string)
  default     = ["1", "2", "3"]
}

variable "pod_cidr" {
  description = "Overlay CIDR for pod IPs. Must not overlap the VNet."
  type        = string
  default     = "10.244.0.0/16"
}

variable "service_cidr" {
  description = "CIDR for ClusterIP Services. Must not overlap the VNet or pod_cidr."
  type        = string
  default     = "10.0.16.0/20"
}

variable "dns_service_ip" {
  description = "kube-dns address. Must sit inside service_cidr."
  type        = string
  default     = "10.0.16.10"
}

variable "outbound_type" {
  description = "loadBalancer for simplicity, userDefinedRouting when egress goes via a firewall."
  type        = string
  default     = "loadBalancer"
}

variable "automatic_upgrade_channel" {
  description = "patch keeps the cluster on supported patches without surprise minor bumps."
  type        = string
  default     = "patch"
}

variable "node_os_upgrade_channel" {
  type    = string
  default = "NodeImage"
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "private_cluster_enabled" {
  description = "Give the API server a private endpoint. True in prod; false in dev so kubectl works without a jumpbox."
  type        = bool
  default     = false
}

variable "private_cluster_dns_zone_id" {
  description = "Private DNS zone for the API server, or \"System\" to let AKS manage it."
  type        = string
  default     = "System"
}

variable "api_server_authorized_ip_ranges" {
  description = "CIDRs allowed to reach a public API server. Ignored when the cluster is private. Empty means unrestricted, so set it in prod."
  type        = list(string)
  default     = []
}

variable "os_disk_type" {
  description = "Managed or Ephemeral. Ephemeral is faster and cheaper but needs a VM size whose cache exceeds the disk size."
  type        = string
  default     = "Managed"

  validation {
    condition     = contains(["Managed", "Ephemeral"], var.os_disk_type)
    error_message = "os_disk_type must be Managed or Ephemeral."
  }
}
