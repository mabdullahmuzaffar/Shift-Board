output "dead_letter_alert_id" {
  value       = var.servicebus_namespace_id == null ? null : azurerm_monitor_metric_alert.servicebus_dead_letters[0].id
  description = "Dead-letter depth alert id, or null when Service Bus was not supplied."
}

output "sql_alert_ids" {
  value = var.sql_database_id == null ? [] : [
    azurerm_monitor_metric_alert.sql_dtu[0].id,
    azurerm_monitor_metric_alert.sql_storage[0].id,
  ]
  description = "SQL CPU and storage alert ids."
}
