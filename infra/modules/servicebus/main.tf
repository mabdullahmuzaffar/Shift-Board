resource "azurerm_servicebus_namespace" "this" {
  # checkov:skip=CKV_AZURE_201:Customer-managed keys require Premium; Microsoft-managed encryption at rest is the documented trade-off for Standard. Revisit if the data classification changes.
  # checkov:skip=CKV_AZURE_199:Double encryption is Premium-only, same trade-off as above.
  # checkov:skip=CKV_AZURE_204:public_network_access_enabled is driven by var and forced false on Premium in prod; Standard has no private endpoint support.
  name                = var.namespace_name
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = var.sku
  capacity            = var.sku == "Premium" ? var.capacity : 0

  # Local (SAS key) auth disabled: producers and consumers authenticate with
  # workload identity, so no connection string exists anywhere.
  local_auth_enabled = false

  minimum_tls_version = "1.2"

  # Satisfies CKV_AZURE_202. Also lets the namespace itself authenticate
  # outward for future customer-managed-key support without a rewrite.
  identity {
    type = "SystemAssigned"
  }

  public_network_access_enabled = var.sku == "Premium" ? var.public_network_access_enabled : true

  tags = var.tags
}

resource "azurerm_servicebus_queue" "this" {
  name         = var.queue_name
  namespace_id = azurerm_servicebus_namespace.this.id

  # Duplicate detection uses the message_id that shift-api sets to the
  # event_id. This is belt-and-braces: the worker's own idempotency ledger is
  # the real guarantee, since dedup only covers a rolling window.
  requires_duplicate_detection            = true
  duplicate_detection_history_time_window = "PT10M"

  # After 5 failed deliveries the message is dead-lettered rather than
  # retried forever. The DLQ depth has its own alert rule.
  max_delivery_count = var.max_delivery_count

  # Lock duration must exceed the worst-case handler time, or a slow handler
  # loses its lock mid-work and the message is redelivered while still
  # being processed.
  lock_duration = var.lock_duration

  default_message_ttl                  = var.message_ttl
  dead_lettering_on_message_expiration = true
  max_size_in_megabytes                = var.max_size_in_megabytes
  partitioning_enabled                 = var.sku == "Premium" ? false : var.partitioning_enabled
}

# Dedicated queue for operators to replay dead letters into after a fix.
resource "azurerm_servicebus_queue" "replay" {
  name                                 = "${var.queue_name}-replay"
  namespace_id                         = azurerm_servicebus_namespace.this.id
  max_delivery_count                   = var.max_delivery_count
  lock_duration                        = var.lock_duration
  default_message_ttl                  = var.message_ttl
  dead_lettering_on_message_expiration = true
}

# Least privilege: the API can only send, the worker can only receive.
# A compromised API pod cannot drain the queue.
resource "azurerm_role_assignment" "senders" {
  for_each = var.sender_principal_ids

  scope                = azurerm_servicebus_queue.this.id
  role_definition_name = "Azure Service Bus Data Sender"
  principal_id         = each.value
}

resource "azurerm_role_assignment" "receivers" {
  for_each = var.receiver_principal_ids

  scope                = azurerm_servicebus_queue.this.id
  role_definition_name = "Azure Service Bus Data Receiver"
  principal_id         = each.value
}

resource "azurerm_monitor_diagnostic_setting" "sb" {
  name                       = "diag-servicebus"
  target_resource_id         = azurerm_servicebus_namespace.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log { category = "OperationalLogs" }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}
