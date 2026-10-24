resource "google_monitoring_notification_channel" "email" {
  display_name = "Lab email"
  type         = "email"

  labels = {
    email_address = var.alert_email
  }
}

locals {
  alerts = {
    vpn_tunnel_down = {
      name     = "VPN tunnel down"
      resource = "vpn_gateway"
      metric   = "vpn.googleapis.com/tunnel_established"
      group_by = "metric.label.tunnel_name"
    }
    bgp_session_down = {
      name     = "BGP session down"
      resource = "gce_router"
      metric   = "router.googleapis.com/bgp/session_up"
      group_by = "metric.label.bgp_peer_name"
    }
  }
}

resource "google_monitoring_alert_policy" "lab" {
  for_each = local.alerts

  display_name = each.value.name
  combiner     = "OR"

  conditions {
    display_name = "${each.value.name} (below 1 for 5 min)"

    condition_threshold {
      filter          = "resource.type = \"${each.value.resource}\" AND metric.type = \"${each.value.metric}\""
      comparison      = "COMPARISON_LT"
      threshold_value = 1
      duration        = "300s"

      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_MEAN"
        cross_series_reducer = "REDUCE_MIN"
        group_by_fields      = [each.value.group_by]
      }

      # "Missing data empty" in the console. Without it, the nightly
      # teardown (tunnel deleted, metric stops) fires an alert every night.
      evaluation_missing_data = "EVALUATION_MISSING_DATA_INACTIVE"
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.id]

  alert_strategy {
    auto_close = "1800s"
  }

  documentation {
    mime_type = "text/markdown"
    content   = "Check layer by layer: tunnel status, then BGP peer status, then router logs. If this fired at teardown time, evaluation_missing_data is wrong."
  }
}
