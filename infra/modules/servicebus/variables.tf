variable "namespace_name" {
  description = "Globally unique Service Bus namespace name."
  type        = string
}

variable "queue_name" {
  type    = string
  default = "roster-events"
}

variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "log_analytics_workspace_id" { type = string }

variable "sku" {
  type    = string
  default = "Standard"

  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.sku)
    error_message = "sku must be Basic, Standard or Premium."
  }
}

variable "capacity" {
  description = "Premium messaging units (1, 2, 4, 8, 16)."
  type        = number
  default     = 1
}

variable "max_delivery_count" {
  description = "Deliveries before a message is dead-lettered."
  type        = number
  default     = 5
}

variable "lock_duration" {
  description = "ISO-8601 peek-lock duration. Must exceed worst-case handler time. Max PT5M."
  type        = string
  default     = "PT1M"
}

variable "message_ttl" {
  type    = string
  default = "P7D"
}

variable "max_size_in_megabytes" {
  type    = number
  default = 1024
}

variable "partitioning_enabled" {
  type    = bool
  default = false
}

variable "public_network_access_enabled" {
  type    = bool
  default = true
}

variable "sender_principal_ids" {
  description = "Principals granted Data Sender on the queue, keyed by name."
  type        = map(string)
  default     = {}
}

variable "receiver_principal_ids" {
  description = "Principals granted Data Receiver on the queue, keyed by name."
  type        = map(string)
  default     = {}
}

variable "tags" {
  type    = map(string)
  default = {}
}
