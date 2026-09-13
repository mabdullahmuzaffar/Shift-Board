variable "vault_name" {
  description = "Globally unique vault name, 3-24 chars."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9-]{3,24}$", var.vault_name))
    error_message = "Key Vault names must be 3-24 alphanumeric or hyphen characters."
  }
}

variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "tenant_id" { type = string }
variable "log_analytics_workspace_id" { type = string }

variable "private_endpoint_subnet_id" {
  type    = string
  default = null
}

variable "private_dns_zone_id" {
  type    = string
  default = null
}

variable "sku_name" {
  type    = string
  default = "standard"
}

variable "purge_protection_enabled" {
  description = "Must be true in prod. Once enabled it cannot be turned off, so dev leaves it false to allow clean teardown."
  type        = bool
  default     = false
}

variable "soft_delete_retention_days" {
  type    = number
  default = 7
}

variable "public_network_access_enabled" {
  type    = bool
  default = true
}

variable "allowed_ip_rules" {
  type    = list(string)
  default = []
}

variable "secret_reader_principal_ids" {
  description = "Principals granted Key Vault Secrets User, keyed by name."
  type        = map(string)
  default     = {}
}

variable "secret_officer_principal_ids" {
  description = "Principals granted Key Vault Secrets Officer, keyed by name."
  type        = map(string)
  default     = {}
}

variable "tags" {
  type    = map(string)
  default = {}
}
