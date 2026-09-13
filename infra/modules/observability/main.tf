# Log Analytics is the sink for control-plane logs, container stdout via
# Container Insights, and platform diagnostics. In-cluster Prometheus handles
# metrics and alerting (see gitops/platform), so this module deliberately
# does not provision Azure Managed Prometheus -- that arrives in project 8
# when Managed Grafana and Argo Rollouts analysis need it.

resource "azurerm_log_analytics_workspace" "this" {
  name                = "log-${var.name_prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "PerGB2018"
  retention_in_days   = var.retention_in_days

  # Hard cap so a log storm cannot generate an unbounded bill. Ingestion is
  # throttled once the cap is hit rather than silently charging.
  daily_quota_gb = var.daily_quota_gb

  tags = var.tags
}

resource "azurerm_log_analytics_workspace_table" "container_log_v2" {
  workspace_id = azurerm_log_analytics_workspace.this.id
  name         = "ContainerLogV2"
  # Container stdout is high volume and low long-term value; keeping it for
  # 30 days while the workspace default is longer cuts cost noticeably.
  retention_in_days = var.container_log_retention_days
}

resource "azurerm_monitor_action_group" "oncall" {
  name                = "ag-${var.name_prefix}-oncall"
  resource_group_name = var.resource_group_name
  short_name          = substr(replace(var.name_prefix, "-", ""), 0, 12)
  tags                = var.tags

  dynamic "email_receiver" {
    for_each = var.oncall_emails
    content {
      name                    = "email-${email_receiver.key}"
      email_address           = email_receiver.value
      use_common_alert_schema = true
    }
  }

  dynamic "webhook_receiver" {
    for_each = var.oncall_webhooks
    content {
      name                    = "webhook-${webhook_receiver.key}"
      service_uri             = webhook_receiver.value
      use_common_alert_schema = true
    }
  }
}
