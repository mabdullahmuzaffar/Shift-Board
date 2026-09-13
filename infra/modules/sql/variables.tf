variable "server_name" {
  description = "Globally unique logical server name."
  type        = string
}

variable "database_name" { type = string }
variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "tenant_id" { type = string }
variable "private_endpoint_subnet_id" { type = string }
variable "private_dns_zone_id" { type = string }
variable "log_analytics_workspace_id" { type = string }

variable "entra_admin_login" {
  description = "Display name of the Entra group that administers the server."
  type        = string
}

variable "entra_admin_object_id" {
  description = "Object id of that Entra group."
  type        = string
}

variable "sku_name" {
  description = "e.g. GP_S_Gen5_1 (serverless, cheap for dev) or GP_Gen5_2."
  type        = string
  default     = "GP_S_Gen5_1"
}

variable "max_size_gb" {
  type    = number
  default = 32
}

variable "zone_redundant" {
  type    = bool
  default = false
}

variable "backup_storage_redundancy" {
  description = "Local, Zone or Geo. Geo is required to restore into another region."
  type        = string
  default     = "Local"

  validation {
    condition     = contains(["Local", "Zone", "Geo", "GeoZone"], var.backup_storage_redundancy)
    error_message = "backup_storage_redundancy must be Local, Zone, Geo or GeoZone."
  }
}

variable "point_in_time_retention_days" {
  description = "PITR window. 7 days is the default; prod uses more."
  type        = number
  default     = 7

  validation {
    condition     = var.point_in_time_retention_days >= 1 && var.point_in_time_retention_days <= 35
    error_message = "point_in_time_retention_days must be between 1 and 35."
  }
}

variable "enable_long_term_retention" {
  type    = bool
  default = false
}

variable "threat_detection_enabled" {
  type    = bool
  default = true
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "audit_retention_days" {
  description = "Audit log retention in days. Must be at least 90 to satisfy common compliance baselines."
  type        = number
  default     = 90

  validation {
    condition     = var.audit_retention_days == 0 || var.audit_retention_days >= 90
    error_message = "audit_retention_days must be 0 (workspace-governed) or at least 90."
  }
}
