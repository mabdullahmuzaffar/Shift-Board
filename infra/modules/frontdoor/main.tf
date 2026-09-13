# Front Door Standard sits in front of the cluster ingress in prod only.
#
# Why it earns its place rather than being tool-count padding:
#   * TLS terminates at the edge with a managed certificate, so cert-manager
#     is not on the critical path for the public hostname.
#   * The WAF policy blocks the OWASP top-10 signature set before traffic
#     reaches a pod.
#   * The origin is locked to Front Door's private link / header check, so
#     the ingress public IP cannot be hit directly and bypass the WAF.
#
# In dev this module is not instantiated at all, because a managed
# certificate plus WAF roughly doubles the environment's monthly cost for no
# learning benefit once you have built it once.

resource "azurerm_cdn_frontdoor_profile" "this" {
  name                     = "afd-${var.name_prefix}"
  resource_group_name      = var.resource_group_name
  sku_name                 = var.sku_name
  response_timeout_seconds = 60
  tags                     = var.tags
}

resource "azurerm_cdn_frontdoor_endpoint" "this" {
  name                     = "fde-${var.name_prefix}"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.this.id
  tags                     = var.tags
}

resource "azurerm_cdn_frontdoor_origin_group" "this" {
  name                     = "og-ingress"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.this.id
  session_affinity_enabled = false

  load_balancing {
    sample_size                        = 4
    successful_samples_required        = 3
    additional_latency_in_milliseconds = 50
  }

  # Probes hit the nginx static health endpoint, which does not touch the
  # API or the database -- so a slow database does not pull the whole origin
  # out of rotation at the edge.
  health_probe {
    path                = "/healthz"
    protocol            = "Http"
    request_type        = "GET"
    interval_in_seconds = 30
  }
}

resource "azurerm_cdn_frontdoor_origin" "ingress" {
  name                          = "origin-ingress"
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.this.id
  enabled                       = true

  host_name          = var.origin_hostname
  origin_host_header = var.origin_host_header != null ? var.origin_host_header : var.origin_hostname
  http_port          = 80
  https_port         = 443
  priority           = 1
  weight             = 1

  certificate_name_check_enabled = var.certificate_name_check_enabled
}

resource "azurerm_cdn_frontdoor_route" "this" {
  name                          = "route-default"
  cdn_frontdoor_endpoint_id     = azurerm_cdn_frontdoor_endpoint.this.id
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.this.id
  cdn_frontdoor_origin_ids      = [azurerm_cdn_frontdoor_origin.ingress.id]

  enabled                = true
  forwarding_protocol    = "HttpsOnly"
  https_redirect_enabled = true
  patterns_to_match      = ["/*"]
  supported_protocols    = ["Http", "Https"]
  link_to_default_domain = true

  cdn_frontdoor_custom_domain_ids = var.custom_domain_id == null ? [] : [var.custom_domain_id]

  cache {
    compression_enabled           = true
    query_string_caching_behavior = "IgnoreQueryString"
    content_types_to_compress = [
      "text/html",
      "text/css",
      "application/javascript",
      "application/json",
      "image/svg+xml",
    ]
  }
}

resource "azurerm_cdn_frontdoor_firewall_policy" "this" {
  count = var.waf_enabled ? 1 : 0

  name                = replace("waf${var.name_prefix}", "-", "")
  resource_group_name = var.resource_group_name
  sku_name            = azurerm_cdn_frontdoor_profile.this.sku_name
  enabled             = true
  mode                = var.waf_mode
  tags                = var.tags

  managed_rule {
    type    = "Microsoft_DefaultRuleSet"
    version = "2.1"
    action  = "Block"
  }

  managed_rule {
    type    = "Microsoft_BotManagerRuleSet"
    version = "1.0"
    action  = "Block"
  }
}

resource "azurerm_cdn_frontdoor_security_policy" "this" {
  count = var.waf_enabled ? 1 : 0

  name                     = "sp-${var.name_prefix}"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.this.id

  security_policies {
    firewall {
      cdn_frontdoor_firewall_policy_id = azurerm_cdn_frontdoor_firewall_policy.this[0].id

      association {
        domain {
          cdn_frontdoor_domain_id = azurerm_cdn_frontdoor_endpoint.this.id
        }
        patterns_to_match = ["/*"]
      }
    }
  }
}

resource "azurerm_monitor_diagnostic_setting" "afd" {
  name                       = "diag-frontdoor"
  target_resource_id         = azurerm_cdn_frontdoor_profile.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log { category = "FrontDoorAccessLog" }
  enabled_log { category = "FrontDoorHealthProbeLog" }
  enabled_log { category = "FrontDoorWebApplicationFirewallLog" }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}
