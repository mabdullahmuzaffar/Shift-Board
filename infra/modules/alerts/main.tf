# Platform metric alerts and the spend budget.
#
# Separated from the observability module because these alerts must reference
# resource ids (Service Bus namespace, SQL database) that are created by
# sibling modules. Terraform cannot create an alert scoped to a resource
# built in the same module instance, and instantiating the observability
# module twice would provision a second Log Analytics workspace -- paying
# twice for nothing.
#
# Application SLO alerts are PrometheusRules in observability/alerts/,
# evaluated in-cluster. The ones here fire on Azure resource metrics that
# never reach Prometheus at all.

resource "azurerm_monitor_metric_alert" "servicebus_dead_letters" {
  count = var.servicebus_namespace_id == null ? 0 : 1

  name                = "alert-${var.name_prefix}-dlq-depth"
  resource_group_name = var.resource_group_name
  scopes              = [var.servicebus_namespace_id]
  description         = "Messages are accumulating in the dead-letter queue, so events are being dropped."
  severity            = 1
  frequency           = "PT5M"
  window_size         = "PT15M"
  tags                = var.tags

  criteria {
    metric_namespace = "Microsoft.ServiceBus/namespaces"
    metric_name      = "DeadletteredMessages"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = var.dead_letter_threshold
  }

  action {
    action_group_id = var.action_group_id
  }
}

resource "azurerm_monitor_metric_alert" "sql_dtu" {
  count = var.sql_database_id == null ? 0 : 1

  name                = "alert-${var.name_prefix}-sql-cpu"
  resource_group_name = var.resource_group_name
  scopes              = [var.sql_database_id]
  description         = "Database CPU is saturated; queries will start timing out."
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"
  tags                = var.tags

  criteria {
    metric_namespace = "Microsoft.Sql/servers/databases"
    metric_name      = "cpu_percent"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 85
  }

  action {
    action_group_id = var.action_group_id
  }
}

resource "azurerm_monitor_metric_alert" "sql_storage" {
  count = var.sql_database_id == null ? 0 : 1

  name                = "alert-${var.name_prefix}-sql-storage"
  resource_group_name = var.resource_group_name
  scopes              = [var.sql_database_id]
  description         = "Database is close to its size limit; writes will begin failing."
  severity            = 2
  frequency           = "PT15M"
  window_size         = "PT1H"
  tags                = var.tags

  criteria {
    metric_namespace = "Microsoft.Sql/servers/databases"
    metric_name      = "storage_percent"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 80
  }

  action {
    action_group_id = var.action_group_id
  }
}

# Cost guardrail. Easy to skip, and the reason unattended lab clusters
# generate surprise bills.
resource "azurerm_consumption_budget_resource_group" "this" {
  count = var.monthly_budget_amount == null ? 0 : 1

  name              = "budget-${var.name_prefix}"
  resource_group_id = var.resource_group_id

  amount     = var.monthly_budget_amount
  time_grain = "Monthly"

  time_period {
    start_date = var.budget_start_date
  }

  notification {
    enabled        = true
    threshold      = 80
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = values(var.oncall_emails)
  }

  notification {
    enabled        = true
    threshold      = 100
    operator       = "GreaterThan"
    threshold_type = "Forecasted"
    contact_emails = values(var.oncall_emails)
  }
}
