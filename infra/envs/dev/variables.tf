variable "subscription_id" {
  description = "Azure subscription id. Required explicitly by azurerm 4.x."
  type        = string
}

variable "tenant_id" {
  description = "Entra tenant id."
  type        = string
}

variable "location" {
  type    = string
  default = "westeurope"
}

variable "name_suffix" {
  description = <<-EOT
    Short unique suffix for globally-unique names (ACR, Key Vault, SQL,
    Service Bus). Use your initials plus digits, e.g. "ar01". Without this
    two people cannot deploy the project into the same tenant.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{2,6}$", var.name_suffix))
    error_message = "name_suffix must be 2-6 lowercase alphanumeric characters."
  }
}

variable "aks_admin_group_object_ids" {
  description = "Entra group object ids granted cluster-admin. Get one with: az ad group show --group <name> --query id -o tsv"
  type        = list(string)
  default     = []
}

variable "sql_admin_group_name" {
  description = "Display name of the Entra group that administers Azure SQL."
  type        = string
}

variable "sql_admin_group_object_id" {
  description = "Object id of that group."
  type        = string
}

variable "oncall_emails" {
  description = "Alert recipients, keyed by name."
  type        = map(string)
  default     = {}
}

variable "monthly_budget_amount" {
  description = "Monthly spend budget. Set this -- an idle AKS cluster still bills."
  type        = number
  default     = 150
}

variable "pipeline_principal_ids" {
  description = "Pipeline service principal object ids, granted Key Vault Secrets Officer for bootstrap."
  type        = map(string)
  default     = {}
}
