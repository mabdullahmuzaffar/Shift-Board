variable "name_prefix" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }


variable "retention_in_days" {
  type    = number
  default = 30

  validation {
    condition     = var.retention_in_days >= 30 && var.retention_in_days <= 730
    error_message = "Log Analytics retention must be between 30 and 730 days."
  }
}

variable "container_log_retention_days" {
  type    = number
  default = 30
}

variable "daily_quota_gb" {
  description = "Ingestion cap in GB per day. -1 disables the cap (not advised)."
  type        = number
  default     = 5
}

variable "oncall_emails" {
  description = "On-call email recipients, keyed by name."
  type        = map(string)
  default     = {}
}

variable "oncall_webhooks" {
  description = "Webhook receivers (Slack, PagerDuty, Teams), keyed by name."
  type        = map(string)
  default     = {}
}






variable "tags" {
  type    = map(string)
  default = {}
}
