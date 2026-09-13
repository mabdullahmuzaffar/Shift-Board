variable "subscription_id" {
  description = "Target Azure subscription id. Required by azurerm 4.x."
  type        = string
}

variable "resource_group_name" {
  type    = string
  default = "rg-shiftboard-tfstate"
}

variable "location" {
  type    = string
  default = "westeurope"
}

variable "storage_account_name" {
  description = "Globally unique, 3-24 lowercase alphanumeric characters."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.storage_account_name))
    error_message = "Storage account names must be 3-24 lowercase alphanumeric characters."
  }
}

variable "pipeline_principal_ids" {
  description = "Service principal object ids granted Storage Blob Data Contributor, keyed by name."
  type        = map(string)
  default     = {}
}

variable "enable_delete_lock" {
  type    = bool
  default = true
}
