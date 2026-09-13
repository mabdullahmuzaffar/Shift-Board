variable "name_prefix" {
  description = "Short identifier used in resource names, e.g. shiftboard-dev."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group that holds the networking resources."
  type        = string
}

variable "vnet_cidr" {
  description = "Address space for the virtual network."
  type        = string

  validation {
    condition     = can(cidrhost(var.vnet_cidr, 0))
    error_message = "vnet_cidr must be a valid CIDR block."
  }
}

variable "aks_subnet_cidr" {
  description = "Subnet for AKS node IPs. With CNI Overlay this needs one IP per node, not per pod."
  type        = string
}

variable "private_endpoint_subnet_cidr" {
  description = "Subnet that hosts private endpoints for SQL, Key Vault and Service Bus."
  type        = string
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
