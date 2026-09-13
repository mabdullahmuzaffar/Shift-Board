variable "name_prefix" { type = string }
variable "resource_group_name" { type = string }

variable "resource_group_id" {
  description = "Full resource group id, needed for the consumption budget."
  type        = string
}

variable "action_group_id" {
  description = "Action group created by the observability module."
  type        = string
}

variable "oncall_emails" {
  description = "Recipients for budget notifications, keyed by name."
  type        = map(string)
  default     = {}
}

variable "servicebus_namespace_id" {
  description = "Null disables the dead-letter alert."
  type        = string
  default     = null
}

variable "sql_database_id" {
  description = "Null disables the SQL alerts."
  type        = string
  default     = null
}

variable "dead_letter_threshold" {
  description = "Dead-lettered message count that triggers a page. 0 means any dead letter pages."
  type        = number
  default     = 0
}

variable "monthly_budget_amount" {
  description = "Monthly budget in subscription currency. Null disables the budget."
  type        = number
  default     = null
}

variable "budget_start_date" {
  description = "First day of a month in RFC3339, e.g. 2026-10-01T00:00:00Z."
  type        = string
  default     = "2026-10-01T00:00:00Z"
}

variable "tags" {
  type    = map(string)
  default = {}
}
