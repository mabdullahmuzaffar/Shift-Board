variable "name_prefix" { type = string }
variable "resource_group_name" { type = string }
variable "log_analytics_workspace_id" { type = string }

variable "sku_name" {
  description = "Standard_AzureFrontDoor or Premium_AzureFrontDoor. Private Link origins need Premium."
  type        = string
  default     = "Standard_AzureFrontDoor"

  validation {
    condition     = contains(["Standard_AzureFrontDoor", "Premium_AzureFrontDoor"], var.sku_name)
    error_message = "sku_name must be Standard_AzureFrontDoor or Premium_AzureFrontDoor."
  }
}

variable "origin_hostname" {
  description = "Public hostname or IP of the cluster ingress controller."
  type        = string
}

variable "origin_host_header" {
  description = "Host header sent to the origin. Defaults to origin_hostname."
  type        = string
  default     = null
}

variable "certificate_name_check_enabled" {
  description = "Set false only when the origin serves a self-signed or mismatched certificate."
  type        = bool
  default     = true
}

variable "custom_domain_id" {
  type    = string
  default = null
}

variable "waf_enabled" {
  type    = bool
  default = true
}

variable "waf_mode" {
  description = "Detection first, then Prevention once the rule set is tuned against real traffic."
  type        = string
  default     = "Prevention"

  validation {
    condition     = contains(["Detection", "Prevention"], var.waf_mode)
    error_message = "waf_mode must be Detection or Prevention."
  }
}

variable "tags" {
  type    = map(string)
  default = {}
}
