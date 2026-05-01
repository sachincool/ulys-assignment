resource "google_monitoring_notification_channel" "email" {
  count = var.alert_email == "" ? 0 : 1

  display_name = "ulys ops email"
  type         = "email"
  labels = {
    email_address = var.alert_email
  }

  depends_on = [google_project_service.services]
}

# Uptime check on the api LoadBalancer's static IP. Free tier covers
# ~1M check executions/month; this config burns ~262k.
resource "google_monitoring_uptime_check_config" "api" {
  display_name = "api /healthz"
  timeout      = "10s"
  period       = "60s"

  http_check {
    path           = "/healthz"
    port           = 80
    request_method = "GET"
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.project
      host       = google_compute_address.api_lb.address
    }
  }

  depends_on = [google_project_service.services]
}

resource "google_monitoring_alert_policy" "api_down" {
  display_name = "api /healthz down"
  combiner     = "OR"

  conditions {
    display_name = "uptime check failing"
    condition_threshold {
      filter          = "metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\" AND resource.type=\"uptime_url\" AND metric.label.check_id=\"${google_monitoring_uptime_check_config.api.uptime_check_id}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 1
      duration        = "300s"

      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_NEXT_OLDER"
        cross_series_reducer = "REDUCE_COUNT_FALSE"
        group_by_fields      = ["resource.label.host"]
      }

      trigger { count = 1 }
    }
  }

  notification_channels = [for c in google_monitoring_notification_channel.email : c.id]

  alert_strategy {
    auto_close = "1800s"
  }
}

# $20 budget alert — the brief's required threshold. Fires at 100%.
resource "google_billing_budget" "dev" {
  billing_account = var.billing_account
  display_name    = "ulys-dev budget"

  budget_filter {
    # Cloud Billing API normalizes "projects/<id>" to "projects/<number>" on
    # read, so terraform refresh always sees a synthetic diff. Both forms
    # refer to the same project; ignore_changes pins the diff out.
    projects = ["projects/${var.project}"]
  }

  lifecycle {
    ignore_changes = [budget_filter[0].projects]
  }

  amount {
    specified_amount {
      # currency_code intentionally omitted — the API defaults to the
      # billing account's native currency, keeping this code portable.
      units = tostring(var.budget_amount)
    }
  }

  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "CURRENT_SPEND"
  }

  dynamic "all_updates_rule" {
    for_each = length(google_monitoring_notification_channel.email) > 0 ? [1] : []
    content {
      monitoring_notification_channels = [google_monitoring_notification_channel.email[0].id]
    }
  }

  depends_on = [google_project_service.services]
}
