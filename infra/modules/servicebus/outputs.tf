output "namespace_name" {
  value = azurerm_servicebus_namespace.this.name
}

output "namespace_id" {
  value = azurerm_servicebus_namespace.this.id
}

output "queue_name" {
  value = azurerm_servicebus_queue.this.name
}

output "replay_queue_name" {
  value = azurerm_servicebus_queue.replay.name
}
